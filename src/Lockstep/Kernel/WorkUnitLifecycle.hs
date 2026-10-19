{- | The Work Unit lifecycle: bounded engineering (contract C-P2.2 T6, §3.3).
States carry their prerequisite evidence (Bible §37.1): 'Verifying' holds the
observed commit; 'Verified' holds a passing verification of that commit and
the post-verification gates still pending; 'Accepted' holds the contract,
commit and verification. Uncertain verification is never treated as passed.

'AcceptedWorkUnit' and 'FrozenContract' are exported without constructors, so
evidence can be obtained only through 'acceptedWorkUnit' and a contract only
through 'mkFrozenContract'.
-}
module Lockstep.Kernel.WorkUnitLifecycle
  ( FrozenContract
  , mkFrozenContract
  , frozenContractId
  , frozenDigest
  , frozenAttemptBudget
  , frozenGates
  , Attempt (..)
  , CheckOutcome (..)
  , Verification (..)
  , ReviewVerdict (..)
  , WorkUnitState (..)
  , WorkUnit (..)
  , newWorkUnit
  , WorkUnitInput (..)
  , stepWorkUnit
  , workUnitStateName
  , workUnitInputName
  , AcceptedWorkUnit
  , acceptedWorkUnit
  , acceptedWorkUnitId
  , acceptedCommit
  ) where

import Data.Char qualified as Char
import Data.List qualified as L
import Data.List.NonEmpty qualified as NE
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Evidence (CommitId)
import Lockstep.Kernel.Identity (AttemptId, ContractId, WorkUnitId)
import Lockstep.Kernel.Transition (Cell (..), Command (..), Principal (..), TransitionRefusal (..), decide)
import Lockstep.Kernel.WorkUnit (AdmittedWorkUnit (..), WorkUnitRequest (..))

-- | A frozen Contract: identity, digest, attempt budget and post-verification gates.
data FrozenContract
  = FrozenContract ContractId T.Text Int [T.Text]
  deriving (Eq, Show)

-- | Budget 1–10, a 64-character lowercase hex digest, unique non-empty gate names.
mkFrozenContract :: ContractId -> T.Text -> Int -> [T.Text] -> Maybe FrozenContract
mkFrozenContract contract digest budget gates =
  if budget >= 1
    && budget <= 10
    && T.length digest == 64
    && T.all (\c -> Char.isDigit c || (c >= 'a' && c <= 'f')) digest
    && not (L.any T.null gates)
    && L.nub gates == gates
    then Just (FrozenContract contract digest budget gates)
    else Nothing

frozenContractId :: FrozenContract -> ContractId
frozenContractId (FrozenContract contract _ _ _) =
  contract

frozenDigest :: FrozenContract -> T.Text
frozenDigest (FrozenContract _ digest _ _) =
  digest

frozenAttemptBudget :: FrozenContract -> Int
frozenAttemptBudget (FrozenContract _ _ budget _) =
  budget

frozenGates :: FrozenContract -> [T.Text]
frozenGates (FrozenContract _ _ _ gates) =
  gates

data Attempt
  = Attempt
  { attemptId :: AttemptId
  , attemptNumber :: Int
  }
  deriving (Eq, Show)

data CheckOutcome
  = CheckPassed
  | CheckFailed
  | CheckNotRun
  | CheckUnknown
  deriving (Eq, Show, Enum, Bounded)

-- | A deterministic verification of one commit: named checks and their outcomes.
data Verification
  = Verification
  { verifiedCommit :: CommitId
  , verifiedChecks :: NonEmpty (T.Text, CheckOutcome)
  }
  deriving (Eq, Show)

data ReviewVerdict
  = ReviewApproved
  | ReviewChangesRequested T.Text
  deriving (Eq, Show)

data WorkUnitState
  = Candidate
  | Frozen FrozenContract
  | Implementing FrozenContract Attempt
  | Verifying FrozenContract Attempt CommitId
  | Verified FrozenContract Attempt Verification [T.Text]
  | Rework FrozenContract Int T.Text
  | Accepted FrozenContract CommitId Verification
  | Halted T.Text
  deriving (Eq, Show)

data WorkUnit
  = WorkUnit
  { workUnitIdentity :: AdmittedWorkUnit
  , workUnitState :: WorkUnitState
  }
  deriving (Eq, Show)

newWorkUnit :: AdmittedWorkUnit -> WorkUnit
newWorkUnit identity =
  WorkUnit identity Candidate

data WorkUnitInput
  = WuFreeze FrozenContract
  | WuStartAttempt Attempt
  | WuImplementationObserved CommitId
  | WuVerificationObserved Verification
  | WuGatePassed T.Text
  | WuGateFailed T.Text T.Text
  | WuReviewObserved ReviewVerdict
  | WuHalt T.Text
  deriving (Eq, Show)

stepWorkUnit :: WorkUnit -> Command WorkUnitInput -> Either TransitionRefusal WorkUnit
stepWorkUnit unit (Command principal input) =
  let
    state = workUnitState unit
  in
    fmap
      (\next -> unit {workUnitState = next})
      (decide principal (workUnitStateName state) (terminal state) (workUnitInputName input) (cell state input))

terminal :: WorkUnitState -> Bool
terminal state =
  case state of
    Accepted {} -> True
    Halted _ -> True
    _ -> False

-- | The §3.3 table.
cell :: WorkUnitState -> WorkUnitInput -> Maybe (Cell WorkUnitState)
cell state input =
  case (state, input) of
    (_, WuHalt reason) -> Just (Cell [Human, Supervisor] (Right (Halted reason)))
    (Candidate, WuFreeze contract) -> supervisor (Right (Frozen contract))
    (Frozen contract, WuStartAttempt a) -> supervisor (startAttempt contract 0 a)
    (Rework contract used _, WuStartAttempt a) -> supervisor (startAttempt contract used a)
    (Implementing contract a, WuImplementationObserved commit) -> supervisor (Right (Verifying contract a commit))
    (Verifying contract a commit, WuVerificationObserved v) -> supervisor (verify contract a commit v)
    (Verified contract a v pending, WuGatePassed gate) ->
      supervisor $
        if gate `L.elem` pending
          then Right (Verified contract a v (L.delete gate pending))
          else Left (BasisMismatch (T.pack "the gate is not pending"))
    (Verified contract a _ pending, WuGateFailed gate _) ->
      supervisor $
        if gate `L.elem` pending
          then Right (afterFailure contract a (T.pack "gate-failed"))
          else Left (BasisMismatch (T.pack "the gate is not pending"))
    (Verified contract a v pending, WuReviewObserved verdict)
      | not (L.null pending) -> supervisor (Left GatesPending)
      | otherwise ->
          supervisor $
            case verdict of
              ReviewApproved -> Right (Accepted contract (verifiedCommit v) v)
              ReviewChangesRequested _ -> Right (afterFailure contract a (T.pack "review-changes-requested"))
    _ -> Nothing
 where
  supervisor =
    Just . Cell [Supervisor]

-- | The next attempt must be number used + 1 and within the budget.
startAttempt :: FrozenContract -> Int -> Attempt -> Either TransitionRefusal WorkUnitState
startAttempt contract used a
  | used + 1 > frozenAttemptBudget contract = Left AttemptBudgetExhausted
  | attemptNumber a /= used + 1 = Left (BasisMismatch (T.pack "the attempt number is not the next one"))
  | otherwise = Right (Implementing contract a)

-- | Rework while attempts remain; otherwise halt.
afterFailure :: FrozenContract -> Attempt -> T.Text -> WorkUnitState
afterFailure contract a reason =
  if attemptNumber a < frozenAttemptBudget contract
    then Rework contract (attemptNumber a) reason
    else Halted (T.pack "attempts-exhausted")

{- | Any failure is a failure; otherwise everything must have passed. NotRun and
Unknown are never passed: they halt for a human (T6).
-}
verify :: FrozenContract -> Attempt -> CommitId -> Verification -> Either TransitionRefusal WorkUnitState
verify contract a commit v
  | verifiedCommit v /= commit = Left (BasisMismatch (T.pack "the verification is of another commit"))
  | CheckFailed `L.elem` outcomes = Right (afterFailure contract a (T.pack "verification-failed"))
  | L.all (== CheckPassed) outcomes = Right (Verified contract a v (frozenGates contract))
  | otherwise = Right (Halted (T.pack "verification-inconclusive"))
 where
  outcomes = fmap snd (NE.toList (verifiedChecks v))

workUnitStateName :: WorkUnitState -> T.Text
workUnitStateName state =
  T.pack $
    case state of
      Candidate -> "candidate"
      Frozen _ -> "frozen"
      Implementing _ _ -> "implementing"
      Verifying {} -> "verifying"
      Verified {} -> "verified"
      Rework {} -> "rework"
      Accepted {} -> "accepted"
      Halted _ -> "halted"

workUnitInputName :: WorkUnitInput -> T.Text
workUnitInputName input =
  T.pack $
    case input of
      WuFreeze _ -> "freeze"
      WuStartAttempt _ -> "start-attempt"
      WuImplementationObserved _ -> "implementation-observed"
      WuVerificationObserved _ -> "verification-observed"
      WuGatePassed _ -> "gate-passed"
      WuGateFailed _ _ -> "gate-failed"
      WuReviewObserved _ -> "review-observed"
      WuHalt _ -> "halt"

-- | Evidence that a specific Work Unit was accepted at a specific commit.
data AcceptedWorkUnit
  = AcceptedWorkUnit WorkUnitId CommitId
  deriving (Eq, Show)

acceptedWorkUnit :: WorkUnit -> Maybe AcceptedWorkUnit
acceptedWorkUnit unit =
  case workUnitState unit of
    Accepted _ commit _ -> Just (AcceptedWorkUnit (wuId (admittedRequest (workUnitIdentity unit))) commit)
    _ -> Nothing

acceptedWorkUnitId :: AcceptedWorkUnit -> WorkUnitId
acceptedWorkUnitId (AcceptedWorkUnit unit _) =
  unit

acceptedCommit :: AcceptedWorkUnit -> CommitId
acceptedCommit (AcceptedWorkUnit _ commit) =
  commit
