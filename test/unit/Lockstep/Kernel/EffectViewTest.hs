{-# LANGUAGE OverloadedStrings #-}

-- | C-P2.8 §7 unit cases: the effect status table (V1, §3).
module Lockstep.Kernel.EffectViewTest
  ( tests
  ) where

import Control.Monad (foldM)
import Data.List qualified as L
import Data.Text qualified as T
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Kernel.Effect
  ( ClassTerms (..)
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
  , mkEffectKey
  , mkEffectSpec
  , newIntents
  , stepIntent
  )
import Lockstep.Kernel.EffectView
  ( EffectStatus (..)
  , StatusFacts (..)
  , effectStatus
  , effectStatusClass
  , effectStatusLabel
  , effectStatusReason
  )
import Lockstep.Kernel.Identity (WorkOrderId (..), uuidFromWords)
import Lockstep.Kernel.Transition (Command (..), Principal (..))

tests :: TestTree
tests =
  testGroup
    "Effect status (C-P2.8)"
    [ rowTests
    , labelTests
    , passedTests
    ]

-- Fixtures -------------------------------------------------------------------

t0 :: UTCTime
t0 =
  UTCTime (fromGregorian 2026 10 19) (secondsToDiffTime 0)

at :: Integer -> UTCTime
at n =
  addUTCTime (fromInteger n) t0

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

-- | Claimed by w1 at 't0' with the lease to 60 s.
claimedOf :: ClassTerms -> Int -> Either T.Text Intent
claimedOf terms budget =
  pendingOf terms budget >>= \p -> steps p [sup (IntentClaim "w1" t0 (at 60))]

dispatchedOf :: ClassTerms -> Int -> Either T.Text Intent
dispatchedOf terms budget =
  claimedOf terms budget >>= \c -> steps c [sup (IntentDispatch 1 (at 1))]

observedOf :: ClassTerms -> Int -> Observation -> Either T.Text Intent
observedOf terms budget observation =
  dispatchedOf terms budget >>= \d -> steps d [sup (IntentObserve 1 observation)]

-- | Every state of a class, through the real C-P2.5 lifecycle.
statesOf :: ClassTerms -> Int -> Either T.Text [Intent]
statesOf terms budget = do
  p <- pendingOf terms budget
  c <- claimedOf terms budget
  d <- dispatchedOf terms budget
  applied <- observedOf terms budget (DestinationApplied "done")
  notApplied <- observedOf terms budget (DestinationNotApplied "busy")
  unknown <- observedOf terms budget (NoAnswer "timeout")
  appliedSettled <- steps applied [sup (IntentSettle 1)]
  settledNot <- steps notApplied [sup (IntentSettle 1)]
  abandoned <- steps p [Command Human (IntentAbandon "stop")]
  pure [p, c, d, applied, notApplied, unknown, appliedSettled, settledNot, abandoned]

fixture :: Either T.Text a -> IO a
fixture =
  either (assertFailure . T.unpack) pure

facts :: Integer -> Bool -> Bool -> StatusFacts
facts now active attested =
  StatusFacts {factsNow = at now, factsOrderActive = active, factsHumanAttested = attested}

expect :: StatusFacts -> Intent -> EffectStatus -> T.Text -> IO ()
expect f i status reason = do
  effectStatus f i @?= status
  effectStatusReason f i @?= reason

repeatable, idempotent, unqueryable :: ClassTerms
repeatable = TermsRepeatable
idempotent = TermsIdempotent (IdempotencyTerms 86400 True)
unqueryable = TermsUnqueryable

queryable :: ClassTerms
queryable =
  TermsQueryable (LookupTerms True True)

-- Rows -----------------------------------------------------------------------

rowTests :: TestTree
rowTests =
  testGroup
    "the status table (§3), row by row"
    [ testCase "1 abandoned" $ do
        p <- fixture (pendingOf repeatable 1)
        a <- fixture (steps p [Command Human (IntentAbandon "stop")])
        expect (facts 10 True False) a StatusAbandoned "abandoned: stop"
    , testCase "2 and 3: a settled application is ATTESTED when a human attested it, else PASSED" $ do
        applied <- fixture (observedOf repeatable 1 (DestinationApplied "done"))
        s <- fixture (steps applied [sup (IntentSettle 1)])
        expect (facts 10 True True) s StatusAttested "attested by a human, not observed: done"
        expect (facts 10 True False) s StatusPassed "applied: done"
    , testCase "4 settled not applied" $ do
        n <- fixture (observedOf repeatable 1 (DestinationNotApplied "busy"))
        s <- fixture (steps n [sup (IntentSettle 1)])
        expect (facts 10 True False) s StatusNotApplied "not applied: busy"
    , testCase "5 confirmed-applied, not yet settled" $ do
        applied <- fixture (observedOf repeatable 1 (DestinationApplied "done"))
        expect (facts 10 True False) applied StatusInProgress "applied, not yet settled: done"
    , testCase "6 and 7: an unknown outcome needs a lookup when queryable, else a human" $ do
        q <- fixture (observedOf queryable 1 (NoAnswer "timeout"))
        expect (facts 10 True False) q StatusReconciliationNeeded "outcome unknown, a lookup may resolve it: timeout"
        u <- fixture (observedOf unqueryable 0 (NoAnswer "timeout"))
        expect (facts 10 True False) u StatusUnknown "outcome unknown, a human must resolve it: timeout"
        a <- fixture (observedOf repeatable 1 (NoAnswer "timeout"))
        expect (facts 10 False False) a StatusUnknown "outcome unknown, a human must resolve it: timeout"
    , testCase "8 and 9: dispatched; its lease end decides, whatever the order" $ do
        d <- fixture (dispatchedOf repeatable 1)
        expect (facts 60 True False) d StatusReconciliationNeeded "dispatched by w1 (generation 1); its lease ended without an answer"
        expect (facts 59 True False) d StatusInProgress "dispatched by w1 (generation 1)"
        expect (facts 59 False False) d StatusInProgress "dispatched by w1 (generation 1)"
    , testCase "10 pending, claimed and not applied are BLOCKED when the order is not active" $ do
        p <- fixture (pendingOf repeatable 1)
        c <- fixture (claimedOf repeatable 1)
        n <- fixture (observedOf repeatable 1 (DestinationNotApplied "busy"))
        traverse_ (\i -> expect (facts 10 False False) i StatusBlocked "the work order is not active") [p, c, n]
    , testCase "11 and 12: a claim before and after its lease end" $ do
        c <- fixture (claimedOf repeatable 1)
        expect (facts 59 True False) c StatusClaimed "claimed by w1 (generation 1)"
        expect (facts 60 True False) c StatusNotRun "a claim by w1 lapsed before dispatch"
    , testCase "13 pending" $ do
        p <- fixture (pendingOf repeatable 1)
        expect (facts 10 True False) p StatusNotRun "not dispatched"
    , testCase "14 and 15: not applied, with and without a retry left" $ do
        n1 <- fixture (observedOf repeatable 1 (DestinationNotApplied "busy"))
        expect (facts 10 True False) n1 StatusNotApplied "not applied, a retry is left: busy"
        n0 <- fixture (observedOf repeatable 0 (DestinationNotApplied "busy"))
        expect (facts 10 True False) n0 StatusNotApplied "not applied, no retry left: busy"
    ]

-- Labels ---------------------------------------------------------------------

labelTests :: TestTree
labelTests =
  testGroup
    "labels and classes"
    [ testCase "every status has its label and class" $ do
        fmap effectStatusLabel [minBound .. maxBound]
          @?= ["NOT_RUN", "CLAIMED", "IN_PROGRESS", "RECONCILIATION_NEEDED", "UNKNOWN", "BLOCKED", "NOT_APPLIED", "PASSED", "ATTESTED", "ABANDONED"]
        fmap effectStatusClass [minBound .. maxBound]
          @?= [ "ls-effect-not-run"
              , "ls-effect-claimed"
              , "ls-effect-in-progress"
              , "ls-effect-reconciliation-needed"
              , "ls-effect-unknown"
              , "ls-effect-blocked"
              , "ls-effect-not-applied"
              , "ls-effect-passed"
              , "ls-effect-attested"
              , "ls-effect-abandoned"
              ]
    ]

-- PASSED ---------------------------------------------------------------------

settledApplied :: Intent -> Bool
settledApplied i =
  case intentState i of
    IntentSettled (SettledApplied _) -> True
    _ -> False

passedTests :: TestTree
passedTests =
  testGroup
    "PASSED (V1, requirement 6)"
    [ testCase "PASSED exactly for a settled application without attestation, in every state, class and fact" $ do
        all' <- traverse fixture [statesOf c b | (c, b) <- [(repeatable, 1), (idempotent, 1), (queryable, 1), (unqueryable, 0)]]
        let
          combos = [facts now active attested | now <- [0, 59, 60, 200], active <- [True, False], attested <- [True, False]]
          cases = [(f, i) | f <- combos, i <- L.concat all']
        L.length cases @?= 576
        traverse_
          ( \(f, i) ->
              assertBool
                ("PASSED mismatch for " <> show (intentState i) <> " " <> show f)
                ((effectStatus f i == StatusPassed) == (settledApplied i && not (factsHumanAttested f)))
          )
          cases
    ]
