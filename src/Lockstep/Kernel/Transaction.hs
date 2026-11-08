{- | The single-Engineer coding transaction (contract C-P4.6 T1–T4; DG-06,
DG-07, DG-17 as accepted; @engine-design.md@ §1, §3a). Pure: which stage
comes next from what the Supervisor observed, the finite budgets, and what
only a person may do. An Agent is never accepted.
-}
module Lockstep.Kernel.Transaction
  ( Stage (..)
  , stageName
  , parseStage
  , TxState (..)
  , txStateName
  , StateName (..)
  , stateNameOf
  , stateNameText
  , parseStateName
  , HaltCode (..)
  , haltCodeText
  , haltCodeFromText
  , Counters (..)
  , noCounters
  , Transaction (..)
  , newTransaction
  , BaselineClass (..)
  , baselineClassName
  , correctable
  , Disposition (..)
  , dispositionName
  , TxInput (..)
  , txInputName
  , stepTransaction
  , maxCorrections
  , maxAttempts
  , stateColumns
  , stateStage
  , stateFromColumns
  , reproduces
  , haltChoices
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Roles (Check (..))
import Lockstep.Kernel.Runner (RunOutcome (..))
import Lockstep.Kernel.Transition (Principal (..))

{- | T5: the stored columns of a state besides its stage: its name and its
halt or stop code. The stage column is 'stateStage', the one place it is
derived.
-}
stateColumns :: TxState -> (StateName, Maybe T.Text)
stateColumns state =
  ( stateNameOf state
  , case state of
      Halted _ code -> Just code
      Stopped code -> Just code
      _ -> Nothing
  )

-- | T5: the stage stored with a state (the last stage for a stopped one).
stateStage :: Stage -> TxState -> Stage
stateStage lastStage state =
  case state of
    Running s -> s
    Halted s _ -> s
    Accepted -> StageAccept
    Done -> StageAccept
    Stopped _ -> lastStage

{- | The state of stored columns (its name, its stage, its halt or stop code);
nothing for a combination no state has: a halt or stop without its code, a
code on any other state, or an accepted or done one not at the accept stage.
-}
stateFromColumns :: StateName -> Stage -> Maybe T.Text -> Maybe TxState
stateFromColumns name stage code =
  case (name, code) of
    (StateRunning, Nothing) -> Just (Running stage)
    (StateHalted, Just c) -> Just (Halted stage c)
    (StateAccepted, Nothing) | stage == StageAccept -> Just Accepted
    (StateDone, Nothing) | stage == StageAccept -> Just Done
    (StateStopped, Just c) -> Just (Stopped c)
    _ -> Nothing

{- | P4.6 R3: a reproduction holds only if the command ran and failed (not the
shell's 126 or 127 for a program that could not run), and its failure
signature appears in what it printed. A timeout, too much output or a failed
launch never reproduces anything.
-}
reproduces :: Check -> RunOutcome -> T.Text -> T.Text -> Bool
reproduces check outcome out err =
  case outcome of
    Exited n ->
      n /= 0
        && n /= 126
        && n /= 127
        && (checkSignature check `T.isInfixOf` out || checkSignature check `T.isInfixOf` err)
    _ -> False

{- | The choices a person is offered for a halt: accepting non-reproduction only
where reproduction is missing; otherwise retrying the stage or stopping.
-}
haltChoices :: Stage -> T.Text -> [T.Text]
haltChoices stage code =
  if stage == StageReproduction && code == T.pack "reproduction-missing"
    then [T.pack "accept-non-reproduction", T.pack "retry", T.pack "stop"]
    else [T.pack "retry", T.pack "stop"]

data Stage
  = StageBasis
  | StageDiscovery
  | StageReproduction
  | StageCandidate
  | StageChallengePre
  | StageFreeze
  | StageImplement
  | StageVerify
  | StageChallengePost
  | StageReview
  | StageAccept
  deriving (Eq, Show, Enum, Bounded)

stageName :: Stage -> T.Text
stageName stage =
  T.pack $
    case stage of
      StageBasis -> "basis"
      StageDiscovery -> "discovery"
      StageReproduction -> "reproduction"
      StageCandidate -> "candidate"
      StageChallengePre -> "challenge-pre"
      StageFreeze -> "freeze"
      StageImplement -> "implement"
      StageVerify -> "verify"
      StageChallengePost -> "challenge-post"
      StageReview -> "review"
      StageAccept -> "accept"

parseStage :: T.Text -> Maybe Stage
parseStage text =
  L.lookup text [(stageName s, s) | s <- [minBound .. maxBound]]

data TxState
  = Running Stage
  | Halted Stage T.Text
  | Accepted
  | Done
  | Stopped T.Text
  deriving (Eq, Show)

txStateName :: TxState -> T.Text
txStateName =
  stateNameText . stateNameOf

-- | T5: which state it is, without its stage or code (the stored @state@ column).
data StateName
  = StateRunning
  | StateHalted
  | StateAccepted
  | StateDone
  | StateStopped
  deriving (Eq, Show, Enum, Bounded)

stateNameOf :: TxState -> StateName
stateNameOf state =
  case state of
    Running _ -> StateRunning
    Halted _ _ -> StateHalted
    Accepted -> StateAccepted
    Done -> StateDone
    Stopped _ -> StateStopped

-- | The canonical text of a state name, as stored and as shown.
stateNameText :: StateName -> T.Text
stateNameText name =
  T.pack $
    case name of
      StateRunning -> "running"
      StateHalted -> "halted"
      StateAccepted -> "accepted"
      StateDone -> "done"
      StateStopped -> "stopped"

-- | The state name of its canonical text; derived from 'stateNameText'.
parseStateName :: T.Text -> Maybe StateName
parseStateName text =
  L.lookup text [(stateNameText n, n) | n <- [minBound .. maxBound]]

{- | What a halt (or the stop that ended one) records. Three kinds carry the
code of what failed after a fixed word; every other halt is its own code. The
stored text is 'haltCodeText'; 'haltCodeFromText' is its one decoder.
-}
data HaltCode
  = -- | @role-failed CODE@: a role failed in a known way.
    HaltRoleFailed T.Text
  | -- | @uncertain-invocation CODE@: whether a role finished is not known.
    HaltUncertainInvocation T.Text
  | -- | @supervisor-failed CODE@: Lockstep's own step could not be done.
    HaltSupervisorFailed T.Text
  | -- | any other halt or stop code, as it is (a refusal, an exhausted budget, a person's stop)
    HaltPlain T.Text
  deriving (Eq, Show)

haltCodeText :: HaltCode -> T.Text
haltCodeText code =
  case code of
    HaltRoleFailed c -> roleFailedWord <> c
    HaltUncertainInvocation c -> uncertainWord <> c
    HaltSupervisorFailed c -> supervisorFailedWord <> c
    HaltPlain c -> c

{- | The kind of a stored halt code: split once at its leading word. Total: a
code with no such word is 'HaltPlain'. It inverts 'haltCodeText' for every
code Lockstep makes (no plain code begins with one of the three words).
-}
haltCodeFromText :: T.Text -> HaltCode
haltCodeFromText text
  | Just c <- T.stripPrefix roleFailedWord text = HaltRoleFailed c
  | Just c <- T.stripPrefix uncertainWord text = HaltUncertainInvocation c
  | Just c <- T.stripPrefix supervisorFailedWord text = HaltSupervisorFailed c
  | otherwise = HaltPlain text

roleFailedWord :: T.Text
roleFailedWord =
  T.pack "role-failed "

uncertainWord :: T.Text
uncertainWord =
  T.pack "uncertain-invocation "

supervisorFailedWord :: T.Text
supervisorFailedWord =
  T.pack "supervisor-failed "

data Counters
  = Counters
  { candidatesMade :: Int
  , attemptsMade :: Int
  }
  deriving (Eq, Show)

noCounters :: Counters
noCounters =
  Counters 0 0

data Transaction
  = Transaction
  { txState :: TxState
  , txCounters :: Counters
  }
  deriving (Eq, Show)

newTransaction :: Transaction
newTransaction =
  Transaction (Running StageBasis) noCounters

-- | DG-06 D-6.4: two correction rounds, three candidates in all.
maxCorrections :: Int
maxCorrections =
  2

-- | DG-17 D-17.7: two Implementer attempts.
maxAttempts :: Int
maxAttempts =
  2

-- | DG-06 D-6.1 as clarified (engine-design §3a).
data BaselineClass
  = RedConfirmed
  | RedUnexpectedlyPassed
  | RedWrongReason
  | GreenConfirmed
  | GreenCandidateFailed
  | RunFailed
  deriving (Eq, Show, Enum, Bounded)

baselineClassName :: BaselineClass -> T.Text
baselineClassName c =
  T.pack $
    case c of
      RedConfirmed -> "red-confirmed"
      RedUnexpectedlyPassed -> "red-unexpectedly-passed"
      RedWrongReason -> "red-wrong-reason"
      GreenConfirmed -> "green-confirmed"
      GreenCandidateFailed -> "green-candidate-failed"
      RunFailed -> "run-failed"

-- | A class a Planner correction may answer (a run failure is the environment's).
correctable :: BaselineClass -> Bool
correctable c =
  c `L.elem` [RedUnexpectedlyPassed, RedWrongReason, GreenCandidateFailed]

data Disposition
  = Confirmed
  | Disproved
  | NeedsHumanFinding
  | Inconclusive
  deriving (Eq, Show, Enum, Bounded)

dispositionName :: Disposition -> T.Text
dispositionName d =
  T.pack $
    case d of
      Confirmed -> "CONFIRMED"
      Disproved -> "DISPROVED"
      NeedsHumanFinding -> "NEEDS_HUMAN"
      Inconclusive -> "INCONCLUSIVE"

{- | What the Supervisor observed at a stage, or what a person decided. Text
fields are refusal or halt codes.
-}
data TxInput
  = BasisReady
  | BasisRefused T.Text
  | DiscoveryAnswered
  | Reproduced
  | NotReproduced
  | CandidateClassified [BaselineClass]
  | CandidateRejected T.Text
  | RegressionFailed
  | ChallengeDisposed [Disposition]
  | TestsFrozen
  | Implemented
  | ImplementationRefused T.Text
  | VerificationPassed
  | VerificationFailed
  | VerificationInconclusive T.Text
  | ReviewApproved
  | ReviewRejected
  | ReviewNeedsHuman
  | CommitAccepted
  | RoleFailed T.Text
  | RoleUncertain T.Text
  | SupervisorFailed T.Text
  | ScopeRefused T.Text
  | HumanRetry
  | HumanAcceptNonReproduction
  | HumanStop
  | HumanDone
  deriving (Eq, Show)

txInputName :: TxInput -> T.Text
txInputName input =
  T.pack $
    case input of
      BasisReady -> "basis-ready"
      BasisRefused _ -> "basis-refused"
      DiscoveryAnswered -> "discovery-answered"
      Reproduced -> "reproduced"
      NotReproduced -> "not-reproduced"
      CandidateClassified _ -> "candidate-classified"
      CandidateRejected _ -> "candidate-rejected"
      RegressionFailed -> "regression-failed"
      ChallengeDisposed _ -> "challenge-disposed"
      TestsFrozen -> "tests-frozen"
      Implemented -> "implemented"
      ImplementationRefused _ -> "implementation-refused"
      VerificationPassed -> "verification-passed"
      VerificationFailed -> "verification-failed"
      VerificationInconclusive _ -> "verification-inconclusive"
      ReviewApproved -> "review-approved"
      ReviewRejected -> "review-rejected"
      ReviewNeedsHuman -> "review-needs-human"
      CommitAccepted -> "commit-accepted"
      RoleFailed _ -> "role-failed"
      RoleUncertain _ -> "role-uncertain"
      SupervisorFailed _ -> "supervisor-failed"
      ScopeRefused _ -> "scope-refused"
      HumanRetry -> "human-retry"
      HumanAcceptNonReproduction -> "human-accept-non-reproduction"
      HumanStop -> "human-stop"
      HumanDone -> "human-done"

humanInput :: TxInput -> Bool
humanInput input =
  input `L.elem` [HumanRetry, HumanAcceptNonReproduction, HumanStop, HumanDone]

{- | T2: the next transaction, or a refusal code. Check order: @agent-assertion@;
@not-authorized@ (a person's input from the Supervisor, or a Supervisor's
from a person); @closed@ (done or stopped); then the stage's own rule
(@illegal-input@ for anything it does not expect).
-}
stepTransaction :: Principal -> TxInput -> Transaction -> Either T.Text Transaction
stepTransaction principal input tx
  | principal == Agent = Left (T.pack "agent-assertion")
  | humanInput input && principal /= Human = Left (T.pack "not-authorized")
  | not (humanInput input) && principal /= Supervisor = Left (T.pack "not-authorized")
  | closed (txState tx) = Left (T.pack "closed")
  | otherwise = step (txState tx)
 where
  counters = txCounters tx
  to state = Right tx {txState = state}
  toWith state c = Right (Transaction state c)
  halt stage code = to (Halted stage (T.pack code))
  illegal = Left (T.pack "illegal-input")
  closed s =
    case s of
      Done -> True
      Stopped _ -> True
      _ -> False
  -- A role that failed in a known way, a role whose outcome is unknown, or Lockstep's
  -- own step that could not be done, halts at its stage.
  roleEnd stage =
    case input of
      RoleFailed code -> Just (to (Halted stage (haltCodeText (HaltRoleFailed code))))
      RoleUncertain code -> Just (to (Halted stage (haltCodeText (HaltUncertainInvocation code))))
      SupervisorFailed code -> Just (to (Halted stage (haltCodeText (HaltSupervisorFailed code))))
      _ -> Nothing
  anotherAttempt code =
    if attemptsMade counters < maxAttempts
      then toWith (Running StageImplement) counters
      else halt StageImplement code
  anotherCandidate code =
    if candidatesMade counters <= maxCorrections
      then to (Running StageCandidate)
      else halt StageCandidate code
  step state =
    case state of
      Running stage
        | HumanStop <- input -> to (Stopped (T.pack "stopped by a person"))
        | Just next <- roleEnd stage -> next
        | otherwise -> running stage
      Halted stage code ->
        case input of
          HumanStop -> to (Stopped code)
          HumanRetry -> to (Running stage)
          HumanAcceptNonReproduction
            | stage == StageReproduction && code == T.pack "reproduction-missing" -> to (Running StageCandidate)
          _ -> illegal
      Accepted ->
        case input of
          HumanDone -> to Done
          HumanStop -> to (Stopped (T.pack "not accepted by a person"))
          _ -> illegal
      _ -> illegal
  running stage =
    case (stage, input) of
      (StageBasis, BasisReady) -> to (Running StageDiscovery)
      (StageBasis, BasisRefused code) -> to (Halted StageBasis code)
      (StageDiscovery, DiscoveryAnswered) -> to (Running StageReproduction)
      (StageReproduction, Reproduced) -> to (Running StageCandidate)
      (StageReproduction, NotReproduced) -> halt StageReproduction "reproduction-missing"
      (StageCandidate, CandidateClassified classes) ->
        let
          made = counters {candidatesMade = candidatesMade counters + 1}
        in
          if L.all (`L.elem` [RedConfirmed, GreenConfirmed]) classes && RedConfirmed `L.elem` classes
            then toWith (Running StageChallengePre) made
            else
              if RunFailed `L.elem` classes
                then toWith (Halted StageCandidate (T.pack "baseline-run-failed")) made
                else
                  if candidatesMade made <= maxCorrections
                    then toWith (Running StageCandidate) made
                    else toWith (Halted StageCandidate (T.pack "candidates-exhausted")) made
      (StageCandidate, CandidateRejected _) ->
        let
          made = counters {candidatesMade = candidatesMade counters + 1}
        in
          if candidatesMade made <= maxCorrections
            then toWith (Running StageCandidate) made
            else toWith (Halted StageCandidate (T.pack "candidates-exhausted")) made
      (StageCandidate, VerificationInconclusive code) -> to (Halted StageCandidate code)
      (StageCandidate, RegressionFailed) -> halt StageCandidate "green-regression-failed"
      (StageCandidate, ScopeRefused code) -> to (Halted StageCandidate code)
      (StageChallengePre, ChallengeDisposed ds)
        | Confirmed `L.elem` ds -> anotherCandidate "candidates-exhausted"
        | NeedsHumanFinding `L.elem` ds -> halt StageChallengePre "finding-needs-human"
        | otherwise -> to (Running StageFreeze)
      (StageFreeze, TestsFrozen) -> to (Running StageImplement)
      (StageImplement, Implemented) ->
        toWith (Running StageVerify) counters {attemptsMade = attemptsMade counters + 1}
      (StageImplement, ImplementationRefused _) ->
        let
          c = counters {attemptsMade = attemptsMade counters + 1}
        in
          if attemptsMade c < maxAttempts
            then toWith (Running StageImplement) c
            else toWith (Halted StageImplement (T.pack "attempts-exhausted")) c
      (StageVerify, VerificationPassed) -> to (Running StageChallengePost)
      (StageVerify, VerificationFailed) -> anotherAttempt "attempts-exhausted"
      (StageVerify, VerificationInconclusive code) -> to (Halted StageVerify code)
      (StageChallengePost, ChallengeDisposed ds)
        | Confirmed `L.elem` ds -> anotherAttempt "attempts-exhausted"
        | NeedsHumanFinding `L.elem` ds -> halt StageChallengePost "finding-needs-human"
        | otherwise -> to (Running StageReview)
      (StageReview, ReviewApproved) -> to (Running StageAccept)
      (StageReview, ReviewRejected) -> anotherAttempt "attempts-exhausted"
      (StageReview, ReviewNeedsHuman) -> halt StageReview "review-needs-human"
      (StageAccept, CommitAccepted) -> to Accepted
      _ -> illegal
