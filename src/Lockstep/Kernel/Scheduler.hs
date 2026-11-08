{- | The deterministic Work Order scheduler (contract C-P2.4; DG-05 D-5.7 to
D-5.11 and clarifications 1 and 3). Pure: given the authoritative facts it
decides, for every queued Work Order, whether it is eligible and why not,
ranks the eligible ones by human-approved priority, admission time and id,
and selects at most one. It never claims; claims and their fencing
generations are C-P2.5.
-}
module Lockstep.Kernel.Scheduler
  ( Priority
  , mkPriority
  , priorityValue
  , ResourceName
  , mkResourceName
  , resourceNameText
  , Availability (..)
  , SourceBasis (..)
  , ScheduledOrder (..)
  , SchedulerInput (..)
  , Ineligibility (..)
  , ineligibilityCode
  , ScheduleDecision
  , scheduleOrders
  , decisionSelected
  , decisionEligible
  , decisionIneligible
  , schedulingCommands
  , renderScheduleDecision
  , scheduleDigest
  , SchedulerRefusal (..)
  , schedulerRefusalCode
  ) where

import Data.Char qualified as Char
import Data.List qualified as L
import Data.Maybe (isNothing, mapMaybe)
import Data.Ord (Down (..), comparing)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Flipstone.Prelude
import Text.Show (Show, show)

import Lockstep.Kernel.Identity (EngineerId (..), RepositoryId, TicketId, WorkOrderId (..), uuidText)
import Lockstep.Kernel.Profile
  ( ArtifactKind (..)
  , ContentDigest
  , Freshness (..)
  , GateBlock (..)
  , GateEvidence
  , GateId
  , GateStatus (..)
  , Hasher (..)
  , ProfileBinding
  , ProfileConfirmation
  , ProfileId
  , ProfileRef
  , bindingFreshness
  , bindingWorkOrder
  , evaluateGate
  , executionPrerequisites
  , gateId
  , gateIdText
  , profileIdText
  )
import Lockstep.Kernel.Transition (Command (..), Principal (..))
import Lockstep.Kernel.WorkOrder (WorkOrder (..), WorkOrderInput (..), WorkOrderState (..))

-- | A human-approved priority, 0 to 999; higher is scheduled first (S2).
newtype Priority
  = Priority Int
  deriving (Eq, Ord, Show)

mkPriority :: Principal -> Int -> Either SchedulerRefusal Priority
mkPriority principal value
  | principal /= Human = Left (PriorityNotHuman principal)
  | value < 0 || value > 999 = Left (InvalidPriority value)
  | otherwise = Right (Priority value)

priorityValue :: Priority -> Int
priorityValue (Priority value) =
  value

newtype ResourceName
  = ResourceName T.Text
  deriving (Eq, Ord, Show)

mkResourceName :: T.Text -> Either SchedulerRefusal ResourceName
mkResourceName text =
  case T.uncons text of
    Just (first, rest)
      | Char.isAsciiLower first
          && T.length rest <= 63
          && T.all (\c -> Char.isAsciiLower c || Char.isDigit c || c == '-') rest ->
          Right (ResourceName text)
    _ -> Left (InvalidResource text)

resourceNameText :: ResourceName -> T.Text
resourceNameText (ResourceName text) =
  text

-- | A resource absent from the input is unknown, never assumed available (S6).
data Availability
  = ResourceAvailable
  | ResourceUnavailable
  | ResourceUnknown
  deriving (Eq, Show)

-- | The source Ticket revision the order was admitted against.
data SourceBasis
  = SourceBasis
  { sourceTicket :: TicketId
  , sourceRevision :: Int
  }
  deriving (Eq, Show)

data ScheduledOrder
  = ScheduledOrder
  { orderWorkOrder :: WorkOrder
  , orderRepository :: RepositoryId
  , orderPriority :: Priority
  , orderAdmittedAt :: UTCTime
  , orderDependencies :: [WorkOrderId]
  , orderBinding :: ProfileBinding
  , orderConfirmations :: [ProfileConfirmation]
  , orderEvidence :: [GateEvidence]
  , orderResources :: [ResourceName]
  , orderSource :: SourceBasis
  }
  deriving (Eq, Show)

data SchedulerInput
  = SchedulerInput
  { inputOrders :: [ScheduledOrder]
  , inputOwners :: [(RepositoryId, EngineerId)]
  , inputDefaults :: [(RepositoryId, ProfileRef)]
  , inputCatalog :: [ProfileRef]
  , inputResources :: [(ResourceName, Availability)]
  , inputRevisions :: [(TicketId, Int)]
  }
  deriving (Eq, Show)

-- | Why a queued order is not eligible; the constructor order is the S3 order.
data Ineligibility
  = BindingMismatch
  | ProfileDefaultUnset
  | ProfileChangedSince [ProfileId]
  | PrerequisiteBlocked GateId GateBlock
  | DependencyUnknown WorkOrderId
  | DependencyUnsatisfiable WorkOrderId
  | DependencyIncomplete WorkOrderId
  | RepositoryNotOwned
  | RepositoryReserved WorkOrderId
  | ResourceUnknownReason ResourceName
  | ResourceUnavailableReason ResourceName
  | SourceUnknown
  | SourceStale
  deriving (Eq, Show)

ineligibilityCode :: Ineligibility -> T.Text
ineligibilityCode reason =
  T.pack $
    case reason of
      BindingMismatch -> "binding-mismatch"
      ProfileDefaultUnset -> "profile-default-unset"
      ProfileChangedSince _ -> "profile-changed"
      PrerequisiteBlocked _ _ -> "prerequisite-blocked"
      DependencyUnknown _ -> "dependency-unknown"
      DependencyUnsatisfiable _ -> "dependency-unsatisfiable"
      DependencyIncomplete _ -> "dependency-incomplete"
      RepositoryNotOwned -> "repository-not-owned"
      RepositoryReserved _ -> "repository-reserved"
      ResourceUnknownReason _ -> "resource-unknown"
      ResourceUnavailableReason _ -> "resource-unavailable"
      SourceUnknown -> "source-unknown"
      SourceStale -> "source-stale"

data Ranked
  = Ranked WorkOrderId Priority UTCTime
  deriving (Eq, Show)

data ScheduleDecision
  = ScheduleDecision
  { dSelected :: Maybe (WorkOrderId, EngineerId)
  , dEligible :: [Ranked]
  , dIneligible :: [(WorkOrderId, [Ineligibility])]
  }
  deriving (Eq, Show)

data SchedulerRefusal
  = PriorityNotHuman Principal
  | InvalidPriority Int
  | InvalidResource T.Text
  | ConflictingInput T.Text
  deriving (Eq, Show)

schedulerRefusalCode :: SchedulerRefusal -> T.Text
schedulerRefusalCode refusal =
  T.pack $
    case refusal of
      PriorityNotHuman _ -> "priority-not-human"
      InvalidPriority _ -> "invalid-priority"
      InvalidResource _ -> "invalid-resource"
      ConflictingInput _ -> "conflicting-input"

-- Deciding -------------------------------------------------------------------

scheduleOrders :: SchedulerInput -> Either SchedulerRefusal ScheduleDecision
scheduleOrders input = do
  checkInput input
  let
    candidates = L.sortOn orderId (L.filter (isCandidate . orderState) (inputOrders input))
    assessed = fmap (\o -> (o, reasonsFor input o)) candidates
    eligible = L.sortBy (comparing rankKey) [o | (o, []) <- assessed]
    selected =
      case eligible of
        [] -> Nothing
        o : _ -> fmap (\e -> (orderId o, e)) (L.lookup (orderRepository o) (inputOwners input))
  pure
    ScheduleDecision
      { dSelected = selected
      , dEligible = fmap (\o -> Ranked (orderId o) (orderPriority o) (orderAdmittedAt o)) eligible
      , dIneligible = [(orderId o, reasons) | (o, reasons@(_ : _)) <- assessed]
      }

decisionSelected :: ScheduleDecision -> Maybe (WorkOrderId, EngineerId)
decisionSelected =
  dSelected

decisionEligible :: ScheduleDecision -> [WorkOrderId]
decisionEligible =
  fmap (\(Ranked i _ _) -> i) . dEligible

decisionIneligible :: ScheduleDecision -> [(WorkOrderId, [Ineligibility])]
decisionIneligible =
  dIneligible

-- | S7: priority (highest first), admission (oldest first), id (smallest first).
rankKey :: ScheduledOrder -> (Down Priority, UTCTime, WorkOrderId)
rankKey o =
  (Down (orderPriority o), orderAdmittedAt o, orderId o)

-- | S8: a repeated key anywhere refuses the whole decision.
checkInput :: SchedulerInput -> Either SchedulerRefusal ()
checkInput input = do
  unique "work orders" (fmap orderId (inputOrders input))
  unique "repository owners" (fmap fst (inputOwners input))
  unique "repository defaults" (fmap fst (inputDefaults input))
  unique "resources" (fmap fst (inputResources input))
  unique "source revisions" (fmap fst (inputRevisions input))
  traverse_ (unique "order resources" . orderResources) (inputOrders input)
  traverse_ (unique "order dependencies" . orderDependencies) (inputOrders input)
 where
  unique :: Eq a => String -> [a] -> Either SchedulerRefusal ()
  unique what keys =
    if L.length (L.nub keys) == L.length keys
      then Right ()
      else Left (ConflictingInput (T.pack what))

-- | Every S3 reason for one candidate, in the S3 order.
reasonsFor :: SchedulerInput -> ScheduledOrder -> [Ineligibility]
reasonsFor input o =
  L.concat
    [ profileReasons
    , mapMaybe dependency (L.sort (orderDependencies o))
    , [RepositoryNotOwned | isNothing (L.lookup repository (inputOwners input))]
    , [ RepositoryReserved (orderId x)
      | x <- L.sortOn orderId (inputOrders input)
      , orderId x /= orderId o
      , orderRepository x == repository
      , reserves (orderState x)
      ]
    , mapMaybe resource (L.sort (orderResources o))
    , source
    ]
 where
  repository = orderRepository o
  binding = orderBinding o
  profileReasons
    | bindingWorkOrder binding /= orderId o = [BindingMismatch]
    | otherwise = freshness <> prerequisites
  freshness =
    case L.lookup repository (inputDefaults input) of
      Nothing -> [ProfileDefaultUnset]
      Just current ->
        case bindingFreshness binding (orderConfirmations o) current (inputCatalog input) of
          Fresh -> []
          ProfileChanged ids -> [ProfileChangedSince ids]
  -- Clarification 1: only before-execution gates are scheduling prerequisites.
  prerequisites =
    [ PrerequisiteBlocked (gateId gate) block
    | gate <- executionPrerequisites binding
    , GateBlocked block <- [evaluateGate binding (orderEvidence o) gate]
    ]
  states = fmap (\x -> (orderId x, orderState x)) (inputOrders input)
  dependency d =
    case L.lookup d states of
      Nothing -> Just (DependencyUnknown d)
      Just (Completed _ _) -> Nothing
      Just (Superseded _) -> Just (DependencyUnsatisfiable d)
      Just Canceled -> Just (DependencyUnsatisfiable d)
      Just _ -> Just (DependencyIncomplete d)
  resource r =
    case L.lookup r (inputResources input) of
      Just ResourceAvailable -> Nothing
      Just ResourceUnavailable -> Just (ResourceUnavailableReason r)
      _ -> Just (ResourceUnknownReason r)
  basis = orderSource o
  source =
    case L.lookup (sourceTicket basis) (inputRevisions input) of
      Nothing -> [SourceUnknown]
      Just current
        | current /= sourceRevision basis -> [SourceStale]
        | otherwise -> []

orderId :: ScheduledOrder -> WorkOrderId
orderId =
  workOrderId . orderWorkOrder

orderState :: ScheduledOrder -> WorkOrderState
orderState =
  workOrderState . orderWorkOrder

-- | S1: only queued orders are candidates.
isCandidate :: WorkOrderState -> Bool
isCandidate state =
  case state of
    Pending -> True
    Eligible -> True
    _ -> False

-- | S5 (clarification 3): only a claim-bearing order holds an active reservation.
reserves :: WorkOrderState -> Bool
reserves state =
  case state of
    Claimed _ -> True
    Active _ -> True
    Waiting _ _ -> True
    _ -> False

-- | S10: the Scheduler's lifecycle commands, by order id.
schedulingCommands :: SchedulerInput -> ScheduleDecision -> [(WorkOrderId, Command WorkOrderInput)]
schedulingCommands input decision =
  let
    eligible = decisionEligible decision
    command o =
      case (orderState o, orderId o `L.elem` eligible) of
        (Pending, True) -> Just (orderId o, Command Scheduler WoMarkEligible)
        (Eligible, False) -> Just (orderId o, Command Scheduler WoMarkIneligible)
        _ -> Nothing
  in
    mapMaybe command (L.sortOn orderId (inputOrders input))

-- Rendering (§3) -------------------------------------------------------------

renderScheduleDecision :: ScheduleDecision -> T.Text
renderScheduleDecision decision =
  T.unlines $
    [T.pack "lockstep-schedule 1", selectedLine]
      <> L.zipWith eligibleLine [1 :: Int ..] (dEligible decision)
      <> [ineligibleLine i reason | (i, reasons) <- dIneligible decision, reason <- reasons]
 where
  selectedLine =
    case dSelected decision of
      Nothing -> T.pack "selected none"
      Just (i, EngineerId e) -> T.pack "selected " <> orderText i <> T.pack " engineer " <> uuidText e
  eligibleLine rank (Ranked i p t) =
    T.unwords
      [ T.pack "eligible"
      , T.pack (show rank)
      , orderText i
      , T.pack ("priority=" <> show (priorityValue p))
      , T.pack ("admitted-at=" <> iso8601Show t)
      ]
  ineligibleLine i reason =
    T.unwords ([T.pack "ineligible", orderText i, ineligibilityCode reason] <> detail reason)

detail :: Ineligibility -> [T.Text]
detail reason =
  case reason of
    ProfileChangedSince ids -> [T.intercalate (T.pack ",") (L.sort (fmap profileIdText ids))]
    PrerequisiteBlocked g block -> [gateIdText g, blockCode block, artifactName (blockArtifact block)]
    DependencyUnknown d -> [orderText d]
    DependencyUnsatisfiable d -> [orderText d]
    DependencyIncomplete d -> [orderText d]
    RepositoryReserved holder -> [orderText holder]
    ResourceUnknownReason r -> [resourceNameText r]
    ResourceUnavailableReason r -> [resourceNameText r]
    BindingMismatch -> []
    ProfileDefaultUnset -> []
    RepositoryNotOwned -> []
    SourceUnknown -> []
    SourceStale -> []

blockCode :: GateBlock -> T.Text
blockCode block =
  T.pack $
    case block of
      MissingArtifact _ -> "missing-artifact"
      AmbiguousEvidence _ -> "ambiguous-evidence"
      Unverified _ _ -> "unverified"
      NeedsApproval _ _ -> "needs-approval"

blockArtifact :: GateBlock -> ArtifactKind
blockArtifact block =
  case block of
    MissingArtifact kind -> kind
    AmbiguousEvidence kind -> kind
    Unverified kind _ -> kind
    NeedsApproval kind _ -> kind

-- | The C-P2.3 F1 artifact names (the Profile module does not export its own).
artifactName :: ArtifactKind -> T.Text
artifactName kind =
  T.pack $
    case kind of
      RequirementsBasis -> "requirements-basis"
      Reproduction -> "reproduction"
      ImpactAssessment -> "impact-assessment"
      ThreatModel -> "threat-model"
      ArchitectureAssessment -> "architecture-assessment"
      ClassificationRationale -> "classification-rationale"
      HumanApprovalRecord -> "human-approval"
      FrozenTests -> "frozen-tests"
      VerificationRecord -> "verification-record"
      ReviewRecord -> "review-record"
      RegressionEvidence -> "regression-evidence"
      IntegrationRecord -> "integration-record"
      Documentation -> "documentation"

orderText :: WorkOrderId -> T.Text
orderText (WorkOrderId u) =
  uuidText u

scheduleDigest :: Hasher -> ScheduleDecision -> ContentDigest
scheduleDigest (Hasher f) =
  f . renderScheduleDecision
