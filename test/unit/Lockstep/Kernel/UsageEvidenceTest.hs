{-# LANGUAGE OverloadedStrings #-}

{- | Update 2 R6.5: usage is only as complete as its evidence. No provider
invocation, complete usage, partial usage and unavailable usage are different
things; a missing class is never zero; an output Lockstep kept only the tail
of is never complete accounting; each run says what its own evidence is.
-}
module Lockstep.Kernel.UsageEvidenceTest
  ( tests
  ) where

import Data.List qualified as L
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Lockstep.Kernel.Summary (RunUsage (..), Usage (..), UsageStanding (..), noUsage, runEvidence, usageStanding, usageStandingCode)

full :: Usage
full =
  Usage (Just 100) (Just 20) (Just 5) (Just 300)

tests :: TestTree
tests =
  testGroup
    "R6.5 usage is only as complete as its evidence"
    [ testCase "no provider invocation is not zero usage" $ do
        usageStanding [] @?= NoProviderInvocation
        usageStanding [RunUsage "a" (Usage (Just 0) (Just 0) (Just 0) (Just 0)) True] @?= UsageComplete (Usage (Just 0) (Just 0) (Just 0) (Just 0))
    , testCase "every run reporting every class, with its whole output kept, is complete, exactly" $
        usageStanding [RunUsage "a" full True, RunUsage "b" full True] @?= UsageComplete (Usage (Just 200) (Just 40) (Just 10) (Just 600))
    , testCase "a missing cache-read count stays unknown, and the usage is partial" $
        usageStanding [RunUsage "a" full True, RunUsage "b" full {usageCacheRead = Nothing} True] @?= UsagePartial (Usage (Just 200) (Just 40) (Just 10) (Just 300))
    , testCase "an output kept only as its tail is never complete accounting" $ do
        usageStanding [RunUsage "a" full False] @?= UsagePartial full
        runEvidence (RunUsage "a" full False) @?= "truncated"
    , testCase "runs that reported nothing make usage unavailable, never zero" $
        usageStanding [RunUsage "a" noUsage True, RunUsage "b" noUsage True] @?= UsageUnavailable
    , testCase "some runs reporting and some not is partial, never complete" $
        usageStanding [RunUsage "a" full True, RunUsage "b" noUsage True] @?= UsagePartial full
    , testCase "each run says what its own evidence is" $ do
        fmap runEvidence [RunUsage "a" full True, RunUsage "b" full {usageOutput = Nothing} True, RunUsage "c" noUsage True, RunUsage "d" noUsage False]
          @?= ["complete", "partial", "missing", "missing"]
    , testCase "each standing has its own code" $ do
        let
          codes = fmap usageStandingCode [NoProviderInvocation, UsageComplete full, UsagePartial full, UsageUnavailable]
        L.nub codes @?= codes
    ]
