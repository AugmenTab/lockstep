{-# LANGUAGE OverloadedStrings #-}

{- | Decision requests a person makes in the browser (contract C-P3.8 M2, M5):
the canonical payload behind each receipt, the subject and choice names, the
text rules and the plain words.
-}
module Lockstep.Kernel.DecisionTest
  ( tests
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, testCase, (@?=))

import Lockstep.Kernel.Decision
  ( DecisionRequest (..)
  , checkDecisionText
  , choiceWords
  , decisionChoiceName
  , decisionExpected
  , decisionPayload
  , decisionRefusalWords
  , decisionSubject
  )
import Lockstep.Kernel.Effect (OperationId (..))
import Lockstep.Kernel.Identity (WorkOrderId (..), uuidFromWords)

order :: WorkOrderId
order =
  WorkOrderId (uuidFromWords 1 2)

operation :: OperationId
operation =
  OperationId (uuidFromWords 3 4)

internalWords :: [T.Text]
internalWords =
  ["work order", "ticket", "intent", "generation", "supervisor", "scheduler", "profile", "digest"]

plain :: T.Text -> Assertion
plain text = do
  assertBool "empty words" (not (T.null (T.strip text)))
  traverse_
    (\word -> assertBool (T.unpack ("internal word " <> word <> " in: " <> text)) (not (word `T.isInfixOf` T.toLower text)))
    internalWords

every :: [DecisionRequest]
every =
  [ PutBackInLine order 4
  , CancelWork order 4
  , ItHappened operation 2 "I saw the email arrive"
  , ItDidNotHappen operation 2 "Nothing arrived"
  , TryAgain operation 2 True
  , GiveUp operation 2 "Not needed any more" True
  ]

tests :: TestTree
tests =
  testGroup
    "C-P3.8 decision requests"
    [ testCase "the canonical payload of a request" $
        decisionPayload (GiveUp operation 2 "say \"no\"\nnow" True)
          @?= T.unlines
            [ "lockstep-decision-v1"
            , "subject 00000000-0000-0003-0000-000000000004"
            , "choice give-up"
            , "expected 2"
            , "text \"say \\\"no\\\"\\nnow\""
            , "acknowledged true"
            ]
    , testCase "a request without text or acknowledgment has them empty and false" $
        decisionPayload (PutBackInLine order 4)
          @?= T.unlines
            [ "lockstep-decision-v1"
            , "subject 00000000-0000-0001-0000-000000000002"
            , "choice put-back"
            , "expected 4"
            , "text \"\""
            , "acknowledged false"
            ]
    , testCase "every request has its own payload, and every field changes it" $ do
        L.length (L.nub (fmap decisionPayload every)) @?= L.length every
        assertBool "the expected value is not in the payload" (decisionPayload (PutBackInLine order 4) /= decisionPayload (PutBackInLine order 5))
        assertBool "the text is not in the payload" (decisionPayload (ItHappened operation 2 "a") /= decisionPayload (ItHappened operation 2 "b"))
        assertBool "the acknowledgment is not in the payload" (decisionPayload (TryAgain operation 2 True) /= decisionPayload (TryAgain operation 2 False))
        assertBool "the subject is not in the payload" (decisionPayload (CancelWork order 4) /= decisionPayload (CancelWork (WorkOrderId (uuidFromWords 9 9)) 4))
    , testCase "subjects, choice names and expected values" $ do
        fmap decisionChoiceName every @?= ["put-back", "cancel", "happened", "did-not-happen", "try-again", "give-up"]
        fmap decisionSubject every
          @?= L.replicate 2 "00000000-0000-0001-0000-000000000002" <> L.replicate 4 "00000000-0000-0003-0000-000000000004"
        fmap decisionExpected every @?= [4, 4, 2, 2, 2, 2]
    , testCase "evidence and reasons are 1 to 500 characters without control characters" $ do
        traverse_ (\r -> checkDecisionText r @?= Right ()) every
        checkDecisionText (ItHappened operation 2 "   ") @?= Left "text-empty"
        checkDecisionText (ItDidNotHappen operation 2 (T.replicate 501 "x")) @?= Left "text-too-long"
        checkDecisionText (GiveUp operation 2 "a\tb" True) @?= Left "text-control"
        checkDecisionText (ItHappened operation 2 (T.replicate 500 "x")) @?= Right ()
    , testCase "every choice has a label and a consequence in plain words" $
        traverse_
          ( \name -> do
              let
                (label, consequence) = choiceWords name
              plain label
              plain consequence
          )
          ["put-back", "cancel", "happened", "did-not-happen", "try-again", "give-up"]
    , testCase "every refusal has plain words; the changed-meanwhile codes share one sentence" $ do
        let
          changed = ["stale-revision", "stale-claim", "not-unknown", "already-settled", "illegal-transition", "already-terminal"]
          others = ["duplication-risk-not-acknowledged", "idempotency-key-expired", "key-conflict", "text-empty", "text-too-long", "text-control"]
        traverse_ (plain . decisionRefusalWords) (changed <> others <> ["something-else"])
        L.length (L.nub (fmap decisionRefusalWords changed)) @?= 1
        assertBool "not the changed-meanwhile sentence" ("changed since the page was shown" `T.isInfixOf` decisionRefusalWords "stale-revision")
        L.length (L.nub (fmap decisionRefusalWords (L.take 1 changed <> others <> ["something-else"]))) @?= 8
    ]
