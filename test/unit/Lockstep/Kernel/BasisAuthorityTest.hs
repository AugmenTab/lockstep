{-# LANGUAGE OverloadedStrings #-}

{- | Update 2 R6.1: the compatibility rule that turns a dependent fix's
prerequisites into the accepted commits its basis must be built on. Every
prerequisite must still be satisfied; one whose acceptance no longer counts
never gives a basis, even when its Ticket says done; a fix that is accepted or
Done gives its accepted commit whatever kind of dependency reached it; a
prerequisite with no recorded commit refuses a planned unit and gives nothing
to standalone work.
-}
module Lockstep.Kernel.BasisAuthorityTest
  ( tests
  ) where

import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Lockstep.Kernel.Dispatch (BasisSource (..), FixFact (..), basisCommits)

tests :: TestTree
tests =
  testGroup
    "R6.1 the basis a dependent fix is built on"
    [ testCase "no prerequisite gives no commit" $
        basisCommits True [] @?= Right []
    , testCase "an accepted or Done fix gives its accepted commit, planned or not" $ do
        basisCommits True [BasisSource True FixAccepted (Just "a"), BasisSource True FixDone (Just "b")] @?= Right ["a", "b"]
        basisCommits False [BasisSource True FixDone (Just "b")] @?= Right ["b"]
    , testCase "a prerequisite that is not satisfied refuses, before anything else" $ do
        basisCommits True [BasisSource True FixAccepted Nothing, BasisSource False NoFix Nothing] @?= Left "prerequisite-unsatisfied"
        basisCommits False [BasisSource False FixAccepted (Just "a")] @?= Left "prerequisite-unsatisfied"
    , testCase "an acceptance that no longer counts never gives a basis, even when its Ticket is done" $ do
        basisCommits False [BasisSource True FixAcceptanceInvalidated (Just "a")] @?= Left "prerequisite-invalidated"
        basisCommits True [BasisSource True FixAccepted Nothing, BasisSource True FixAcceptanceInvalidated (Just "a")] @?= Left "prerequisite-invalidated"
    , testCase "an accepted or Done fix without its commit refuses, planned or not" $ do
        basisCommits True [BasisSource True FixDone Nothing] @?= Left "prerequisite-basis-unrecorded"
        basisCommits False [BasisSource True FixAccepted Nothing] @?= Left "prerequisite-basis-unrecorded"
    , testCase "a prerequisite satisfied without a Lockstep commit refuses a planned unit and gives nothing to standalone work" $ do
        basisCommits True [BasisSource True NoFix Nothing] @?= Left "prerequisite-basis-unrecorded"
        basisCommits True [BasisSource True FixStopped Nothing] @?= Left "prerequisite-basis-unrecorded"
        basisCommits False [BasisSource True NoFix Nothing, BasisSource True FixDone (Just "b")] @?= Right ["b"]
    ]
