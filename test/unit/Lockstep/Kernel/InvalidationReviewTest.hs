{-# LANGUAGE OverloadedStrings #-}

{- | The independent review of C-P6.7 (R-P6.7), pure: a stopped unit's words
name the rework path.
-}
module Lockstep.Kernel.InvalidationReviewTest
  ( tests
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase)

import Lockstep.Kernel.Dispatch (WaitReason (StoppedUnit), waitReasonWords)

tests :: TestTree
tests =
  testGroup
    "R-P6.7 review of provisional progression (pure)"
    [ testCase "a stopped unit's words say the task can be handed over again to redo it (R-P6.7-12)" $
        assertBool "no rework path in the words" ("hand it over again" `T.isInfixOf` waitReasonWords StoppedUnit)
    ]
