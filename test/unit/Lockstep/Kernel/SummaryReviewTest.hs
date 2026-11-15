{-# LANGUAGE OverloadedStrings #-}

{- | The independent review of C-P6.8 (R-P6.8), pure: a canceled task is
canceled whatever its fix, and only a plan unit that is merely not ready yet is
planned.
-}
module Lockstep.Kernel.SummaryReviewTest
  ( tests
  ) where

import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Lockstep.Kernel.Summary (Category (..), Checks (..), FixSummary (..), ItemFacts (..), ReviewOutcome (..), categoryOf)
import Lockstep.Kernel.Task (TaskReadiness (..))

running :: FixSummary
running =
  FixSummary "tx" "running" Nothing False ChecksNotRun Nothing ReviewNotRun Nothing Nothing

tests :: TestTree
tests =
  testGroup
    "R-P6.8 review of the summary's categories (pure)"
    [ testCase "a canceled task is canceled, even with a fix still under way (R-P6.8-10)" $
        categoryOf (ItemFacts False TaskCanceled (Just running)) @?= CategoryCanceled
    , testCase "a plan unit that is blocked, cannot start or is in an unknown state is waiting, not planned (R-P6.8-10)" $ do
        categoryOf (ItemFacts True (BlockedBecause "a person said so") Nothing) @?= CategoryWaiting
        categoryOf (ItemFacts True (CannotStart ["gone"]) Nothing) @?= CategoryWaiting
        categoryOf (ItemFacts True (StateUnrecognised "odd") Nothing) @?= CategoryWaiting
        categoryOf (ItemFacts True NotYetReady Nothing) @?= CategoryPlanned
        categoryOf (ItemFacts True (WaitingFor ["x"]) Nothing) @?= CategoryPlanned
    ]
