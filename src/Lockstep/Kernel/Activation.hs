{- | Carrying an effect intent into a new activation of its Work Order
(contract C-P2.9-R1 M2, §2.1). An intent belongs to the activation (the claim
generation) that authorized it; after a halt and requeue it cannot run until a
Human carries it, and only when nothing about it is uncertain or in flight.
A carry keeps the intent itself: its operation id, parameters, budget and
history.
-}
module Lockstep.Kernel.Activation
  ( CarryInput (..)
  , carryDecision
  , CarryRefusal (..)
  , carryRefusalCode
  ) where

import Data.Text qualified as T
import Data.Time (UTCTime)
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Effect
  ( EffectClass (..)
  , Intent (..)
  , IntentState (..)
  , Lease (..)
  , effectSpecBudget
  , effectSpecClass
  )
import Lockstep.Kernel.Transition (Command (..), Principal (..))

-- | The time; the intent's activation; the order's current activation, if it is active; whether a class-B key still holds.
data CarryInput
  = CarryInput
  { carryNow :: UTCTime
  , carrySource :: Int
  , carryTarget :: Maybe Int
  , carryKeyHolds :: Bool
  }
  deriving (Eq, Show)

-- | §2.1, in its check order.
carryDecision :: Intent -> Command CarryInput -> Either CarryRefusal ()
carryDecision intent (Command principal input)
  | principal == Agent = Left CarryAgentAssertion
  | principal /= Human = Left (CarryNotAuthorized principal)
  | otherwise =
      case carryTarget input of
        Nothing -> Left CarrySubjectNotActive
        Just target
          | target == carrySource input -> Left CarryNotNeeded
          | otherwise -> stateCheck
 where
  stateCheck =
    case intentState intent of
      IntentSettled _ -> Left CarryAlreadySettled
      IntentAbandoned _ -> Left CarryAlreadySettled
      IntentUnknown _ -> Left CarryOutcomeUnknown
      IntentDispatched _ -> Left CarryInFlight
      IntentClaimed lease
        | carryNow input < leaseUntil lease -> Left CarryClaimHeld
        | otherwise -> Right ()
      IntentApplied _ -> Left CarryNotCarryable
      IntentNotApplied _
        | intentDispatches intent > effectSpecBudget (intentSpec intent) -> Left CarryRetriesExhausted
        | otherwise -> Right ()
      IntentPending
        | effectSpecClass (intentSpec intent) == Idempotent
            && intentDispatches intent >= 1
            && not (carryKeyHolds input) ->
            Left CarryKeyExpired
        | otherwise -> Right ()

data CarryRefusal
  = CarryAgentAssertion
  | CarryNotAuthorized Principal
  | CarrySubjectNotActive
  | CarryNotNeeded
  | CarryAlreadySettled
  | CarryOutcomeUnknown
  | CarryInFlight
  | CarryClaimHeld
  | CarryNotCarryable
  | CarryRetriesExhausted
  | CarryKeyExpired
  deriving (Eq, Show)

carryRefusalCode :: CarryRefusal -> T.Text
carryRefusalCode refusal =
  T.pack $
    case refusal of
      CarryAgentAssertion -> "agent-assertion"
      CarryNotAuthorized _ -> "not-authorized"
      CarrySubjectNotActive -> "subject-not-active"
      CarryNotNeeded -> "carry-not-needed"
      CarryAlreadySettled -> "already-settled"
      CarryOutcomeUnknown -> "outcome-unknown"
      CarryInFlight -> "dispatched-needs-recovery"
      CarryClaimHeld -> "claim-held"
      CarryNotCarryable -> "not-carryable"
      CarryRetriesExhausted -> "retries-exhausted"
      CarryKeyExpired -> "idempotency-key-expired"
