{-# LANGUAGE OverloadedStrings #-}

module Lockstep.Kernel.WorkUnitLifecycleTest
  ( tests
  ) where

import Data.Maybe (isJust)
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Kernel.Identity (ContractId (..), uuidFromWords)
import Lockstep.Kernel.LifecycleFixtures
  ( Expect (..)
  , Fixtures (..)
  , admitted
  , attempt
  , exhaustive
  , passing
  , row
  , rows
  , verificationWith
  , withFixtures
  )
import Lockstep.Kernel.Transition (Command (..), Principal (..), replay, transitionRefusalCode)
import Lockstep.Kernel.WorkUnit (AdmittedWorkUnit (..), WorkUnitRequest (..))
import Lockstep.Kernel.WorkUnitLifecycle
  ( CheckOutcome (..)
  , FrozenContract
  , ReviewVerdict (..)
  , WorkUnit (..)
  , WorkUnitInput (..)
  , WorkUnitState (..)
  , acceptedCommit
  , acceptedWorkUnit
  , acceptedWorkUnitId
  , frozenAttemptBudget
  , mkFrozenContract
  , newWorkUnit
  , stepWorkUnit
  , workUnitStateName
  )

tests :: TestTree
tests =
  testGroup
    "Kernel Work Unit lifecycle (C-P2.2 §3.3)"
    [ testCase "exhaustive: every state × input × principal matches the table" $
        withFixtures $ \fx -> do
          let
            gated = fxGated fx
            a = fxCommitA fx
            v = passing a
            unit = WorkUnit (admitted 1)
            states =
              fmap
                (fmap unit)
                [ ("candidate", Candidate)
                , ("frozen", Frozen gated)
                , ("implementing", Implementing gated (attempt 1))
                , ("verifying", Verifying gated (attempt 1) a)
                , ("verified-gated", Verified gated (attempt 1) v ["challenge"])
                , ("verified", Verified gated (attempt 1) v [])
                , ("rework", Rework gated 1 "verification-failed")
                , ("accepted", Accepted gated a v)
                , ("halted", Halted "operator halt")
                ]
            inputs =
              [ ("freeze", WuFreeze gated)
              , ("start-1", WuStartAttempt (attempt 1))
              , ("start-2", WuStartAttempt (attempt 2))
              , ("implementation", WuImplementationObserved a)
              , ("verification-pass", WuVerificationObserved v)
              , ("gate-passed", WuGatePassed "challenge")
              , ("gate-failed", WuGateFailed "challenge" "challenger found a gap")
              , ("review-approved", WuReviewObserved ReviewApproved)
              , ("halt", WuHalt "halt")
              ]
            table =
              [ row "candidate" "freeze" [Supervisor] (To "frozen")
              , row "frozen" "start-1" [Supervisor] (To "implementing")
              , row "frozen" "start-2" [Supervisor] (Refuse "basis-mismatch")
              , row "rework" "start-2" [Supervisor] (To "implementing")
              , row "rework" "start-1" [Supervisor] (Refuse "basis-mismatch")
              , row "implementing" "implementation" [Supervisor] (To "verifying")
              , row "verifying" "verification-pass" [Supervisor] (To "verified")
              , row "verified-gated" "gate-passed" [Supervisor] (To "verified")
              , row "verified" "gate-passed" [Supervisor] (Refuse "basis-mismatch")
              , row "verified-gated" "gate-failed" [Supervisor] (To "rework")
              , row "verified" "gate-failed" [Supervisor] (Refuse "basis-mismatch")
              , row "verified" "review-approved" [Supervisor] (To "accepted")
              , row "verified-gated" "review-approved" [Supervisor] (Refuse "gates-pending")
              ]
                <> rows ["candidate", "frozen", "implementing", "verifying", "verified-gated", "verified", "rework"] "halt" [Human, Supervisor] (To "halted")
          exhaustive stepWorkUnit (workUnitStateName . workUnitState) states inputs ["accepted", "halted"] table
    , testCase "a full happy path with a gate reaches Accepted and yields accepted evidence" $
        withFixtures $ \fx -> do
          let
            a = fxCommitA fx
          result <-
            run
              (fxGated fx)
              [ WuStartAttempt (attempt 1)
              , WuImplementationObserved a
              , WuVerificationObserved (passing a)
              , WuGatePassed "challenge"
              , WuReviewObserved ReviewApproved
              ]
          workUnitStateName (workUnitState result) @?= "accepted"
          fmap acceptedCommit (acceptedWorkUnit result) @?= Just a
          fmap acceptedWorkUnitId (acceptedWorkUnit result) @?= Just (wuId (admittedRequest (admitted 1)))
    , testCase "a failed check with attempts left goes to rework; at the budget it halts" $
        withFixtures $ \fx -> do
          let
            a = fxCommitA fx
            failing = verificationWith a [CheckPassed, CheckFailed]
          first <- run (fxPlain fx) [WuStartAttempt (attempt 1), WuImplementationObserved a, WuVerificationObserved failing]
          workUnitState first @?= Rework (fxPlain fx) 1 "verification-failed"
          second <- runFrom first [WuStartAttempt (attempt 2), WuImplementationObserved a, WuVerificationObserved failing]
          workUnitState second @?= Halted "attempts-exhausted"
          tight <- run (fxTight fx) [WuStartAttempt (attempt 1), WuImplementationObserved a, WuVerificationObserved failing]
          workUnitState tight @?= Halted "attempts-exhausted"
    , testCase "NotRun or Unknown without a failure halts as inconclusive; never Verified" $
        withFixtures $ \fx -> do
          let
            a = fxCommitA fx
          traverse_
            ( \outcomes -> do
                result <- run (fxPlain fx) [WuStartAttempt (attempt 1), WuImplementationObserved a, WuVerificationObserved (verificationWith a outcomes)]
                workUnitState result @?= Halted "verification-inconclusive"
            )
            [[CheckPassed, CheckNotRun], [CheckUnknown], [CheckNotRun, CheckUnknown, CheckPassed]]
          failedAndUnknown <- run (fxPlain fx) [WuStartAttempt (attempt 1), WuImplementationObserved a, WuVerificationObserved (verificationWith a [CheckUnknown, CheckFailed])]
          workUnitState failedAndUnknown @?= Rework (fxPlain fx) 1 "verification-failed"
    , testCase "a verification of another commit is basis-mismatch" $
        withFixtures $ \fx ->
          refusalAfter
            (fxPlain fx)
            [WuStartAttempt (attempt 1), WuImplementationObserved (fxCommitA fx)]
            (WuVerificationObserved (passing (fxCommitB fx)))
            "basis-mismatch"
    , testCase "starting past the attempt budget is attempt-budget-exhausted" $
        withFixtures $ \fx -> do
          let
            reworked = WorkUnit (admitted 1) (Rework (fxTight fx) 1 "verification-failed")
          either transitionRefusalCode (workUnitStateName . workUnitState) (stepWorkUnit reworked (Command Supervisor (WuStartAttempt (attempt 2))))
            @?= "attempt-budget-exhausted"
    , testCase "review changes requested: rework within the budget" $
        withFixtures $ \fx -> do
          let
            a = fxCommitA fx
          result <- run (fxPlain fx) [WuStartAttempt (attempt 1), WuImplementationObserved a, WuVerificationObserved (passing a), WuReviewObserved (ReviewChangesRequested "naming")]
          workUnitState result @?= Rework (fxPlain fx) 1 "review-changes-requested"
    , testCase "gates pass one at a time and in any order" $
        withFixtures $ \fx -> do
          let
            a = fxCommitA fx
            digest = T.replicate 64 "e"
          two <- maybe (assertFailure "contract") pure (mkFrozenContract (ContractId (uuidFromWords 7 2)) digest 3 ["g1", "g2"])
          result <- run two [WuStartAttempt (attempt 1), WuImplementationObserved a, WuVerificationObserved (passing a), WuGatePassed "g2", WuGatePassed "g1", WuReviewObserved ReviewApproved]
          workUnitStateName (workUnitState result) @?= "accepted"
          frozenAttemptBudget two @?= 3
    , testCase "frozen contract validation" $ do
        let
          contract = ContractId (uuidFromWords 7 3)
          ok = T.replicate 64 "0"
        isJust (mkFrozenContract contract ok 1 []) @?= True
        isJust (mkFrozenContract contract ok 10 ["a", "b"]) @?= True
        isJust (mkFrozenContract contract ok 0 []) @?= False
        isJust (mkFrozenContract contract ok 11 []) @?= False
        isJust (mkFrozenContract contract (T.replicate 63 "0") 1 []) @?= False
        isJust (mkFrozenContract contract (T.replicate 64 "A") 1 []) @?= False
        isJust (mkFrozenContract contract ok 1 ["a", "a"]) @?= False
        isJust (mkFrozenContract contract ok 1 [""]) @?= False
    , testCase "accepted evidence exists only for an Accepted Work Unit" $
        withFixtures $ \fx -> do
          let
            a = fxCommitA fx
            v = passing a
            others =
              [ Candidate
              , Frozen (fxPlain fx)
              , Implementing (fxPlain fx) (attempt 1)
              , Verifying (fxPlain fx) (attempt 1) a
              , Verified (fxPlain fx) (attempt 1) v []
              , Rework (fxPlain fx) 1 "x"
              , Halted "x"
              ]
          traverse_ (\s -> fmap acceptedCommit (acceptedWorkUnit (WorkUnit (admitted 1) s)) @?= Nothing) others
          fmap acceptedCommit (acceptedWorkUnit (WorkUnit (admitted 1) (Accepted (fxPlain fx) a v))) @?= Just a
    ]

-- | Freezes the contract on a new Work Unit and runs the inputs as the Supervisor.
run :: FrozenContract -> [WorkUnitInput] -> IO WorkUnit
run contract inputs =
  runFrom (newWorkUnit (admitted 1)) (WuFreeze contract : inputs)

runFrom :: WorkUnit -> [WorkUnitInput] -> IO WorkUnit
runFrom start inputs =
  case replay stepWorkUnit start (fmap (Command Supervisor) inputs) of
    Right result -> pure result
    Left (index, refusal) -> assertFailure ("input " <> show index <> " refused: " <> show refusal)

refusalAfter :: FrozenContract -> [WorkUnitInput] -> WorkUnitInput -> T.Text -> Assertion
refusalAfter contract prefix input code = do
  start <- run contract prefix
  either transitionRefusalCode (workUnitStateName . workUnitState) (stepWorkUnit start (Command Supervisor input)) @?= code
