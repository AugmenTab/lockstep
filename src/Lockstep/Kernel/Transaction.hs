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

{- | T5: the stored columns of a state: its name, its stage (the last stage for
a closed one) and its halt or stop code.
-}
stateColumns :: Stage -> TxState -> (T.Text, T.Text, Maybe T.Text)
stateColumns lastStage state =
  ( txStateName state
  , stageName (stateStage lastStage state)
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

-- | The state of stored columns; nothing for columns that do not read back.
stateFromColumns :: T.Text -> T.Text -> Maybe T.Text -> Maybe TxState
stateFromColumns name stage code = do
  s <- parseStage stage
  case (T.unpack name, code) of
    ("running", Nothing) -> Just (Running s)
    ("halted", Just c) -> Just (Halted s c)
    ("accepted", Nothing) -> Just Accepted
    ("done", Nothing) -> Just Done
    ("stopped", Just c) -> Just (Stopped c)
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
txStateName state =
  T.pack $
    case state of
      Running _ -> "running"
      Halted _ _ -> "halted"
      Accepted -> "accepted"
      Done -> "done"
      Stopped _ -> "stopped"

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
  deriving (Eq, Show)

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
  deriving (Eq, Show)

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
      RoleFailed code -> Just (to (Halted stage (T.pack "role-failed " <> code)))
      RoleUncertain code -> Just (to (Halted stage (T.pack "uncertain-invocation " <> code)))
      SupervisorFailed code -> Just (to (Halted stage (T.pack "supervisor-failed " <> code)))
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
