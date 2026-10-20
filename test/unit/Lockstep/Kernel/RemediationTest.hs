{-# LANGUAGE OverloadedStrings #-}

-- | C-P2.9-R1 §3 unit cases: the key-lifetime guard (M1), the carry decision (§2.1) and the attested display (M4).
module Lockstep.Kernel.RemediationTest
  ( tests
  ) where

import Control.Monad (foldM)
import Data.Text qualified as T
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Kernel.Activation (CarryInput (..), CarryRefusal (..), carryDecision, carryRefusalCode)
import Lockstep.Kernel.Effect
  ( ClassTerms (..)
  , IdempotencyTerms (..)
  , Intent (..)
  , IntentInput (..)
  , IntentRequest (..)
  , LookupTerms (..)
  , Observation (..)
  , OperationId (..)
  , SubjectRef (..)
  , mkEffectKey
  , mkEffectSpec
  , newIntents
  , stepIntent
  )
import Lockstep.Kernel.EffectView (EffectStatus (..), StatusFacts (..), effectStatus, effectStatusReason)
import Lockstep.Kernel.Identity (WorkOrderId (..), uuidFromWords)
import Lockstep.Kernel.KeyLifetime (idempotencyHolds, keyMarginSeconds)
import Lockstep.Kernel.Reconciliation (Resolution (..), resolveIntent)
import Lockstep.Kernel.Transition (Command (..), Principal (..))

tests :: TestTree
tests =
  testGroup
    "Gate B remediation (C-P2.9-R1)"
    [ keyTests
    , carryTests
    , attestedTests
    ]

-- Fixtures -------------------------------------------------------------------

t0 :: UTCTime
t0 =
  UTCTime (fromGregorian 2026 10 19) (secondsToDiffTime 0)

at :: Integer -> UTCTime
at n =
  addUTCTime (fromInteger n) t0

idempotent :: Integer -> ClassTerms
idempotent lifetime =
  TermsIdempotent (IdempotencyTerms lifetime True)

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

claimed, dispatched :: ClassTerms -> Int -> IO Intent
claimed terms budget = pendingOf terms budget >>= \p -> steps p [sup (IntentClaim "w1" t0 (at 60))]
dispatched terms budget = claimed terms budget >>= \c -> steps c [sup (IntentDispatch 1 (at 1))]

observed :: ClassTerms -> Int -> Observation -> IO Intent
observed terms budget o =
  dispatched terms budget >>= \d -> steps d [sup (IntentObserve 1 o)]

resolved :: Intent -> Resolution -> IO Intent
resolved i r =
  either (assertFailure . show) pure (resolveIntent i (Command Human (intentGeneration i, r)))

-- Key lifetime ---------------------------------------------------------------

keyTests :: TestTree
keyTests =
  testGroup
    "key lifetime (M1)"
    [ testCase "the margin is max 30 s (lifetime / 10)" $
        fmap keyMarginSeconds [1, 40, 300, 3600, 86400] @?= [30, 30, 30, 360, 8640]
    , testCase "an idempotent key holds until first dispatch + lifetime - margin, exclusive" $ do
        i <- dispatched (idempotent 3600) 1
        idempotencyHolds (Just t0) (at 3239) i @?= True
        idempotencyHolds (Just t0) (at 3240) i @?= False
        idempotencyHolds (Just t0) (at 9999) i @?= False
    , testCase "without a first dispatch time the guarantee is unverifiable" $ do
        i <- dispatched (idempotent 3600) 1
        idempotencyHolds Nothing t0 i @?= False
    , testCase "a lifetime no longer than the margin never holds" $ do
        i <- dispatched (idempotent 20) 1
        idempotencyHolds (Just t0) t0 i @?= False
    , testCase "other classes are unaffected" $ do
        is <- traverse (uncurry dispatched) [(TermsRepeatable, 1), (TermsQueryable (LookupTerms True True), 1), (TermsUnqueryable, 0)]
        fmap (idempotencyHolds Nothing (at 99999)) is @?= [True, True, True]
    ]

-- Carry ----------------------------------------------------------------------

input :: Integer -> Int -> Maybe Int -> Bool -> CarryInput
input now source target holds =
  CarryInput {carryNow = at now, carrySource = source, carryTarget = target, carryKeyHolds = holds}

-- | A carry by a Human from activation 1 to 2 at 100 s, the key holding.
human :: Intent -> Either CarryRefusal ()
human i =
  carryDecision i (Command Human (input 100 1 (Just 2) True))

carryTests :: TestTree
carryTests =
  testGroup
    "the carry decision (§2.1), in check order"
    [ testCase "an Agent is agent-assertion; a Supervisor or Scheduler is not-authorized" $ do
        p <- pendingOf TermsRepeatable 1
        carryDecision p (Command Agent (input 100 1 (Just 2) True)) @?= Left CarryAgentAssertion
        carryDecision p (Command Supervisor (input 100 1 (Just 2) True)) @?= Left (CarryNotAuthorized Supervisor)
        carryDecision p (Command Scheduler (input 100 1 (Just 2) True)) @?= Left (CarryNotAuthorized Scheduler)
    , testCase "an order that is not active, or the same activation (a duplicate carry)" $ do
        p <- pendingOf TermsRepeatable 1
        carryDecision p (Command Human (input 100 1 Nothing True)) @?= Left CarrySubjectNotActive
        carryDecision p (Command Human (input 100 2 (Just 2) True)) @?= Left CarryNotNeeded
    , testCase "settled, abandoned, unknown, dispatched, an active claim, confirmed applied" $ do
        settled <- observed TermsRepeatable 1 (DestinationApplied "ok") >>= \a -> steps a [sup (IntentSettle 1)]
        abandoned <- pendingOf TermsRepeatable 1 >>= \p -> steps p [Command Human (IntentAbandon "stop")]
        unknown <- observed TermsUnqueryable 0 (NoAnswer "timeout")
        inFlight <- dispatched TermsRepeatable 1
        holding <- claimed TermsRepeatable 1
        applied <- observed TermsRepeatable 1 (DestinationApplied "ok")
        fmap human [settled, abandoned, unknown, inFlight, applied]
          @?= [Left CarryAlreadySettled, Left CarryAlreadySettled, Left CarryOutcomeUnknown, Left CarryInFlight, Left CarryNotCarryable]
        carryDecision holding (Command Human (input 59 1 (Just 2) True)) @?= Left CarryClaimHeld
        carryDecision holding (Command Human (input 60 1 (Just 2) True)) @?= Right ()
    , testCase "not applied: carried with a retry left, refused without one" $ do
        withRetry <- observed TermsRepeatable 1 (DestinationNotApplied "busy")
        noRetry <- observed TermsRepeatable 0 (DestinationNotApplied "busy")
        human withRetry @?= Right ()
        human noRetry @?= Left CarryRetriesExhausted
    , testCase "pending: carried; after a human retry an idempotent intent needs its key to hold" $ do
        fresh <- pendingOf (idempotent 3600) 1
        human fresh @?= Right ()
        retriedB <- observed (idempotent 3600) 1 (NoAnswer "timeout") >>= \u -> resolved u (RetryAcknowledgingDuplication True)
        carryDecision retriedB (Command Human (input 100 1 (Just 2) False)) @?= Left CarryKeyExpired
        carryDecision retriedB (Command Human (input 100 1 (Just 2) True)) @?= Right ()
        retriedD <- observed TermsUnqueryable 0 (NoAnswer "timeout") >>= \u -> resolved u (RetryAcknowledgingDuplication True)
        carryDecision retriedD (Command Human (input 100 1 (Just 2) False)) @?= Right ()
    , testCase "every refusal code" $
        fmap
          carryRefusalCode
          [ CarryAgentAssertion
          , CarryNotAuthorized Supervisor
          , CarrySubjectNotActive
          , CarryNotNeeded
          , CarryAlreadySettled
          , CarryOutcomeUnknown
          , CarryInFlight
          , CarryClaimHeld
          , CarryNotCarryable
          , CarryRetriesExhausted
          , CarryKeyExpired
          ]
          @?= [ "agent-assertion"
              , "not-authorized"
              , "subject-not-active"
              , "carry-not-needed"
              , "already-settled"
              , "outcome-unknown"
              , "dispatched-needs-recovery"
              , "claim-held"
              , "not-carryable"
              , "retries-exhausted"
              , "idempotency-key-expired"
              ]
    ]

-- Attested display -----------------------------------------------------------

facts :: Bool -> Bool -> StatusFacts
facts active attested =
  StatusFacts {factsNow = at 100, factsOrderActive = active, factsHumanAttested = attested}

expect :: StatusFacts -> Intent -> EffectStatus -> T.Text -> IO ()
expect f i status reason = do
  effectStatus f i @?= status
  effectStatusReason f i @?= reason

attestedTests :: TestTree
attestedTests =
  testGroup
    "attested outcomes are ATTESTED (M4)"
    [ testCase "a human 'not applied' with a retry left is ATTESTED, not BLOCKED, even when the order is halted" $ do
        u <- observed TermsRepeatable 1 (NoAnswer "timeout")
        n <- resolved u (AttestNotApplied "nothing there")
        expect (facts False False) n StatusAttested "attested by a human, not observed: human-attested: nothing there; a retry is left"
    , testCase "a human 'not applied' without a retry left is settled and ATTESTED" $ do
        u <- observed TermsUnqueryable 0 (NoAnswer "timeout")
        s <- resolved u (AttestNotApplied "nothing there")
        expect (facts False False) s StatusAttested "attested by a human, not observed: human-attested: nothing there"
    , testCase "a 'human-attested:' outcome is ATTESTED without the record (defence in depth)" $ do
        u <- observed TermsUnqueryable 0 (NoAnswer "timeout")
        a <- resolved u (AttestApplied "seen")
        expect (facts True False) a StatusAttested "attested by a human, not observed: human-attested: seen"
    , testCase "the attestation flag makes a settled not-applied outcome ATTESTED" $ do
        n <- observed TermsRepeatable 1 (DestinationNotApplied "busy") >>= \o -> steps o [sup (IntentSettle 1)]
        expect (facts True True) n StatusAttested "attested by a human, not observed: busy"
    , testCase "a destination's not-applied answer stays NOT_APPLIED" $ do
        n <- observed TermsRepeatable 1 (DestinationNotApplied "busy")
        expect (facts True False) n StatusNotApplied "not applied, a retry is left: busy"
        s <- steps n [sup (IntentSettle 1)]
        expect (facts True False) s StatusNotApplied "not applied: busy"
    ]
