{-# LANGUAGE OverloadedStrings #-}

{- | Human Requests and their conversations (contract C-P4.3 H1, H2, H5): the
choice and text rules, who may give each input and in which order the checks
run, a clarification that never decides, one binding answer, revisions that make
older messages stale, and the canonical payload texts.
-}
module Lockstep.Kernel.ConversationTest
  ( tests
  ) where

import Data.List qualified as L
import Data.List.NonEmpty qualified as NE
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Kernel.Conversation
  ( HumanRequest (..)
  , RequestInput (..)
  , RequestKind (..)
  , RequestState (..)
  , checkRequestText
  , choiceText
  , conversationRefusalCodes
  , messagePayloadText
  , mkChoice
  , mkDecisionKind
  , newHumanRequest
  , requestPayloadText
  , stepRequest
  )
import Lockstep.Kernel.Transition (Command (..), Principal (..))

decision :: IO HumanRequest
decision =
  either (\c -> assertFailure ("choices refused: " <> T.unpack c)) (pure . newHumanRequest) (mkDecisionKind ["fix-now", "wait"])

clarification :: HumanRequest
clarification =
  newHumanRequest ClarificationRequest

step :: HumanRequest -> Principal -> RequestInput -> Either T.Text HumanRequest
step request principal input =
  stepRequest request (Command principal input)

accepted :: Either T.Text HumanRequest -> IO HumanRequest
accepted =
  either (\c -> assertFailure ("refused: " <> T.unpack c)) pure

refusedWith :: T.Text -> Either T.Text HumanRequest -> Assertion
refusedWith code result =
  case result of
    Left c -> c @?= code
    Right r -> assertFailure ("accepted, expected " <> T.unpack code <> ": " <> show r)

-- | Every kind of input from this principal is refused with this code.
everyRefused :: T.Text -> HumanRequest -> Principal -> Assertion
everyRefused code request principal =
  traverse_ (refusedWith code . step request principal) every

numbered :: Int -> [T.Text]
numbered n =
  fmap (\i -> "c" <> T.pack (show i)) [1 .. n]

answerOf :: HumanRequest -> Maybe T.Text
answerOf r =
  case requestState r of
    Answered c -> Just (choiceText c)
    _ -> Nothing

every :: [RequestInput]
every =
  [HumanSays 1 "Which page?", PlannerSays 1 "The menu page.", HumanDecides 1 "fix-now" "Fix it now.", Revise 1 "Which menu?", Withdraw 1 "Not needed."]

tests :: TestTree
tests =
  testGroup
    "human requests and their conversations (C-P4.3)"
    [ testCase "choices: valid names, one to ten, no repeats" $ do
        fmap (\k -> case k of DecisionRequest cs -> fmap choiceText (NE.toList cs); ClarificationRequest -> []) (mkDecisionKind ["fix-now", "wait"]) @?= Right ["fix-now", "wait"]
        mkDecisionKind [] @?= Left "invalid-choices"
        mkDecisionKind ["Fix"] @?= Left "invalid-choices"
        mkDecisionKind ["fix now"] @?= Left "invalid-choices"
        mkDecisionKind ["a", "a"] @?= Left "invalid-choices"
        mkDecisionKind (numbered 11) @?= Left "invalid-choices"
        assertBool "ten choices refused" (isRight (mkDecisionKind (numbered 10)))
        fmap choiceText (mkChoice (T.replicate 40 "a")) @?= Just (T.replicate 40 "a")
        mkChoice (T.replicate 41 "a") @?= Nothing
    , testCase "text: 1 to 4000 characters after trimming; new lines and tabs only" $ do
        checkRequestText "" @?= Left "text-empty"
        checkRequestText "   \n " @?= Left "text-empty"
        checkRequestText "ring \a the bell" @?= Left "text-control"
        checkRequestText (T.replicate 4001 "x") @?= Left "text-too-long"
        checkRequestText (T.replicate 4000 "x") @?= Right (T.replicate 4000 "x")
        checkRequestText "  first\r\nsecond\tthird  " @?= Right "first\nsecond\tthird"
    , testCase "an agent is never accepted, whatever the input or the request" $ do
        d <- decision
        everyRefused "agent-assertion" d Agent
        everyRefused "agent-assertion" clarification Agent
    , testCase "who may give each input" $ do
        d <- decision
        let
          allowed input = [p | p <- [minBound .. maxBound], p /= Agent, either (const False) (const True) (step d p input)]
        allowed (HumanSays 1 "Which page?") @?= [Human]
        allowed (PlannerSays 1 "The menu page.") @?= [Supervisor]
        allowed (HumanDecides 1 "fix-now" "Fix it now.") @?= [Human]
        allowed (Revise 1 "Which menu?") @?= [Supervisor]
        allowed (Withdraw 1 "Not needed.") @?= [Human, Supervisor]
        refusedWith "not-authorized" (step d Scheduler (HumanSays 1 "Hello"))
        refusedWith "not-authorized" (step d DeliveryAdapter (Withdraw 1 "No"))
    , testCase "a clarification is information: it never answers, and a clarification request cannot be decided" $ do
        asked <- accepted (step clarification Human (HumanSays 1 "Which page?"))
        answered <- accepted (step asked Supervisor (PlannerSays 1 "The menu page."))
        (requestState answered, requestRevision answered) @?= (Open, 1)
        refusedWith "not-a-decision" (step answered Human (HumanDecides 1 "fix-now" "Fix it."))
        d <- decision
        talked <- accepted (step d Human (HumanSays 1 "Is it urgent?"))
        requestState talked @?= Open
    , testCase "a decision is answered once, with a choice it offers" $ do
        d <- decision
        refusedWith "unknown-choice" (step d Human (HumanDecides 1 "later" "Later."))
        done <- accepted (step d Human (HumanDecides 1 "fix-now" "Fix it now."))
        answerOf done @?= Just "fix-now"
        everyRefused "request-closed" done Human
        everyRefused "request-closed" done Supervisor
    , testCase "a revision makes anything written against the old one stale" $ do
        d <- decision
        revised <- accepted (step d Supervisor (Revise 1 "Which menu, the top one?"))
        requestRevision revised @?= 2
        refusedWith "stale-revision" (step revised Human (HumanDecides 1 "fix-now" "Fix it."))
        refusedWith "stale-revision" (step revised Supervisor (PlannerSays 1 "The top one."))
        done <- accepted (step revised Human (HumanDecides 2 "wait" "Wait for now."))
        (requestRevision done, answerOf done) @?= (2, Just "wait")
    , testCase "a withdrawn request takes nothing more" $ do
        d <- decision
        withdrawn <- accepted (step d Human (Withdraw 1 "Not needed any more."))
        requestState withdrawn @?= Withdrawn
        everyRefused "request-closed" withdrawn Human
    , testCase "the check order: agent, closed, stale, who, text, then the input's own rule" $ do
        d <- decision
        done <- accepted (step d Human (HumanDecides 1 "fix-now" "Fix it now."))
        refusedWith "agent-assertion" (step done Agent (HumanSays 9 ""))
        refusedWith "request-closed" (step done Supervisor (PlannerSays 9 ""))
        refusedWith "stale-revision" (step d Supervisor (HumanDecides 9 "nope" ""))
        refusedWith "not-authorized" (step d Supervisor (HumanDecides 1 "nope" ""))
        refusedWith "text-empty" (step d Human (HumanDecides 1 "nope" "  "))
        refusedWith "unknown-choice" (step d Human (HumanDecides 1 "nope" "Yes"))
        L.sort conversationRefusalCodes
          @?= L.sort ["agent-assertion", "request-closed", "stale-revision", "not-authorized", "not-a-decision", "unknown-choice", "invalid-choices", "text-empty", "text-too-long", "text-control"]
    , testCase "the payload texts are exact, and every field changes them" $ do
        let
          wo = "0b6f8a52-35a6-4a3e-9a51-7d3b3c1d2e4f"
          rq = "5d1c2b3a-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
          digest = T.replicate 64 "a"
        kind <- either (const (assertFailure "choices")) pure (mkDecisionKind ["fix-now", "wait"])
        requestPayloadText wo "p-website" (Just digest) kind "Fix \"it\"?" "line 1\nline 2" "decide"
          @?= T.unlines
            [ "lockstep-human-request-v1"
            , "work-order " <> wo
            , "engineer p-website"
            , "contract " <> digest
            , "kind decision"
            , "choices fix-now,wait"
            , "question \"Fix \\\"it\\\"?\""
            , "evidence \"line 1\\nline 2\""
            , "authority \"decide\""
            ]
        requestPayloadText wo "p-website" Nothing ClarificationRequest "Q" "E" "A"
          @?= T.unlines ["lockstep-human-request-v1", "work-order " <> wo, "engineer p-website", "contract none", "kind clarification", "choices ", "question \"Q\"", "evidence \"E\"", "authority \"A\""]
        messagePayloadText rq Human "application-session" (HumanDecides 2 "wait" "Wait \\ please")
          @?= T.unlines
            [ "lockstep-conversation-message-v1"
            , "request " <> rq
            , "principal Human"
            , "evidence \"application-session\""
            , "kind decision"
            , "revision 2"
            , "choice wait"
            , "text \"Wait \\\\ please\""
            ]
        let
          base = messagePayloadText rq Human "application-session" (HumanSays 1 "Hi")
          variants =
            [ messagePayloadText wo Human "application-session" (HumanSays 1 "Hi")
            , messagePayloadText rq Supervisor "application-session" (HumanSays 1 "Hi")
            , messagePayloadText rq Human "cli-session" (HumanSays 1 "Hi")
            , messagePayloadText rq Human "application-session" (PlannerSays 1 "Hi")
            , messagePayloadText rq Human "application-session" (HumanSays 2 "Hi")
            , messagePayloadText rq Human "application-session" (HumanSays 1 "Hello")
            ]
        traverse_ (\v -> assertBool "a field does not change the message text" (v /= base)) variants
        let
          request = requestPayloadText wo "p-website" Nothing ClarificationRequest "Q" "E" "A"
          requestVariants =
            [ requestPayloadText rq "p-website" Nothing ClarificationRequest "Q" "E" "A"
            , requestPayloadText wo "p-garden" Nothing ClarificationRequest "Q" "E" "A"
            , requestPayloadText wo "p-website" (Just digest) ClarificationRequest "Q" "E" "A"
            , requestPayloadText wo "p-website" Nothing kind "Q" "E" "A"
            , requestPayloadText wo "p-website" Nothing ClarificationRequest "Q2" "E" "A"
            , requestPayloadText wo "p-website" Nothing ClarificationRequest "Q" "E2" "A"
            , requestPayloadText wo "p-website" Nothing ClarificationRequest "Q" "E" "A2"
            ]
        traverse_ (\v -> assertBool "a field does not change the request text" (v /= request)) requestVariants
    ]
