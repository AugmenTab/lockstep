{-# LANGUAGE OverloadedStrings #-}

{- | Stabilization S2 (post-Phase-5 handoff §3): a separate reproduction command
may be omitted; a RED baseline may not; a retry is never offered where it can
only repeat a known-impossible step, and it names what it runs.
-}
module Lockstep.Kernel.ReproductionRetryTest
  ( tests
  ) where

import Control.Monad (foldM)
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Lockstep.Kernel.Transaction
  ( BaselineClass (..)
  , Stage (..)
  , Transaction (..)
  , TxInput (..)
  , TxState (..)
  , haltChoices
  , newTransaction
  , retryOperation
  , stepTransaction
  , txInputName
  )
import Lockstep.Kernel.Transition (Principal (..))

tests :: TestTree
tests =
  testGroup
    "S2 reproduction may be omitted, RED may not; no ineffective retry"
    [ testCase "a supplied command that reproduces goes on to the tests" $
        stateOf (run [BasisReady, DiscoveryAnswered, Reproduced]) @?= Right (Running StageCandidate)
    , testCase "an omitted command goes on to the tests, given only by the Supervisor" $ do
        stateOf (run [BasisReady, DiscoveryAnswered, ReproductionOmitted]) @?= Right (Running StageCandidate)
        (run [BasisReady, DiscoveryAnswered] >>= stepTransaction Human ReproductionOmitted) @?= Left "not-authorized"
        (run [BasisReady, DiscoveryAnswered] >>= stepTransaction Agent ReproductionOmitted) @?= Left "agent-assertion"
        (run [BasisReady] >>= stepTransaction Supervisor ReproductionOmitted) @?= Left "illegal-input"
    , testCase "after an omission, only a RED-confirmed candidate reaches the challenge" $ do
        let
          omitted = [BasisReady, DiscoveryAnswered, ReproductionOmitted]
        stateOf (run (omitted <> [CandidateClassified [RedConfirmed]])) @?= Right (Running StageChallengePre)
        stateOf (run (omitted <> [CandidateClassified [RedWrongReason]])) @?= Right (Running StageCandidate)
        stateOf (run (omitted <> [CandidateClassified [GreenConfirmed]])) @?= Right (Running StageCandidate)
        stateOf (run (omitted <> [CandidateClassified [RedWrongReason], CandidateClassified [GreenConfirmed], CandidateClassified [RedUnexpectedlyPassed]]))
          @?= Right (Halted StageCandidate "candidates-exhausted")
    , testCase "a command that did not reproduce halts; replan, never retry, is offered" $ do
        let
          halted = run [BasisReady, DiscoveryAnswered, NotReproduced]
        stateOf halted @?= Right (Halted StageReproduction "reproduction-missing")
        haltChoices StageReproduction "reproduction-missing" @?= ["accept-non-reproduction", "replan", "stop"]
        assertBool "no retry" ("retry" `L.notElem` haltChoices StageReproduction "reproduction-missing")
    , testCase "replan goes back to the Planner's discovery; only a person, only at that halt" $ do
        let
          halted = run [BasisReady, DiscoveryAnswered, NotReproduced]
        stateOf (halted >>= stepTransaction Human HumanReplan) @?= Right (Running StageDiscovery)
        (halted >>= stepTransaction Supervisor HumanReplan) @?= Left "not-authorized"
        (run [BasisRefused "repository-dirty"] >>= stepTransaction Human HumanReplan) @?= Left "illegal-input"
        (run [BasisReady, RoleFailed "role-crashed"] >>= stepTransaction Human HumanReplan) @?= Left "illegal-input"
        fmap txCounters (halted >>= stepTransaction Human HumanReplan) @?= fmap txCounters halted
    , testCase "every other halt still offers retry, and a retry names what it runs" $ do
        haltChoices StageBasis "repository-dirty" @?= ["retry", "stop"]
        haltChoices StageDiscovery "role-failed role-crashed" @?= ["retry", "stop"]
        haltChoices StageCandidate "candidates-exhausted" @?= ["retry", "stop"]
        assertBool "discovery names the Planner" ("Planner" `T.isInfixOf` retryOperation StageDiscovery)
        assertBool "candidate names the Planner" ("Planner" `T.isInfixOf` retryOperation StageCandidate)
        assertBool "reproduction names its command" ("reproduction command" `T.isInfixOf` retryOperation StageReproduction)
        assertBool "review names the Reviewer" ("Reviewer" `T.isInfixOf` retryOperation StageReview)
        L.length (L.nub (fmap retryOperation [minBound .. maxBound])) @?= L.length [minBound .. maxBound :: Stage]
    , testCase "names are stable" $
        fmap txInputName [ReproductionOmitted, HumanReplan] @?= ["reproduction-omitted", "human-replan"]
    ]

run :: [TxInput] -> Either T.Text Transaction
run =
  foldM (flip (stepTransaction Supervisor)) newTransaction

stateOf :: Either T.Text Transaction -> Either T.Text TxState
stateOf =
  fmap txState
