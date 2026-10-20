{-# LANGUAGE OverloadedStrings #-}

-- | C-P2.9-R1 §4.5 unit cases, after the third review: an attestation needs the acknowledgment in every carryable state (P2).
module Lockstep.Kernel.RemediationThirdReviewTest
  ( tests
  ) where

import Control.Monad (foldM)
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Kernel.Activation (CarryInput (..), CarryRefusal (..), CarryRequest (..), carryChecked)
import Lockstep.Kernel.Effect
  ( ClassTerms (..)
  , Intent (..)
  , IntentInput (..)
  , IntentRequest (..)
  , Observation (..)
  , OperationId (..)
  , SubjectRef (..)
  , mkEffectKey
  , mkEffectSpec
  , newIntents
  , stepIntent
  )
import Lockstep.Kernel.Identity (WorkOrderId (..), uuidFromWords)
import Lockstep.Kernel.Reconciliation (Resolution (..), resolveIntent)
import Lockstep.Kernel.Transition (Command (..), Principal (..))

tests :: TestTree
tests =
  testGroup
    "Gate B remediation, third review (C-P2.9-R1 §4.5)"
    [ testCase "a lapsed claim after a human 'not applied' needs the acknowledgment" $ do
        c <- attestedThenClaimed
        checked c request @?= Left CarryNotAcknowledged
        checked c request {requestAcknowledged = True} @?= Right ()
    , testCase "a pending intent with an attestation record needs it too" $ do
        p <- pendingOf
        checked p request {requestAttested = True} @?= Left CarryNotAcknowledged
        checked p request {requestAttested = True, requestAcknowledged = True} @?= Right ()
        checked p request @?= Right ()
    , testCase "an attested claim still held is claim-held first" $ do
        c <- attestedThenClaimed
        checked c request {requestInput = (requestInput request) {carryNow = at 80}} @?= Left CarryClaimHeld
    ]

t0 :: UTCTime
t0 =
  UTCTime (fromGregorian 2026 10 20) (secondsToDiffTime 0)

at :: Integer -> UTCTime
at n =
  addUTCTime (fromInteger n) t0

pendingOf :: IO Intent
pendingOf = do
  spec <- either (assertFailure . show) pure (mkEffectSpec "step" TermsRepeatable 1)
  key <- either (assertFailure . show) pure (mkEffectKey "first")
  intents <-
    either
      (assertFailure . show)
      pure
      (newIntents sha256Hasher (SubjectWorkOrder (WorkOrderId (uuidFromWords 2 1))) 4 [(OperationId (uuidFromWords 4 1), IntentRequest key spec "p=1")])
  case intents of
    [i] -> pure i
    _ -> assertFailure "one intent"

steps :: Intent -> [Command IntentInput] -> IO Intent
steps i =
  either (assertFailure . show) pure . foldM stepIntent i

-- | Unknown, attested not applied by a Human, then claimed again until 90 s.
attestedThenClaimed :: IO Intent
attestedThenClaimed = do
  p <- pendingOf
  u <- steps p [Command Supervisor (IntentClaim "w1" t0 (at 60)), Command Supervisor (IntentDispatch 1 (at 1)), Command Supervisor (IntentObserve 1 (NoAnswer "timeout"))]
  n <- either (assertFailure . show) pure (resolveIntent u (Command Human (intentGeneration u, AttestNotApplied "nothing there")))
  steps n [Command Supervisor (IntentClaim "w2" (at 61) (at 90))]

request :: CarryRequest
request =
  CarryRequest
    { requestInput = CarryInput {carryNow = at 100, carrySource = 1, carryTarget = Just 2, carryKeyHolds = True}
    , requestExpected = Just (1, 2)
    , requestAcknowledged = False
    , requestAttested = True
    , requestConflict = False
    }

checked :: Intent -> CarryRequest -> Either CarryRefusal ()
checked i r =
  carryChecked i (Command Human r)
