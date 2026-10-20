{-# LANGUAGE OverloadedStrings #-}

{- | C-P2.9-R1 §4.2 unit cases, after the second review: the key check for
every carryable state (N1), the checked carry (N2-N4) and the carry command
line (N3).
-}
module Lockstep.Kernel.RemediationReviewTest
  ( tests
  ) where

import Control.Monad (foldM)
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Foundation.Cli qualified as Cli
import Lockstep.Kernel.Activation (CarryInput (..), CarryRefusal (..), CarryRequest (..), carryChecked, carryDecision, carryRefusalCode)
import Lockstep.Kernel.Effect
  ( ClassTerms (..)
  , IdempotencyTerms (..)
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
    "Gate B remediation, second review (C-P2.9-R1 §4.2)"
    [ keyTests
    , checkedTests
    , cliTests
    ]

-- Fixtures -------------------------------------------------------------------

t0 :: UTCTime
t0 =
  UTCTime (fromGregorian 2026 10 20) (secondsToDiffTime 0)

at :: Integer -> UTCTime
at n =
  addUTCTime (fromInteger n) t0

idempotent :: ClassTerms
idempotent =
  TermsIdempotent (IdempotencyTerms 3600 True)

pendingOf :: ClassTerms -> Int -> IO Intent
pendingOf terms budget = do
  spec <- either (assertFailure . show) pure (mkEffectSpec "step" terms budget)
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

sup :: IntentInput -> Command IntentInput
sup =
  Command Supervisor

observed :: ClassTerms -> Int -> Observation -> IO Intent
observed terms budget o =
  pendingOf terms budget >>= \p -> steps p [sup (IntentClaim "w1" t0 (at 60)), sup (IntentDispatch 1 (at 1)), sup (IntentObserve 1 o)]

-- | Not applied, then claimed again by a worker whose lease ended at 90 s.
lapsedRetry :: ClassTerms -> IO Intent
lapsedRetry terms =
  observed terms 1 (DestinationNotApplied "busy") >>= \n -> steps n [sup (IntentClaim "w2" (at 61) (at 90))]

resolved :: Intent -> Resolution -> IO Intent
resolved i r =
  either (assertFailure . show) pure (resolveIntent i (Command Human (intentGeneration i, r)))

input :: Int -> Maybe Int -> Bool -> CarryInput
input source target holds =
  CarryInput {carryNow = at 100, carrySource = source, carryTarget = target, carryKeyHolds = holds}

request :: CarryRequest
request =
  CarryRequest
    { requestInput = input 1 (Just 2) True
    , requestExpected = Nothing
    , requestAcknowledged = False
    , requestAttested = False
    , requestConflict = False
    }

checked :: Intent -> CarryRequest -> Either CarryRefusal ()
checked i r =
  carryChecked i (Command Human r)

-- N1 -------------------------------------------------------------------------

keyTests :: TestTree
keyTests =
  testGroup
    "the key check applies to every carryable state (N1)"
    [ testCase "a lapsed claim of an idempotent intent dispatched before needs its key to hold" $ do
        i <- lapsedRetry idempotent
        carryDecision i (Command Human (input 1 (Just 2) False)) @?= Left CarryKeyExpired
        carryDecision i (Command Human (input 1 (Just 2) True)) @?= Right ()
    , testCase "a not-applied idempotent intent with a retry left needs its key to hold" $ do
        i <- observed idempotent 1 (DestinationNotApplied "busy")
        carryDecision i (Command Human (input 1 (Just 2) False)) @?= Left CarryKeyExpired
        carryDecision i (Command Human (input 1 (Just 2) True)) @?= Right ()
    , testCase "other classes, and an idempotent intent never dispatched, need no key" $ do
        repeatable <- lapsedRetry TermsRepeatable
        fresh <- pendingOf idempotent 1
        fmap (\i -> carryDecision i (Command Human (input 1 (Just 2) False))) [repeatable, fresh] @?= [Right (), Right ()]
    , testCase "an exhausted budget is still retries-exhausted, not a key refusal" $ do
        i <- observed idempotent 0 (DestinationNotApplied "busy")
        carryDecision i (Command Human (input 1 (Just 2) False)) @?= Left CarryRetriesExhausted
    ]

-- N2-N4 ----------------------------------------------------------------------

checkedTests :: TestTree
checkedTests =
  testGroup
    "the checked carry (N2-N4), in check order"
    [ testCase "it applies every check of the plain carry" $ do
        p <- pendingOf TermsRepeatable 1
        carryChecked p (Command Agent request) @?= Left CarryAgentAssertion
        carryChecked p (Command Supervisor request) @?= Left (CarryNotAuthorized Supervisor)
        checked p request {requestInput = input 1 Nothing True} @?= Left CarrySubjectNotActive
        i <- lapsedRetry idempotent
        checked i request {requestInput = input 1 (Just 2) False} @?= Left CarryKeyExpired
        checked p request @?= Right ()
    , testCase "the expected activations must be the current ones (stale-carry)" $ do
        p <- pendingOf TermsRepeatable 1
        checked p request {requestExpected = Just (1, 2)} @?= Right ()
        checked p request {requestExpected = Just (1, 3)} @?= Left CarryStale
        checked p request {requestExpected = Just (0, 2)} @?= Left CarryStale
    , testCase "a duplicate carry is carry-not-needed before it is stale" $ do
        p <- pendingOf TermsRepeatable 1
        checked p request {requestInput = input 2 (Just 2) True, requestExpected = Just (1, 2)} @?= Left CarryNotNeeded
    , testCase "stale-carry comes before a state refusal" $ do
        u <- observed TermsUnqueryable 0 (NoAnswer "timeout")
        checked u request {requestExpected = Just (1, 3)} @?= Left CarryStale
        checked u request {requestExpected = Just (1, 2)} @?= Left CarryOutcomeUnknown
    , testCase "a human-attested 'not applied' needs the duplication-risk acknowledgment" $ do
        u <- observed TermsRepeatable 1 (NoAnswer "timeout")
        n <- resolved u (AttestNotApplied "nothing there")
        checked n request @?= Left CarryNotAcknowledged
        checked n request {requestAcknowledged = True} @?= Right ()
    , testCase "the attestation record alone also needs it; a destination's own answer does not" $ do
        n <- observed TermsRepeatable 1 (DestinationNotApplied "busy")
        checked n request {requestAttested = True} @?= Left CarryNotAcknowledged
        checked n request @?= Right ()
    , testCase "the plain carry is the checked one without expectation or acknowledgment" $ do
        u <- observed TermsRepeatable 1 (NoAnswer "timeout")
        n <- resolved u (AttestNotApplied "nothing there")
        carryDecision n (Command Human (input 1 (Just 2) True)) @?= Left CarryNotAcknowledged
    , testCase "a live intent with the same effect key in the target activation is carry-conflict" $ do
        p <- pendingOf TermsRepeatable 1
        checked p request {requestConflict = True} @?= Left CarryConflict
        carryChecked p (Command Supervisor request {requestConflict = True}) @?= Left (CarryNotAuthorized Supervisor)
        u <- observed TermsRepeatable 1 (NoAnswer "timeout")
        n <- resolved u (AttestNotApplied "nothing there")
        checked n request {requestConflict = True} @?= Left CarryNotAcknowledged
        checked n request {requestConflict = True, requestAcknowledged = True} @?= Left CarryConflict
    , testCase "the new refusal codes" $
        fmap carryRefusalCode [CarryStale, CarryNotAcknowledged, CarryConflict]
          @?= ["stale-carry", "duplication-risk-not-acknowledged", "carry-conflict"]
    ]

-- The command line (N3, N4) ----------------------------------------------------

cliTests :: TestTree
cliTests =
  testGroup
    "effects carry states the activations (N3, N4)"
    [ testCase "both activations are required" $ do
        Cli.parseArgs ["effects", "carry", "op"] @?= Left (Cli.MissingOption "--from-activation")
        Cli.parseArgs ["effects", "carry", "op", "--from-activation", "1"] @?= Left (Cli.MissingOption "--to-activation")
    , testCase "the activations and the acknowledgment are parsed" $ do
        Cli.parseArgs ["effects", "carry", "op", "--from-activation", "1", "--to-activation", "2"] @?= Right (Cli.EffectsCarry "op" 1 2 False)
        Cli.parseArgs ["effects", "carry", "--from-activation", "3", "--to-activation", "4", "--acknowledge-duplication-risk", "op"] @?= Right (Cli.EffectsCarry "op" 3 4 True)
    , testCase "an activation is a number" $
        Cli.parseArgs ["effects", "carry", "op", "--from-activation", "one", "--to-activation", "2"] @?= Left (Cli.InvalidNumber "--from-activation" "one")
    ]
