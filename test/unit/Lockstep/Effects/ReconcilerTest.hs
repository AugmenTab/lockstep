{-# LANGUAGE OverloadedStrings #-}

-- | C-P2.7 §7 unit cases: lookup invocation (R1) and scripted lookups (R2).
module Lockstep.Effects.ReconcilerTest
  ( tests
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (throwIO)
import Data.Text qualified as T
import Flipstone.Prelude
import System.IO.Error (userError)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Effects.Executor (invokeAdapter)
import Lockstep.Effects.Reconciler (EffectReconciler (..), LookupAnswer (..), invokeLookup)
import Lockstep.Effects.Scripted (LookupStep (..), ScriptStep (..), newScriptedDestination, scriptedAdapter, scriptedReconciler)
import Lockstep.Kernel.Effect (ClassTerms (..), EffectSpec, LookupTerms (..), OperationId (..), mkEffectSpec)
import Lockstep.Kernel.Identity (uuidFromWords)
import Lockstep.Kernel.Reconciliation (LookupResult (..))

tests :: TestTree
tests =
  testGroup
    "Destination lookups (C-P2.7)"
    [ invocationTests
    , scriptedTests
    ]

op :: Word64 -> OperationId
op n =
  OperationId (uuidFromWords 4 n)

querySpec :: IO EffectSpec
querySpec =
  either (assertFailure . show) pure (mkEffectSpec "query" (TermsQueryable (LookupTerms True True)) 1)

answering :: EffectSpec -> LookupAnswer -> EffectReconciler
answering spec answer =
  EffectReconciler spec (\_ _ -> pure answer)

invocationTests :: TestTree
invocationTests =
  testGroup
    "lookup invocation (R1)"
    [ testCase "found and absent" $ do
        spec <- querySpec
        found <- invokeLookup 1000 (answering spec (LookupApplied "r")) (op 1) "p"
        found @?= LookupFound "r"
        absent <- invokeLookup 1000 (answering spec LookupAbsent) (op 1) "p"
        absent @?= LookupNotFound
    , testCase "an invalid result text is malformed-answer" $ do
        spec <- querySpec
        results <- traverse (\t -> invokeLookup 1000 (answering spec (LookupApplied t)) (op 1) "p") ["", "a\nb", T.replicate 4097 "x"]
        results @?= [LookupFailed "malformed-answer", LookupFailed "malformed-answer", LookupFailed "malformed-answer"]
    , testCase "no answer in time is timeout, and the call returns" $ do
        spec <- querySpec
        result <- timeout 5000000 (invokeLookup 50 (EffectReconciler spec (\_ _ -> threadDelay 10000000 >> pure LookupAbsent)) (op 1) "p")
        result @?= Just (LookupFailed "timeout")
    , testCase "a throwing lookup is lookup-failed" $ do
        spec <- querySpec
        result <- invokeLookup 1000 (EffectReconciler spec (\_ _ -> throwIO (userError "boom"))) (op 1) "p"
        result @?= LookupFailed "lookup-failed"
    , testCase "an outer cancellation is not turned into a result" $ do
        spec <- querySpec
        result <- timeout 100000 (invokeLookup 60000 (EffectReconciler spec (\_ _ -> threadDelay 10000000 >> pure LookupAbsent)) (op 1) "p")
        result @?= Nothing
    ]

scriptedTests :: TestTree
scriptedTests =
  testGroup
    "scripted lookups (R2)"
    [ testCase "truthful: absent before an application, the recorded result after it" $ do
        spec <- querySpec
        dest <- newScriptedDestination
        adapter <- scriptedAdapter spec dest [StepApply "one", StepApplyThenHang "kept", StepMalformed, StepApplyThenFail]
        reconciler <- scriptedReconciler spec dest []
        before <- invokeLookup 1000 reconciler (op 1) "p"
        before @?= LookupNotFound
        traverse_ (\n -> invokeAdapter 100 adapter (op n) "p") [1, 2, 3, 4]
        results <- traverse (\n -> invokeLookup 1000 reconciler (op n) "p") [1, 2, 3, 4, 5]
        results @?= [LookupFound "one", LookupFound "kept", LookupFound "applied", LookupFound "applied", LookupNotFound]
    , testCase "hang and fail, then truthful after the script" $ do
        spec <- querySpec
        dest <- newScriptedDestination
        adapter <- scriptedAdapter spec dest []
        _ <- invokeAdapter 1000 adapter (op 1) "p"
        reconciler <- scriptedReconciler spec dest [LookupHang, LookupFail]
        results <- traverse (const (invokeLookup 100 reconciler (op 1) "p")) [1 :: Int, 2, 3]
        results @?= [LookupFailed "timeout", LookupFailed "lookup-failed", LookupFound "ok"]
    ]
