{-# LANGUAGE OverloadedStrings #-}

-- | C-P2.7 §7 unit cases: reconciliation (R3), human resolution (R5), late observations (R7).
module Lockstep.Kernel.ReconciliationTest
  ( tests
  ) where

import Control.Monad (foldM)
import Data.List qualified as L
import Data.Text qualified as T
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Kernel.Effect
  ( ClassTerms (..)
  , EffectRefusal (..)
  , IdempotencyTerms (..)
  , Intent (..)
  , IntentInput (..)
  , IntentRequest (..)
  , IntentState (..)
  , LookupTerms (..)
  , Observation (..)
  , OperationId (..)
  , Settlement (..)
  , SubjectRef (..)
  , intentStateName
  , mkEffectKey
  , mkEffectSpec
  , newIntents
  , stepIntent
  )
import Lockstep.Kernel.Identity (WorkOrderId (..), uuidFromWords)
import Lockstep.Kernel.Reconciliation
  ( LateVerdict (..)
  , LookupResult (..)
  , ReconcileInput (..)
  , ReconcileRefusal (..)
  , Resolution (..)
  , judgeLateObservation
  , reconcileIntent
  , reconcileRefusalCode
  , renderLookup
  , renderResolution
  , resolveIntent
  )
import Lockstep.Kernel.Transition (Command (..), Principal (..))

tests :: TestTree
tests =
  testGroup
    "Reconciliation and resolution (C-P2.7)"
    [ fixtureTests
    , reconcileCheckTests
    , reconcileTableTests
    , resolveTests
    , lateTests
    , textTests
    ]

-- Fixtures -------------------------------------------------------------------

t0 :: UTCTime
t0 =
  UTCTime (fromGregorian 2026 10 19) (secondsToDiffTime 0)

at :: Integer -> UTCTime
at n =
  addUTCTime (fromInteger n) t0

repeatable, idempotent, unqueryable :: ClassTerms
repeatable = TermsRepeatable
idempotent = TermsIdempotent (IdempotencyTerms 86400 True)
unqueryable = TermsUnqueryable

queryable :: Bool -> Bool -> ClassTerms
queryable authoritative excludesLate =
  TermsQueryable (LookupTerms authoritative excludesLate)

-- | The queryable terms of the reconciliation table, in §3 order.
queryTerms :: [ClassTerms]
queryTerms =
  [queryable True True, queryable True False, queryable False True, queryable False False]

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

steps :: Intent -> [Command IntentInput] -> Either T.Text Intent
steps =
  foldM (\i c -> either (Left . T.pack . show) Right (stepIntent i c))

sup :: IntentInput -> Command IntentInput
sup =
  Command Supervisor

-- | Every state of the late table, in its row order, through the real C-P2.5 lifecycle.
statesOf :: ClassTerms -> Int -> Either T.Text [Intent]
statesOf terms budget = do
  p <- pendingOf terms budget
  claimed <- steps p [sup (IntentClaim "w1" t0 (at 60))]
  dispatched <- steps claimed [sup (IntentDispatch 1 (at 1))]
  notApplied <- steps dispatched [sup (IntentObserve 1 (DestinationNotApplied "busy"))]
  unknown <- steps dispatched [sup (IntentObserve 1 (NoAnswer "timeout"))]
  applied <- steps dispatched [sup (IntentObserve 1 (DestinationApplied "done"))]
  settledApplied <- steps applied [sup (IntentSettle 1)]
  settledNotApplied <- steps notApplied [sup (IntentSettle 1)]
  abandoned <- steps p [Command Human (IntentAbandon "operator stop")]
  pure [p, claimed, dispatched, notApplied, unknown, applied, settledApplied, settledNotApplied, abandoned]

unknownOf :: ClassTerms -> Int -> Either T.Text Intent
unknownOf terms budget = do
  states <- statesOf terms budget
  case L.drop 4 states of
    u : _ -> Right u
    [] -> Left "no unknown state"

dispatchedOf :: ClassTerms -> Int -> Either T.Text Intent
dispatchedOf terms budget = do
  states <- statesOf terms budget
  case L.drop 2 states of
    d : _ -> Right d
    [] -> Left "no dispatched state"

fixture :: Either T.Text a -> IO a
fixture =
  either (assertFailure . T.unpack) pure

reconcileAt :: Integer -> LookupResult -> Command ReconcileInput
reconcileAt now lookup' =
  Command Supervisor (ReconcileInput (at now) lookup')

fixtureTests :: TestTree
fixtureTests =
  testGroup
    "fixtures"
    [ testCase "every state of every class builds through the real C-P2.5 lifecycle" $ do
        all' <- traverse fixture [statesOf c b | (c, b) <- [(repeatable, 1), (idempotent, 1), (queryable True True, 1), (unqueryable, 0)]]
        traverse_
          ( \states ->
              fmap (intentStateName . intentState) states
                @?= ["pending", "claimed", "dispatched", "confirmed-not-applied", "outcome-unknown", "confirmed-applied", "settled", "settled", "abandoned"]
          )
          all'
        u <- fixture (unknownOf (queryable True True) 1)
        intentGeneration u @?= 1
        intentDispatches u @?= 1
        d <- fixture (dispatchedOf (queryable True True) 1)
        intentStateName (intentState d) @?= "dispatched"
    ]

-- Reconcile ------------------------------------------------------------------

refusedWith :: Show a => ReconcileRefusal -> Either ReconcileRefusal a -> Assertion
refusedWith expected result =
  case result of
    Left r -> r @?= expected
    Right other -> assertFailure ("expected " <> show expected <> ", got " <> show other)

reconcileCheckTests :: TestTree
reconcileCheckTests =
  testGroup
    "reconcile checks, in order"
    [ testCase "an Agent is agent-assertion" $ do
        u <- fixture (unknownOf (queryable True True) 1)
        refusedWith ReconcileAgentAssertion (reconcileIntent u (Command Agent (ReconcileInput (at 100) LookupNotFound)))
    , testCase "settled and abandoned intents are already-settled" $ do
        states <- fixture (statesOf (queryable True True) 1)
        traverse_ (\i -> refusedWith ReconcileAlreadySettled (reconcileIntent i (reconcileAt 100 LookupNotFound))) (L.drop 6 states)
    , testCase "only the Supervisor reconciles" $ do
        u <- fixture (unknownOf (queryable True True) 1)
        refusedWith (ReconcileNotAuthorized Human) (reconcileIntent u (Command Human (ReconcileInput (at 100) LookupNotFound)))
        refusedWith (ReconcileNotAuthorized Scheduler) (reconcileIntent u (Command Scheduler (ReconcileInput (at 100) LookupNotFound)))
    , testCase "only a queryable effect is reconciled" $ do
        others <- traverse fixture [unknownOf c b | (c, b) <- [(repeatable, 1), (idempotent, 1), (unqueryable, 0)]]
        traverse_ (\i -> refusedWith NotQueryable (reconcileIntent i (reconcileAt 100 LookupNotFound))) others
    , testCase "pending, claimed, confirmed-applied and confirmed-not-applied have nothing to reconcile" $ do
        states <- fixture (statesOf (queryable True True) 1)
        let
          picked = [s | (n, s) <- L.zip [0 :: Int ..] states, n `L.elem` [0, 1, 3, 5]]
        traverse_
          (\i -> refusedWith (NothingToReconcile (intentStateName (intentState i))) (reconcileIntent i (reconcileAt 100 LookupNotFound)))
          picked
    , testCase "a dispatched intent: one second before its lease end is lease-active, equal reconciles" $ do
        d <- fixture (dispatchedOf (queryable True True) 1)
        refusedWith ReconcileLeaseActive (reconcileIntent d (reconcileAt 59 LookupNotFound))
        case reconcileIntent d (reconcileAt 60 LookupNotFound) of
          Right _ -> pure ()
          Left r -> assertFailure ("refused at the lease end: " <> show r)
    ]

reconciled :: Intent -> IntentState -> Intent
reconciled before state =
  before {intentState = state, intentGeneration = intentGeneration before + 1}

reconcileTableTests :: TestTree
reconcileTableTests =
  testGroup
    "the reconciliation table (§3)"
    [ testCase "found: confirmed-applied with the destination's result, generation + 1" $ do
        bases <- traverse fixture ([unknownOf c 1 | c <- queryTerms] <> [dispatchedOf c 1 | c <- queryTerms])
        traverse_ (\b -> reconcileIntent b (reconcileAt 100 (LookupFound "r")) @?= Right (reconciled b (IntentApplied "r"))) bases
    , testCase "not found: confirmed-not-applied only when authoritative and excluding a late application" $ do
        let
          expected =
            [ IntentNotApplied "lookup: not found"
            , IntentUnknown "lookup: not found, late application not excluded"
            , IntentUnknown "lookup: not found, not authoritative"
            , IntentUnknown "lookup: not found, not authoritative"
            ]
        unknowns <- traverse (\c -> fixture (unknownOf c 1)) queryTerms
        dispatched <- traverse (\c -> fixture (dispatchedOf c 1)) queryTerms
        traverse_
          (\(b, e) -> reconcileIntent b (reconcileAt 100 LookupNotFound) @?= Right (reconciled b e))
          (L.zip unknowns expected <> L.zip dispatched expected)
    , testCase "failed: unknown with the failure, whatever the terms" $ do
        bases <- traverse fixture [unknownOf c 1 | c <- queryTerms]
        traverse_ (\b -> reconcileIntent b (reconcileAt 100 (LookupFailed "timeout")) @?= Right (reconciled b (IntentUnknown "lookup failed: timeout"))) bases
    , testCase "the identity and dispatch count are kept, and the old generation is fenced out" $ do
        u <- fixture (unknownOf (queryable True True) 1)
        r <- either (assertFailure . show) pure (reconcileIntent u (reconcileAt 100 LookupNotFound))
        intentOperation r @?= intentOperation u
        intentParameters r @?= intentParameters u
        intentParametersDigest r @?= intentParametersDigest u
        intentDispatches r @?= intentDispatches u
        stepIntent r (sup (IntentObserve 1 (DestinationApplied "late"))) @?= Left StaleClaim
    ]

-- Resolve --------------------------------------------------------------------

resolveTests :: TestTree
resolveTests =
  testGroup
    "human resolution (R5)"
    [ testCase "checks, in order: Agent, terminal, principal, generation, state" $ do
        u <- fixture (unknownOf unqueryable 0)
        states <- fixture (statesOf unqueryable 0)
        refusedWith ReconcileAgentAssertion (resolveIntent u (Command Agent (1, AttestApplied "seen")))
        traverse_ (\i -> refusedWith ReconcileAlreadySettled (resolveIntent i (Command Human (1, AttestApplied "seen")))) (L.drop 6 states)
        refusedWith (ReconcileNotAuthorized Supervisor) (resolveIntent u (Command Supervisor (1, AttestApplied "seen")))
        refusedWith ReconcileStaleClaim (resolveIntent u (Command Human (0, AttestApplied "seen")))
        refusedWith ReconcileStaleClaim (resolveIntent u (Command Human (2, AttestApplied "seen")))
        case states of
          p : claimed : _ -> do
            refusedWith (NotUnknown "pending") (resolveIntent p (Command Human (0, AttestApplied "seen")))
            refusedWith (NotUnknown "claimed") (resolveIntent claimed (Command Human (1, AttestApplied "seen")))
          _ -> assertFailure "states"
    , testCase "attest applied: settled with a human-attested result" $ do
        u <- fixture (unknownOf unqueryable 0)
        resolveIntent u (Command Human (1, AttestApplied "operator saw the receipt"))
          @?= Right u {intentState = IntentSettled (SettledApplied "human-attested: operator saw the receipt")}
    , testCase "attest not applied: claimable with a retry left, settled without one" $ do
        b <- fixture (unknownOf idempotent 1)
        resolveIntent b (Command Human (1, AttestNotApplied "nothing there"))
          @?= Right b {intentState = IntentNotApplied "human-attested: nothing there"}
        d <- fixture (unknownOf unqueryable 0)
        resolveIntent d (Command Human (1, AttestNotApplied "nothing there"))
          @?= Right d {intentState = IntentSettled (SettledNotApplied "human-attested: nothing there")}
    , testCase "retry: refused unless the duplication risk is acknowledged; then pending and claimable past the budget" $ do
        d <- fixture (unknownOf unqueryable 0)
        refusedWith DuplicationNotAcknowledged (resolveIntent d (Command Human (1, RetryAcknowledgingDuplication False)))
        retried <- either (assertFailure . show) pure (resolveIntent d (Command Human (1, RetryAcknowledgingDuplication True)))
        retried @?= d {intentState = IntentPending}
        intentGeneration retried @?= 1
        intentDispatches retried @?= 1
        case stepIntent retried (sup (IntentClaim "w2" (at 100) (at 160))) of
          Right claimed -> intentGeneration claimed @?= 2
          Left e -> assertFailure ("claim refused: " <> show e)
        refusedWith (NotUnknown "pending") (resolveIntent retried (Command Human (1, RetryAcknowledgingDuplication True)))
    , testCase "evidence must be 1-4096 characters without control characters" $ do
        u <- fixture (unknownOf unqueryable 0)
        traverse_
          (\e -> refusedWith InvalidEvidence (resolveIntent u (Command Human (1, AttestApplied e))))
          ["", "a\nb", T.replicate 4097 "x"]
        refusedWith InvalidEvidence (resolveIntent u (Command Human (1, AttestNotApplied "")))
    ]

-- Late observations ----------------------------------------------------------

lateTests :: TestTree
lateTests =
  testGroup
    "late applied observations (R7, §3)"
    [ testCase "repeatable and idempotent: conflict only where the state says not applied" $ do
        traverse_
          ( \(c, b) -> do
              states <- fixture (statesOf c b)
              fmap (\s -> judgeLateObservation s (DestinationApplied "late")) states @?= expectedAB states
          )
          [(repeatable, 1), (idempotent, 1)]
    , testCase "queryable and unqueryable: conflict unless an application is already recorded" $ do
        traverse_
          ( \(c, b) -> do
              states <- fixture (statesOf c b)
              fmap (\s -> judgeLateObservation s (DestinationApplied "late")) states @?= expectedCD states
          )
          [(queryable True True, 1), (queryable False False, 1), (unqueryable, 0)]
    , testCase "a late not-applied or no-answer observation never conflicts" $ do
        all' <- traverse fixture [statesOf c b | (c, b) <- [(repeatable, 1), (idempotent, 1), (queryable True True, 1), (unqueryable, 0)]]
        traverse_
          ( \s -> do
              judgeLateObservation s (DestinationNotApplied "no") @?= LateConsistent
              judgeLateObservation s (NoAnswer "timeout") @?= LateConsistent
          )
          (L.concat all')
    ]

blocked :: Intent -> LateVerdict
blocked s =
  LateConflict s {intentState = IntentUnknown "late-application"}

-- | Rows: pending, claimed, dispatched, not applied, unknown, applied, settled applied, settled not applied, abandoned.
expectedAB :: [Intent] -> [LateVerdict]
expectedAB =
  L.zipWith
    (\n s -> if n == (3 :: Int) then blocked s else if n `L.elem` [7, 8] then LateConflict s else LateConsistent)
    [0 ..]

expectedCD :: [Intent] -> [LateVerdict]
expectedCD =
  L.zipWith
    ( \n s ->
        if n `L.elem` [0, 1, 2, 3 :: Int]
          then blocked s
          else if n `L.elem` [5, 6] then LateConsistent else LateConflict s
    )
    [0 ..]

-- Texts ----------------------------------------------------------------------

textTests :: TestTree
textTests =
  testGroup
    "canonical texts (§4) and codes"
    [ testCase "lookup records" $
        fmap renderLookup [LookupFound "a\"b\\", LookupNotFound, LookupFailed "timeout"]
          @?= ["found result=\"a\\\"b\\\\\"", "not-found", "failed reason=\"timeout\""]
    , testCase "human records" $
        fmap renderResolution [AttestApplied "seen \"it\"", AttestNotApplied "none", RetryAcknowledgingDuplication True]
          @?= ["attested-applied evidence=\"seen \\\"it\\\"\"", "attested-not-applied evidence=\"none\"", "retry duplication-acknowledged"]
    , testCase "every refusal code" $
        fmap
          reconcileRefusalCode
          [ ReconcileAgentAssertion
          , ReconcileAlreadySettled
          , ReconcileNotAuthorized Human
          , NotQueryable
          , NothingToReconcile "pending"
          , ReconcileLeaseActive
          , ReconcileStaleClaim
          , NotUnknown "pending"
          , InvalidEvidence
          , DuplicationNotAcknowledged
          ]
          @?= [ "agent-assertion"
              , "already-settled"
              , "not-authorized"
              , "not-queryable"
              , "nothing-to-reconcile"
              , "lease-active"
              , "stale-claim"
              , "not-unknown"
              , "invalid-evidence"
              , "duplication-risk-not-acknowledged"
              ]
    ]
