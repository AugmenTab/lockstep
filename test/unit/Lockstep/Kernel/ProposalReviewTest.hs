{-# LANGUAGE OverloadedStrings #-}

{- | The independent review of C-P6.9 (R-P6.9), pure: an evidence key reads
back to exactly the evidence it names, and text that could not is not a key.
-}
module Lockstep.Kernel.ProposalReviewTest
  ( tests
  ) where

import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Lockstep.Kernel.Proposal (evidenceFromKey, evidenceKey)
import Lockstep.Kernel.Summary (Evidence (..))

tests :: TestTree
tests =
  testGroup
    "R-P6.9 the review of improvement proposals (pure)"
    [ testCase "every kind of evidence reads back from its key (R-P6.9-3)" $
        traverse_
          (\e -> evidenceFromKey (evidenceKey e) @?= Just e)
          [OfFix "tx-1", OfRecord "tx-1" 7, OfCommit "0123456789abcdef0123456789abcdef01234567", OfInvalidation "tx-1", OfRequest "q-1"]
    , testCase "an id that is empty or holds a space, a tab or a control character is not a key (R-P6.9-3)" $
        traverse_
          (\key -> evidenceFromKey key @?= Nothing)
          ["fix:", "record::3", "record:a b:3", "fix:a b", "fix:a\tb", "request:q\n", "commit: abc", "invalidation:\x7f"]
    , testCase "text that is not one of the five kinds is not a key" $
        traverse_ (\key -> evidenceFromKey key @?= Nothing) ["", "fix", "opinion:trust-me", "record:tx-1:", "record:tx-1:x", "record:tx-1:3:4"]
    ]
