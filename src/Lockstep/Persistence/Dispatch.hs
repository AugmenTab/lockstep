{- | Storage for the dispatcher (contract C-P6.5 S4, S8; migration 26): each
hand-over the scheduler made of a plan unit, and the accepted ancestors a fix
was built on. Both are written once and never changed.
-}
module Lockstep.Persistence.Dispatch
  ( DispatchRow (..)
  , insertDispatch
  , FixBaseRow (..)
  , insertFixBase
  , fixBasesOf
  , RefusalRow (..)
  , insertRefusal
  , latestRefusal
  , allFixBases
  , InvalidationRow (..)
  , insertInvalidation
  , invalidationsOf
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Text.Show (Show)

import Lockstep.Kernel.Identity (PlanRevisionId (..), TaskId (..), TransactionId (..), WorkOrderId (..))
import Lockstep.Persistence.Entity (keyField)

data DispatchRow
  = DispatchRow
  { dispatchRowRevision :: PlanRevisionId
  , dispatchRowUnit :: T.Text
  , dispatchRowTask :: TaskId
  , dispatchRowWorkOrder :: WorkOrderId
  , dispatchRowKey :: T.Text
  }
  deriving (Eq, Show)

dispatchTable :: O.TableDefinition O.NoKey DispatchRow DispatchRow
dispatchTable =
  O.mkTableDefinitionWithoutKey "lockstep_plan_dispatches" $
    DispatchRow
      <$> O.marshallField dispatchRowRevision (keyField "revision_id")
      <*> O.marshallField dispatchRowUnit (O.unboundedTextField "unit_key")
      <*> O.marshallField dispatchRowTask (keyField "task_id")
      <*> O.marshallField dispatchRowWorkOrder (keyField "work_order_id")
      <*> O.marshallField dispatchRowKey (O.unboundedTextField "idempotency_key")

insertDispatch :: O.MonadOrville m => DispatchRow -> m ()
insertDispatch =
  O.insertEntity dispatchTable

-- | A fix and one accepted ancestor it was built on (S8).
data FixBaseRow
  = FixBaseRow
  { fixBaseTransaction :: TransactionId
  , fixBaseAncestor :: TransactionId
  , fixBaseCommit :: T.Text
  }
  deriving (Eq, Show)

fixBaseTable :: O.TableDefinition O.NoKey FixBaseRow FixBaseRow
fixBaseTable =
  O.mkTableDefinitionWithoutKey "lockstep_fix_bases" $
    FixBaseRow
      <$> O.marshallField fixBaseTransaction fixBaseTransactionField
      <*> O.marshallField fixBaseAncestor (keyField "ancestor_transaction_id")
      <*> O.marshallField fixBaseCommit (O.unboundedTextField "accepted_commit")

fixBaseTransactionField :: O.FieldDefinition O.NotNull TransactionId
fixBaseTransactionField =
  keyField "transaction_id"

insertFixBase :: O.MonadOrville m => FixBaseRow -> m ()
insertFixBase =
  O.insertEntity fixBaseTable

fixBasesOf :: O.MonadOrville m => TransactionId -> m [FixBaseRow]
fixBasesOf tx =
  O.findEntitiesBy fixBaseTable (O.where_ (O.fieldEquals fixBaseTransactionField tx))

-- | C-P6.7: every recorded basis (a fix and one accepted fix it was built on).
allFixBases :: O.MonadOrville m => m [FixBaseRow]
allFixBases =
  O.findEntitiesBy fixBaseTable mempty

-- | C-P6.7 V2: a fix that stopped counting, why, and what caused it.
data InvalidationRow
  = InvalidationRow
  { invalidationTransaction :: TransactionId
  , invalidationCodeOf :: T.Text
  , invalidationCauseTransaction :: Maybe TransactionId
  , invalidationCauseRevision :: Maybe PlanRevisionId
  }
  deriving (Eq, Show)

invalidationTable :: O.TableDefinition O.NoKey InvalidationRow InvalidationRow
invalidationTable =
  O.mkTableDefinitionWithoutKey "lockstep_fix_invalidations" $
    InvalidationRow
      <$> O.marshallField invalidationTransaction invalidationTransactionField
      <*> O.marshallField invalidationCodeOf (O.unboundedTextField "code")
      <*> O.marshallField invalidationCauseTransaction (O.nullableField (keyField "cause_transaction_id"))
      <*> O.marshallField invalidationCauseRevision (O.nullableField (keyField "cause_revision_id"))

invalidationTransactionField :: O.FieldDefinition O.NotNull TransactionId
invalidationTransactionField =
  keyField "transaction_id"

insertInvalidation :: O.MonadOrville m => InvalidationRow -> m ()
insertInvalidation =
  O.insertEntity invalidationTable

-- | A fix's invalidations, if any.
invalidationsOf :: O.MonadOrville m => TransactionId -> m [InvalidationRow]
invalidationsOf tx =
  O.findEntitiesBy invalidationTable (O.where_ (O.fieldEquals invalidationTransactionField tx))

-- | R-P6.5-6: a refused hand-over of a unit of a revision, and its code.
data RefusalRow
  = RefusalRow
  { refusalRevision :: PlanRevisionId
  , refusalUnit :: T.Text
  , refusalCode :: T.Text
  }
  deriving (Eq, Show)

refusalTable :: O.TableDefinition O.NoKey RefusalRow RefusalRow
refusalTable =
  O.mkTableDefinitionWithoutKey "lockstep_plan_dispatch_refusals" $
    RefusalRow
      <$> O.marshallField refusalRevision refusalRevisionField
      <*> O.marshallField refusalUnit refusalUnitField
      <*> O.marshallField refusalCode (O.unboundedTextField "code")

refusalRevisionField :: O.FieldDefinition O.NotNull PlanRevisionId
refusalRevisionField =
  keyField "revision_id"

refusalUnitField :: O.FieldDefinition O.NotNull T.Text
refusalUnitField =
  O.unboundedTextField "unit_key"

insertRefusal :: O.MonadOrville m => RefusalRow -> m ()
insertRefusal =
  O.insertEntity refusalTable

-- | The last refusal recorded for a unit of a revision.
latestRefusal :: O.MonadOrville m => PlanRevisionId -> T.Text -> m (Maybe RefusalRow)
latestRefusal revision unit =
  O.findFirstEntityBy
    refusalTable
    ( O.where_ (O.fieldEquals refusalRevisionField revision `O.andExpr` O.fieldEquals refusalUnitField unit)
        <> O.orderBy (O.orderByField (O.bigIntegerField "id") O.descendingOrder)
    )
