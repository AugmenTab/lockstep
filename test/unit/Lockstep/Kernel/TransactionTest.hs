{-# LANGUAGE OverloadedStrings #-}

-- | The coding transaction's pure rules (contract C-P4.6 T1–T4).
module Lockstep.Kernel.TransactionTest
  ( tests
  ) where

import Control.Monad (foldM)
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Lockstep.Kernel.Transaction
  ( BaselineClass (..)
  , Counters (..)
  , Disposition (..)
  , Stage (..)
  , Transaction (..)
  , TxInput (..)
  , TxState (..)
  , baselineClassName
  , correctable
  , dispositionName
  , newTransaction
  , parseStage
  , stageName
  , stepTransaction
  )
import Lockstep.Kernel.Transition (Principal (..))

tests :: TestTree
tests =
  testGroup
    "C-P4.6 coding transaction rules"
    [ testCase "the happy path runs every stage in order, then a person marks it done" happyPath
    , testCase "an agent is never accepted; each input has its one principal" principals
    , testCase "missing reproduction halts; only a person may accept non-reproduction" reproduction
    , testCase "baseline classes: corrections at most twice, run failures and regressions halt" baseline
    , testCase "a confirmed pre-freeze finding sends it back to the Planner within the budget" challengePre
    , testCase "attempts: at most two; a refusal, a failure, a finding or a rejection uses one" attempts
    , testCase "an unknown or failed role halts at its stage; a person retries or stops" roles
    , testCase "done and stopped are final; inputs out of place are illegal" closed
    , testCase "names are stable" names
    ]

sup :: TxInput -> Transaction -> Either T.Text Transaction
sup =
  stepTransaction Supervisor

human :: TxInput -> Transaction -> Either T.Text Transaction
human =
  stepTransaction Human

-- | Applies Supervisor inputs in order.
run :: [TxInput] -> Either T.Text Transaction
run =
  foldM (flip sup) newTransaction

stateOf :: Either T.Text Transaction -> Either T.Text TxState
stateOf =
  fmap txState

toFreeze :: [TxInput]
toFreeze =
  [BasisReady, DiscoveryAnswered, Reproduced, CandidateClassified [RedConfirmed, GreenConfirmed], ChallengeDisposed [Disproved, Inconclusive]]

toVerify :: [TxInput]
toVerify =
  toFreeze <> [TestsFrozen, Implemented]

happyPath :: IO ()
happyPath = do
  let
    path = toVerify <> [VerificationPassed, ChallengeDisposed [], ReviewApproved, CommitAccepted]
    states = fmap (stateOf . run) [L.take n path | n <- [0 .. L.length path]]
  states
    @?= fmap
      Right
      [ Running StageBasis
      , Running StageDiscovery
      , Running StageReproduction
      , Running StageCandidate
      , Running StageChallengePre
      , Running StageFreeze
      , Running StageImplement
      , Running StageVerify
      , Running StageChallengePost
      , Running StageReview
      , Running StageAccept
      , Accepted
      ]
  fmap txCounters (run path) @?= Right (Counters 1 1)
  stateOf (run path >>= human HumanDone) @?= Right Done

principals :: IO ()
principals = do
  stepTransaction Agent BasisReady newTransaction @?= Left "agent-assertion"
  stepTransaction Agent HumanStop newTransaction @?= Left "agent-assertion"
  human BasisReady newTransaction @?= Left "not-authorized"
  stepTransaction Scheduler BasisReady newTransaction @?= Left "not-authorized"
  sup HumanStop newTransaction @?= Left "not-authorized"
  sup HumanDone newTransaction @?= Left "not-authorized"
  (run (toVerify <> [VerificationPassed, ChallengeDisposed [], ReviewApproved, CommitAccepted]) >>= sup HumanDone) @?= Left "not-authorized"

reproduction :: IO ()
reproduction = do
  let
    halted = run [BasisReady, DiscoveryAnswered, NotReproduced]
  stateOf halted @?= Right (Halted StageReproduction "reproduction-missing")
  (halted >>= sup HumanAcceptNonReproduction) @?= Left "not-authorized"
  stateOf (halted >>= human HumanAcceptNonReproduction) @?= Right (Running StageCandidate)
  stateOf (halted >>= human HumanRetry) @?= Right (Running StageReproduction)
  -- Accepting non-reproduction means nothing at any other halt.
  (run [BasisReady, DiscoveryAnswered, RoleUncertain "x"] >>= human HumanAcceptNonReproduction) @?= Left "illegal-input"

baseline :: IO ()
baseline = do
  let
    atCandidate = [BasisReady, DiscoveryAnswered, Reproduced]
    wrong = CandidateClassified [RedUnexpectedlyPassed]
  stateOf (run (atCandidate <> [wrong])) @?= Right (Running StageCandidate)
  stateOf (run (atCandidate <> [wrong, wrong])) @?= Right (Running StageCandidate)
  stateOf (run (atCandidate <> [wrong, wrong, wrong])) @?= Right (Halted StageCandidate "candidates-exhausted")
  fmap txCounters (run (atCandidate <> [wrong, wrong, wrong])) @?= Right (Counters 3 0)
  stateOf (run (atCandidate <> [wrong, wrong, CandidateClassified [RedConfirmed]])) @?= Right (Running StageChallengePre)
  stateOf (run (atCandidate <> [CandidateClassified [RedConfirmed, RunFailed]])) @?= Right (Halted StageCandidate "baseline-run-failed")
  stateOf (run (atCandidate <> [CandidateClassified [GreenConfirmed]])) @?= Right (Running StageCandidate)
  stateOf (run (atCandidate <> [CandidateClassified [RedConfirmed, GreenCandidateFailed]])) @?= Right (Running StageCandidate)
  stateOf (run (atCandidate <> [RegressionFailed])) @?= Right (Halted StageCandidate "green-regression-failed")
  stateOf (run (atCandidate <> [ScopeRefused "tests-overlap-allowed"])) @?= Right (Halted StageCandidate "tests-overlap-allowed")
  fmap correctable [RedConfirmed, RedUnexpectedlyPassed, RedWrongReason, GreenConfirmed, GreenCandidateFailed, RunFailed]
    @?= [False, True, True, False, True, False]

challengePre :: IO ()
challengePre = do
  let
    atCandidate = [BasisReady, DiscoveryAnswered, Reproduced]
    good = CandidateClassified [RedConfirmed]
    confirmed = ChallengeDisposed [Disproved, Confirmed]
  stateOf (run (atCandidate <> [good, confirmed])) @?= Right (Running StageCandidate)
  stateOf (run (atCandidate <> [good, confirmed, good, confirmed, good, confirmed])) @?= Right (Halted StageCandidate "candidates-exhausted")
  stateOf (run (atCandidate <> [good, ChallengeDisposed [NeedsHumanFinding, Inconclusive]])) @?= Right (Halted StageChallengePre "finding-needs-human")
  stateOf (run (atCandidate <> [good, ChallengeDisposed [Confirmed, NeedsHumanFinding]])) @?= Right (Running StageCandidate)

attempts :: IO ()
attempts = do
  let
    atImplement = toFreeze <> [TestsFrozen]
  stateOf (run (atImplement <> [ImplementationRefused "protected-test-changed"])) @?= Right (Running StageImplement)
  stateOf (run (atImplement <> [ImplementationRefused "a", ImplementationRefused "b"])) @?= Right (Halted StageImplement "attempts-exhausted")
  stateOf (run (atImplement <> [Implemented, VerificationFailed])) @?= Right (Running StageImplement)
  stateOf (run (atImplement <> [Implemented, VerificationFailed, Implemented, VerificationFailed])) @?= Right (Halted StageImplement "attempts-exhausted")
  stateOf (run (atImplement <> [Implemented, VerificationPassed, ChallengeDisposed [Confirmed]])) @?= Right (Running StageImplement)
  stateOf (run (atImplement <> [Implemented, VerificationPassed, ChallengeDisposed [], ReviewRejected])) @?= Right (Running StageImplement)
  stateOf (run (atImplement <> [Implemented, VerificationPassed, ChallengeDisposed [], ReviewRejected, Implemented, VerificationPassed, ChallengeDisposed [], ReviewRejected]))
    @?= Right (Halted StageImplement "attempts-exhausted")
  stateOf (run (atImplement <> [Implemented, VerificationPassed, ChallengeDisposed [], ReviewNeedsHuman])) @?= Right (Halted StageReview "review-needs-human")
  stateOf (run (atImplement <> [Implemented, VerificationInconclusive "verification-environment-missing"])) @?= Right (Halted StageVerify "verification-environment-missing")
  stateOf (run (atImplement <> [Implemented, VerificationPassed, ChallengeDisposed [NeedsHumanFinding]])) @?= Right (Halted StageChallengePost "finding-needs-human")

roles :: IO ()
roles = do
  let
    lost = run [BasisReady, RoleUncertain "helper-no-result"]
  stateOf lost @?= Right (Halted StageDiscovery "uncertain-invocation helper-no-result")
  stateOf (run [BasisReady, DiscoveryAnswered, Reproduced, RoleFailed "malformed-output"]) @?= Right (Halted StageCandidate "role-failed malformed-output")
  (lost >>= sup DiscoveryAnswered) @?= Left "illegal-input"
  (lost >>= sup HumanRetry) @?= Left "not-authorized"
  stateOf (lost >>= human HumanRetry) @?= Right (Running StageDiscovery)
  stateOf (lost >>= human HumanStop) @?= Right (Stopped "uncertain-invocation helper-no-result")
  stateOf (run [BasisRefused "repository-dirty"]) @?= Right (Halted StageBasis "repository-dirty")
  stateOf (run [BasisReady, DiscoveryAnswered, SupervisorFailed "snapshot-failed"]) @?= Right (Halted StageReproduction "supervisor-failed snapshot-failed")
  human (SupervisorFailed "x") newTransaction @?= Left "not-authorized"

closed :: IO ()
closed = do
  let
    done = run (toVerify <> [VerificationPassed, ChallengeDisposed [], ReviewApproved, CommitAccepted]) >>= human HumanDone
    stopped = human HumanStop newTransaction
  stateOf stopped @?= Right (Stopped "stopped by a person")
  (done >>= human HumanStop) @?= Left "closed"
  (stopped >>= sup BasisReady) @?= Left "closed"
  (stopped >>= human HumanRetry) @?= Left "closed"
  sup TestsFrozen newTransaction @?= Left "illegal-input"
  sup CommitAccepted newTransaction @?= Left "illegal-input"
  (run toVerify >>= sup CommitAccepted) @?= Left "illegal-input"
  human HumanDone newTransaction @?= Left "illegal-input"
  stateOf (run (toVerify <> [VerificationPassed, ChallengeDisposed [], ReviewApproved, CommitAccepted]) >>= human HumanStop)
    @?= Right (Stopped "not accepted by a person")

names :: IO ()
names = do
  fmap stageName [minBound .. maxBound]
    @?= ["basis", "discovery", "reproduction", "candidate", "challenge-pre", "freeze", "implement", "verify", "challenge-post", "review", "accept"]
  fmap (parseStage . stageName) [minBound .. maxBound] @?= fmap Just [minBound .. maxBound :: Stage]
  parseStage "done" @?= Nothing
  fmap baselineClassName [RedConfirmed, RedUnexpectedlyPassed, RedWrongReason, GreenConfirmed, GreenCandidateFailed, RunFailed]
    @?= ["red-confirmed", "red-unexpectedly-passed", "red-wrong-reason", "green-confirmed", "green-candidate-failed", "run-failed"]
  fmap dispositionName [Confirmed, Disproved, NeedsHumanFinding, Inconclusive] @?= ["CONFIRMED", "DISPROVED", "NEEDS_HUMAN", "INCONCLUSIVE"]
