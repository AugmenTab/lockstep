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
