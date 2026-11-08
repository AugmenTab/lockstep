{- | The Work Order lifecycle: scheduling, claim and execution authorization
(contract C-P2.2 T5, §3.2). The kind fixes the effect class: only Engineering
and PR rework orders complete with Work Units. Every claim-bearing input must
name the current claim exactly, the groundwork for P2.5 fencing. An active or
claimed order is halted before it can be canceled. Work Order completion is
not Ticket completion.
-}
module Lockstep.Kernel.WorkOrder
  ( WorkOrderKind (..)
  , mayCompleteWithWorkUnits
  , workOrderKindName
  , parseWorkOrderKind
  , Claim (..)
  , WorkOrderState (..)
  , WorkOrder (..)
  , newWorkOrder
  , WorkOrderInput (..)
  , stepWorkOrder
  , workOrderStateName
  , workOrderInputName
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Identity (EngineerId, WorkOrderId)
import Lockstep.Kernel.Transition (Cell (..), Command (..), Principal (..), TransitionRefusal (..), decide)
import Lockstep.Kernel.WorkUnitLifecycle (AcceptedWorkUnit)

data WorkOrderKind
  = Engineering
  | Investigate
  | PrRework
  | Integrate
  | Plan
  | PublishReport
  | SkillInstall
  deriving (Eq, Show, Enum, Bounded)

mayCompleteWithWorkUnits :: WorkOrderKind -> Bool
mayCompleteWithWorkUnits kind =
  kind `L.elem` [Engineering, PrRework]

-- | The kind's stable kebab-case name (C-P2.3 F1).
workOrderKindName :: WorkOrderKind -> T.Text
workOrderKindName kind =
  T.pack $
    case kind of
      Engineering -> "engineering"
      Investigate -> "investigate"
      PrRework -> "pr-rework"
      Integrate -> "integrate"
      Plan -> "plan"
      PublishReport -> "publish-report"
      SkillInstall -> "skill-install"

parseWorkOrderKind :: T.Text -> Maybe WorkOrderKind
parseWorkOrderKind text =
  L.find ((== text) . workOrderKindName) [minBound .. maxBound]

data Claim
  = Claim
  { claimEngineer :: EngineerId
  , claimGeneration :: Int
  }
  deriving (Eq, Show)

data WorkOrderState
  = Pending
  | Eligible
  | Claimed Claim
  | Active Claim
  | Waiting Claim T.Text
  | Halted T.Text
  | Completed Claim [AcceptedWorkUnit]
  | Superseded WorkOrderId
  | Canceled
  deriving (Eq, Show)

data WorkOrder
  = WorkOrder
  { workOrderId :: WorkOrderId
  , workOrderKind :: WorkOrderKind
  , workOrderState :: WorkOrderState
  }
  deriving (Eq, Show)

newWorkOrder :: WorkOrderId -> WorkOrderKind -> WorkOrder
newWorkOrder identity kind =
  WorkOrder identity kind Pending

data WorkOrderInput
  = WoMarkEligible
  | WoMarkIneligible
  | WoClaim Claim
  | WoRelease Claim
  | WoStart Claim
  | WoWait Claim T.Text
  | WoResume Claim
  | WoComplete Claim [AcceptedWorkUnit]
  | WoHalt T.Text
  | WoRequeue
  | WoSupersede WorkOrderId
  | WoCancel
  deriving (Eq, Show)

stepWorkOrder :: WorkOrder -> Command WorkOrderInput -> Either TransitionRefusal WorkOrder
stepWorkOrder order (Command principal input) =
  let
    state = workOrderState order
  in
    fmap
      (\next -> order {workOrderState = next})
      (decide principal (workOrderStateName state) (terminal state) (workOrderInputName input) (cell (workOrderKind order) state input))

terminal :: WorkOrderState -> Bool
terminal state =
  case state of
    Completed _ _ -> True
    Superseded _ -> True
    Canceled -> True
    _ -> False

-- | The §3.2 table.
cell :: WorkOrderKind -> WorkOrderState -> WorkOrderInput -> Maybe (Cell WorkOrderState)
cell kind state input =
  case (state, input) of
    (Pending, WoMarkEligible) -> scheduler (Right Eligible)
    (Eligible, WoMarkIneligible) -> scheduler (Right Pending)
    (Eligible, WoClaim c) -> scheduler (Right (Claimed c))
    (Claimed current, WoRelease c) -> scheduler (matching current c Eligible)
    (Claimed current, WoStart c) -> supervisor (matching current c (Active current))
    (Active current, WoWait c reason) -> supervisor (matching current c (Waiting current reason))
    (Waiting current _, WoResume c) -> supervisor (matching current c (Active current))
    (Active current, WoComplete c units) ->
      supervisor $
        if c /= current
          then Left ClaimMismatch
          else
            if mayCompleteWithWorkUnits kind == L.null units
              then Left (KindForbids (T.pack (if L.null units then "this kind completes with Work Units" else "this kind does not create Work Units")))
              else Right (Completed current units)
    (Claimed _, WoHalt reason) -> humanOrSupervisor (Halted reason)
    (Active _, WoHalt reason) -> humanOrSupervisor (Halted reason)
    (Waiting _ _, WoHalt reason) -> humanOrSupervisor (Halted reason)
    (Halted _, WoRequeue) -> human (Right Pending)
    (_, WoSupersede replacement) | unclaimed -> human (Right (Superseded replacement))
    (_, WoCancel) | unclaimed -> human (Right Canceled)
    _ -> Nothing
 where
  unclaimed =
    case state of
      Pending -> True
      Eligible -> True
      Halted _ -> True
      _ -> False
  scheduler = Just . Cell [Scheduler]
  supervisor = Just . Cell [Supervisor]
  human = Just . Cell [Human]
  humanOrSupervisor = Just . Cell [Human, Supervisor] . Right
  matching current c next =
    if c == current then Right next else Left ClaimMismatch

workOrderStateName :: WorkOrderState -> T.Text
workOrderStateName state =
  T.pack $
    case state of
      Pending -> "pending"
      Eligible -> "eligible"
      Claimed _ -> "claimed"
      Active _ -> "active"
      Waiting _ _ -> "waiting"
      Halted _ -> "halted"
      Completed _ _ -> "completed"
      Superseded _ -> "superseded"
      Canceled -> "canceled"

workOrderInputName :: WorkOrderInput -> T.Text
workOrderInputName input =
  T.pack $
    case input of
      WoMarkEligible -> "mark-eligible"
      WoMarkIneligible -> "mark-ineligible"
      WoClaim _ -> "claim"
      WoRelease _ -> "release"
      WoStart _ -> "start"
      WoWait _ _ -> "wait"
      WoResume _ -> "resume"
      WoComplete _ _ -> "complete"
      WoHalt _ -> "halt"
      WoRequeue -> "requeue"
      WoSupersede _ -> "supersede"
      WoCancel -> "cancel"
