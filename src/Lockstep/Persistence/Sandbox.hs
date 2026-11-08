{-# LANGUAGE TypeFamilies #-}

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

import Lockstep.Kernel.Effect (OperationId (..))
import Lockstep.Persistence.Entity (EntityKey, Table, keyField, mkEntityTable)
import Lockstep.Persistence.Fields (ConflictTarget (..), countOf, insertIgnoringConflict, selectJoined, tableReference)

-- The sandbox destination is the simulated external world, not the ledger:
-- its operation ids are typed but reference no ledger table (the schema
-- declares no constraint), so every operation_id column here is the
-- destination's own key ('operationField'), not a foreign key.

-- | (operation id, effect, parameters): one row per application.
applicationTable :: O.TableDefinition O.NoKey (OperationId, T.Text, T.Text) (OperationId, T.Text, T.Text)
applicationTable =
  O.mkTableDefinitionWithoutKey "lockstep_sandbox_applications" $
    (,,)
      <$> O.marshallField (\(o, _, _) -> o) operationField
      <*> O.marshallField (\(_, e, _) -> e) applicationEffectField
      <*> O.marshallField (\(_, _, p) -> p) (O.unboundedTextField "parameters")

applicationEffectField :: O.FieldDefinition O.NotNull T.Text
applicationEffectField =
  O.unboundedTextField "effect"

-- | An idempotency key: the parameters an operation id was first applied with.
data SandboxKey
  = SandboxKey
  { sandboxKeyOperation :: OperationId
  , sandboxKeyParameters :: T.Text
  }

type instance EntityKey SandboxKey = OperationId

keyTable :: Table SandboxKey SandboxKey
keyTable =
  mkEntityTable "lockstep_sandbox_keys" operationField $
    SandboxKey
      <$> O.marshallField sandboxKeyOperation operationField
      <*> O.marshallField sandboxKeyParameters (O.unboundedTextField "parameters")

-- | The queryable destination's outcome for an operation id.
data SandboxOutcome
  = SandboxOutcome
  { sandboxOutcomeOperation :: OperationId
  , sandboxOutcome :: T.Text
  }

type instance EntityKey SandboxOutcome = OperationId

queryableTable :: Table SandboxOutcome SandboxOutcome
queryableTable =
  mkEntityTable "lockstep_sandbox_queryable" operationField $
    SandboxOutcome
      <$> O.marshallField sandboxOutcomeOperation operationField
      <*> O.marshallField sandboxOutcome (O.unboundedTextField "outcome")

operationField :: O.FieldDefinition O.NotNull OperationId
operationField =
  keyField "operation_id"

recordApplication :: O.MonadOrville m => OperationId -> T.Text -> T.Text -> m ()
recordApplication operation effect parameters =
  O.insertEntity applicationTable (operation, effect, parameters)

-- | Inserts an idempotency key; True when it was new.
insertKey :: O.MonadOrville m => OperationId -> T.Text -> m Bool
insertKey operation parameters =
  insertIgnoringConflict AnyConflict keyTable (SandboxKey operation parameters)

-- | The parameters an operation id was first applied with, if any.
keyParameters :: O.MonadOrville m => OperationId -> m (Maybe T.Text)
keyParameters operation =
  fmap sandboxKeyParameters <$> O.findEntity keyTable operation

{- | The queryable destination's one row per operation id: inserts the outcome
unless a row exists, then returns the row's outcome and whether this call
inserted it. An application inserts @applied@ and a lookup @fenced@; the first
wins.
-}
settleQueryable :: O.MonadOrville m => OperationId -> T.Text -> m (T.Text, Bool)
settleQueryable operation outcome = do
  inserted <- insertIgnoringConflict AnyConflict queryableTable (SandboxOutcome operation outcome)
  current <- queryableOutcome operation
  pure (fromMaybe outcome current, inserted)

-- | The queryable destination's outcome for an operation id, if it has one.
queryableOutcome :: O.MonadOrville m => OperationId -> m (Maybe T.Text)
queryableOutcome operation =
  fmap sandboxOutcome <$> O.findEntity queryableTable operation

-- | (operation, effect, applications), in first-application order.
applicationCounts :: O.MonadOrville m => m [(OperationId, T.Text, Int32)]
applicationCounts =
  selectJoined
    ( (,,)
        <$> O.marshallReadOnlyField operationField
        <*> O.marshallReadOnlyField applicationEffectField
        <*> countOf "n"
    )
    (tableReference applicationTable)
    ( O.groupBy (Expr.groupByColumnsExpr (Expr.unqualified (O.fieldColumnName operationField) :| [Expr.unqualified (O.fieldColumnName applicationEffectField)]))
        <> O.orderBy (Expr.orderByValueExpression (Expr.minAggregateFunction Nothing (O.fieldColumnReference (O.bigIntegerField "id")) Nothing Nothing) O.ascendingOrder)
    )
