{-# LANGUAGE OverloadedStrings #-}

{- | Provisional progression and its invalidation (contract C-P6.7 V2–V4),
pure: the codes, the descendants of a rejected or invalidated fix, the
engine's input that stops an invalidated fix, and the waiting reason of an
invalidated unit.
-}
module Lockstep.Kernel.InvalidationTest
  ( tests
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Lockstep.Kernel.Dispatch (BudgetFact (..), DispatchDecision (..), FixFact (..), ProjectFacts (..), UnitFacts (..), WaitReason (..), dispatchDecision, waitReasonCode, waitReasonWords)
import Lockstep.Kernel.Invalidation (InvalidationCause, descendantsOf, invalidationCode, stopOnlyCodes)
import Lockstep.Kernel.Plan (UnitKey, mkUnitKey)
import Lockstep.Kernel.Task (TaskReadiness (..))
import Lockstep.Kernel.Transaction (Stage (..), Transaction (..), TxInput (..), TxState (..), haltChoices, noCounters, stepTransaction, txInputName)
import Lockstep.Kernel.Transition (Principal (..))

key :: T.Text -> UnitKey
key text =
  case mkUnitKey text of
    Just k -> k
    Nothing -> key "invalid-key-in-test"

at :: TxState -> Transaction
at state =
  Transaction state noCounters

tests :: TestTree
tests =
  testGroup
    "C-P6.7 provisional progression and invalidation (pure)"
    [ testGroup
        "causes and descendants (V2)"
        [ testCase "each cause has its code" $
            fmap invalidationCode [minBound .. maxBound :: InvalidationCause] @?= ["ancestor-rejected", "plan-changed"]
        , testCase "a chain: rejecting the first invalidates the second and the third, not the root nor an unrelated fix" $
            descendantsOf [("b", "a"), ("c", "b"), ("x", "y")] ["a" :: T.Text] @?= ["b", "c"]
        , testCase "a diamond and a fix built on two: each descendant once, sorted" $
            descendantsOf [("b", "a"), ("c", "a"), ("d", "b"), ("d", "c")] ["a" :: T.Text] @?= ["b", "c", "d"]
        , testCase "several roots; a fix with no descendants has none" $ do
            descendantsOf [("b", "a"), ("d", "c")] ["a", "c" :: T.Text] @?= ["b", "d"]
            descendantsOf [("b", "a")] ["b" :: T.Text] @?= []
        , testCase "recorded bases that loop still give an answer" $
            descendantsOf [("b", "a"), ("a", "b")] ["a" :: T.Text] @?= ["a", "b"]
        ]
    , testGroup
        "the engine stops an invalidated fix at a safe boundary (V4)"
        [ testCase "a running fix halts at the stage it was at, with the cause" $
            fmap txState (stepTransaction Supervisor (Invalidated "ancestor-rejected") (at (Running StageImplement))) @?= Right (Halted StageImplement "ancestor-rejected")
        , testCase "a fix halted for something else halts again for the invalidation, so a retry cannot run on it" $
            fmap txState (stepTransaction Supervisor (Invalidated "plan-changed") (at (Halted StageReview "review-needs-human"))) @?= Right (Halted StageReview "plan-changed")
        , testCase "the acceptance stage too: a late finding prevents the acceptance" $
            fmap txState (stepTransaction Supervisor (Invalidated "ancestor-rejected") (at (Running StageAccept))) @?= Right (Halted StageAccept "ancestor-rejected")
        , testCase "an accepted, done or stopped fix keeps its state: its history is not rewritten" $ do
            stepTransaction Supervisor (Invalidated "ancestor-rejected") (at Accepted) @?= Left "illegal-input"
            stepTransaction Supervisor (Invalidated "ancestor-rejected") (at Done) @?= Left "closed"
            stepTransaction Supervisor (Invalidated "ancestor-rejected") (at (Stopped "stopped-by-person")) @?= Left "closed"
        , testCase "only the Supervisor invalidates" $ do
            stepTransaction Human (Invalidated "ancestor-rejected") (at (Running StageImplement)) @?= Left "not-authorized"
            stepTransaction Agent (Invalidated "ancestor-rejected") (at (Running StageImplement)) @?= Left "agent-assertion"
        , testCase "its halts offer only Stop" $ do
            stopOnlyCodes @?= ["ancestor-rejected", "plan-changed", "basis-stale"]
            fmap (haltChoices StageImplement) stopOnlyCodes @?= [["stop"], ["stop"], ["stop"]]
            haltChoices StageImplement "attempts-exhausted" @?= ["retry", "stop"]
        , testCase "the input has its name" $
            txInputName (Invalidated "plan-changed") @?= "invalidated"
        ]
    , testGroup
        "an invalidated unit waits (V3)"
        [ testCase "its own reason, with words that say it must be redone" $ do
            let
              d = dispatchDecision (ProjectFacts True Nothing NoBudget) [UnitFacts (key "a") "Unit a" 500 0 ReadyToWork (Just FixAcceptanceInvalidated) True]
            decisionNext d @?= Nothing
            decisionWaiting d @?= [(key "a", InvalidatedUnit)]
            waitReasonCode InvalidatedUnit @?= "invalidated"
            assertWords (waitReasonWords InvalidatedUnit)
        ]
    ]
 where
  assertWords w = T.isInfixOf "redone" w @?= True
