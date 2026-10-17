{- | Read-side queries through Orville: the migration ledger (never created
here, so readiness stays read-only) and the service-start projection
(contract C-P1.2 E9).
-}
module Lockstep.Persistence.Queries
  ( readLedger
  , lastAppliedAt
  , recordServiceStart
  , serviceStartSummary
  ) where

import Data.Time qualified as Time
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql

import Lockstep.Persistence.Migration (AppliedMigration (..), mkChecksum, mkMigrationId)

ledgerExists :: O.MonadOrville m => m Bool
ledgerExists = do
  rows <-
    O.executeAndDecode
      O.SelectQuery
      (RawSql.fromString "SELECT to_regclass('public.lockstep_schema_migrations') IS NOT NULL AS v")
      (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.booleanField "v")))
  pure (rows == [True])

{- | The applied migrations in id order; empty when the ledger table does not
exist yet. Rows that do not decode are dropped by 'mkMigrationId' only if their
id is below 1, which the table's CHECK constraint forbids.
-}
readLedger :: O.MonadOrville m => m [AppliedMigration]
readLedger = do
  exists <- ledgerExists
  if not exists
    then pure []
    else do
      rows <-
        O.executeAndDecode
          O.SelectQuery
          (RawSql.fromString "SELECT id, checksum FROM lockstep_schema_migrations ORDER BY id")
          ( O.annotateSqlMarshallerEmptyAnnotation $
              (,)
                <$> O.marshallField fst (O.integerField "id")
                <*> O.marshallField snd (O.unboundedTextField "checksum")
          )
      pure
        [ AppliedMigration applied (mkChecksum checksum)
        | (rawId, checksum) <- rows
        , Just applied <- [mkMigrationId (fromIntegral rawId)]
        ]

lastAppliedAt :: O.MonadOrville m => m (Maybe Time.UTCTime)
lastAppliedAt = do
  exists <- ledgerExists
  if not exists
    then pure Nothing
    else do
      rows <-
        O.executeAndDecode
          O.SelectQuery
          (RawSql.fromString "SELECT max(applied_at) AS v FROM lockstep_schema_migrations")
          (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.nullableField (O.utcTimestampField "v"))))
      pure (join (headMay rows))

recordServiceStart :: O.MonadOrville m => m ()
recordServiceStart =
  O.executeVoid O.InsertQuery (RawSql.fromString "INSERT INTO lockstep_service_starts DEFAULT VALUES")

-- | Number of recorded starts and the latest one.
serviceStartSummary :: O.MonadOrville m => m (Int, Maybe Time.UTCTime)
serviceStartSummary = do
  rows <-
    O.executeAndDecode
      O.SelectQuery
      (RawSql.fromString "SELECT count(*)::integer AS n, max(started_at) AS latest FROM lockstep_service_starts")
      ( O.annotateSqlMarshallerEmptyAnnotation $
          (,)
            <$> O.marshallField fst (O.integerField "n")
            <*> O.marshallField snd (O.nullableField (O.utcTimestampField "latest"))
      )
  pure $
    case rows of
      [(n, latest)] -> (fromIntegral n, latest)
      _ -> (0, Nothing)

headMay :: [a] -> Maybe a
headMay xs =
  case xs of
    [] -> Nothing
    x : _ -> Just x
