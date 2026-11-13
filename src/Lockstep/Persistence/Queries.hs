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

import Data.List qualified as L
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Maybe (isJust)
import Data.Text qualified as T
import Data.Time qualified as Time
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Expr qualified as Expr
import Orville.PostgreSQL.Raw.SqlValue qualified as SqlValue

import Lockstep.Persistence.Fields (assignExpression, clockTimestamp, countOf, headMay, insertComputed, selectJoined, selectValue, tableReference)
import Lockstep.Persistence.Migration (AppliedMigration (..), mkChecksum, mkMigrationId)

-- | @lockstep_schema_migrations@, which "Lockstep.Persistence.Migrate" creates: (id, checksum).
ledgerTable :: O.TableDefinition (O.HasKey Int32) (Int32, T.Text) (Int32, T.Text)
ledgerTable =
  O.mkTableDefinition "lockstep_schema_migrations" (O.primaryKey ledgerIdField) $
    (,)
      <$> O.marshallField fst ledgerIdField
      <*> O.marshallField snd (O.unboundedTextField "checksum")

ledgerIdField :: O.FieldDefinition O.NotNull Int32
ledgerIdField =
  O.integerField "id"

ledgerAppliedAtField :: O.FieldDefinition O.NotNull Time.UTCTime
ledgerAppliedAtField =
  O.utcTimestampField "applied_at"

-- | Whether the ledger table exists: @to_regclass('public.lockstep_schema_migrations')@ is not null.
ledgerExists :: O.MonadOrville m => m Bool
ledgerExists = do
  rows <-
    selectValue
      (Expr.functionCall (Expr.functionName "to_regclass") [Expr.valueExpression (SqlValue.fromText (T.pack "public.lockstep_schema_migrations"))])
      (O.nullableField (O.unboundedTextField "v"))
  pure (L.any isJust rows)

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
      rows <- O.findEntitiesBy ledgerTable (O.orderBy (O.orderByField ledgerIdField O.ascendingOrder))
      pure
        [ AppliedMigration applied (mkChecksum checksum)
        | (rawId, checksum) <- rows
        , Just applied <- [mkMigrationId (fromIntegral rawId)]
        ]

-- | @max(column)@ as a nullable timestamp: none when the table is empty.
latestOf :: O.FieldDefinition O.NotNull Time.UTCTime -> String -> O.SqlMarshaller w (Maybe Time.UTCTime)
latestOf field alias =
  O.marshallSyntheticField
    ( O.nullableSyntheticField
        (O.syntheticField (Expr.maxAggregateFunction Nothing (O.fieldColumnReference field) Nothing Nothing) alias (O.fieldType field))
    )

lastAppliedAt :: O.MonadOrville m => m (Maybe Time.UTCTime)
lastAppliedAt = do
  exists <- ledgerExists
  if not exists
    then pure Nothing
    else join . headMay <$> selectJoined (latestOf ledgerAppliedAtField "v") (tableReference ledgerTable) mempty

-- | @lockstep_service_starts@: one row per start, stamped by the database.
serviceStartTable :: O.TableDefinition O.NoKey () Time.UTCTime
serviceStartTable =
  O.mkTableDefinitionWithoutKey "lockstep_service_starts" (O.marshallReadOnlyField serviceStartedAtField)

serviceStartedAtField :: O.FieldDefinition O.NotNull Time.UTCTime
serviceStartedAtField =
  O.utcTimestampField "started_at"

-- | Records a start at the statement's time (the column's default, @clock_timestamp()@).
recordServiceStart :: O.MonadOrville m => m ()
recordServiceStart =
  void (insertComputed serviceStartTable (assignExpression serviceStartedAtField clockTimestamp :| []))

-- | Number of recorded starts and the latest one.
serviceStartSummary :: O.MonadOrville m => m (Int, Maybe Time.UTCTime)
serviceStartSummary = do
  rows <- selectJoined ((,) <$> countOf "n" <*> latestOf serviceStartedAtField "latest") (tableReference serviceStartTable) mempty
  pure $
    case rows of
      [(n, latest)] -> (fromIntegral n, latest)
      _ -> (0, Nothing)
