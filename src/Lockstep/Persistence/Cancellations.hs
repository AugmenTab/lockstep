{- | Storage for a person's cancel of a task whose fix is live (Update 2
R6.3; migration 32): the request, one per fix, and its settlement once the
fix stopped. Both are written once and never changed.
-}
module Lockstep.Persistence.Cancellations
  ( CancellationRow (..)
  , insertCancellation
  , cancellationFor
  , latestCancellationOfTask
  , allCancellations
  , SettlementRow (..)
  , insertSettlement
  , settlementFor
  , pendingCancellation
  ) where

import Data.Maybe (isJust)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Text.Show (Show)

import Lockstep.Kernel.Identity (TaskId (..), WorkOrderId (..))
import Lockstep.Persistence.Entity (keyField)

-- | A person asked to cancel the task while this fix (its Work Order) was live.
data CancellationRow
  = CancellationRow
  { cancellationWorkOrder :: WorkOrderId
  , cancellationTask :: TaskId
  , cancellationSession :: T.Text
  }
  deriving (Eq, Show)

cancellationTable :: O.TableDefinition O.NoKey CancellationRow CancellationRow
cancellationTable =
  O.mkTableDefinitionWithoutKey "lockstep_task_cancellations" $
    CancellationRow
      <$> O.marshallField cancellationWorkOrder cancellationWorkOrderField
      <*> O.marshallField cancellationTask cancellationTaskField
      <*> O.marshallField cancellationSession (O.unboundedTextField "session")

cancellationWorkOrderField :: O.FieldDefinition O.NotNull WorkOrderId
cancellationWorkOrderField =
  keyField "work_order_id"

cancellationTaskField :: O.FieldDefinition O.NotNull TaskId
cancellationTaskField =
  keyField "task_id"

-- | Set by the database on insert; only ordered by.
requestedAtField :: O.FieldDefinition O.NotNull UTCTime
requestedAtField =
  O.utcTimestampField "requested_at"

insertCancellation :: O.MonadOrville m => CancellationRow -> m ()
insertCancellation =
  O.insertEntity cancellationTable

cancellationFor :: O.MonadOrville m => WorkOrderId -> m (Maybe CancellationRow)
cancellationFor workOrder =
  O.findFirstEntityBy cancellationTable (O.where_ (O.fieldEquals cancellationWorkOrderField workOrder))

latestCancellationOfTask :: O.MonadOrville m => TaskId -> m (Maybe CancellationRow)
latestCancellationOfTask task =
  O.findFirstEntityBy cancellationTable (O.where_ (O.fieldEquals cancellationTaskField task) <> O.orderBy (O.orderByField requestedAtField O.descendingOrder))

allCancellations :: O.MonadOrville m => m [CancellationRow]
allCancellations =
  O.findEntitiesBy cancellationTable (O.orderBy (O.orderByField requestedAtField O.ascendingOrder))

-- | How a cancel was settled once its fix stopped: the task canceled, or not (and why).
data SettlementRow
  = SettlementRow
  { settlementWorkOrder :: WorkOrderId
  , settlementOutcome :: T.Text
  , settlementReason :: T.Text
  }
  deriving (Eq, Show)

settlementTable :: O.TableDefinition O.NoKey SettlementRow SettlementRow
settlementTable =
  O.mkTableDefinitionWithoutKey "lockstep_task_cancellation_settlements" $
    SettlementRow
      <$> O.marshallField settlementWorkOrder settlementWorkOrderField
      <*> O.marshallField settlementOutcome (O.unboundedTextField "outcome")
      <*> O.marshallField settlementReason (O.unboundedTextField "reason")

settlementWorkOrderField :: O.FieldDefinition O.NotNull WorkOrderId
settlementWorkOrderField =
  keyField "work_order_id"

insertSettlement :: O.MonadOrville m => SettlementRow -> m ()
insertSettlement =
  O.insertEntity settlementTable

settlementFor :: O.MonadOrville m => WorkOrderId -> m (Maybe SettlementRow)
settlementFor workOrder =
  O.findFirstEntityBy settlementTable (O.where_ (O.fieldEquals settlementWorkOrderField workOrder))

-- | The session of a cancel of this fix not settled yet, if there is one.
pendingCancellation :: O.MonadOrville m => WorkOrderId -> m (Maybe T.Text)
pendingCancellation workOrder = do
  requested <- cancellationFor workOrder
  settled <- settlementFor workOrder
  pure (if isJust settled then Nothing else cancellationSession <$> requested)
