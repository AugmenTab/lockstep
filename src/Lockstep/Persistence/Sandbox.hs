{- | Storage for the sandbox destination (contract C-P2.8 V5, V6): the
simulated external world of the sandbox effects. Statements only; the
adapters in "Lockstep.Application.Sandbox" run each in its own transaction,
never in the ledger's.
-}
module Lockstep.Persistence.Sandbox
  ( recordApplication
  , insertKey
  , keyParameters
  , settleQueryable
  , queryableOutcome
  , applicationCounts
  ) where

import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Expr qualified as Expr

import Lockstep.Persistence.Fields (ConflictTarget (..), countOf, insertIgnoringConflict, selectJoined, tableReference, uuidField)

-- | (operation id, effect, parameters): one row per application.
applicationTable :: O.TableDefinition O.NoKey (T.Text, T.Text, T.Text) (T.Text, T.Text, T.Text)
applicationTable =
  O.mkTableDefinitionWithoutKey "lockstep_sandbox_applications" $
    (,,)
      <$> O.marshallField (\(o, _, _) -> o) applicationOperationField
      <*> O.marshallField (\(_, e, _) -> e) applicationEffectField
      <*> O.marshallField (\(_, _, p) -> p) (O.unboundedTextField "parameters")

applicationOperationField :: O.FieldDefinition O.NotNull T.Text
applicationOperationField =
  uuidField "operation_id"

applicationEffectField :: O.FieldDefinition O.NotNull T.Text
applicationEffectField =
  O.unboundedTextField "effect"

-- | (operation id, parameters): the idempotency keys.
keyTable :: O.TableDefinition (O.HasKey T.Text) (T.Text, T.Text) (T.Text, T.Text)
keyTable =
  O.mkTableDefinition "lockstep_sandbox_keys" (O.primaryKey operationField) $
    (,)
      <$> O.marshallField fst operationField
      <*> O.marshallField snd (O.unboundedTextField "parameters")

-- | (operation id, outcome): the queryable destination.
queryableTable :: O.TableDefinition (O.HasKey T.Text) (T.Text, T.Text) (T.Text, T.Text)
queryableTable =
  O.mkTableDefinition "lockstep_sandbox_queryable" (O.primaryKey operationField) $
    (,)
      <$> O.marshallField fst operationField
      <*> O.marshallField snd (O.unboundedTextField "outcome")

operationField :: O.FieldDefinition O.NotNull T.Text
operationField =
  uuidField "operation_id"

recordApplication :: O.MonadOrville m => T.Text -> T.Text -> T.Text -> m ()
recordApplication operation effect parameters =
  O.insertEntity applicationTable (operation, effect, parameters)

-- | Inserts an idempotency key; True when it was new.
insertKey :: O.MonadOrville m => T.Text -> T.Text -> m Bool
insertKey operation parameters =
  insertIgnoringConflict AnyConflict keyTable (operation, parameters)

-- | The parameters an operation id was first applied with, if any.
keyParameters :: O.MonadOrville m => T.Text -> m (Maybe T.Text)
keyParameters operation =
  fmap snd <$> O.findFirstEntityBy keyTable (O.where_ (O.fieldEquals operationField operation))

{- | The queryable destination's one row per operation id: inserts the outcome
unless a row exists, then returns the row's outcome and whether this call
inserted it. An application inserts @applied@ and a lookup @fenced@; the first
wins.
-}
settleQueryable :: O.MonadOrville m => T.Text -> T.Text -> m (T.Text, Bool)
settleQueryable operation outcome = do
  inserted <- insertIgnoringConflict AnyConflict queryableTable (operation, outcome)
  current <- queryableOutcome operation
  pure (fromMaybe outcome current, inserted)

-- | The queryable destination's outcome for an operation id, if it has one.
queryableOutcome :: O.MonadOrville m => T.Text -> m (Maybe T.Text)
queryableOutcome operation =
  fmap snd <$> O.findFirstEntityBy queryableTable (O.where_ (O.fieldEquals operationField operation))

-- | (operation, effect, applications), in first-application order.
applicationCounts :: O.MonadOrville m => m [(T.Text, T.Text, Int32)]
applicationCounts =
  selectJoined
    ( (,,)
        <$> O.marshallReadOnlyField applicationOperationField
        <*> O.marshallReadOnlyField applicationEffectField
        <*> countOf "n"
    )
    (tableReference applicationTable)
    ( O.groupBy (Expr.groupByColumnsExpr (Expr.unqualified (O.fieldColumnName applicationOperationField) :| [Expr.unqualified (O.fieldColumnName applicationEffectField)]))
        <> O.orderBy (Expr.orderByValueExpression (Expr.minAggregateFunction Nothing (O.fieldColumnReference (O.bigIntegerField "id")) Nothing Nothing) O.ascendingOrder)
    )
