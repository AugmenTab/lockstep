{-# LANGUAGE OverloadedStrings #-}

{- | C-P2.5 integration: durable Tickets and Work Orders, one-transaction
decisions with effect intents, scheduling runs, Work Unit admission, intent
claims and fencing, against real PostgreSQL.
-}
module Lockstep.LedgerTest
  ( tests
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, throwIO, try)
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import System.IO.Error (userError)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Ledger
  ( Faults (..)
  , LedgerFailure (..)
  , NewWorkOrder (..)
  , Receipt (..)
  , ScheduleReceipt (..)
  , StoredObservation (..)
  , SubjectView (..)
  , WorkOrderView (..)
  , abandonIntent
  , admitWorkUnit
  , claimIntent
  , createTicket
  , createWorkOrder
  , decideTicket
  , decideWorkOrder
  , dispatchIntent
  , intentObservations
  , ledgerFailureCode
  , noFaults
  , observeIntent
  , recordGateEvidence
  , reviseTicket
  , scheduleOnce
  , settleIntent
  , showTicket
  , showWorkOrder
  )
import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Kernel.Effect
  ( ClassTerms (..)
  , EffectSpec
  , Intent (..)
  , IntentRequest (..)
  , IntentState (..)
  , Observation (..)
  , OperationId (..)
  , mkEffectKey
  , mkEffectSpec
  )
import Lockstep.Kernel.Identity (EngineerId (..), TicketId (..), WorkOrderId (..), parseUuid, uuidFromWords, uuidText)
import Lockstep.Kernel.Profile (Approval (..), ArtifactKind (..), GateEvidence (..), Hasher (..), VerifierKind (..), contentDigestText, mkContentDigest)
import Lockstep.Kernel.Ticket (TicketInput (..))
import Lockstep.Kernel.Transition (Command (..), Principal (..))
import Lockstep.Kernel.WorkOrder (Claim (..), WorkOrderInput (..), WorkOrderKind (..), WorkOrderState (..))
import Lockstep.Support.Ledger (Ledger (..), addEngineer, addEngineerWithRepository, count, queryTexts, sql, sqlFails, withLedger)
import Lockstep.Support.Postgres (queryBool)

tests :: TestTree
tests =
  testGroup
    "Durable ledger (C-P2.5; real PostgreSQL)"
    [ testCase "scenario setup: migrate, Engineer, repository, Profile and default through the binary" $
        withLedger $ \lg -> do
          counts <- traverse (count lg) ["lockstep_engineers", "lockstep_repositories", "lockstep_profiles", "lockstep_repository_profiles"]
          counts @?= [1, 1, 1, 1]
          names <- queryTexts lg "SELECT name AS v FROM lockstep_engineers"
          names @?= ["alice"]
          _ <- aliceId lg
          -- every helper and SQL idiom the other cases use, on tables that already exist
          addEngineer lg "carol"
          addEngineerWithRepository lg "dave"
          count lg "lockstep_engineers WHERE name <> 'alice'" >>= (@?= 2)
          sql lg "ALTER TABLE lockstep_profile_decisions DISABLE TRIGGER USER"
          -- with the trigger off the update succeeds, so a later failure is the trigger's
          sql lg "UPDATE lockstep_profile_decisions SET decided_at = decided_at"
          sql lg "ALTER TABLE lockstep_profile_decisions ENABLE TRIGGER USER"
          immutable lg "UPDATE lockstep_profile_decisions SET decided_at = decided_at"
          immutable lg "DELETE FROM lockstep_profile_decisions"
          immutable lg "TRUNCATE lockstep_profile_decisions"
          sqlFails lg "SELECT no_such_column FROM lockstep_profiles"
          hashed <- queryBool (lgAdmin lg) (lgDb lg) "SELECT bool_and(encode(sha256(convert_to('abc', 'UTF8')), 'hex') = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad') AS v FROM lockstep_profiles"
          assertBool "sha256() in SQL" hashed
          stamp <- queryBool (lgAdmin lg) (lgDb lg) "SELECT (now() - interval '1 second') < now() AS v"
          assertBool "interval arithmetic" stamp
          v <- newEmptyMVar
          _ <- forkIO (try (pure (1 :: Int)) >>= putMVar v)
          r <- takeMVar v
          assertBool "a forked thread reports back" (either (const False) (== 1) (r :: Either SomeException Int))
    , testCase "tickets: create, accept, stale revision, illegal input, revise" $
        withLedger $ \lg -> do
          t <- ok "create" (createTicket (lgRuntime lg) "Fix login")
          shown <- ok "show" (showTicket (lgRuntime lg) t)
          shown @?= SubjectView 1 "proposed" 1
          accepted <- ok "accept" (decideTicket (lgRuntime lg) noFaults t 1 (Command Human TicketAccept))
          accepted @?= Receipt 2 "ready" []
          refused "stale-revision" (decideTicket (lgRuntime lg) noFaults t 1 (Command Human TicketAccept))
          again <- ok "show" (showTicket (lgRuntime lg) t)
          again @?= SubjectView 2 "ready" 1
          count lg "lockstep_decision_refusals" >>= (@?= 1)
          refused "illegal-transition" (decideTicket (lgRuntime lg) noFaults t 2 (Command Human TicketUnblock))
          count lg "lockstep_decision_refusals" >>= (@?= 2)
          revised <- ok "revise" (reviseTicket (lgRuntime lg) t 2 "Fix login properly")
          receiptRevision revised @?= 3
          receiptState revised @?= "ready"
          final <- ok "show" (showTicket (lgRuntime lg) t)
          final @?= SubjectView 3 "ready" 2
          refused "invalid-record" (createTicket (lgRuntime lg) "")
    , testCase "work order creation from a ready Ticket, and each refusal" $
        withLedger $ \lg -> do
          proposed <- ok "create" (createTicket (lgRuntime lg) "Proposed only")
          refused "ticket-not-ready" (createWorkOrder (lgRuntime lg) (order proposed))
          t <- readyTicket lg
          wo <- ok "create work order" (createWorkOrder (lgRuntime lg) (order t))
          view <- ok "show" (showWorkOrder (lgRuntime lg) wo)
          woRevision view @?= 1
          woState view @?= Pending
          T.length (woBindingDigest view) @?= 64
          count lg "lockstep_work_order_profile_sources" >>= (@?= 2)
          refused "unknown-ticket" (createWorkOrder (lgRuntime lg) (order (TicketId (uuidFromWords 9 9))))
          refused "unknown-engineer" (createWorkOrder (lgRuntime lg) (order t) {newEngineer = "bob"})
          addEngineer lg "carol"
          refused "engineer-has-no-repository" (createWorkOrder (lgRuntime lg) (order t) {newEngineer = "carol"})
          addEngineerWithRepository lg "dave"
          refused "repository-default-profile-unset" (createWorkOrder (lgRuntime lg) (order t) {newEngineer = "dave"})
          refused "invalid-facts" (createWorkOrder (lgRuntime lg) (order t) {newPathClasses = ["nonsense"]})
          refused "invalid-priority" (createWorkOrder (lgRuntime lg) (order t) {newPriority = 1000})
          refused "unknown-dependency" (createWorkOrder (lgRuntime lg) (order t) {newDependencies = [WorkOrderId (uuidFromWords 9 8)]})
          refused "non-behavioural-refused" (createWorkOrder (lgRuntime lg) (order t) {newNonBehavioural = Just "docs only"})
          count lg "lockstep_work_orders" >>= (@?= 1)
    , testCase "a decision commits its event and intents together; faults leave neither" $
        withLedger $ \lg -> do
          (wo, c) <- claimedOrder lg
          requests <- twoRequests
          let
            boom = throwIO (userError "injected fault")
          r1 <- try (decideWorkOrder (lgRuntime lg) noFaults {faultAfterEvent = boom} wo 3 (Command Supervisor (WoStart c)) requests)
          assertBool "the fault propagates" (isException r1)
          r2 <- try (decideWorkOrder (lgRuntime lg) noFaults {faultAfterIntents = boom} wo 3 (Command Supervisor (WoStart c)) requests)
          assertBool "the fault propagates" (isException r2)
          unchanged <- ok "show" (showWorkOrder (lgRuntime lg) wo)
          woRevision unchanged @?= 3
          woState unchanged @?= Claimed c
          count lg "lockstep_effect_intents" >>= (@?= 0)
          count lg ("lockstep_events WHERE subject_id = '" <> woText wo <> "'") >>= (@?= 3)
          started <- ok "start" (decideWorkOrder (lgRuntime lg) noFaults wo 3 (Command Supervisor (WoStart c)) requests)
          receiptRevision started @?= 4
          receiptState started @?= "active"
          L.length (receiptOperations started) @?= 2
          count lg "lockstep_effect_intents" >>= (@?= 2)
          count lg ("lockstep_events WHERE subject_id = '" <> woText wo <> "'") >>= (@?= 4)
          refused "stale-revision" (decideWorkOrder (lgRuntime lg) noFaults wo 3 (Command Supervisor (WoStart c)) requests)
          count lg "lockstep_effect_intents" >>= (@?= 2)
    , testCase "intents with any input but start or resume are refused" $
        withLedger $ \lg -> do
          (wo, c) <- claimedOrder lg
          requests <- twoRequests
          refused "intents-not-authorized" (decideWorkOrder (lgRuntime lg) noFaults wo 3 (Command Scheduler (WoRelease c)) requests)
          view <- ok "show" (showWorkOrder (lgRuntime lg) wo)
          woRevision view @?= 3
          count lg "lockstep_effect_intents" >>= (@?= 0)
    , testCase "replay integrity: a tampered projection or Profile source is an integrity failure" $
        withLedger $ \lg -> do
          (wo, c) <- claimedOrder lg
          view <- ok "show" (showWorkOrder (lgRuntime lg) wo)
          woState view @?= Claimed c
          sql lg ("UPDATE lockstep_subjects SET state = 'active' WHERE id = '" <> woText wo <> "'")
          refused "integrity" (showWorkOrder (lgRuntime lg) wo)
          sql lg ("UPDATE lockstep_subjects SET state = 'claimed' WHERE id = '" <> woText wo <> "'")
          _ <- ok "show restored" (showWorkOrder (lgRuntime lg) wo)
          sql lg "ALTER TABLE lockstep_work_order_profile_sources DISABLE TRIGGER USER"
          sql lg "UPDATE lockstep_work_order_profile_sources SET digest = repeat('0', 64)"
          sql lg "ALTER TABLE lockstep_work_order_profile_sources ENABLE TRIGGER USER"
          refused "integrity" (showWorkOrder (lgRuntime lg) wo)
    , testCase "scheduling claims an order with satisfied evidence; the decision is stored with its digest" $
        withLedger $ \lg -> do
          t <- readyTicket lg
          wo <- ok "create" (createWorkOrder (lgRuntime lg) (order t))
          evidence lg wo
          alice <- aliceId lg
          receipt <- ok "schedule" (scheduleOnce (lgRuntime lg))
          scheduleClaimed receipt @?= Just (wo, Claim alice 1)
          case sha256Hasher of
            Hasher f -> scheduleDigestText receipt @?= contentDigestText (f (scheduleRendering receipt))
          stored <- queryBool (lgAdmin lg) (lgDb lg) "SELECT bool_and(encode(sha256(convert_to(rendering, 'UTF8')), 'hex') = digest) AS v FROM lockstep_schedule_decisions"
          assertBool "stored digest is the SHA-256 of the stored rendering" stored
          count lg "lockstep_schedule_decisions" >>= (@?= 1)
          view <- ok "show" (showWorkOrder (lgRuntime lg) wo)
          woRevision view @?= 3
          woState view @?= Claimed (Claim alice 1)
    , testCase "scheduling leaves an order missing evidence pending, with the reason" $
        withLedger $ \lg -> do
          t <- readyTicket lg
          wo <- ok "create" (createWorkOrder (lgRuntime lg) (order t))
          receipt <- ok "schedule" (scheduleOnce (lgRuntime lg))
          scheduleClaimed receipt @?= Nothing
          assertBool
            ("rendering: " <> T.unpack (scheduleRendering receipt))
            (("ineligible " <> T.pack (woText wo) <> " prerequisite-blocked impact missing-artifact impact-assessment") `T.isInfixOf` scheduleRendering receipt)
          view <- ok "show" (showWorkOrder (lgRuntime lg) wo)
          woState view @?= Pending
          woRevision view @?= 1
    , testCase "after a halt and requeue the next claim has generation 2" $
        withLedger $ \lg -> do
          (wo, _) <- claimedOrder lg
          _ <- ok "halt" (decideWorkOrder (lgRuntime lg) noFaults wo 3 (Command Human (WoHalt "operator")) [])
          _ <- ok "requeue" (decideWorkOrder (lgRuntime lg) noFaults wo 4 (Command Human WoRequeue) [])
          alice <- aliceId lg
          receipt <- ok "schedule" (scheduleOnce (lgRuntime lg))
          scheduleClaimed receipt @?= Just (wo, Claim alice 2)
    , testCase "a revised Ticket makes its order source-stale" $
        withLedger $ \lg -> do
          t <- readyTicket lg
          wo <- ok "create" (createWorkOrder (lgRuntime lg) (order t))
          evidence lg wo
          _ <- ok "revise" (reviseTicket (lgRuntime lg) t 2 "New scope")
          receipt <- ok "schedule" (scheduleOnce (lgRuntime lg))
          scheduleClaimed receipt @?= Nothing
          assertBool
            ("rendering: " <> T.unpack (scheduleRendering receipt))
            (("ineligible " <> T.pack (woText wo) <> " source-stale") `T.isInfixOf` scheduleRendering receipt)
    , testCase "work unit admission: plan-less for a claimed order; refused for a pending one" $
        withLedger $ \lg -> do
          (wo, _) <- claimedOrder lg
          _ <- ok "admit" (admitWorkUnit (lgRuntime lg) wo Nothing)
          count lg "lockstep_work_units" >>= (@?= 1)
          planless <- queryBool (lgAdmin lg) (lgDb lg) "SELECT bool_and(plan_ref IS NULL) AS v FROM lockstep_work_units"
          assertBool "plan-less" planless
          t2 <- readyTicket lg
          pending <- ok "create" (createWorkOrder (lgRuntime lg) (order t2))
          refused "work-order-not-active" (admitWorkUnit (lgRuntime lg) pending Nothing)
    , testCase "claims and fencing: one winner, reclaim after expiry, stale writes refused and stored, unknown blocks" $
        withLedger $ \lg -> do
          (_, _, ops) <- startedOrder lg
          o <- case ops of
            first : _ -> pure first
            [] -> assertFailure "no intents"
          a <- newEmptyMVar
          b <- newEmptyMVar
          _ <- forkIO (try (claimIntent (lgRuntime lg) "w1" 60 o) >>= putMVar a)
          _ <- forkIO (try (claimIntent (lgRuntime lg) "w2" 60 o) >>= putMVar b)
          ra <- takeMVar a
          rb <- takeMVar b
          case (ra, rb) of
            (Right (Right i), Right (Left f)) -> winner i f
            (Right (Left f), Right (Right i)) -> winner i f
            other -> assertFailure ("expected exactly one claim: " <> showResults other)
          sql lg ("UPDATE lockstep_effect_intents SET lease_until = now() - interval '1 second' WHERE operation_id = '" <> opText o <> "'")
          reclaimed <- ok "reclaim" (claimIntent (lgRuntime lg) "w3" 60 o)
          intentGeneration reclaimed @?= 2
          refused "stale-claim" (dispatchIntent (lgRuntime lg) o 1)
          refused "stale-claim" (observeIntent (lgRuntime lg) o 1 (DestinationApplied "late"))
          late <- ok "observations" (intentObservations (lgRuntime lg) o)
          late @?= [StoredObservation 1 "applied result=\"late\"" False (Just "stale-claim")]
          dispatched <- ok "dispatch" (dispatchIntent (lgRuntime lg) o 2)
          intentDispatches dispatched @?= 1
          unknown <- ok "observe" (observeIntent (lgRuntime lg) o 2 (NoAnswer "timeout"))
          intentState unknown @?= IntentUnknown "timeout"
          refused "outcome-unknown" (claimIntent (lgRuntime lg) "w4" 60 o)
          refused "outcome-unknown" (settleIntent (lgRuntime lg) o 2)
          abandoned <- ok "abandon" (abandonIntent (lgRuntime lg) o "operator stop")
          intentState abandoned @?= IntentAbandoned "operator stop"
          all' <- ok "observations" (intentObservations (lgRuntime lg) o)
          all'
            @?= [ StoredObservation 1 "applied result=\"late\"" False (Just "stale-claim")
                , StoredObservation 2 "no-answer reason=\"timeout\"" True Nothing
                ]
    , testCase "retry budget 1: not applied twice, then retries-exhausted" $
        withLedger $ \lg -> do
          (_, _, ops) <- startedOrder lg
          o <- case ops of
            first : _ -> pure first
            [] -> assertFailure "no intents"
          _ <- ok "claim" (claimIntent (lgRuntime lg) "w1" 60 o)
          _ <- ok "dispatch" (dispatchIntent (lgRuntime lg) o 1)
          _ <- ok "observe" (observeIntent (lgRuntime lg) o 1 (DestinationNotApplied "busy"))
          again <- ok "claim again" (claimIntent (lgRuntime lg) "w1" 60 o)
          intentGeneration again @?= 2
          _ <- ok "dispatch" (dispatchIntent (lgRuntime lg) o 2)
          _ <- ok "observe" (observeIntent (lgRuntime lg) o 2 (DestinationNotApplied "busy"))
          refused "retries-exhausted" (claimIntent (lgRuntime lg) "w1" 60 o)
    , testCase "events, refusals, observations, evidence, schedule decisions and Profile sources are immutable" $
        withLedger $ \lg -> do
          (wo, _, ops) <- startedOrder lg
          refused "stale-revision" (decideWorkOrder (lgRuntime lg) noFaults wo 1 (Command Human WoCancel) [])
          o <- case ops of
            first : _ -> pure first
            [] -> assertFailure "no intents"
          _ <- ok "claim" (claimIntent (lgRuntime lg) "w1" 60 o)
          _ <- ok "dispatch" (dispatchIntent (lgRuntime lg) o 1)
          _ <- ok "observe" (observeIntent (lgRuntime lg) o 1 (DestinationApplied "done"))
          let
            tables =
              [ "lockstep_events"
              , "lockstep_decision_refusals"
              , "lockstep_effect_observations"
              , "lockstep_gate_evidence"
              , "lockstep_schedule_decisions"
              , "lockstep_work_order_profile_sources"
              ]
          traverse_
            ( \table -> do
                n <- count lg table
                assertBool (table <> " has rows") (n > 0)
                immutable lg ("UPDATE " <> table <> " SET recorded_at = recorded_at")
                immutable lg ("DELETE FROM " <> table)
            )
            tables
          traverse_
            (\table -> immutable lg ("TRUNCATE " <> table))
            ["lockstep_decision_refusals", "lockstep_effect_observations", "lockstep_gate_evidence", "lockstep_schedule_decisions", "lockstep_work_order_profile_sources"]
    ]

-- Helpers --------------------------------------------------------------------

ok :: String -> IO (Either LedgerFailure a) -> IO a
ok what action =
  action >>= either (\failure -> assertFailure (what <> ": " <> show failure)) pure

refused :: T.Text -> IO (Either LedgerFailure a) -> Assertion
refused code action = do
  result <- action
  case result of
    Left failure -> ledgerFailureCode failure @?= code
    Right _ -> assertFailure ("expected refusal " <> T.unpack code)

-- | The statement fails because the immutability trigger refused it, not for any other reason.
immutable :: Ledger -> String -> Assertion
immutable lg statement = do
  result <- try (sql lg statement) :: IO (Either SomeException ())
  case result of
    Left e -> assertBool (statement <> ": failed, but not by the trigger: " <> show e) ("rows are immutable" `L.isInfixOf` show e)
    Right () -> assertFailure ("statement succeeded: " <> statement)

isException :: Either SomeException a -> Bool
isException =
  either (const True) (const False)

showResults :: (Show a, Show b) => (Either SomeException a, Either SomeException b) -> String
showResults (x, y) =
  show (either show show x, either show show y)

winner :: Intent -> LedgerFailure -> Assertion
winner i f = do
  intentGeneration i @?= 1
  ledgerFailureCode f @?= "claim-held"

woText :: WorkOrderId -> String
woText (WorkOrderId u) =
  T.unpack (uuidText u)

opText :: OperationId -> String
opText (OperationId u) =
  T.unpack (uuidText u)

aliceId :: Ledger -> IO EngineerId
aliceId lg = do
  ids <- queryTexts lg "SELECT id::text AS v FROM lockstep_engineers WHERE name = 'alice'"
  case fmap parseUuid ids of
    [Right u] -> pure (EngineerId u)
    other -> assertFailure ("alice: " <> show other)

order :: TicketId -> NewWorkOrder
order t =
  NewWorkOrder
    { newTicket = t
    , newEngineer = "alice"
    , newKind = Engineering
    , newPriority = 5
    , newDependencies = []
    , newClasses = []
    , newPathClasses = ["source"]
    , newNonBehavioural = Nothing
    }

readyTicket :: Ledger -> IO TicketId
readyTicket lg = do
  t <- ok "create ticket" (createTicket (lgRuntime lg) "Fix login")
  _ <- ok "accept ticket" (decideTicket (lgRuntime lg) noFaults t 1 (Command Human TicketAccept))
  pure t

evidence :: Ledger -> WorkOrderId -> Assertion
evidence lg wo = do
  digest <- maybe (assertFailure "digest") pure (mkContentDigest (T.replicate 64 "a"))
  ok
    "evidence"
    ( recordGateEvidence
        (lgRuntime lg)
        Human
        wo
        GateEvidence
          { evidenceArtifact = ImpactAssessment
          , evidenceDigest = digest
          , evidenceVerifiedBy = [VerifyHumanInspection]
          , evidenceApproval = ApprovalSupervisor
          }
    )

-- | A ready Ticket's order with evidence, claimed by the scheduler: revision 3 (create, mark-eligible, claim).
claimedOrder :: Ledger -> IO (WorkOrderId, Claim)
claimedOrder lg = do
  t <- readyTicket lg
  wo <- ok "create work order" (createWorkOrder (lgRuntime lg) (order t))
  evidence lg wo
  receipt <- ok "schedule" (scheduleOnce (lgRuntime lg))
  case scheduleClaimed receipt of
    Just (claimed, c) | claimed == wo -> pure (wo, c)
    other -> assertFailure ("not claimed: " <> show other <> "\n" <> T.unpack (scheduleRendering receipt))

stepSpec :: IO EffectSpec
stepSpec =
  either (assertFailure . show) pure (mkEffectSpec "step" TermsRepeatable 1)

twoRequests :: IO [IntentRequest]
twoRequests = do
  s <- stepSpec
  k1 <- either (assertFailure . show) pure (mkEffectKey "first")
  k2 <- either (assertFailure . show) pure (mkEffectKey "second")
  pure [IntentRequest k1 s "p=1", IntentRequest k2 s "p=2"]

-- | A claimed order started with two repeatable intents (budget 1): revision 4.
startedOrder :: Ledger -> IO (WorkOrderId, Claim, [OperationId])
startedOrder lg = do
  (wo, c) <- claimedOrder lg
  requests <- twoRequests
  receipt <- ok "start" (decideWorkOrder (lgRuntime lg) noFaults wo 3 (Command Supervisor (WoStart c)) requests)
  pure (wo, c, receiptOperations receipt)
