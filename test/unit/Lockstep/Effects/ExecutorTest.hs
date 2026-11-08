{-# LANGUAGE OverloadedStrings #-}

-- | C-P2.6 §7 unit cases: adapter invocation (X2) and scripted destinations (X3).
module Lockstep.Effects.ExecutorTest
  ( tests
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (throwIO)
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import System.IO.Error (userError)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Effects.Executor (DestinationAnswer (..), EffectAdapter (..), invokeAdapter)
import Lockstep.Effects.Scripted
  ( Application (..)
  , ScriptStep (..)
  , destinationApplications
  , newScriptedDestination
  , scriptedAdapter
  )
import Lockstep.Kernel.Effect (ClassTerms (..), EffectSpec, IdempotencyTerms (..), Observation (..), OperationId (..), mkEffectSpec)
import Lockstep.Kernel.Identity (uuidFromWords)

tests :: TestTree
tests =
  testGroup
    "Effect adapters (C-P2.6)"
    [ fixtureTests
    , invocationTests
    , scriptedTests
    ]

-- Fixtures -------------------------------------------------------------------

op :: Word64 -> OperationId
op n =
  OperationId (uuidFromWords 4 n)

specOf :: ClassTerms -> Int -> IO EffectSpec
specOf terms budget =
  either (assertFailure . show) pure (mkEffectSpec "step" terms budget)

-- | An adapter that always answers as given.
answering :: EffectSpec -> DestinationAnswer -> EffectAdapter
answering spec answer =
  EffectAdapter spec (\_ _ -> pure answer)

hanging :: EffectSpec -> EffectAdapter
hanging spec =
  EffectAdapter spec (\_ _ -> threadDelay 10000000 >> pure (AnswerApplied "late"))

throwing :: EffectSpec -> EffectAdapter
throwing spec =
  EffectAdapter spec (\_ _ -> throwIO (userError "boom"))

fixtureTests :: TestTree
fixtureTests =
  testGroup
    "fixtures"
    [ testCase "a hand-built adapter answers as written" $ do
        spec <- specOf TermsRepeatable 1
        answer <- adapterRun (answering spec (AnswerApplied "r")) (op 1) "p"
        answer @?= AnswerApplied "r"
        refused <- adapterRun (answering spec (AnswerNotApplied "busy")) (op 1) "p"
        refused @?= AnswerNotApplied "busy"
    ]

-- Invocation -----------------------------------------------------------------

invocationTests :: TestTree
invocationTests =
  testGroup
    "invocation (X2)"
    [ testCase "valid answers become destination observations" $ do
        spec <- specOf TermsRepeatable 1
        applied <- invokeAdapter 1000 (answering spec (AnswerApplied "done")) (op 1) "p"
        applied @?= DestinationApplied "done"
        refused <- invokeAdapter 1000 (answering spec (AnswerNotApplied "busy")) (op 1) "p"
        refused @?= DestinationNotApplied "busy"
        longest <- invokeAdapter 1000 (answering spec (AnswerApplied (T.replicate 4096 "x"))) (op 1) "p"
        longest @?= DestinationApplied (T.replicate 4096 "x")
    , testCase "an empty, control-character or over-long text is malformed-answer" $ do
        spec <- specOf TermsRepeatable 1
        results <-
          traverse
            (\a -> invokeAdapter 1000 (answering spec a) (op 1) "p")
            [AnswerApplied "", AnswerNotApplied "a\nb", AnswerApplied (T.replicate 4097 "x"), AnswerNotApplied ""]
        results @?= L.replicate 4 (NoAnswer "malformed-answer")
    , testCase "no answer within the timeout is timeout, and the call returns" $ do
        spec <- specOf TermsRepeatable 1
        result <- timeout 5000000 (invokeAdapter 50 (hanging spec) (op 1) "p")
        result @?= Just (NoAnswer "timeout")
    , testCase "a throwing adapter is adapter-failed" $ do
        spec <- specOf TermsUnqueryable 0
        result <- invokeAdapter 1000 (throwing spec) (op 1) "p"
        result @?= NoAnswer "adapter-failed"
    , testCase "an outer cancellation is not turned into an observation" $ do
        spec <- specOf TermsRepeatable 1
        result <- timeout 100000 (invokeAdapter 60000 (hanging spec) (op 1) "p")
        result @?= Nothing
    ]

-- Scripted destinations ------------------------------------------------------

scriptedTests :: TestTree
scriptedTests =
  testGroup
    "scripted destinations (X3)"
    [ testCase "steps are taken in order, then every call applies \"ok\"" $ do
        spec <- specOf TermsRepeatable 1
        dest <- newScriptedDestination
        adapter <- scriptedAdapter spec dest [StepApply "one", StepRefuse "busy"]
        results <- traverse (\n -> invokeAdapter 1000 adapter (op n) "p") [1, 2, 3]
        results @?= [DestinationApplied "one", DestinationNotApplied "busy", DestinationApplied "ok"]
        applications <- destinationApplications dest
        applications @?= [Application (op 1) "p", Application (op 3) "p"]
    , testCase "refuse, hang and fail record nothing" $ do
        spec <- specOf TermsRepeatable 1
        dest <- newScriptedDestination
        adapter <- scriptedAdapter spec dest [StepRefuse "no", StepHang, StepFail]
        results <- traverse (\n -> invokeAdapter 100 adapter (op n) "p") [1, 2, 3]
        results @?= [DestinationNotApplied "no", NoAnswer "timeout", NoAnswer "adapter-failed"]
        destinationApplications dest >>= (@?= [])
    , testCase "apply-then-hang, apply-then-fail and malformed record the application" $ do
        spec <- specOf TermsUnqueryable 0
        dest <- newScriptedDestination
        adapter <- scriptedAdapter spec dest [StepApplyThenHang "r", StepApplyThenFail, StepMalformed]
        results <- traverse (\n -> invokeAdapter 100 adapter (op n) "p") [1, 2, 3]
        results @?= [NoAnswer "timeout", NoAnswer "adapter-failed", NoAnswer "malformed-answer"]
        applications <- destinationApplications dest
        applications @?= [Application (op 1) "p", Application (op 2) "p", Application (op 3) "p"]
    , testCase "idempotent: a repeat answers the first result and applies nothing; changed parameters are refused" $ do
        spec <- specOf (TermsIdempotent (IdempotencyTerms 86400 True)) 1
        dest <- newScriptedDestination
        adapter <- scriptedAdapter spec dest [StepApply "first", StepApply "second"]
        first <- invokeAdapter 1000 adapter (op 1) "p"
        again <- invokeAdapter 1000 adapter (op 1) "p"
        changed <- invokeAdapter 1000 adapter (op 1) "other"
        other <- invokeAdapter 1000 adapter (op 2) "q"
        [first, again, changed, other]
          @?= [DestinationApplied "first", DestinationApplied "first", DestinationNotApplied "changed-parameters", DestinationApplied "second"]
        applications <- destinationApplications dest
        applications @?= [Application (op 1) "p", Application (op 2) "q"]
    , testCase "idempotent: an application whose answer was lost is deduplicated too" $ do
        spec <- specOf (TermsIdempotent (IdempotencyTerms 86400 True)) 1
        dest <- newScriptedDestination
        adapter <- scriptedAdapter spec dest [StepApplyThenHang "kept"]
        lost <- invokeAdapter 100 adapter (op 1) "p"
        again <- invokeAdapter 1000 adapter (op 1) "p"
        [lost, again] @?= [NoAnswer "timeout", DestinationApplied "kept"]
        destinationApplications dest >>= (@?= [Application (op 1) "p"])
    , testCase "repeatable: every applying call records, even for one operation" $ do
        spec <- specOf TermsRepeatable 1
        dest <- newScriptedDestination
        adapter <- scriptedAdapter spec dest []
        _ <- invokeAdapter 1000 adapter (op 1) "p"
        _ <- invokeAdapter 1000 adapter (op 1) "p"
        destinationApplications dest >>= (@?= [Application (op 1) "p", Application (op 1) "p"])
    ]
