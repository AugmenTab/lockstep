{-# LANGUAGE OverloadedStrings #-}

{- | The dispatcher's pure rules (contract C-P6.5 S1–S3, S7, S8): when a
prerequisite is satisfied, which unit goes next and why the others wait, and
the basis of a dependent fix.
-}
module Lockstep.Kernel.DispatchTest
  ( tests
  ) where

import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Lockstep.Kernel.Dispatch
  ( BudgetFact (..)
  , DispatchDecision (..)
  , FixFact (..)
  , PrerequisiteFact (..)
  , ProjectFacts (..)
  , UnitFacts (..)
  , WaitReason (..)
  , chooseBasis
  , dispatchDecision
  , fixFactCode
  , prerequisiteSatisfied
  , readinessWith
  , waitReasonCode
  , waitReasonWords
  )
import Lockstep.Kernel.Plan (EdgeKind (..), UnitKey, mkUnitKey, unitKeyText)
import Lockstep.Kernel.Task (TaskReadiness (..))

key :: T.Text -> UnitKey
key text =
  fromMaybe (fallback text) (mkUnitKey text)
 where
  fallback _ =
    case mkUnitKey "invalid-key-in-test" of
      Just k -> k
      Nothing -> fallback "x"

prereq :: Maybe EdgeKind -> Bool -> FixFact -> PrerequisiteFact
prereq =
  PrerequisiteFact "Parse poems" "ready"

unit :: T.Text -> Int -> Int -> TaskReadiness -> UnitFacts
unit k priority ordinal readiness =
  UnitFacts (key k) ("Unit " <> k) priority ordinal readiness Nothing True

open :: ProjectFacts
open =
  ProjectFacts True Nothing NoBudget

reasons :: DispatchDecision -> [(T.Text, T.Text)]
reasons d =
  [(unitKeyText k, waitReasonCode r) | (k, r) <- decisionWaiting d]

tests :: TestTree
tests =
  testGroup
    "C-P6.5 the dispatcher (pure)"
    [ testGroup
        "when a prerequisite is satisfied (S1)"
        [ testCase "the person's Done satisfies every kind of edge, and an untyped task dependency (P6.2 D1)" $
            traverse_ (\e -> assertBool (show' e) (prerequisiteSatisfied (prereq e False FixDone))) [Nothing, Just Technical, Just HumanAcceptance, Just External]
        , testCase "a technical acceptance satisfies only a technical edge of a provisional unit" $ do
            prerequisiteSatisfied (prereq (Just Technical) True FixAccepted) @?= True
            prerequisiteSatisfied (prereq (Just Technical) False FixAccepted) @?= False
            prerequisiteSatisfied (prereq (Just HumanAcceptance) True FixAccepted) @?= False
            prerequisiteSatisfied (prereq (Just External) True FixAccepted) @?= False
            prerequisiteSatisfied (prereq Nothing True FixAccepted) @?= False
        , testCase "an invalidated acceptance, a fix under way, a stopped fix or none satisfy nothing" $
            traverse_
              (\f -> prerequisiteSatisfied (prereq (Just Technical) True f) @?= False)
              [NoFix, FixUnderWay, FixAcceptanceInvalidated, FixStopped]
        , testCase "a done Ticket still satisfies, as before" $
            prerequisiteSatisfied (PrerequisiteFact "x" "done" Nothing False NoFix) @?= True
        , testCase "readiness: satisfied prerequisites count as finished; a canceled one still means cannot start" $ do
            readinessWith "ready" Nothing [prereq (Just Technical) True FixAccepted] @?= ReadyToWork
            readinessWith "ready" Nothing [prereq (Just HumanAcceptance) True FixAccepted] @?= WaitingFor ["Parse poems"]
            readinessWith "ready" Nothing [PrerequisiteFact "Gone" "canceled" Nothing False FixDone] @?= CannotStart ["Gone"]
            readinessWith "proposed" Nothing [prereq Nothing False FixDone] @?= NotYetReady
            readinessWith "ready" Nothing [] @?= ReadyToWork
        , testCase "each fix fact has its code" $
            fmap fixFactCode [minBound .. maxBound] @?= ["none", "under-way", "accepted", "acceptance-invalidated", "done", "stopped"]
        ]
    , testGroup
        "which unit goes next, and why the others wait (S2, S3, S7)"
        [ testCase "priority first, then the plan's order, then the key; the rest wait behind the chosen one" $ do
            let
              d = dispatchDecision open [unit "c" 500 2 ReadyToWork, unit "b" 500 1 ReadyToWork, unit "a" 200 0 ReadyToWork, unit "hi" 800 3 ReadyToWork]
            decisionNext d @?= Just (key "hi")
            fmap (waitReasonCode . snd) (decisionWaiting d) @?= ["queued-behind", "queued-behind", "queued-behind"]
            fmap fst (decisionWaiting d) @?= [key "a", key "b", key "c"]
        , testCase "the same position and priority: the key decides" $
            decisionNext (dispatchDecision open [unit "b" 500 1 ReadyToWork, unit "a" 500 1 ReadyToWork]) @?= Just (key "a")
        , testCase "priority never bypasses a dependency" $ do
            let
              d = dispatchDecision open [unit "hi" 800 0 (WaitingFor ["Unit a"]), unit "a" 200 1 ReadyToWork]
            decisionNext d @?= Just (key "a")
            decisionWaiting d @?= [(key "hi", WaitingForPrerequisites ["Unit a"])]
        , testCase "a busy writer, a project not enabled, an unknown budget: nothing goes, each says why" $ do
            let
              units = [unit "a" 500 0 ReadyToWork]
            dispatchDecision open {projectWriter = Just "Unit z"} units @?= DispatchDecision Nothing [(key "a", WriterBusy "Unit z")]
            dispatchDecision open {projectEnabled = False} units @?= DispatchDecision Nothing [(key "a", ExecutionNotEnabled)]
            dispatchDecision open {projectBudget = UsageUnknown} units @?= DispatchDecision Nothing [(key "a", UsageNotKnown)]
        , testCase "a unit's own state: handed over, finished, blocked, cannot start, canceled, not local, not accepted, unknown" $ do
            let
              d =
                dispatchDecision
                  open
                  [ (unit "a" 500 0 ReadyToWork) {unitFactHandedOver = Just FixUnderWay}
                  , (unit "b" 500 1 ReadyToWork) {unitFactHandedOver = Just FixDone}
                  , unit "c" 500 2 (BlockedBecause "waiting for the designer")
                  , unit "d" 500 3 (CannotStart ["Gone"])
                  , unit "e" 500 4 TaskCanceled
                  ]
            decisionNext d @?= Nothing
            fmap snd (decisionWaiting d) @?= [HandedOver, FinishedUnit, BlockedUnit "waiting for the designer", CannotStartUnit ["Gone"], CanceledUnit]
            decisionWaiting (dispatchDecision open [(unit "a" 500 0 ReadyToWork) {unitFactLocal = False}]) @?= [(key "a", NotLocal)]
            decisionWaiting (dispatchDecision open [unit "a" 500 0 NotYetReady]) @?= [(key "a", NotYetAccepted)]
            decisionWaiting (dispatchDecision open [unit "a" 500 0 (StateUnrecognised "odd")]) @?= [(key "a", UnrecognisedState "odd")]
            decisionWaiting (dispatchDecision open [unit "a" 500 0 Finished]) @?= [(key "a", FinishedUnit)]
            decisionWaiting (dispatchDecision open [unit "a" 500 0 BeingWorkedOn]) @?= [(key "a", HandedOver)]
        , testCase "every waiting reason has a code and plain words" $ do
            let
              all' = [WaitingForPrerequisites ["x"], WriterBusy "x", ExecutionNotEnabled, UsageNotKnown, QueuedBehind "x", HandedOver, FinishedUnit, NotYetAccepted, BlockedUnit "x", CannotStartUnit ["x"], CanceledUnit, NotLocal, UnrecognisedState "x"]
            fmap waitReasonCode all'
              @?= ["waiting-for", "writer-busy", "execution-not-enabled", "usage-unknown", "queued-behind", "handed-over", "finished", "not-ready", "blocked", "cannot-start", "canceled", "not-local", "unknown"]
            traverse_ (assertBool "no words" . not . T.null . waitReasonWords) all'
            assertBool "unknown usage is not called available" (not ("available" `T.isInfixOf` T.toLower (waitReasonWords UsageNotKnown)))
        , testCase "the reasons read in the plan's order, whatever the order given" $
            reasons (dispatchDecision open [unit "b" 500 1 TaskCanceled, unit "a" 500 0 TaskCanceled]) @?= [("a", "canceled"), ("b", "canceled")]
        ]
    , testGroup
        "the basis of a dependent fix (S8)"
        [ testCase "no accepted prerequisite: the checkout, as before" $
            chooseBasis (\_ _ -> False) [] @?= Right Nothing
        , testCase "one, or one that contains the others: that commit" $ do
            chooseBasis (==) ["c1"] @?= Right (Just "c1")
            chooseBasis c1BeforeC2 ["c1", "c2"] @?= Right (Just "c2")
            chooseBasis c1BeforeC2 ["c2", "c1"] @?= Right (Just "c2")
            chooseBasis (==) ["c1", "c1"] @?= Right (Just "c1")
        , testCase "two that do not contain each other: basis-ambiguous" $
            chooseBasis (==) ["c1", "c2"] @?= Left "basis-ambiguous"
        ]
    ]
 where
  -- c1 is an ancestor of c2; every commit is its own ancestor.
  c1BeforeC2 a b = a == b || (a, b) == ("c1", "c2")
  show' e = "not satisfied by Done: " <> maybe "untyped" (const "typed") e
