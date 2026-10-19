{-# LANGUAGE OverloadedStrings #-}

-- | C-P2.5 §7 unit cases: effect specs, intent identity and the intent lifecycle (§3).
module Lockstep.Kernel.EffectTest
  ( tests
  ) where

import Control.Monad (foldM)
import Data.List qualified as L
import Data.Text qualified as T
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertEqual, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Kernel.Effect
  ( ClassTerms (..)
  , EffectClass (..)
  , EffectKey
  , EffectRefusal (..)
  , EffectSpec
  , IdempotencyTerms (..)
  , Intent (..)
  , IntentInput (..)
  , IntentRequest (..)
  , IntentState (..)
  , Lease (..)
  , LookupTerms (..)
  , Observation (..)
  , OperationId (..)
  , Settlement (..)
  , SubjectRef (..)
  , effectClassName
  , effectKeyText
  , effectRefusalCode
  , effectSpecBudget
  , effectSpecClass
  , effectSpecName
  , effectSpecTerms
  , intentStateName
  , mkEffectKey
  , mkEffectSpec
  , newIntents
  , stepIntent
  )
import Lockstep.Kernel.Identity (WorkOrderId (..), uuidFromWords)
import Lockstep.Kernel.Profile (Hasher (..), mkContentDigest)
import Lockstep.Kernel.Transition (Command (..), Principal (..))

tests :: TestTree
tests =
  testGroup
    "Effect intents (C-P2.5)"
    [ fixtureTests
    , specTests
    , identityTests
    , lifecycleTests
    , fencingTests
    , observationTests
    , budgetTests
    , codeTests
    ]

-- Fixtures -------------------------------------------------------------------

t0 :: UTCTime
t0 =
  UTCTime (fromGregorian 2026 10 19) (secondsToDiffTime 0)

-- | @n@ minutes after 't0'.
t :: Integer -> UTCTime
t n =
  addUTCTime (fromInteger (n * 60)) t0

op :: Word64 -> OperationId
op n =
  OperationId (uuidFromWords 4 n)

subject :: SubjectRef
subject =
  SubjectWorkOrder (WorkOrderId (uuidFromWords 0 1))

spec :: T.Text -> ClassTerms -> Int -> IO EffectSpec
spec name terms budget =
  either (\refusal -> assertFailure ("fixture spec refused: " <> show refusal)) pure (mkEffectSpec name terms budget)

key :: T.Text -> IO EffectKey
key text =
  either (\refusal -> assertFailure ("fixture key refused: " <> show refusal)) pure (mkEffectKey text)

specA :: IO EffectSpec
specA =
  spec "step" TermsRepeatable 1

-- | A pending intent built directly (not through 'newIntents'), so the lifecycle fixtures do not depend on it.
pendingWith :: EffectSpec -> IO Intent
pendingWith s = do
  k <- key "first"
  digest <- maybe (assertFailure "fixture digest") pure (mkContentDigest (T.replicate 64 "c"))
  pure
    Intent
      { intentOperation = op 1
      , intentSubject = subject
      , intentBasisRevision = 3
      , intentKey = k
      , intentSpec = s
      , intentParameters = "p=1"
      , intentParametersDigest = digest
      , intentState = IntentPending
      , intentGeneration = 0
      , intentDispatches = 0
      }

sup :: IntentInput -> Command IntentInput
sup =
  Command Supervisor

hum :: IntentInput -> Command IntentInput
hum =
  Command Human

-- | Applies the commands in order; the first refusal fails the fixture.
after :: Intent -> [Command IntentInput] -> IO Intent
after =
  foldM (\i c -> either (\refusal -> assertFailure ("fixture step refused: " <> show (c, refusal))) pure (stepIntent i c))

claim0 :: Command IntentInput
claim0 =
  sup (IntentClaim "w1" t0 (t 5))

-- | The intent in each §3 state (A spec, budget 1): claimed by w1 at t0 until t5, dispatched at t1.
data States
  = States
  { sPending :: Intent
  , sClaimed :: Intent
  , sDispatched :: Intent
  , sApplied :: Intent
  , sNotApplied :: Intent
  , sUnknown :: Intent
  , sSettled :: Intent
  , sAbandoned :: Intent
  }

states :: IO States
states = do
  pending <- specA >>= pendingWith
  claimed <- after pending [claim0]
  dispatched <- after claimed [sup (IntentDispatch 1 (t 1))]
  applied <- after dispatched [sup (IntentObserve 1 (DestinationApplied "ok"))]
  notApplied <- after dispatched [sup (IntentObserve 1 (DestinationNotApplied "rejected"))]
  unknown <- after dispatched [sup (IntentObserve 1 (NoAnswer "timeout"))]
  settled <- after applied [sup (IntentSettle 1)]
  abandoned <- after pending [hum (IntentAbandon "operator stop")]
  pure (States pending claimed dispatched applied notApplied unknown settled abandoned)

-- | The result of one step: the next state's name, or the refusal code.
outcome :: Intent -> Command IntentInput -> T.Text
outcome i c =
  either effectRefusalCode (intentStateName . intentState) (stepIntent i c)

refusedWith :: T.Text -> Either EffectRefusal a -> Assertion
refusedWith code result =
  case result of
    Left refusal -> effectRefusalCode refusal @?= code
    Right _ -> assertFailure ("expected refusal " <> T.unpack code)

fixtureTests :: TestTree
fixtureTests =
  testGroup
    "fixtures (exercised on their own before the freeze)"
    [ testCase "the fixture specs, keys and pending intent build" $ do
        a <- specA
        _ <- spec "notify" (TermsIdempotent (IdempotencyTerms 3600 True)) 2
        _ <- spec "commit" (TermsQueryable (LookupTerms True True)) 3
        _ <- spec "invoke" TermsUnqueryable 0
        i <- pendingWith a
        intentGeneration i @?= 0
        effectKeyText (intentKey i) @?= "first"
    ]

-- Specs ----------------------------------------------------------------------

specTests :: TestTree
specTests =
  testGroup
    "effect specs (E1)"
    [ testCase "each class is accepted with budget 0 to 3, D only with 0" $ do
        traverse_
          (\b -> fmap effectSpecBudget (mkEffectSpec "step" TermsRepeatable b) @?= Right b)
          [0, 1, 2, 3]
        fmap effectSpecClass (mkEffectSpec "notify" (TermsIdempotent (IdempotencyTerms 1 True)) 3) @?= Right Idempotent
        fmap effectSpecClass (mkEffectSpec "commit" (TermsQueryable (LookupTerms False False)) 0) @?= Right Queryable
        fmap effectSpecClass (mkEffectSpec "invoke" TermsUnqueryable 0) @?= Right Unqueryable
        fmap effectSpecName (mkEffectSpec "invoke" TermsUnqueryable 0) @?= Right "invoke"
        fmap effectSpecTerms (mkEffectSpec "commit" (TermsQueryable (LookupTerms True False)) 0) @?= Right (TermsQueryable (LookupTerms True False))
    , testCase "budgets outside 0 to 3 are invalid; D with a budget is unsafe" $ do
        refusedWith "invalid-effect-spec" (mkEffectSpec "step" TermsRepeatable 4)
        refusedWith "invalid-effect-spec" (mkEffectSpec "step" TermsRepeatable (-1))
        refusedWith "unsafe-retry-budget" (mkEffectSpec "invoke" TermsUnqueryable 1)
    , testCase "class B needs a positive key lifetime and refusal of changed parameters" $ do
        refusedWith "invalid-effect-spec" (mkEffectSpec "notify" (TermsIdempotent (IdempotencyTerms 0 True)) 1)
        refusedWith "idempotency-undocumented" (mkEffectSpec "notify" (TermsIdempotent (IdempotencyTerms 60 False)) 1)
    , testCase "bad names are invalid" $
        traverse_
          (\name -> refusedWith "invalid-effect-spec" (mkEffectSpec name TermsRepeatable 0))
          ["", "Step", "1step", "step_two", T.cons 's' (T.replicate 64 "x")]
    , testCase "class names" $
        fmap effectClassName [Repeatable, Idempotent, Queryable, Unqueryable] @?= ["repeatable", "idempotent", "queryable", "unqueryable"]
    ]

-- Identity -------------------------------------------------------------------

identityTests :: TestTree
identityTests =
  testGroup
    "stable intent identity (E2, requirement 1)"
    [ testCase "new intents are pending with the parameters' SHA-256; two keys at one revision stay distinct" $ do
        a <- specA
        k1 <- key "first"
        k2 <- key "second"
        case newIntents sha256Hasher subject 3 [(op 1, IntentRequest k1 a "p=1"), (op 2, IntentRequest k2 a "p=1")] of
          Left refusal -> assertFailure (show refusal)
          Right intents -> do
            fmap intentOperation intents @?= [op 1, op 2]
            fmap intentKey intents @?= [k1, k2]
            fmap intentState intents @?= [IntentPending, IntentPending]
            fmap intentGeneration intents @?= [0, 0]
            fmap intentDispatches intents @?= [0, 0]
            fmap intentBasisRevision intents @?= [3, 3]
            fmap intentSubject intents @?= [subject, subject]
            case sha256Hasher of
              Hasher f -> fmap intentParametersDigest intents @?= [f "p=1", f "p=1"]
    , testCase "one key twice in a decision is duplicate-effect-key" $ do
        a <- specA
        k1 <- key "first"
        refusedWith "duplicate-effect-key" (newIntents sha256Hasher subject 3 [(op 1, IntentRequest k1 a "x"), (op 2, IntentRequest k1 a "y")])
    , testCase "parameters: 1 to 4096 characters, no control characters" $ do
        a <- specA
        k1 <- key "first"
        let
          with p = newIntents sha256Hasher subject 3 [(op 1, IntentRequest k1 a p)]
        traverse_ (refusedWith "invalid-effect-parameters" . with) ["", "a\nb", "tab\there", T.replicate 4097 "x"]
        fmap (fmap intentParameters) (with (T.replicate 4096 "x")) @?= Right [T.replicate 4096 "x"]
    , testCase "bad effect keys are invalid-effect-key" $
        traverse_ (refusedWith "invalid-effect-key" . mkEffectKey) ["", "First", "1st", "a b"]
    ]

-- Lifecycle ------------------------------------------------------------------

lifecycleTests :: TestTree
lifecycleTests =
  testGroup
    "intent lifecycle table (§3, E3)"
    [ testCase "every cell for a repeatable spec" $ do
        s <- states
        let
          claimLive = sup (IntentClaim "w2" (t 2) (t 10))
          claimExpired = sup (IntentClaim "w2" (t 5) (t 10))
          dispatchLive = sup (IntentDispatch 1 (t 2))
          dispatchExpired = sup (IntentDispatch 1 (t 5))
          observe1 = sup (IntentObserve 1 (DestinationApplied "ok"))
          settle1 = sup (IntentSettle 1)
          abandon = hum (IntentAbandon "stop")
          check name i expected =
            assertEqual name expected (fmap (outcome i) [claimLive, claimExpired, dispatchLive, dispatchExpired, observe1, settle1, abandon])
        -- pending has generation 0, so every generation-1 input is stale
        check "pending" (sPending s) ["claimed", "claimed", "stale-claim", "stale-claim", "stale-claim", "stale-claim", "abandoned"]
        outcome (sPending s) (sup (IntentDispatch 0 (t 1))) @?= "illegal-intent-transition"
        outcome (sPending s) (sup (IntentObserve 0 (DestinationApplied "x"))) @?= "illegal-intent-transition"
        outcome (sPending s) (sup (IntentSettle 0)) @?= "illegal-intent-transition"
        check "claimed" (sClaimed s) ["claim-held", "claimed", "dispatched", "lease-expired", "illegal-intent-transition", "illegal-intent-transition", "abandoned"]
        check "dispatched" (sDispatched s) ["dispatched-needs-recovery", "dispatched-needs-recovery", "illegal-intent-transition", "illegal-intent-transition", "confirmed-applied", "illegal-intent-transition", "abandoned"]
        check "applied" (sApplied s) ["already-observed", "already-observed", "illegal-intent-transition", "illegal-intent-transition", "already-observed", "settled", "abandoned"]
        check "not applied" (sNotApplied s) ["claimed", "claimed", "illegal-intent-transition", "illegal-intent-transition", "already-observed", "settled", "abandoned"]
        check "unknown" (sUnknown s) ["outcome-unknown", "outcome-unknown", "illegal-intent-transition", "illegal-intent-transition", "already-observed", "outcome-unknown", "abandoned"]
        check "settled" (sSettled s) (L.replicate 7 "already-settled")
        check "abandoned" (sAbandoned s) (L.replicate 7 "already-settled")
    , testCase "a claim records the owner, the next generation and the lease end; a dispatch counts" $ do
        s <- states
        intentGeneration (sClaimed s) @?= 1
        intentState (sClaimed s) @?= IntentClaimed (Lease "w1" 1 (t 5))
        intentDispatches (sClaimed s) @?= 0
        intentState (sDispatched s) @?= IntentDispatched (Lease "w1" 1 (t 5))
        intentDispatches (sDispatched s) @?= 1
        intentState (sSettled s) @?= IntentSettled (SettledApplied "ok")
        notSettled <- after (sNotApplied s) [sup (IntentSettle 1)]
        intentState notSettled @?= IntentSettled (SettledNotApplied "rejected")
        intentState (sAbandoned s) @?= IntentAbandoned "operator stop"
    , testCase "Agent is refused in every state" $ do
        s <- states
        traverse_
          ( \i ->
              traverse_
                (\input -> outcome i (Command Agent input) @?= "agent-assertion")
                [IntentClaim "a" t0 (t 9), IntentDispatch 1 t0, IntentObserve 1 (DestinationApplied "x"), IntentSettle 1, IntentAbandon "x"]
          )
          [sPending s, sClaimed s, sDispatched s, sApplied s, sNotApplied s, sUnknown s, sSettled s, sAbandoned s]
    , testCase "wrong principals are not-authorized; terminal states answer already-settled first" $ do
        s <- states
        traverse_
          (\p -> outcome (sPending s) (Command p (IntentClaim "w" t0 (t 5))) @?= "not-authorized")
          [Human, Scheduler, DeliveryAdapter]
        traverse_
          (\p -> outcome (sDispatched s) (Command p (IntentObserve 1 (DestinationApplied "x"))) @?= "not-authorized")
          [Human, Scheduler]
        traverse_
          (\p -> outcome (sPending s) (Command p (IntentAbandon "x")) @?= "not-authorized")
          [Supervisor, Scheduler, DeliveryAdapter]
        outcome (sSettled s) (hum (IntentClaim "w" t0 (t 5))) @?= "already-settled"
    , testCase "every stale generation is stale-claim" $ do
        s <- states
        traverse_
          ( \i ->
              traverse_
                (\input -> outcome i (sup input) @?= "stale-claim")
                [IntentDispatch 7 t0, IntentObserve 7 (DestinationApplied "x"), IntentSettle 7]
          )
          [sPending s, sClaimed s, sDispatched s, sApplied s, sNotApplied s, sUnknown s]
    ]

-- Fencing --------------------------------------------------------------------

fencingTests :: TestTree
fencingTests =
  testGroup
    "fencing (E4)"
    [ testCase "a reclaim after the lease ends raises the generation; the old owner's writes are stale" $ do
        s <- states
        reclaimed <- after (sClaimed s) [sup (IntentClaim "w2" (t 5) (t 10))]
        intentGeneration reclaimed @?= 2
        intentState reclaimed @?= IntentClaimed (Lease "w2" 2 (t 10))
        outcome reclaimed (sup (IntentDispatch 1 (t 6))) @?= "stale-claim"
        outcome reclaimed (sup (IntentObserve 1 (DestinationApplied "late"))) @?= "stale-claim"
        outcome reclaimed (sup (IntentSettle 1)) @?= "stale-claim"
        outcome reclaimed (sup (IntentDispatch 2 (t 6))) @?= "dispatched"
    , testCase "an observation from the current generation needs no live lease" $ do
        s <- states
        -- dispatched at t1 with a lease to t5; the observation carries no time and is accepted
        observed <- after (sDispatched s) [sup (IntentObserve 1 (DestinationApplied "slow but done"))]
        intentState observed @?= IntentApplied "slow but done"
    , testCase "nothing is dispatched on an expired lease, even exactly at its end" $ do
        s <- states
        outcome (sClaimed s) (sup (IntentDispatch 1 (t 5))) @?= "lease-expired"
        outcome (sClaimed s) (sup (IntentDispatch 1 (addUTCTime (-1) (t 5)))) @?= "dispatched"
    ]

-- Observations ---------------------------------------------------------------

observationTests :: TestTree
observationTests =
  testGroup
    "observations (E6)"
    [ testCase "applied, not applied and no answer" $ do
        s <- states
        applied <- after (sDispatched s) [sup (IntentObserve 1 (DestinationApplied "r"))]
        intentState applied @?= IntentApplied "r"
        notApplied <- after (sDispatched s) [sup (IntentObserve 1 (DestinationNotApplied "no"))]
        intentState notApplied @?= IntentNotApplied "no"
        unknown <- after (sDispatched s) [sup (IntentObserve 1 (NoAnswer "timeout after 30 s"))]
        intentState unknown @?= IntentUnknown "timeout after 30 s"
        assertBool "a no-answer is never not-applied" (intentStateName (intentState unknown) /= "confirmed-not-applied")
    ]

-- Budget ---------------------------------------------------------------------

budgetTests :: TestTree
budgetTests =
  testGroup
    "retry budget (E7)"
    [ testCase "budget 1: one re-dispatch after not-applied, then retries-exhausted" $ do
        i <- specA >>= pendingWith
        once <-
          after
            i
            [ claim0
            , sup (IntentDispatch 1 (t 1))
            , sup (IntentObserve 1 (DestinationNotApplied "busy"))
            , sup (IntentClaim "w1" (t 2) (t 7))
            , sup (IntentDispatch 2 (t 3))
            , sup (IntentObserve 2 (DestinationNotApplied "busy"))
            ]
        intentDispatches once @?= 2
        outcome once (sup (IntentClaim "w1" (t 4) (t 9))) @?= "retries-exhausted"
    , testCase "budget 0 is never reclaimed after not-applied, in any class" $ do
        specs <-
          sequenceA
            [ spec "step" TermsRepeatable 0
            , spec "notify" (TermsIdempotent (IdempotencyTerms 60 True)) 0
            , spec "commit" (TermsQueryable (LookupTerms True True)) 0
            , spec "invoke" TermsUnqueryable 0
            ]
        traverse_
          ( \s -> do
              i <- pendingWith s
              done <- after i [claim0, sup (IntentDispatch 1 (t 1)), sup (IntentObserve 1 (DestinationNotApplied "no"))]
              outcome done (sup (IntentClaim "w1" (t 2) (t 7))) @?= "retries-exhausted"
          )
          specs
    , testCase "reclaiming an expired, undispatched claim consumes no budget" $ do
        z <- spec "step" TermsRepeatable 0
        i <- pendingWith z
        reclaimed <- after i [claim0, sup (IntentClaim "w2" (t 5) (t 10)), sup (IntentClaim "w3" (t 10) (t 15))]
        intentGeneration reclaimed @?= 3
        intentDispatches reclaimed @?= 0
        outcome reclaimed (sup (IntentDispatch 3 (t 11))) @?= "dispatched"
    , testCase "an unknown outcome is never claimable" $ do
        s <- states
        outcome (sUnknown s) (sup (IntentClaim "w9" (t 60) (t 70))) @?= "outcome-unknown"
    ]

-- Codes ----------------------------------------------------------------------

codeTests :: TestTree
codeTests =
  testGroup
    "codes"
    [ testCase "refusal codes and state names" $ do
        k <- key "first"
        fmap
          effectRefusalCode
          [ InvalidEffectSpec "x"
          , IdempotencyUndocumented
          , UnsafeRetryBudget
          , InvalidEffectKey "x"
          , InvalidEffectParameters
          , DuplicateEffectKey k
          , EffectAgentAssertion
          , EffectAlreadySettled
          , EffectNotAuthorized Human
          , StaleClaim
          , IllegalIntentTransition "pending" "dispatch"
          , ClaimHeld
          , LeaseExpired
          , DispatchedNeedsRecovery
          , AlreadyObserved
          , OutcomeUnknownBlocks
          , RetriesExhausted
          ]
          @?= [ "invalid-effect-spec"
              , "idempotency-undocumented"
              , "unsafe-retry-budget"
              , "invalid-effect-key"
              , "invalid-effect-parameters"
              , "duplicate-effect-key"
              , "agent-assertion"
              , "already-settled"
              , "not-authorized"
              , "stale-claim"
              , "illegal-intent-transition"
              , "claim-held"
              , "lease-expired"
              , "dispatched-needs-recovery"
              , "already-observed"
              , "outcome-unknown"
              , "retries-exhausted"
              ]
        fmap
          intentStateName
          [ IntentPending
          , IntentClaimed (Lease "w" 1 t0)
          , IntentDispatched (Lease "w" 1 t0)
          , IntentApplied "r"
          , IntentNotApplied "r"
          , IntentUnknown "r"
          , IntentSettled (SettledApplied "r")
          , IntentAbandoned "r"
          ]
          @?= ["pending", "claimed", "dispatched", "confirmed-applied", "confirmed-not-applied", "outcome-unknown", "settled", "abandoned"]
    ]
