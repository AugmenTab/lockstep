{- | The Delivery lifecycle: integration and downstream completion (contract
C-P2.2 T7, §3.4). There is no Done state: an integrated delivery yields
'IntegrationEvidence', which moves a Ticket only to Ready for Signoff; Done
remains a human decision on the Ticket.

In PullRequest mode integration requires an approval of exactly the commit
being integrated, and a push after approval makes that approval stale. In
LocalOnly mode the Supervisor integrates locally and nothing is published.
-}
module Lockstep.Kernel.Delivery
  ( DeliveryMode (..)
  , PullRequestRef
  , mkPullRequestRef
  , pullRequestRefText
  , DeliveryState (..)
  , Delivery (..)
  , newDelivery
  , DeliveryInput (..)
  , stepDelivery
  , deliveryStateName
  , deliveryInputName
  , IntegrationEvidence
  , integrationEvidence
  , integratedWorkUnits
  , integratedCommit
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Evidence (CommitId)
import Lockstep.Kernel.Identity (WorkUnitId)
import Lockstep.Kernel.Transition (Cell (..), Command (..), Principal (..), TransitionRefusal (..), decide)
import Lockstep.Kernel.WorkUnitLifecycle (AcceptedWorkUnit, acceptedWorkUnitId)

data DeliveryMode
  = LocalOnly
  | PullRequest
  deriving (Eq, Show, Enum, Bounded)

newtype PullRequestRef
  = PullRequestRef T.Text
  deriving (Eq, Show)

mkPullRequestRef :: T.Text -> Maybe PullRequestRef
mkPullRequestRef text =
  if T.null text then Nothing else Just (PullRequestRef text)

pullRequestRefText :: PullRequestRef -> T.Text
pullRequestRefText (PullRequestRef text) =
  text

data DeliveryState
  = LocallyAccepted (NonEmpty AcceptedWorkUnit)
  | Published (NonEmpty AcceptedWorkUnit) PullRequestRef CommitId
  | Approved (NonEmpty AcceptedWorkUnit) PullRequestRef CommitId
  | ChangesRequested (NonEmpty AcceptedWorkUnit) PullRequestRef
  | StaleApproval (NonEmpty AcceptedWorkUnit) PullRequestRef CommitId
  | Integrated (NonEmpty AcceptedWorkUnit) CommitId
  | ClosedWithoutMerge (NonEmpty AcceptedWorkUnit) PullRequestRef
  | NeedsReconciliation DeliveryState T.Text
  deriving (Eq, Show)

data Delivery
  = Delivery
  { deliveryMode :: DeliveryMode
  , deliveryState :: DeliveryState
  }
  deriving (Eq, Show)

newDelivery :: DeliveryMode -> NonEmpty AcceptedWorkUnit -> Delivery
newDelivery mode units =
  Delivery mode (LocallyAccepted units)

data DeliveryInput
  = DelPublish PullRequestRef CommitId
  | DelApprove CommitId
  | DelRequestChanges
  | DelPush CommitId
  | DelIntegrate CommitId
  | DelClose
  | DelOutcomeUnknown T.Text
  | DelReconciled
  deriving (Eq, Show)

stepDelivery :: Delivery -> Command DeliveryInput -> Either TransitionRefusal Delivery
stepDelivery delivery (Command principal input) =
  let
    state = deliveryState delivery
  in
    fmap
      (\next -> delivery {deliveryState = next})
      (decide principal (deliveryStateName state) (terminal state) (deliveryInputName input) (cell (deliveryMode delivery) state input))

terminal :: DeliveryState -> Bool
terminal state =
  case state of
    Integrated _ _ -> True
    ClosedWithoutMerge _ _ -> True
    _ -> False

-- | The §3.4 table.
cell :: DeliveryMode -> DeliveryState -> DeliveryInput -> Maybe (Cell DeliveryState)
cell mode state input =
  case (state, input) of
    (NeedsReconciliation prior _, DelReconciled) -> Just (Cell [Supervisor] (Right prior))
    (NeedsReconciliation _ _, _) -> Nothing
    (_, DelOutcomeUnknown reason) -> Just (Cell [DeliveryAdapter, Supervisor] (Right (NeedsReconciliation state reason)))
    (LocallyAccepted units, DelPublish pr commit) ->
      adapter $
        case mode of
          LocalOnly -> Left (KindForbids (T.pack "a local-only delivery is never published"))
          PullRequest -> Right (Published units pr commit)
    (LocallyAccepted units, DelIntegrate commit)
      | mode == LocalOnly -> Just (Cell [Supervisor] (Right (Integrated units commit)))
    (Published units pr published, DelApprove commit) -> adapter (approve units pr published commit)
    (StaleApproval units pr pushed, DelApprove commit) -> adapter (approve units pr pushed commit)
    (Published units pr _, DelRequestChanges) -> adapter (Right (ChangesRequested units pr))
    (Approved units pr _, DelRequestChanges) -> adapter (Right (ChangesRequested units pr))
    (StaleApproval units pr _, DelRequestChanges) -> adapter (Right (ChangesRequested units pr))
    (ChangesRequested units pr, DelPush commit) -> adapter (Right (Published units pr commit))
    (Approved units pr approved, DelPush commit) ->
      adapter $
        if commit == approved
          then Left (BasisMismatch (T.pack "the pushed commit is the approved one"))
          else Right (StaleApproval units pr commit)
    (Approved units _ approved, DelIntegrate commit) ->
      adapter $
        if commit == approved
          then Right (Integrated units commit)
          else Left (BasisMismatch (T.pack "the integrated commit is not the approved one"))
    (Published units pr _, DelClose) -> adapter (Right (ClosedWithoutMerge units pr))
    (Approved units pr _, DelClose) -> adapter (Right (ClosedWithoutMerge units pr))
    (ChangesRequested units pr, DelClose) -> adapter (Right (ClosedWithoutMerge units pr))
    (StaleApproval units pr _, DelClose) -> adapter (Right (ClosedWithoutMerge units pr))
    _ -> Nothing
 where
  adapter =
    Just . Cell [DeliveryAdapter]
  approve units pr current commit =
    if commit == current
      then Right (Approved units pr current)
      else Left (BasisMismatch (T.pack "the approval is for another commit"))

deliveryStateName :: DeliveryState -> T.Text
deliveryStateName state =
  T.pack $
    case state of
      LocallyAccepted _ -> "locally-accepted"
      Published {} -> "published"
      Approved {} -> "approved"
      ChangesRequested _ _ -> "changes-requested"
      StaleApproval {} -> "stale-approval"
      Integrated _ _ -> "integrated"
      ClosedWithoutMerge _ _ -> "closed-without-merge"
      NeedsReconciliation _ _ -> "needs-reconciliation"

deliveryInputName :: DeliveryInput -> T.Text
deliveryInputName input =
  T.pack $
    case input of
      DelPublish _ _ -> "publish"
      DelApprove _ -> "approve"
      DelRequestChanges -> "request-changes"
      DelPush _ -> "push"
      DelIntegrate _ -> "integrate"
      DelClose -> "close"
      DelOutcomeUnknown _ -> "outcome-unknown"
      DelReconciled -> "reconciled"

-- | Evidence that specific Work Units were integrated at a specific commit.
data IntegrationEvidence
  = IntegrationEvidence (NonEmpty WorkUnitId) CommitId
  deriving (Eq, Show)

integrationEvidence :: Delivery -> Maybe IntegrationEvidence
integrationEvidence delivery =
  case deliveryState delivery of
    Integrated units commit -> Just (IntegrationEvidence (fmap acceptedWorkUnitId units) commit)
    _ -> Nothing

integratedWorkUnits :: IntegrationEvidence -> NonEmpty WorkUnitId
integratedWorkUnits (IntegrationEvidence units _) =
  units

integratedCommit :: IntegrationEvidence -> CommitId
integratedCommit (IntegrationEvidence _ commit) =
  commit
