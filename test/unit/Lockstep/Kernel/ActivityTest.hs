{-# LANGUAGE OverloadedStrings #-}

{- | The plain words of the Activity view (contract C-P3.9 N1): what each
C-P2.8 status means, what needs attention, what to do next, the state of a
piece of work, and refused requests. The labels themselves stay C-P2.8's.
-}
module Lockstep.Kernel.ActivityTest
  ( tests
  ) where

import Data.List qualified as L
import Data.Maybe (isJust)
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, testCase, (@?=))
import Text.Show (show)

import Lockstep.Kernel.Activity (needsAttention, nextStep, orderStateWords, refusalMeaning, statusMeaning)
import Lockstep.Kernel.EffectView (EffectStatus (..))
import Lockstep.Kernel.Identity (EngineerId (..), WorkOrderId (..), uuidFromWords)
import Lockstep.Kernel.WorkOrder (Claim (..), WorkOrderState (..))

internalWords :: [T.Text]
internalWords =
  ["work order", "ticket", "intent", "generation", "supervisor", "scheduler"]

plain :: T.Text -> Assertion
plain text = do
  assertBool "empty words" (not (T.null (T.strip text)))
  traverse_
    (\word -> assertBool (T.unpack ("internal word " <> word <> " in: " <> text)) (not (word `T.isInfixOf` T.toLower text)))
    internalWords

cases :: [(EffectStatus, Bool)]
cases =
  [(s, retry) | s <- [minBound .. maxBound], retry <- [True, False]]

claim :: Claim
claim =
  Claim (EngineerId (uuidFromWords 1 1)) 1

states :: [WorkOrderState]
states =
  [Pending, Eligible, Claimed claim, Active claim, Waiting claim "a reply", Halted "the printer jammed", Completed claim [], Superseded (WorkOrderId (uuidFromWords 2 2)), Canceled]

tests :: TestTree
tests =
  testGroup
    "C-P3.9 plain words for activity"
    [ testCase "every status has a meaning in plain words, with and without a retry left" $
        traverse_ (\(s, retry) -> plain (statusMeaning s retry)) cases
    , testCase "only PASSED says the destination confirmed it" $
        traverse_
          ( \(s, retry) ->
              ("confirmed by the destination" `T.isInfixOf` statusMeaning s retry) @?= (s == StatusPassed)
          )
          cases
    , testCase "ATTESTED says a person said so and Lockstep did not check it" $
        traverse_
          ( \retry -> do
              let
                meaning = statusMeaning StatusAttested retry
              assertBool (T.unpack meaning) ("a person said" `T.isInfixOf` meaning && "did not check" `T.isInfixOf` meaning)
          )
          [True, False]
    , testCase "Failed is said only of a step the destination refused with no try left" $
        traverse_
          ( \(s, retry) ->
              ("Failed" `T.isInfixOf` statusMeaning s retry) @?= (s == StatusNotApplied && not retry)
          )
          cases
    , testCase "attention is needed exactly for unknown, reconciliation needed, blocked and failed steps" $
        traverse_
          ( \(s, retry) ->
              needsAttention s retry @?= (s `L.elem` [StatusUnknown, StatusReconciliationNeeded, StatusBlocked] || (s == StatusNotApplied && not retry))
          )
          cases
    , testCase "every step that needs attention has a next step; an unknown one points to Decisions" $ do
        traverse_
          ( \(s, retry) ->
              assertBool (show s <> " has no next step") (not (needsAttention s retry) || isJust (nextStep s retry))
          )
          cases
        traverse_ (\(s, retry) -> maybe (pure ()) plain (nextStep s retry)) cases
        fmap ("Decisions" `T.isInfixOf`) (nextStep StatusUnknown False) @?= Just True
        nextStep StatusPassed False @?= Nothing
    , testCase "every state of a piece of work has its own plain words" $ do
        traverse_ (plain . orderStateWords) states
        L.length (L.nub (fmap orderStateWords states)) @?= L.length states
        assertBool "the halt reason is not shown" ("the printer jammed" `T.isInfixOf` orderStateWords (Halted "the printer jammed"))
    , testCase "refused requests have plain words, and an unknown code has general ones" $ do
        let
          codes = ["stale-revision", "not-authorized", "agent-assertion", "illegal-transition", "already-terminal", "intents-not-authorized"]
        traverse_ (plain . refusalMeaning) (codes <> ["something-else"])
        L.length (L.nub (fmap refusalMeaning codes)) @?= L.length codes
        assertBool "a known code reads like an unknown one" (refusalMeaning "something-else" `L.notElem` fmap refusalMeaning codes)
    ]
