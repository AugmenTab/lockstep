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
  , CarryRequest (..)
  , carryChecked
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

-- | §2.1, in its check order: 'carryChecked' with no expected activations, no acknowledgment and no conflict.
carryDecision :: Intent -> Command CarryInput -> Either CarryRefusal ()
carryDecision intent (Command principal input) =
  carryChecked
    intent
    ( Command
        principal
        CarryRequest
          { requestInput = input
          , requestExpected = Nothing
          , requestAcknowledged = False
          , requestAttested = False
          , requestConflict = False
          }
    )

{- | A carry as the Human states it (§4.2 N2-N4): the activations it expects
to carry between, whether it acknowledges the duplication risk; and what the
ledger knows: whether the intent's not-applied outcome was attested by a
Human, and whether the target activation already has a live intent with the
same effect key.
-}
data CarryRequest
  = CarryRequest
  { requestInput :: CarryInput
  , requestExpected :: Maybe (Int, Int)
  , requestAcknowledged :: Bool
  , requestAttested :: Bool
  , requestConflict :: Bool
  }
  deriving (Eq, Show)

-- | §2.1 and §4.2, in check order.
carryChecked :: Intent -> Command CarryRequest -> Either CarryRefusal ()
carryChecked intent (Command principal request)
  | principal == Agent = Left CarryAgentAssertion
  | principal /= Human = Left (CarryNotAuthorized principal)
  | otherwise =
      case carryTarget input of
        Nothing -> Left CarrySubjectNotActive
        Just target
          | target == carrySource input -> Left CarryNotNeeded
          | maybe False (/= (carrySource input, target)) (requestExpected request) -> Left CarryStale
          | otherwise -> do
              stateCheck
              when (attested && not (requestAcknowledged request)) (Left CarryNotAcknowledged)
              when (requestConflict request) (Left CarryConflict)
 where
  input = requestInput request
  dispatchedBefore =
    effectSpecClass (intentSpec intent) == Idempotent && intentDispatches intent >= 1
  -- N1: a carryable idempotent intent that was dispatched before needs its key guarantee.
  keyCheck
    | dispatchedBefore && not (carryKeyHolds input) = Left CarryKeyExpired
    | otherwise = Right ()
  -- §4.5 P2: an attestation record needs the acknowledgment in every carryable state.
  attested =
    requestAttested request
      || case intentState intent of
        IntentNotApplied reason -> T.pack "human-attested: " `T.isPrefixOf` reason
        _ -> False
  stateCheck =
    case intentState intent of
      IntentSettled _ -> Left CarryAlreadySettled
      IntentAbandoned _ -> Left CarryAlreadySettled
      IntentUnknown _ -> Left CarryOutcomeUnknown
      IntentDispatched _ -> Left CarryInFlight
      IntentClaimed lease
        | carryNow input < leaseUntil lease -> Left CarryClaimHeld
        | otherwise -> keyCheck
      IntentApplied _ -> Left CarryNotCarryable
      IntentNotApplied _
        | intentDispatches intent > effectSpecBudget (intentSpec intent) -> Left CarryRetriesExhausted
        | otherwise -> keyCheck
      IntentPending -> keyCheck

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
  | CarryStale
  | CarryNotAcknowledged
  | CarryConflict
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
      CarryStale -> "stale-carry"
      CarryNotAcknowledged -> "duplication-risk-not-acknowledged"
      CarryConflict -> "carry-conflict"
