{-# LANGUAGE OverloadedStrings #-}

-- | The rules of candidate tests and their challenge (contract C-P4.7–9 K1–K4).
module Lockstep.Kernel.CandidateTest
  ( tests
  ) where

import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Lockstep.Kernel.Candidate (MutantRun (..), classifyTest, disposeFinding, quoteGrounded, testStem)
import Lockstep.Kernel.Roles (Expectation (..), FindingHint (..))
import Lockstep.Kernel.Runner (RunOutcome (..), Stream (..))
import Lockstep.Kernel.Transaction
  ( BaselineClass (..)
  , Counters (..)
  , Disposition (..)
  , Stage (..)
  , Transaction (..)
  , TxInput (..)
  , TxState (..)
  , newTransaction
  , stepTransaction
  )
import Lockstep.Kernel.Transition (Principal (..))

tests :: TestTree
tests =
  testGroup
    "C-P4.7-9 candidate tests and their challenge"
    [ testCase "a test's name is its file name without directory or extension" stems
    , testCase "RED: failing with its signature and its name; anything else is not RED" red
    , testCase "GREEN: passing; a failing new GREEN test is a defective fixture, never RED" green
    , testCase "a run that did not end normally is run-failed, whatever it expected" runFailures
    , testCase "a quote is grounded only in the Ticket's own words" grounding
    , testCase "a finding is confirmed only by an observed survivor, its demonstration and a named requirement" dispositions
    , testCase "a rejected candidate goes back to the Planner within the correction budget" rejections
    , testCase "a missing program at the baseline halts the candidate" environment
    ]

stems :: IO ()
stems =
  fmap testStem ["test_calc.py", "tests/test_discount.py", "spec/a/b_spec.rb", "Makefile", ".hidden", "x.y.z"]
    @?= ["test_calc", "test_discount", "b_spec", "Makefile", ".hidden", "x.y"]

red :: IO ()
red = do
  let
    c = classifyTest ExpectRed "tests/test_calc.py" (Just "add is wrong")
  c (Exited 1) "FAIL: test_add (test_calc.TestAdd)\nAssertionError: 0 != 4 : add is wrong" "" @?= RedConfirmed
  c (Exited 1) "" "FAIL: test_add (test_calc.TestAdd) add is wrong" @?= RedConfirmed
  c (Exited 0) "OK" "" @?= RedUnexpectedlyPassed
  c (Exited 1) "ModuleNotFoundError: No module named test_calc" "" @?= RedWrongReason
  c (Exited 1) "add is wrong" "" @?= RedWrongReason
  c (Exited 127) "test_calc add is wrong" "" @?= RedWrongReason
  c (Exited 126) "test_calc add is wrong" "" @?= RedWrongReason
  classifyTest ExpectRed "test_calc.py" Nothing (Exited 1) "test_calc failed" "" @?= RedWrongReason
  classifyTest ExpectRed "test_calc.py" (Just "") (Exited 1) "test_calc failed" "" @?= RedWrongReason

green :: IO ()
green = do
  classifyTest ExpectGreen "test_mul.py" Nothing (Exited 0) "" "" @?= GreenConfirmed
  classifyTest ExpectGreen "test_mul.py" Nothing (Exited 1) "test_mul broke" "" @?= GreenCandidateFailed
  classifyTest ExpectGreen "test_mul.py" (Just "x") (Exited 2) "" "" @?= GreenCandidateFailed

runFailures :: IO ()
runFailures =
  fmap
    (\o -> (classifyTest ExpectRed "t.py" (Just "s") o "t s" "", classifyTest ExpectGreen "t.py" Nothing o "" ""))
    [TimedOut, OutputLimit Stdout, OutputHeld Stderr, Cancelled, LaunchFailed "x"]
    @?= [(RunFailed, RunFailed), (RunFailed, RunFailed), (RunFailed, RunFailed), (RunFailed, RunFailed), (RunFailed, RunFailed)]

grounding :: IO ()
grounding = do
  let
    ticket = ["add subtracts", "add(2, 2) is 4\nand  add(0, 0)   is 0"]
  quoteGrounded ticket "add subtracts" @?= True
  quoteGrounded ticket "ADD   Subtracts" @?= True
  quoteGrounded ticket "add(0, 0) is 0" @?= True
  quoteGrounded ticket "add multiplies" @?= False
  quoteGrounded ticket "" @?= False
  quoteGrounded ticket "   " @?= False
  quoteGrounded [] "add" @?= False

dispositions :: IO ()
dispositions = do
  disposeFinding True (MutantSurvived True) HintNone @?= Confirmed
  disposeFinding False (MutantSurvived True) HintNone @?= Inconclusive
  disposeFinding True (MutantSurvived False) HintNone @?= Inconclusive
  disposeFinding True (MutantSurvived False) HintNeedsHuman @?= NeedsHumanFinding
  disposeFinding True MutantKilled HintNeedsHuman @?= Disproved
  disposeFinding False MutantKilled HintNone @?= Disproved
  disposeFinding True NoMutant HintNone @?= Inconclusive
  disposeFinding True NoMutant HintNeedsHuman @?= NeedsHumanFinding
  disposeFinding True NoMutant HintInconclusive @?= Inconclusive
  disposeFinding True MutantOutsideScope HintNone @?= Inconclusive

atCandidate :: Either a Transaction
atCandidate =
  Right (Transaction (Running StageCandidate) (Counters 0 0))

rejections :: IO ()
rejections = do
  let
    reject t = t >>= stepTransaction Supervisor (CandidateRejected "criterion-not-grounded")
    once = reject atCandidate
    thrice = reject (reject (reject atCandidate))
  fmap txState once @?= Right (Running StageCandidate)
  fmap txCounters once @?= Right (Counters 1 0)
  fmap txState thrice @?= Right (Halted StageCandidate "candidates-exhausted")
  stepTransaction Human (CandidateRejected "x") (Transaction (Running StageCandidate) (Counters 0 0)) @?= Left "not-authorized"
  stepTransaction Supervisor (CandidateRejected "x") newTransaction @?= Left "illegal-input"

environment :: IO ()
environment = do
  fmap txState (atCandidate >>= stepTransaction Supervisor (VerificationInconclusive "verification-environment-missing"))
    @?= Right (Halted StageCandidate "verification-environment-missing")
  fmap txState (atCandidate >>= stepTransaction Supervisor RegressionFailed)
    @?= Right (Halted StageCandidate "green-regression-failed")
