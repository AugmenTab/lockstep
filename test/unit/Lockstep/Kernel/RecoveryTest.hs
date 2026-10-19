{-# LANGUAGE OverloadedStrings #-}

-- | C-P2.6 §7 unit cases: recovery of an interrupted dispatch (X7, §3, §4).
module Lockstep.Kernel.RecoveryTest
  ( tests
  ) where

import Control.Monad (foldM)
import Data.List qualified as L
import Data.Text qualified as T
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Kernel.Effect
  ( ClassTerms (..)
  , EffectRefusal (..)
  , IdempotencyTerms (..)
  , Intent (..)
  , IntentInput (..)
  , IntentRequest (..)
  , IntentState (..)
  , Lease (..)
  , LookupTerms (..)
  , Observation (..)
  , OperationId (..)
  , SubjectRef (..)
  , intentStateName
  , mkEffectKey
  , mkEffectSpec
  , newIntents
  , stepIntent
  )
import Lockstep.Kernel.Identity (WorkOrderId (..), uuidFromWords)
import Lockstep.Kernel.Recovery
  ( Recovery (..)
  , RecoveryInput (..)
  , RecoveryRefusal (..)
  , recoverIntent
  , recoveryIntent
  , recoveryRefusalCode
  , renderRecovery
  )
import Lockstep.Kernel.Transition (Command (..), Principal (..))

tests :: TestTree
tests =
  testGroup
    "Dispatch recovery (C-P2.6)"
    [ fixtureTests
    , checkTests
    , tableTests
    , textTests
    ]

-- Fixtures -------------------------------------------------------------------

t0 :: UTCTime
t0 =
  UTCTime (fromGregorian 2026 10 19) (secondsToDiffTime 0)

-- | @n@ seconds after 't0'.
at :: Integer -> UTCTime
at n =
  addUTCTime (fromInteger n) t0

repeatable, idempotent, queryable, unqueryable :: ClassTerms
repeatable = TermsRepeatable
idempotent = TermsIdempotent (IdempotencyTerms 86400 True)
queryable = TermsQueryable (LookupTerms True True)
unqueryable = TermsUnqueryable

-- | A pending intent of the class, with the budget.
pendingOf :: ClassTerms -> Int -> Either T.Text Intent
pendingOf terms budget = do
  spec <- either (Left . T.pack . show) Right (mkEffectSpec "step" terms budget)
  key <- either (Left . T.pack . show) Right (mkEffectKey "first")
  intents <-
    either
      (Left . T.pack . show)
      Right
      (newIntents sha256Hasher (SubjectWorkOrder (WorkOrderId (uuidFromWords 2 1))) 4 [(OperationId (uuidFromWords 4 1), IntentRequest key spec "p=1")])
  case intents of
    [i] -> Right i
    _ -> Left "expected one intent"

-- | Steps through the real C-P2.5 lifecycle.
steps :: Intent -> [Command IntentInput] -> Either T.Text Intent
steps =
  foldM (\i c -> either (Left . T.pack . show) Right (stepIntent i c))

sup :: IntentInput -> Command IntentInput
sup =
  Command Supervisor

{- | A dispatched intent: claimed at 't0' by @w1@ with the lease ending at 60
s and dispatched; with @twice@, observed not applied, claimed again at 61 s
(lease to 121 s) and dispatched again.
-}
dispatchedOf :: ClassTerms -> Int -> Bool -> Either T.Text Intent
dispatchedOf terms budget twice = do
  p <- pendingOf terms budget
  once <- steps p [sup (IntentClaim "w1" t0 (at 60)), sup (IntentDispatch 1 (at 1))]
  if twice
    then steps once [sup (IntentObserve 1 (DestinationNotApplied "busy")), sup (IntentClaim "w1" (at 61) (at 121)), sup (IntentDispatch 2 (at 62))]
    else Right once

leaseEnd :: Intent -> UTCTime
leaseEnd i =
  case intentState i of
    IntentDispatched l -> leaseUntil l
    IntentClaimed l -> leaseUntil l
    _ -> t0

-- | Every state other than dispatched, through the real lifecycle.
otherStates :: Either T.Text [Intent]
otherStates = do
  p <- pendingOf repeatable 1
  claimed <- steps p [sup (IntentClaim "w1" t0 (at 60))]
  d <- dispatchedOf repeatable 1 False
  applied <- steps d [sup (IntentObserve 1 (DestinationApplied "done"))]
  notApplied <- steps d [sup (IntentObserve 1 (DestinationNotApplied "busy"))]
  unknown <- steps d [sup (IntentObserve 1 (NoAnswer "timeout"))]
  settled <- steps applied [sup (IntentSettle 1)]
  abandoned <- steps p [Command Human (IntentAbandon "operator stop")]
  pure [p, claimed, applied, notApplied, unknown, settled, abandoned]

fixture :: Either T.Text a -> IO a
fixture =
  either (assertFailure . T.unpack) pure

input :: Bool -> Integer -> RecoveryInput
input active now =
  RecoveryInput {recoveryOwner = "w2", recoveryNow = at now, recoveryLeaseUntil = at (now + 60), recoverySubjectActive = active}

-- | Recovers at the lease end, by the Supervisor, for an active order.
recoverAtEnd :: Bool -> Intent -> Either RecoveryRefusal Recovery
recoverAtEnd active i =
  recoverIntent i (Command Supervisor (lastInput active i))

lastInput :: Bool -> Intent -> RecoveryInput
lastInput active i =
  (input active 0) {recoveryNow = leaseEnd i, recoveryLeaseUntil = addUTCTime 60 (leaseEnd i)}

fixtureTests :: TestTree
fixtureTests =
  testGroup
    "fixtures"
    [ testCase "the fixtures build through the real C-P2.5 lifecycle" $ do
        dispatched <- traverse fixture [dispatchedOf c b twice | (c, b, twice) <- [(repeatable, 1, False), (idempotent, 1, True), (queryable, 0, False), (unqueryable, 0, False)]]
        fmap (intentStateName . intentState) dispatched @?= ["dispatched", "dispatched", "dispatched", "dispatched"]
        fmap intentDispatches dispatched @?= [1, 2, 1, 1]
        fmap intentGeneration dispatched @?= [1, 2, 1, 1]
        fmap leaseEnd dispatched @?= [at 60, at 121, at 60, at 60]
        others <- fixture otherStates
        fmap (intentStateName . intentState) others
          @?= ["pending", "claimed", "confirmed-applied", "confirmed-not-applied", "outcome-unknown", "settled", "abandoned"]
    ]

-- Checks ---------------------------------------------------------------------

refusedWith :: RecoveryRefusal -> Either RecoveryRefusal Recovery -> Assertion
refusedWith expected result =
  case result of
    Left r -> r @?= expected
    Right other -> assertFailure ("expected " <> show expected <> ", got " <> show other)

checkTests :: TestTree
checkTests =
  testGroup
    "checks, in order"
    [ testCase "an Agent is agent-assertion, before anything else" $ do
        others <- fixture otherStates
        d <- fixture (dispatchedOf repeatable 1 False)
        traverse_ (\i -> refusedWith RecoveryAgentAssertion (recoverIntent i (Command Agent (lastInput True i)))) (d : others)
    , testCase "settled and abandoned intents are already-settled, whoever asks" $ do
        others <- fixture otherStates
        let
          terminal = L.drop 5 others
        fmap (intentStateName . intentState) terminal @?= ["settled", "abandoned"]
        traverse_ (\i -> refusedWith RecoveryAlreadySettled (recoverIntent i (Command Human (lastInput True i)))) terminal
        traverse_ (refusedWith RecoveryAlreadySettled . recoverAtEnd True) terminal
    , testCase "only the Supervisor recovers" $ do
        d <- fixture (dispatchedOf repeatable 1 False)
        refusedWith (RecoveryNotAuthorized Human) (recoverIntent d (Command Human (lastInput True d)))
        refusedWith (RecoveryNotAuthorized Scheduler) (recoverIntent d (Command Scheduler (lastInput True d)))
    , testCase "an intent that is not dispatched has nothing to recover" $ do
        others <- fixture otherStates
        traverse_
          (\i -> refusedWith (NothingToRecover (intentStateName (intentState i))) (recoverAtEnd True i))
          (L.take 5 others)
    , testCase "the lease end gates recovery: one second before is lease-active, equal recovers" $ do
        d <- fixture (dispatchedOf repeatable 1 False)
        refusedWith RecoveryLeaseActive (recoverIntent d (Command Supervisor (input True 59)))
        case recoverIntent d (Command Supervisor (input True 60)) of
          Right (RecoverRedispatch _) -> pure ()
          other -> assertFailure ("expected a redispatch: " <> show other)
    , testCase "the order's activity is checked after the lease" $ do
        d <- fixture (dispatchedOf repeatable 1 False)
        refusedWith RecoveryLeaseActive (recoverIntent d (Command Supervisor (input False 59)))
    ]

-- Table ----------------------------------------------------------------------

unknownWith :: T.Text -> Intent -> Either RecoveryRefusal Recovery -> Assertion
unknownWith reason before result =
  result @?= Right (RecoverUnknown before {intentState = IntentUnknown reason})

redispatched :: Intent -> Either RecoveryRefusal Recovery -> Assertion
redispatched before result = do
  let
    next = intentGeneration before + 1
    end = addUTCTime 60 (leaseEnd before)
  result @?= Right (RecoverRedispatch before {intentState = IntentClaimed (Lease "w2" next end), intentGeneration = next})
  case result of
    Right r -> do
      let
        i = recoveryIntent r
      intentOperation i @?= intentOperation before
      intentKey i @?= intentKey before
      intentSpec i @?= intentSpec before
      intentParameters i @?= intentParameters before
      intentParametersDigest i @?= intentParametersDigest before
      intentDispatches i @?= intentDispatches before
    Left _ -> pure ()

tableTests :: TestTree
tableTests =
  testGroup
    "the recovery table (§3)"
    [ testCase "an order that is not active: unknown, for every class" $ do
        ds <- traverse fixture [dispatchedOf c b False | (c, b) <- [(repeatable, 1), (idempotent, 1), (queryable, 1), (unqueryable, 0)]]
        traverse_ (\d -> unknownWith "dispatch-interrupted: subject not active" d (recoverAtEnd False d)) ds
    , testCase "repeatable and idempotent with a retry left: redispatch under generation + 1" $ do
        ds <- traverse fixture [dispatchedOf c 1 False | c <- [repeatable, idempotent]]
        traverse_ (\d -> redispatched d (recoverAtEnd True d)) ds
    , testCase "repeatable and idempotent without a retry left: unknown" $ do
        ds <- traverse fixture [dispatchedOf c b twice | c <- [repeatable, idempotent], (b, twice) <- [(0, False), (1, True)]]
        fmap intentDispatches ds @?= [1, 2, 1, 2]
        traverse_ (\d -> unknownWith "dispatch-interrupted: no retry left" d (recoverAtEnd True d)) ds
    , testCase "queryable: unknown until a lookup exists (C-P2.7), whatever the budget" $ do
        ds <- traverse fixture [dispatchedOf queryable b twice | (b, twice) <- [(0, False), (1, False), (1, True)]]
        traverse_ (\d -> unknownWith "dispatch-interrupted: lookup not available" d (recoverAtEnd True d)) ds
    , testCase "unqueryable: unknown, never redispatched" $ do
        d <- fixture (dispatchedOf unqueryable 0 False)
        unknownWith "dispatch-interrupted: unqueryable effect" d (recoverAtEnd True d)
    , testCase "after a redispatch the new generation may dispatch and the old one is stale" $ do
        d <- fixture (dispatchedOf repeatable 1 False)
        r <- either (assertFailure . show) pure (recoverAtEnd True d)
        let
          i = recoveryIntent r
        case stepIntent i (sup (IntentDispatch 2 (at 61))) of
          Right next -> do
            intentStateName (intentState next) @?= "dispatched"
            intentDispatches next @?= 2
          Left e -> assertFailure ("dispatch refused: " <> show e)
        stepIntent i (sup (IntentDispatch 1 (at 61))) @?= Left StaleClaim
    ]

-- Texts ----------------------------------------------------------------------

textTests :: TestTree
textTests =
  testGroup
    "canonical texts (§4)"
    [ testCase "a redispatch names the new generation and the owner, escaped" $ do
        d <- fixture (dispatchedOf repeatable 1 False)
        r <- either (assertFailure . show) pure (recoverIntent d (Command Supervisor (lastInput True d) {recoveryOwner = "w\"2\\"}))
        renderRecovery r @?= "redispatch generation=2 owner=\"w\\\"2\\\\\""
    , testCase "an unknown result names its reason" $ do
        d <- fixture (dispatchedOf unqueryable 0 False)
        r <- either (assertFailure . show) pure (recoverAtEnd True d)
        renderRecovery r @?= "unknown reason=\"dispatch-interrupted: unqueryable effect\""
        q <- fixture (dispatchedOf queryable 1 False)
        rq <- either (assertFailure . show) pure (recoverAtEnd False q)
        renderRecovery rq @?= "unknown reason=\"dispatch-interrupted: subject not active\""
    , testCase "every refusal code" $
        fmap
          recoveryRefusalCode
          [RecoveryAgentAssertion, RecoveryAlreadySettled, RecoveryNotAuthorized Human, NothingToRecover "pending", RecoveryLeaseActive]
          @?= ["agent-assertion", "already-settled", "not-authorized", "nothing-to-recover", "lease-active"]
    ]
