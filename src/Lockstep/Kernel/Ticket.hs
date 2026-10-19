{- | The Ticket lifecycle: business intent and the final human disposition
(contract C-P2.2 T4, §3.1). A Ticket state grants no code-mutation authority.
Code Complete needs accepted Work Unit evidence; Ready for Signoff needs
integration evidence covering those Work Units; Done needs a human signoff
from Ready for Signoff and is reachable in no other way.
-}
module Lockstep.Kernel.Ticket
  ( TicketState (..)
  , TicketInput (..)
  , stepTicket
  , ticketStateName
  , ticketInputName
  ) where

import Data.List qualified as L
import Data.List.NonEmpty qualified as NE
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Delivery (IntegrationEvidence, integratedWorkUnits)
import Lockstep.Kernel.Evidence (HumanSignoff)
import Lockstep.Kernel.Transition (Cell (..), Command (..), Principal (..), TransitionRefusal (..), decide)
import Lockstep.Kernel.WorkUnitLifecycle (AcceptedWorkUnit, acceptedWorkUnitId)

data TicketState
  = Proposed
  | Ready
  | InProgress
  | CodeComplete (NonEmpty AcceptedWorkUnit)
  | AwaitingReview (NonEmpty AcceptedWorkUnit)
  | ReadyForSignoff IntegrationEvidence
  | Done HumanSignoff
  | Canceled HumanSignoff
  | -- | The reason and the state to return to (never Blocked or terminal).
    Blocked T.Text TicketState
  deriving (Eq, Show)

data TicketInput
  = TicketAccept
  | TicketStartWork
  | TicketWorkAccepted (NonEmpty AcceptedWorkUnit)
  | TicketReviewRequested
  | TicketChangesRequested
  | TicketIntegrated IntegrationEvidence
  | TicketSignoff HumanSignoff
  | TicketCancel HumanSignoff
  | TicketBlock T.Text
  | TicketUnblock
  deriving (Eq, Show)

stepTicket :: TicketState -> Command TicketInput -> Either TransitionRefusal TicketState
stepTicket state (Command principal input) =
  decide principal (ticketStateName state) (terminal state) (ticketInputName input) (cell state input)

terminal :: TicketState -> Bool
terminal state =
  case state of
    Done _ -> True
    Canceled _ -> True
    _ -> False

-- | The §3.1 table.
cell :: TicketState -> TicketInput -> Maybe (Cell TicketState)
cell state input =
  case (state, input) of
    (_, TicketCancel signoff) -> Just (Cell [Human] (Right (Canceled signoff)))
    (Blocked _ prior, TicketUnblock) -> Just (Cell [Human] (Right prior))
    (Blocked _ _, _) -> Nothing
    (_, TicketBlock reason) -> Just (Cell [Human, Supervisor] (Right (Blocked reason state)))
    (Proposed, TicketAccept) -> Just (Cell [Human] (Right Ready))
    (Ready, TicketStartWork) -> Just (Cell [Supervisor] (Right InProgress))
    (InProgress, TicketWorkAccepted units) -> Just (Cell [Supervisor] (Right (CodeComplete units)))
    (CodeComplete units, TicketReviewRequested) -> Just (Cell [DeliveryAdapter] (Right (AwaitingReview units)))
    (CodeComplete _, TicketChangesRequested) -> Just (Cell [DeliveryAdapter] (Right InProgress))
    (AwaitingReview _, TicketChangesRequested) -> Just (Cell [DeliveryAdapter] (Right InProgress))
    (CodeComplete units, TicketIntegrated evidence) -> integrated units evidence
    (AwaitingReview units, TicketIntegrated evidence) -> integrated units evidence
    (ReadyForSignoff _, TicketSignoff signoff) -> Just (Cell [Human] (Right (Done signoff)))
    _ -> Nothing
 where
  integrated units evidence =
    Just . Cell [Supervisor, DeliveryAdapter] $
      if L.all ((`L.elem` NE.toList (integratedWorkUnits evidence)) . acceptedWorkUnitId) (NE.toList units)
        then Right (ReadyForSignoff evidence)
        else Left (BasisMismatch (T.pack "the integration does not cover every accepted Work Unit"))

ticketStateName :: TicketState -> T.Text
ticketStateName state =
  T.pack $
    case state of
      Proposed -> "proposed"
      Ready -> "ready"
      InProgress -> "in-progress"
      CodeComplete _ -> "code-complete"
      AwaitingReview _ -> "awaiting-review"
      ReadyForSignoff _ -> "ready-for-signoff"
      Done _ -> "done"
      Canceled _ -> "canceled"
      Blocked _ _ -> "blocked"

ticketInputName :: TicketInput -> T.Text
ticketInputName input =
  T.pack $
    case input of
      TicketAccept -> "accept"
      TicketStartWork -> "start-work"
      TicketWorkAccepted _ -> "work-accepted"
      TicketReviewRequested -> "review-requested"
      TicketChangesRequested -> "changes-requested"
      TicketIntegrated _ -> "integrated"
      TicketSignoff _ -> "signoff"
      TicketCancel _ -> "cancel"
      TicketBlock _ -> "block"
      TicketUnblock -> "unblock"
