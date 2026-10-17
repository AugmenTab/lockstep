{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

{- | Applies pending migrations (contract C-P1.2 E4). Uses libpq's simple query
protocol directly because migrations may hold several statements, which
Orville's parameterised execution cannot run. Each migration runs in its own
transaction that holds an advisory lock, re-plans against the ledger it reads
inside that transaction, and writes its ledger row with its DDL.
-}
module Lockstep.Persistence.Migrate
  ( MigrateFailure (..)
  , applyPending
  ) where

import Control.Exception (bracket)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.String.Interpolate qualified as Interpolate
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Database.PostgreSQL.LibPQ qualified as LibPQ
import Flipstone.Prelude
import Text.Read (readMaybe)
import Text.Show (show)

import Lockstep.Foundation.SystemConfig (DatabaseConfig)
import Lockstep.Persistence.Connection (connectionString)
import Lockstep.Persistence.Migration
  ( AppliedMigration (..)
  , Migration (..)
  , MigrationId
  , MigrationRefusal
  , checksumText
  , migrationChecksum
  , migrationIdInt
  , mkChecksum
  , mkMigrationId
  , planMigrations
  )

data MigrateFailure
  = MigrateConnectionFailed String
  | MigratePlanRefused MigrationRefusal
  | MigrationSqlFailed MigrationId [MigrationId]
  | MigrateLedgerUnreadable String

-- | Identifies Lockstep's migration lock among advisory locks.
migrationLockKey :: BS.ByteString
migrationLockKey =
  "7310428871"

applyPending :: DatabaseConfig -> [Migration] -> IO (Either MigrateFailure [MigrationId])
applyPending config list =
  bracket
    (LibPQ.connectdb (BS8.pack (connectionString config)))
    LibPQ.finish
    ( \conn -> do
        status <- LibPQ.status conn
        if status == LibPQ.ConnectionOk
          then do
            -- The ledger DDL is idempotent; its "already exists" NOTICE is noise.
            _ <- run conn "SET client_min_messages TO warning"
            loop conn []
          else Left . MigrateConnectionFailed <$> connectionMessage conn
    )
 where
  loop conn applied = do
    step <- applyNext conn list
    case step of
      Left failure ->
        pure . Left $
          case failure of
            MigrationSqlFailed failedId _ -> MigrationSqlFailed failedId (L.reverse applied)
            other -> other
      Right Nothing ->
        pure (Right (L.reverse applied))
      Right (Just appliedId') ->
        loop conn (appliedId' : applied)

{- | One transaction: lock, ensure the ledger exists, re-plan, apply the first
pending migration (if any) and record it.
-}
applyNext :: LibPQ.Connection -> [Migration] -> IO (Either MigrateFailure (Maybe MigrationId))
applyNext conn list = do
  begun <- run conn "BEGIN"
  case begun of
    Left err -> pure (Left (MigrateLedgerUnreadable err))
    Right _ -> do
      result <- inTransaction
      case result of
        Right (Just _) -> commitOr result
        Right Nothing -> commitOr result
        Left _ -> do
          _ <- run conn "ROLLBACK"
          pure result
 where
  commitOr result = do
    committed <- run conn "COMMIT"
    pure $ case committed of
      Left err -> Left (MigrateLedgerUnreadable err)
      Right _ -> result

  inTransaction = do
    prepared <-
      sequenceSteps
        [ run conn ("SELECT pg_advisory_xact_lock(" <> migrationLockKey <> ")")
        , run conn ledgerDdl
        ]
    case prepared of
      Left err -> pure (Left (MigrateLedgerUnreadable err))
      Right () -> do
        ledgerOrErr <- readLedger conn
        case ledgerOrErr of
          Left err -> pure (Left (MigrateLedgerUnreadable err))
          Right ledger ->
            case planMigrations list ledger of
              Left refusal -> pure (Left (MigratePlanRefused refusal))
              Right [] -> pure (Right Nothing)
              Right (next : _) -> applyOne next

  applyOne migration = do
    executed <- run conn (TE.encodeUtf8 (migrationSql migration))
    case executed of
      Left _ -> pure (Left (MigrationSqlFailed (migrationId migration) []))
      Right _ -> do
        recorded <- recordApplied conn migration
        pure $ case recorded of
          Left err -> Left (MigrateLedgerUnreadable err)
          Right () -> Right (Just (migrationId migration))

ledgerDdl :: BS.ByteString
ledgerDdl =
  [Interpolate.i|
CREATE TABLE IF NOT EXISTS lockstep_schema_migrations (
  id integer PRIMARY KEY CHECK (id >= 1),
  description text NOT NULL,
  checksum text NOT NULL,
  applied_at timestamptz NOT NULL DEFAULT clock_timestamp()
)
|]

readLedger :: LibPQ.Connection -> IO (Either String [AppliedMigration])
readLedger conn = do
  resultOrErr <- run conn "SELECT id, checksum FROM lockstep_schema_migrations ORDER BY id"
  case resultOrErr of
    Left err -> pure (Left err)
    Right result -> do
      rows <- LibPQ.ntuples result
      fmap sequenceA . traverse (readRow result) $ rowsUpTo rows
 where
  rowsUpTo (LibPQ.Row n) =
    fmap LibPQ.Row (L.take (fromIntegral n) [0 ..])

  readRow result row = do
    idBytes <- LibPQ.getvalue' result row (LibPQ.Col 0)
    checksumBytes <- LibPQ.getvalue' result row (LibPQ.Col 1)
    pure $
      case (idBytes >>= readMaybe . BS8.unpack >>= mkMigrationId, checksumBytes) of
        (Just appliedId', Just checksum) ->
          Right (AppliedMigration appliedId' (mkChecksum (TE.decodeUtf8Lenient checksum)))
        _ ->
          Left "unreadable row in lockstep_schema_migrations"

recordApplied :: LibPQ.Connection -> Migration -> IO (Either String ())
recordApplied conn migration = do
  let
    param text =
      Just (LibPQ.invalidOid, TE.encodeUtf8 text, LibPQ.Text)
  mbResult <-
    LibPQ.execParams
      conn
      "INSERT INTO lockstep_schema_migrations (id, description, checksum) VALUES ($1::integer, $2, $3)"
      [ param (T.pack (show (migrationIdInt (migrationId migration))))
      , param (migrationDescription migration)
      , param (checksumText (migrationChecksum migration))
      ]
      LibPQ.Text
  fmap (() <$) (checked conn mbResult)

sequenceSteps :: [IO (Either String a)] -> IO (Either String ())
sequenceSteps steps =
  case steps of
    [] -> pure (Right ())
    step : rest -> do
      result <- step
      case result of
        Left err -> pure (Left err)
        Right _ -> sequenceSteps rest

-- | Runs SQL with the simple query protocol (several statements allowed).
run :: LibPQ.Connection -> BS.ByteString -> IO (Either String LibPQ.Result)
run conn sql =
  LibPQ.exec conn sql >>= checked conn

checked :: LibPQ.Connection -> Maybe LibPQ.Result -> IO (Either String LibPQ.Result)
checked conn mbResult =
  case mbResult of
    Nothing -> Left <$> connectionMessage conn
    Just result -> do
      status <- LibPQ.resultStatus result
      if status == LibPQ.CommandOk || status == LibPQ.TuplesOk
        then pure (Right result)
        else do
          message <- LibPQ.resultErrorMessage result
          pure (Left (maybe "unknown error" (T.unpack . TE.decodeUtf8Lenient) message))

connectionMessage :: LibPQ.Connection -> IO String
connectionMessage conn =
  maybe "unknown connection error" (T.unpack . TE.decodeUtf8Lenient) <$> LibPQ.errorMessage conn
