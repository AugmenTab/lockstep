{-# LANGUAGE OverloadedStrings #-}

-- | C-P2.9-R1 §4.7 F1: @effects abandon@ takes the duplication-risk acknowledgment.
module Lockstep.Foundation.CliFinalReviewTest
  ( tests
  ) where

import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Lockstep.Foundation.Cli (CliError (..), Command (..), parseArgs)

tests :: TestTree
tests =
  testGroup
    "effects abandon and the acknowledgment (C-P2.9-R1 §4.7)"
    [ testCase "without the flag it is the plain abandonment" $
        parseArgs ["effects", "abandon", "OP", "--reason", "stop"] @?= Right (EffectsAbandon "OP" "stop")
    , testCase "with the flag, in any position, it is acknowledged" $ do
        parseArgs ["effects", "abandon", "OP", "--reason", "stop", "--acknowledge-duplication-risk"] @?= Right (EffectsAbandonAcknowledged "OP" "stop")
        parseArgs ["effects", "abandon", "--acknowledge-duplication-risk", "--reason", "stop", "OP"] @?= Right (EffectsAbandonAcknowledged "OP" "stop")
    , testCase "the flag once, and a reason, are required" $ do
        parseArgs ["effects", "abandon", "OP", "--acknowledge-duplication-risk", "--acknowledge-duplication-risk", "--reason", "stop"] @?= Left (DuplicateOption "--acknowledge-duplication-risk")
        parseArgs ["effects", "abandon", "OP", "--acknowledge-duplication-risk"] @?= Left (MissingOption "--reason")
    ]
