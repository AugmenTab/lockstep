{-# LANGUAGE OverloadedStrings #-}

{- | The Human Inbox's words and the Planner's clarification answer (contract
C-P6.3 I2, I4): every offered choice says what it does; a clarification is the
Planner's text alone, checked like any role answer, and nothing else.
-}
module Lockstep.Kernel.InboxTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))
import Text.Show (show)

import Lockstep.Effects.Roles (decodeAnswer)
import Lockstep.Kernel.Inbox (choiceConsequence, maxClarifications)
import Lockstep.Kernel.Roles (Clarification (..), Role (..), RoleAnswer (..), checkAnswer)
import Lockstep.Kernel.Transaction (Stage (..), haltChoices, retryOperation)

stages :: [Stage]
stages =
  [StageBasis, StageDiscovery, StageReproduction, StageCandidate, StageChallengePre, StageFreeze, StageImplement, StageVerify, StageChallengePost, StageReview, StageAccept]

decode :: BS.ByteString -> Either T.Text RoleAnswer
decode =
  decodeAnswer

tests :: TestTree
tests =
  testGroup
    "the Human Inbox's words and the clarification answer (C-P6.3)"
    [ testCase "retry says what runs again at that step (I2)" $
        traverse_ (\s -> choiceConsequence s "retry" @?= retryOperation s) stages
    , testCase "stop, replan and going on without a reproduction say what they do (I2)" $ do
        choiceConsequence StageVerify "stop" @?= "Stop ends this fix: nothing more runs, its work branch is kept as it is, and nothing is published."
        choiceConsequence StageReproduction "replan" @?= "Replan runs the Planner's search for the cause again, from the start."
        choiceConsequence StageReproduction "accept-non-reproduction"
          @?= "Going on without a reproduction: the fix continues, and the tests it writes must still fail because of the bug."
    , testCase "every choice a halt can offer has words; an unknown one says it cannot be described, never nothing (I2)" $ do
        let
          offered = [c | s <- stages, code <- ["repository-dirty", "reproduction-missing", "protected-test-changed", "role-failed no-coding-agent"], c <- haltChoices s code]
        traverse_ (\c -> assertBool ("no words for " <> show c) (not (T.null (choiceConsequence StageBasis c)))) offered
        choiceConsequence StageBasis "launch-the-rockets" @?= "Lockstep cannot describe what this choice does."
    , testCase "at most 3 answers per request (I6)" $
        maxClarifications @?= 3
    , testCase "the Planner's clarification is accepted from the Planner only, with checked text (I4)" $ do
        let
          answer = AnswerClarification (Clarification "Retry checks the folder again.")
        checkAnswer Planner answer @?= Right answer
        traverse_ (\r -> checkAnswer r answer @?= Left "wrong-kind") [Challenger, Implementer, Reviewer]
        checkAnswer Planner (AnswerClarification (Clarification "   ")) @?= Left "text-invalid"
        checkAnswer Planner (AnswerClarification (Clarification (T.replicate 4001 "x"))) @?= Left "text-invalid"
        checkAnswer Planner (AnswerClarification (Clarification "a\NULb")) @?= Left "text-invalid"
    , testCase "a clarification answer decodes to its text only; any other key refuses it (I4, I5)" $ do
        decode "{\"kind\":\"clarification\",\"text\":\"It reruns the basis check.\"}" @?= Right (AnswerClarification (Clarification "It reruns the basis check."))
        assertBool "an extra decision key was accepted" (isLeft (decode "{\"kind\":\"clarification\",\"text\":\"ok\",\"choice\":\"retry\"}"))
        assertBool "a missing text was accepted" (isLeft (decode "{\"kind\":\"clarification\"}"))
    ]
