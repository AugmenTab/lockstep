{-# LANGUAGE OverloadedStrings #-}

{- | Database operations as the rest of the application sees them (ADR-0002,
contract C-P1.2): readiness that never pretends, migrations under the backup
policy, and the service-start projection. Web uses this module, never
Persistence.
-}
module Lockstep.Application.Database
  ( DatabaseRuntime
  , openDatabase
  , closeDatabase
  , NotReadyReason (..)
  , Readiness (..)
  , classifyConnectionFailure
  , readinessCode
  , revisionNumber
  , checkReadiness
  , withDatabase
  , SchemaStatus (..)
  , schemaStatus
  , MigrateError (..)
  , renderMigrateError
  , runMigrations
  , migrateWithPolicy
  , ServiceStarts (..)
  , recordServiceStart
  , readServiceStarts
  , SessionLock (..)
  , Locked (..)
  , LockFailure (..)
  , withSessionLock
  ) where

import Control.Exception (SomeException, finally, fromException, throwIO, try)
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Text qualified as T
import Data.Time qualified as Time
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.Connection qualified as Connection
import System.Directory (doesFileExist, getFileSize, getModificationTime)
import System.IO (FilePath)
import Text.Show (Show, show)

import Lockstep.Foundation.Cli (BackupPolicy (..))
import Lockstep.Foundation.SystemConfig (DatabaseConfig)
import Lockstep.Persistence.Connection (connectionString, poolOptions)
import Lockstep.Persistence.Migrate (MigrateFailure (..), applyPending)
import Lockstep.Persistence.Migration
  ( Migration (..)
  , MigrationId
  , MigrationRefusal (..)
  , migrationIdInt
  , planMigrations
  )
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Persistence.Queries qualified as Queries
import Lockstep.Persistence.SessionLocks qualified as SessionLocks

data DatabaseRuntime
  = DatabaseRuntime
  { runtimeConfig :: DatabaseConfig
  , runtimePool :: O.ConnectionPool
  }

-- | Creates the connection pool. No connection is made until first use.
openDatabase :: DatabaseConfig -> IO DatabaseRuntime
openDatabase config =
  DatabaseRuntime config <$> O.createConnectionPool (poolOptions config)

closeDatabase :: DatabaseRuntime -> IO ()
closeDatabase =
  Connection.destroyIdleConnections . runtimePool

data NotReadyReason
  = DatabaseNotConfigured
  | DatabaseUnreachable
  | AuthenticationFailed
  | DatabaseMissing
  | SchemaBehind Int
  | SchemaInvalid MigrationRefusal
  | DatabaseError
  deriving (Eq, Show)

data Readiness
  = Ready MigrationId
  | NotReady NotReadyReason
  deriving (Eq, Show)

revisionNumber :: MigrationId -> Int
revisionNumber =
  migrationIdInt

{- | Classifies a libpq connection failure from its message. Before a session
exists there is no SQLSTATE, so the message text is all libpq offers.
-}
classifyConnectionFailure :: String -> NotReadyReason
classifyConnectionFailure message
  | has "password authentication failed" = AuthenticationFailed
  | has "does not exist" && has "database" = DatabaseMissing
  | has "Connection refused"
      || has "could not translate host name"
      || has "timeout expired"
      || has "No route to host"
      || has "Network is unreachable" =
      DatabaseUnreachable
  | otherwise = DatabaseError
 where
  has needle =
    needle `L.isInfixOf` message

readinessCode :: Readiness -> T.Text
readinessCode readiness =
  case readiness of
    Ready revision -> "ready " <> T.pack (show (migrationIdInt revision))
    NotReady reason -> "not_ready " <> reasonCode reason

reasonCode :: NotReadyReason -> T.Text
reasonCode reason =
  case reason of
    DatabaseNotConfigured -> "database_not_configured"
    DatabaseUnreachable -> "database_unreachable"
    AuthenticationFailed -> "authentication_failed"
    DatabaseMissing -> "database_missing"
    SchemaBehind n -> "schema_behind " <> T.pack (show n)
    SchemaInvalid refusal -> "schema_invalid " <> refusalCode refusal
    DatabaseError -> "database_error"

refusalCode :: MigrationRefusal -> T.Text
refusalCode refusal =
  case refusal of
    InvalidMigrationList -> "invalid_migration_list"
    ChecksumMismatch m -> "checksum_mismatch " <> idText m
    UnknownAppliedMigration m -> "unknown_applied_migration " <> idText m
    MissingAppliedMigration m -> "missing_applied_migration " <> idText m
 where
  idText =
    T.pack . show . migrationIdInt

-- | Runs an Orville action; any failure becomes a classified reason.
withDatabase :: DatabaseRuntime -> O.Orville a -> IO (Either NotReadyReason a)
withDatabase runtime action = do
  result <- try (O.runOrville (runtimePool runtime) action)
  pure $
    case result of
      Right value -> Right value
      Left err -> Left (classifyException err)

classifyException :: SomeException -> NotReadyReason
classifyException err =
  case fromException err of
    Just connectionError -> classifyConnectionFailure (show (connectionError :: Connection.ConnectionError))
    Nothing -> DatabaseError

-- | Readiness against the binary's own migration list. Never throws.
checkReadiness :: Maybe DatabaseRuntime -> IO Readiness
checkReadiness mbRuntime =
  case mbRuntime of
    Nothing ->
      pure (NotReady DatabaseNotConfigured)
    Just runtime -> do
      status <- schemaStatus runtime
      pure $
        case status of
          Left reason -> NotReady reason
          Right (SchemaStatus (Just revision) 0) -> Ready revision
          Right (SchemaStatus Nothing 0) -> NotReady (SchemaInvalid InvalidMigrationList)
          Right (SchemaStatus _ pending) -> NotReady (SchemaBehind pending)

data SchemaStatus
  = SchemaStatus
  { appliedRevision :: Maybe MigrationId
  , pendingCount :: Int
  }

schemaStatus :: DatabaseRuntime -> IO (Either NotReadyReason SchemaStatus)
schemaStatus runtime = do
  ledgerOrErr <- withDatabase runtime Queries.readLedger
  pure $ do
    ledger <- ledgerOrErr
    pending <- either (Left . SchemaInvalid) Right (planMigrations migrations ledger)
    let
      applied = fmap migrationId (L.take (L.length migrations - L.length pending) migrations)
    pure (SchemaStatus (lastMay applied) (L.length pending))

data MigrateError
  = MigrateRefused MigrationRefusal
  | MigrateFailed MigrationId [MigrationId]
  | BackupRequired
  | BackupMissing FilePath
  | BackupStale FilePath
  | MigrateNotReady NotReadyReason
  deriving (Eq, Show)

renderMigrateError :: MigrateError -> String
renderMigrateError err =
  case err of
    MigrateRefused refusal ->
      "migrations refused, nothing applied: " <> T.unpack (refusalCode refusal)
    MigrateFailed failed applied ->
      "migration "
        <> show (migrationIdInt failed)
        <> " failed and was rolled back; applied before it: "
        <> show (fmap migrationIdInt applied)
    BackupRequired ->
      "migrations are already applied: take a backup (scripts/db backup) and pass --backup FILE, or pass --no-backup"
    BackupMissing path ->
      "backup file " <> path <> " does not exist or is empty"
    BackupStale path ->
      "backup file " <> path <> " is older than the last applied migration"
    MigrateNotReady reason ->
      "database not reachable for migration: " <> T.unpack (reasonCode reason)

-- | Applies whatever the list has pending. No backup check.
runMigrations :: [Migration] -> DatabaseRuntime -> IO (Either MigrateError [MigrationId])
runMigrations list runtime = do
  result <- applyPending (runtimeConfig runtime) list
  pure $
    case result of
      Right applied -> Right applied
      Left (MigrateConnectionFailed message) -> Left (MigrateNotReady (classifyConnectionFailure message))
      Left (MigratePlanRefused refusal) -> Left (MigrateRefused refusal)
      Left (MigrationSqlFailed failed applied) -> Left (MigrateFailed failed applied)
      Left (MigrateLedgerUnreadable _) -> Left (MigrateNotReady DatabaseError)

{- | 'runMigrations' under the backup policy (contract C-P1.2 E6): nothing
pending is a no-op; an empty ledger needs no backup; otherwise a backup file
newer than the last applied migration, or an explicit 'NoBackup', is required.
-}
migrateWithPolicy :: BackupPolicy -> [Migration] -> DatabaseRuntime -> IO (Either MigrateError [MigrationId])
migrateWithPolicy policy list runtime = do
  stateOrErr <- withDatabase runtime ((,) <$> Queries.readLedger <*> Queries.lastAppliedAt)
  case stateOrErr of
    Left reason ->
      pure (Left (MigrateNotReady reason))
    Right (ledger, mbLastApplied) ->
      case planMigrations list ledger of
        Left refusal -> pure (Left (MigrateRefused refusal))
        Right [] -> pure (Right [])
        Right _ ->
          case mbLastApplied of
            Nothing -> runMigrations list runtime
            Just lastApplied -> do
              allowed <- backupAllows policy lastApplied
              case allowed of
                Left err -> pure (Left err)
                Right () -> runMigrations list runtime

backupAllows :: BackupPolicy -> Time.UTCTime -> IO (Either MigrateError ())
backupAllows policy lastApplied =
  case policy of
    NoBackup ->
      pure (Right ())
    BackupRequiredIfApplied ->
      pure (Left BackupRequired)
    BackupFile path -> do
      exists <- doesFileExist path
      if not exists
        then pure (Left (BackupMissing path))
        else do
          size <- getFileSize path
          modified <- getModificationTime path
          pure $
            if size <= 0
              then Left (BackupMissing path)
              else
                if modified > lastApplied
                  then Right ()
                  else Left (BackupStale path)

data ServiceStarts
  = ServiceStarts
  { startCount :: Int
  , latestStart :: Time.UTCTime
  }
  deriving (Eq, Show)

-- | Records one service start. Call only when the database is 'Ready'.
recordServiceStart :: DatabaseRuntime -> IO (Either NotReadyReason ())
recordServiceStart runtime =
  withDatabase runtime Queries.recordServiceStart

readServiceStarts :: DatabaseRuntime -> IO (Maybe ServiceStarts)
readServiceStarts runtime = do
  result <- withDatabase runtime Queries.serviceStartSummary
  pure $
    case result of
      Right (n, Just latest) | n > 0 -> Just (ServiceStarts n latest)
      _ -> Nothing

lastMay :: [a] -> Maybe a
lastMay =
  L.foldl' (\_ x -> Just x) Nothing

-- Session locks (C-C.R1 R1, R5) ----------------------------------------------

-- | What a session lock serializes; each kind has its own fixed namespace.
data SessionLock
  = DecisionKeyLock
  | ProjectConnectLock
  deriving (Eq, Show)

lockNamespace :: SessionLock -> Int32
lockNamespace lock =
  case lock of
    DecisionKeyLock -> 7301
    ProjectConnectLock -> 7302

-- | How long a request waits for a lock another request holds.
lockWaitSeconds :: Int
lockWaitSeconds =
  5

{- | Runs Orville actions on the lock's own connection, and proves the lock is
still held there.
-}
data Locked
  = Locked
  { onLockConnection :: forall a. O.Orville a -> IO a
  , lockStillHeld :: O.Orville Bool
  }

data LockFailure
  = LockBusy
  | LockUnavailable NotReadyReason
  deriving (Eq, Show)

{- | Takes the session-level advisory lock for the key on a connection of its
own (a pool of one, outside the service pool, so work done under the lock can
use the service pool without waiting for itself), runs the action while that
connection stays pinned, then unlocks and closes the connection whatever
happened; closing ends the session and so releases the lock even when the
unlock could not run. A lock not granted within 'lockWaitSeconds' is
'LockBusy'. Any failure of the lock's connection is 'LockUnavailable': the
caller cannot know how far its action got, so it must not guess.
-}
withSessionLock :: DatabaseRuntime -> SessionLock -> T.Text -> (Locked -> IO a) -> IO (Either LockFailure a)
withSessionLock runtime lock key action = do
  pool <- O.createConnectionPool (lockOptions (runtimeConfig runtime))
  let
    namespace = lockNamespace lock
    locked = O.withConnection_ $ do
      state <- O.askOrvilleState
      acquired <- liftIO (try (O.runOrvilleWithState state (SessionLocks.acquire namespace lockWaitSeconds key)))
      case acquired of
        Left err
          | lockTimedOut err -> pure Nothing
          | otherwise -> liftIO (throwIO err)
        Right () -> do
          result <- liftIO (action (Locked (O.runOrvilleWithState state) (SessionLocks.held namespace key)))
          -- Best effort: the action's outcome stands even when the unlock cannot run,
          -- because closing the connection below releases the lock anyway.
          _ <- liftIO (try (O.runOrvilleWithState state (SessionLocks.release namespace key)) :: IO (Either SomeException Bool))
          pure (Just result)
  outcome <- try (O.runOrville pool locked) `finally` Connection.destroyIdleConnections pool
  pure $
    case outcome of
      Right (Just result) -> Right result
      Right Nothing -> Left LockBusy
      Left err -> Left (LockUnavailable (classifyException err))

lockTimedOut :: SomeException -> Bool
lockTimedOut err =
  case fromException err of
    Just failure -> Connection.sqlExecutionErrorSqlState failure == Just (BS8.pack "55P03")
    Nothing -> False

-- | One connection, never shared: the lock lives exactly as long as it.
lockOptions :: DatabaseConfig -> O.ConnectionOptions
lockOptions config =
  O.ConnectionOptions
    { O.connectionString = connectionString config
    , O.connectionNoticeReporting = O.DisableNoticeReporting
    , O.connectionPoolStripes = O.StripeCount 1
    , O.connectionPoolLingerTime = 1
    , O.connectionPoolMaxConnections = O.MaxConnectionsTotal 1
    }
