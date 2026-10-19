{-# LANGUAGE OverloadedStrings #-}

{- | C-P2.7 integration: reconciliation by lookup, human resolution, late
observations, and contention between real separate processes, against real
PostgreSQL.

The cross-process cases start this test binary again as worker processes,
selecting only the "contention worker role" case with a tasty pattern and
naming the role in the environment (R8). Their shared external destination is
a pair of tables the test owns, written over separate connections.
-}
module Lockstep.ReconciliationTest
  ( tests
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, throwIO, try)
import Control.Monad ((>=>))
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import System.Environment (getEnvironment, getExecutablePath, lookupEnv)
import System.Exit (ExitCode (..))
import System.IO (FilePath, IOMode (WriteMode), openFile, readFile, writeFile)
import System.IO.Error (userError)
import System.IO.Temp (withSystemTempDirectory)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Executor
  ( Executor (..)
  , ExecutorFaults (..)
  , RunOutcome (..)
  , executeIntent
  , executeOnce
  , noExecutorFaults
  , recoverAndExecute
  )
import Lockstep.Application.Ledger
  ( LedgerFailure (..)
  , NewWorkOrder (..)
  , Receipt (..)
  , ScheduleReceipt (..)
  , StoredObservation (..)
  , StoredResolution (..)
  , WorkOrderView (..)
  , abandonIntent
  , claimIntent
  , createTicket
  , createWorkOrder
  , decideTicket
  , decideWorkOrder
  , intentObservations
  , intentRecoveries
  , intentResolutions
  , ledgerFailureCode
  , loadIntent
  , noFaults
  , reconcilableIntents
  , recordGateEvidence
  , resolveOutcome
  , scheduleOnce
  , showWorkOrder
  )
import Lockstep.Application.Reconciler (ReconcileOutcome (..), Reconciliation (..), reconcileEffect)
import Lockstep.Effects.Executor (DestinationAnswer (..), EffectAdapter (..))
import Lockstep.Effects.Reconciler (EffectReconciler (..), LookupAnswer (..))
import Lockstep.Effects.Scripted
  ( Application (..)
  , LookupStep (..)
  , ScriptStep (..)
  , ScriptedDestination
  , destinationApplications
  , newScriptedDestination
  , scriptedAdapter
  , scriptedReconciler
  )
import Lockstep.Kernel.Effect
  ( ClassTerms (..)
  , EffectSpec
  , IdempotencyTerms (..)
  , Intent (..)
  , IntentRequest (..)
  , IntentState (..)
  , LookupTerms (..)
  , OperationId (..)
  , Settlement (..)
  , effectSpecName
  , intentStateName
  , mkEffectKey
  , mkEffectSpec
  )
import Lockstep.Kernel.Identity (EngineerId (..), TicketId, WorkOrderId (..), parseUuid, uuidText)
import Lockstep.Kernel.Profile (Approval (..), ArtifactKind (..), GateEvidence (..), VerifierKind (..), mkContentDigest)
import Lockstep.Kernel.Reconciliation (Resolution (..))
import Lockstep.Kernel.Ticket (TicketInput (..))
import Lockstep.Kernel.Transition (Command (..), Principal (..))
import Lockstep.Kernel.WorkOrder (Claim (..), WorkOrderInput (..), WorkOrderKind (..), WorkOrderState (..))
import Lockstep.Support.Ledger (Ledger (..), count, queryTexts, sql, withLedger)
import Lockstep.Support.Postgres (AdminSettings, adminExecute, databaseConfigFor, queryInts, requireAdmin, withRuntime)

tests :: TestTree
tests =
  testGroup
    "Reconciliation, resolution and cross-process contention (C-P2.7; real PostgreSQL)"
    [ testCase "contention worker role (the role of a child worker process; nothing to do in the suite itself)" $ do
        role <- lookupEnv "LOCKSTEP_P27_ROLE"
        maybe (pure ()) workerRole role
    , testCase "scenario setup: six intents, the destination tables, a child worker process, restart and polling" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          intents <- traverse (intentOf lg) (allOps ops)
          fmap (intentStateName . intentState) intents @?= L.replicate 6 "pending"
          createDestination lg
          adapters <- dbAdapters (lgAdmin lg) (lgDb lg) "setup" 0
          L.length adapters @?= 6
          alpha <- adapterNamed "alpha" adapters
          bravo <- adapterNamed "bravo" adapters
          _ <- adapterRun alpha (opA ops) "p=alpha"
          _ <- adapterRun bravo (opB ops) "p=bravo"
          again <- adapterRun bravo (opB ops) "p=bravo"
          again @?= AnswerApplied "ok"
          dbApplications lg (opA ops) >>= (@?= 1)
          dbApplications lg (opB ops) >>= (@?= 1)
          reconcilers <- dbReconcilers (lgAdmin lg) (lgDb lg)
          L.length reconcilers @?= 3
          charlie <- reconcilerNamed "charlie" reconcilers
          absent <- reconcilerLookup charlie (opC ops) "p=charlie"
          absent @?= LookupAbsent
          withSystemTempDirectory "lockstep-p27" $ \tmp -> do
            outcome <- runWorkers lg tmp [("probe", opA ops, "w-probe", 0)]
            outcome @?= ["probe pending"]
          _ <- ok "claim" (claimIntent (lgRuntime lg) "w1" 60 (opD ops))
          endLease lg (opD ops)
          haltByHuman lg wo
          restartOrder lg wo
          view <- ok "show" (showWorkOrder (lgRuntime lg) wo)
          isActive (woState view) @?= True
          eventually "an intent is pending" ((== IntentPending) . intentState <$> intentOf lg (opE ops))
          lastEvent lg wo >>= (@?= "supervisor start engineer=" <> engineerOf (woState view) <> " generation=2")
    , testCase "lookup found: settled with the recorded result; one lookup record; the order stays halted" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- scripted dest [("charlie", [StepApplyThenHang "kept"])]
          unknown <- ok "execute" (executeIntent (lgRuntime lg) (exec "w1" adapters) {executorTimeoutMs = 200} noExecutorFaults (opC ops))
          unknown @?= RanUnknown "timeout"
          reconciliation <- lookups dest []
          result <- ok "reconcile" (reconcileEffect (lgRuntime lg) reconciliation (opC ops))
          result @?= ReconciledApplied "kept"
          i <- intentOf lg (opC ops)
          intentState i @?= IntentSettled (SettledApplied "kept")
          intentGeneration i @?= 2
          ok "resolutions" (intentResolutions (lgRuntime lg) (opC ops)) >>= (@?= [StoredResolution 1 "lookup" "found result=\"kept\"" False])
          ok "observations" (intentObservations (lgRuntime lg) (opC ops)) >>= (@?= [StoredObservation 1 "no-answer reason=\"timeout\"" True Nothing])
          haltedFor lg wo ("outcome-unknown operation=" <> opText (opC ops))
    , testCase "authoritative not found: confirmed not applied, then retried with the same operation id" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- scripted dest [("charlie", [StepHang])]
          _ <- ok "execute" (executeIntent (lgRuntime lg) (exec "w1" adapters) {executorTimeoutMs = 200} noExecutorFaults (opC ops))
          reconciliation <- lookups dest []
          result <- ok "reconcile" (reconcileEffect (lgRuntime lg) reconciliation (opC ops))
          result @?= ReconciledNotApplied "lookup: not found"
          i <- intentOf lg (opC ops)
          intentState i @?= IntentNotApplied "lookup: not found"
          intentGeneration i @?= 2
          restartOrder lg wo
          retried <- ok "execute" (executeIntent (lgRuntime lg) (exec "w2" adapters) noExecutorFaults (opC ops))
          retried @?= RanApplied "ok"
          after <- intentOf lg (opC ops)
          intentGeneration after @?= 3
          intentDispatches after @?= 2
          scriptedCount dest (opC ops) >>= (@?= 1)
    , testCase "not found without authority or late exclusion stays unknown and is never re-executed" $
        withLedger $ \lg -> do
          dest <- newScriptedDestination
          adapters <- scripted dest [("echo", [StepHang]), ("foxtrot", [StepHang])]
          reconciliation <- lookups dest []
          (_, ops) <- activeOrder lg
          _ <- ok "execute" (executeIntent (lgRuntime lg) (exec "w1" adapters) {executorTimeoutMs = 200} noExecutorFaults (opE ops))
          ok "reconcile" (reconcileEffect (lgRuntime lg) reconciliation (opE ops)) >>= (@?= StillUnknown "lookup: not found, late application not excluded")
          refused "outcome-unknown" (executeIntent (lgRuntime lg) (exec "w2" adapters) noExecutorFaults (opE ops))
          (_, ops2) <- activeOrder lg
          _ <- ok "execute" (executeIntent (lgRuntime lg) (exec "w1" adapters) {executorTimeoutMs = 200} noExecutorFaults (opF ops2))
          ok "reconcile" (reconcileEffect (lgRuntime lg) reconciliation (opF ops2)) >>= (@?= StillUnknown "lookup: not found, not authoritative")
          refused "outcome-unknown" (executeIntent (lgRuntime lg) (exec "w2" adapters) noExecutorFaults (opF ops2))
          scriptedCount dest (opE ops) >>= (@?= 0)
          scriptedCount dest (opF ops2) >>= (@?= 0)
    , testCase "lookup failures stay unknown, each under a new generation, each recorded" $
        withLedger $ \lg -> do
          (_, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- scripted dest [("charlie", [StepHang])]
          _ <- ok "execute" (executeIntent (lgRuntime lg) (exec "w1" adapters) {executorTimeoutMs = 200} noExecutorFaults (opC ops))
          failing <- lookups dest [LookupHang, LookupFail]
          let
            short = failing {reconciliationTimeoutMs = 200}
          ok "reconcile" (reconcileEffect (lgRuntime lg) short (opC ops)) >>= (@?= StillUnknown "lookup failed: timeout")
          ok "reconcile" (reconcileEffect (lgRuntime lg) short (opC ops)) >>= (@?= StillUnknown "lookup failed: lookup-failed")
          i <- intentOf lg (opC ops)
          intentGeneration i @?= 3
          records <- ok "resolutions" (intentResolutions (lgRuntime lg) (opC ops))
          records @?= [StoredResolution 1 "lookup" "failed reason=\"timeout\"" False, StoredResolution 2 "lookup" "failed reason=\"lookup-failed\"" False]
    , testCase "a dispatched queryable intent is reconciled directly once its lease ends" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- scripted dest []
          crashed <- try (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults {faultAfterEffect = crash} (opC ops))
          assertBool "the crash propagates" (isException crashed)
          ok "reconcilable" (reconcilableIntents (lgRuntime lg)) >>= (@?= [])
          endLease lg (opC ops)
          ok "reconcilable" (reconcilableIntents (lgRuntime lg)) >>= (@?= [opC ops])
          reconciliation <- lookups dest []
          ok "reconcile" (reconcileEffect (lgRuntime lg) reconciliation (opC ops)) >>= (@?= ReconciledApplied "ok")
          ok "recoveries" (intentRecoveries (lgRuntime lg) (opC ops)) >>= (@?= [])
          view <- ok "show" (showWorkOrder (lgRuntime lg) wo)
          isActive (woState view) @?= True
          scriptedCount dest (opC ops) >>= (@?= 1)
    , testCase "reconciliation refusals write nothing" $
        withLedger $ \lg -> do
          (_, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- scripted dest []
          reconciliation <- lookups dest []
          refused "not-queryable" (reconcileEffect (lgRuntime lg) reconciliation (opA ops))
          refused "nothing-to-reconcile" (reconcileEffect (lgRuntime lg) reconciliation (opC ops))
          crashed <- try (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults {faultAfterDispatch = crash} (opC ops))
          assertBool "the crash propagates" (isException crashed)
          refused "lease-active" (reconcileEffect (lgRuntime lg) reconciliation (opC ops))
          refused "no-reconciler" (reconcileEffect (lgRuntime lg) reconciliation {reconciliationReconcilers = []} (opC ops))
          wrongSpec <- spec "charlie" (TermsQueryable (LookupTerms False False)) 1
          wrong <- scriptedReconciler wrongSpec dest []
          refused "reconciler-mismatch" (reconcileEffect (lgRuntime lg) reconciliation {reconciliationReconcilers = [wrong]} (opC ops))
          refused "invalid-record" (reconcileEffect (lgRuntime lg) reconciliation {reconciliationTimeoutMs = 0} (opC ops))
          i <- intentOf lg (opC ops)
          intentStateName (intentState i) @?= "dispatched"
          intentGeneration i @?= 1
          count lg "lockstep_effect_resolutions" >>= (@?= 0)
    , testCase "human: attest applied, bound to the generation, recorded apart from observations" $
        withLedger $ \lg -> do
          (_, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- scripted dest [("delta", [StepApplyThenHang "late"])]
          _ <- ok "execute" (executeIntent (lgRuntime lg) (exec "w1" adapters) {executorTimeoutMs = 200} noExecutorFaults (opD ops))
          refused "stale-claim" (resolveOutcome (lgRuntime lg) (opD ops) 0 (AttestApplied "operator saw the receipt"))
          resolved <- ok "resolve" (resolveOutcome (lgRuntime lg) (opD ops) 1 (AttestApplied "operator saw the receipt"))
          intentState resolved @?= IntentSettled (SettledApplied "human-attested: operator saw the receipt")
          ok "resolutions" (intentResolutions (lgRuntime lg) (opD ops))
            >>= (@?= [StoredResolution 1 "human-attested" "attested-applied evidence=\"operator saw the receipt\"" False])
          ok "observations" (intentObservations (lgRuntime lg) (opD ops)) >>= (@?= [StoredObservation 1 "no-answer reason=\"timeout\"" True Nothing])
          refused "already-settled" (resolveOutcome (lgRuntime lg) (opD ops) 1 (AttestApplied "again"))
    , testCase "human: attest not applied, claimable with a retry left and settled without one" $
        withLedger $ \lg -> do
          dest <- newScriptedDestination
          adapters <- scripted dest [("bravo", [StepHang]), ("delta", [StepHang])]
          (_, ops) <- activeOrder lg
          _ <- ok "execute" (executeIntent (lgRuntime lg) (exec "w1" adapters) {executorTimeoutMs = 200} noExecutorFaults (opB ops))
          b <- ok "resolve" (resolveOutcome (lgRuntime lg) (opB ops) 1 (AttestNotApplied "nothing at the destination"))
          intentState b @?= IntentNotApplied "human-attested: nothing at the destination"
          (_, ops2) <- activeOrder lg
          _ <- ok "execute" (executeIntent (lgRuntime lg) (exec "w1" adapters) {executorTimeoutMs = 200} noExecutorFaults (opD ops2))
          d <- ok "resolve" (resolveOutcome (lgRuntime lg) (opD ops2) 1 (AttestNotApplied "nothing at the destination"))
          intentState d @?= IntentSettled (SettledNotApplied "human-attested: nothing at the destination")
    , testCase "human: a retry needs the duplication risk acknowledged; then the same operation id runs again" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- scripted dest [("delta", [StepHang])]
          _ <- ok "execute" (executeIntent (lgRuntime lg) (exec "w1" adapters) {executorTimeoutMs = 200} noExecutorFaults (opD ops))
          refused "duplication-risk-not-acknowledged" (resolveOutcome (lgRuntime lg) (opD ops) 1 (RetryAcknowledgingDuplication False))
          retried <- ok "resolve" (resolveOutcome (lgRuntime lg) (opD ops) 1 (RetryAcknowledgingDuplication True))
          intentState retried @?= IntentPending
          ok "resolutions" (intentResolutions (lgRuntime lg) (opD ops)) >>= (@?= [StoredResolution 1 "human-retry" "retry duplication-acknowledged" True])
          refused "not-unknown" (resolveOutcome (lgRuntime lg) (opD ops) 1 (RetryAcknowledgingDuplication True))
          restartOrder lg wo
          result <- ok "execute" (executeIntent (lgRuntime lg) (exec "w2" adapters) noExecutorFaults (opD ops))
          result @?= RanApplied "ok"
          after <- intentOf lg (opD ops)
          intentGeneration after @?= 2
          intentDispatches after @?= 2
          scriptedCount dest (opD ops) >>= (@?= 1)
    , testCase "late application after an authoritative negative lookup: blocked, halted, recorded" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- scripted dest []
          reconciliation <- lookups dest []
          let
            overtaken = do
              endLease lg (opC ops)
              ok "reconcile" (reconcileEffect (lgRuntime lg) reconciliation (opC ops)) >>= (@?= ReconciledNotApplied "lookup: not found")
          refused "stale-claim" (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults {faultAfterDispatch = overtaken} (opC ops))
          i <- intentOf lg (opC ops)
          intentState i @?= IntentUnknown "late-application"
          haltedFor lg wo ("late-application operation=" <> opText (opC ops))
          ok "resolutions" (intentResolutions (lgRuntime lg) (opC ops))
            >>= (@?= [StoredResolution 1 "lookup" "not-found" False, StoredResolution 1 "late-observation" "late-application applied result=\"ok\"" False])
          refused "outcome-unknown" (executeIntent (lgRuntime lg) (exec "w2" adapters) noExecutorFaults (opC ops))
          scriptedCount dest (opC ops) >>= (@?= 1)
    , testCase "abandoned, then applied: a late-application conflict halts the order" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- scripted dest []
          let
            abandon = () <$ ok "abandon" (abandonIntent (lgRuntime lg) (opA ops) "operator stop")
          refused "already-settled" (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults {faultAfterEffect = abandon} (opA ops))
          haltedFor lg wo ("late-application operation=" <> opText (opA ops))
          ok "resolutions" (intentResolutions (lgRuntime lg) (opA ops))
            >>= (@?= [StoredResolution 1 "late-observation" "late-application applied result=\"ok\"" False])
    , testCase "resolution records are immutable" $
        withLedger $ \lg -> do
          (_, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- scripted dest [("delta", [StepHang])]
          _ <- ok "execute" (executeIntent (lgRuntime lg) (exec "w1" adapters) {executorTimeoutMs = 200} noExecutorFaults (opD ops))
          _ <- ok "resolve" (resolveOutcome (lgRuntime lg) (opD ops) 1 (AttestApplied "seen"))
          count lg "lockstep_effect_resolutions" >>= (@?= 1)
          immutable lg "UPDATE lockstep_effect_resolutions SET recorded_at = recorded_at"
          immutable lg "DELETE FROM lockstep_effect_resolutions"
          immutable lg "TRUNCATE lockstep_effect_resolutions"
    , testCase "two processes drain one order: every intent applied exactly once" $
        withLedger $ \lg -> do
          (_, ops) <- activeOrder lg
          createDestination lg
          outcomes <- withSystemTempDirectory "lockstep-p27" $ \tmp ->
            runWorkers lg tmp [("drain", opA ops, "w-a", 300), ("drain", opA ops, "w-b", 300)]
          let
            drained = L.sum (fmap drainedCount outcomes)
          drained @?= 6
          traverse_ (dbApplications lg >=> (@?= 1)) (allOps ops)
          intents <- traverse (intentOf lg) (allOps ops)
          fmap (intentStateName . intentState) intents @?= L.replicate 6 "settled"
    , testCase "two processes recover one crashed idempotent intent: one applies, one is refused" $
        withLedger $ \lg -> do
          (_, ops) <- activeOrder lg
          createDestination lg
          adapters <- dbAdapters (lgAdmin lg) (lgDb lg) "parent" 0
          crashed <- try (executeIntent (lgRuntime lg) (exec "parent" adapters) noExecutorFaults {faultAfterDispatch = crash} (opB ops))
          assertBool "the crash propagates" (isException crashed)
          endLease lg (opB ops)
          outcomes <- withSystemTempDirectory "lockstep-p27" $ \tmp ->
            runWorkers lg tmp [("recover", opB ops, "w-a", 300), ("recover", opB ops, "w-b", 300)]
          case L.sort outcomes of
            [first, second] -> do
              first @?= "applied ok"
              assertBool ("the other is refused: " <> second) (second `L.elem` ["refused nothing-to-recover", "refused already-settled"])
            other -> assertFailure ("two outcomes expected: " <> show other)
          dbApplications lg (opB ops) >>= (@?= 1)
    , testCase "two processes recover one crashed unqueryable intent: unknown once, never re-executed" $
        withLedger $ \lg -> do
          (_, ops) <- activeOrder lg
          createDestination lg
          adapters <- dbAdapters (lgAdmin lg) (lgDb lg) "parent" 0
          crashed <- try (executeIntent (lgRuntime lg) (exec "parent" adapters) noExecutorFaults {faultAfterEffect = crash} (opD ops))
          assertBool "the crash propagates" (isException crashed)
          endLease lg (opD ops)
          outcomes <- withSystemTempDirectory "lockstep-p27" $ \tmp ->
            runWorkers lg tmp [("recover", opD ops, "w-a", 0), ("recover", opD ops, "w-b", 0)]
          L.sort outcomes @?= ["refused nothing-to-recover", "unknown dispatch-interrupted: unqueryable effect"]
          dbApplications lg (opD ops) >>= (@?= 1)
    , testCase "a stalled process completes late: fenced by a reconciliation, its application recorded as a conflict" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          createDestination lg
          reconcilers <- dbReconcilers (lgAdmin lg) (lgDb lg)
          outcomes <- withSystemTempDirectory "lockstep-p27" $ \tmp -> do
            worker <- spawnWorker lg tmp ("stall", opE ops, "w-stall", 0)
            eventually "the worker dispatched" ((== "dispatched") . intentStateName . intentState <$> intentOf lg (opE ops))
            endLease lg (opE ops)
            result <- ok "reconcile" (reconcileEffect (lgRuntime lg) (Reconciliation 5000 reconcilers) (opE ops))
            result @?= StillUnknown "lookup: not found, late application not excluded"
            out <- awaitWorker worker
            pure [out]
          outcomes @?= ["refused stale-claim"]
          dbApplications lg (opE ops) >>= (@?= 1)
          i <- intentOf lg (opE ops)
          intentState i @?= IntentUnknown "lookup: not found, late application not excluded"
          intentGeneration i @?= 2
          ok "observations" (intentObservations (lgRuntime lg) (opE ops)) >>= (@?= [StoredObservation 1 "applied result=\"ok\"" False (Just "stale-claim")])
          ok "resolutions" (intentResolutions (lgRuntime lg) (opE ops))
            >>= (@?= [StoredResolution 1 "lookup" "not-found" False, StoredResolution 1 "late-observation" "late-application applied result=\"ok\"" False])
          haltedFor lg wo ("outcome-unknown operation=" <> opText (opE ops))
    ]

-- Scenario -------------------------------------------------------------------

data Ops
  = Ops
  { opA :: OperationId
  , opB :: OperationId
  , opC :: OperationId
  , opD :: OperationId
  , opE :: OperationId
  , opF :: OperationId
  }

allOps :: Ops -> [OperationId]
allOps ops =
  [opA ops, opB ops, opC ops, opD ops, opE ops, opF ops]

-- | The six specs: name, terms, budget (§7).
specTable :: [(T.Text, ClassTerms, Int)]
specTable =
  [ ("alpha", TermsRepeatable, 1)
  , ("bravo", TermsIdempotent (IdempotencyTerms 86400 True), 1)
  , ("charlie", TermsQueryable (LookupTerms True True), 1)
  , ("delta", TermsUnqueryable, 0)
  , ("echo", TermsQueryable (LookupTerms True False), 1)
  , ("foxtrot", TermsQueryable (LookupTerms False False), 1)
  ]

spec :: T.Text -> ClassTerms -> Int -> IO EffectSpec
spec name terms budget =
  either (assertFailure . show) pure (mkEffectSpec name terms budget)

specs :: IO [EffectSpec]
specs =
  traverse (\(n, t, b) -> spec n t b) specTable

queryable :: EffectSpec -> Bool
queryable s =
  effectSpecName s `L.elem` ["charlie", "echo", "foxtrot"]

-- | Scripted adapters for every spec over one destination; scripts default to [].
scripted :: ScriptedDestination -> [(T.Text, [ScriptStep])] -> IO [EffectAdapter]
scripted dest scripts =
  specs >>= traverse (\s -> scriptedAdapter s dest (fromMaybe [] (L.lookup (effectSpecName s) scripts)))

-- | Scripted lookups for the three queryable specs, all with the same script.
lookups :: ScriptedDestination -> [LookupStep] -> IO Reconciliation
lookups dest steps = do
  all' <- specs
  reconcilers <- traverse (\s -> scriptedReconciler s dest steps) (L.filter queryable all')
  pure (Reconciliation 2000 reconcilers)

scriptedCount :: ScriptedDestination -> OperationId -> IO Int
scriptedCount dest o =
  L.length . L.filter ((== o) . appliedOperation) <$> destinationApplications dest

exec :: T.Text -> [EffectAdapter] -> Executor
exec owner adapters =
  Executor {executorOwner = owner, executorLeaseSeconds = 60, executorTimeoutMs = 2000, executorAdapters = adapters}

crash :: IO ()
crash =
  throwIO (userError "the worker died here")

activeOrder :: Ledger -> IO (WorkOrderId, Ops)
activeOrder lg = do
  t <- readyTicket lg
  wo <- ok "create work order" (createWorkOrder (lgRuntime lg) (order t))
  evidence lg wo
  c <- scheduled lg wo
  requests <-
    traverse
      ( \(name, terms, budget) -> do
          s <- spec name terms budget
          k <- either (assertFailure . show) pure (mkEffectKey name)
          pure (IntentRequest k s ("p=" <> name))
      )
      specTable
  started <- ok "start" (decideWorkOrder (lgRuntime lg) noFaults wo 3 (Command Supervisor (WoStart c)) requests)
  case receiptOperations started of
    [a, b, c', d, e, f] -> pure (wo, Ops a b c' d e f)
    other -> assertFailure ("expected six intents: " <> show other)

scheduled :: Ledger -> WorkOrderId -> IO Claim
scheduled lg wo = do
  receipt <- ok "schedule" (scheduleOnce (lgRuntime lg))
  case scheduleClaimed receipt of
    Just (claimed, c) | claimed == wo -> pure c
    other -> assertFailure ("not claimed: " <> show other <> "\n" <> T.unpack (scheduleRendering receipt))

-- | A halted order requeued by a Human, claimed again by the scheduler and started without new intents.
restartOrder :: Ledger -> WorkOrderId -> Assertion
restartOrder lg wo = do
  view <- ok "show" (showWorkOrder (lgRuntime lg) wo)
  _ <- ok "requeue" (decideWorkOrder (lgRuntime lg) noFaults wo (woRevision view) (Command Human WoRequeue) [])
  c <- scheduled lg wo
  claimedView <- ok "show" (showWorkOrder (lgRuntime lg) wo)
  _ <- ok "start" (decideWorkOrder (lgRuntime lg) noFaults wo (woRevision claimedView) (Command Supervisor (WoStart c)) [])
  pure ()

haltByHuman :: Ledger -> WorkOrderId -> Assertion
haltByHuman lg wo = do
  view <- ok "show" (showWorkOrder (lgRuntime lg) wo)
  _ <- ok "halt" (decideWorkOrder (lgRuntime lg) noFaults wo (woRevision view) (Command Human (WoHalt "operator stop")) [])
  pure ()

isActive :: WorkOrderState -> Bool
isActive state =
  case state of
    Active _ -> True
    _ -> False

engineerOf :: WorkOrderState -> T.Text
engineerOf state =
  case state of
    Active c ->
      case claimEngineer c of
        EngineerId u -> uuidText u
    _ -> "none"

haltedFor :: Ledger -> WorkOrderId -> T.Text -> Assertion
haltedFor lg wo reason = do
  view <- ok "show" (showWorkOrder (lgRuntime lg) wo)
  woState view @?= Halted reason

lastEvent :: Ledger -> WorkOrderId -> IO T.Text
lastEvent lg (WorkOrderId u) = do
  rows <- queryTexts lg ("SELECT principal || ' ' || command AS v FROM lockstep_events WHERE subject_id = '" <> T.unpack (uuidText u) <> "' ORDER BY sequence DESC LIMIT 1")
  case rows of
    [row] -> pure row
    other -> assertFailure ("last event: " <> show other)

endLease :: Ledger -> OperationId -> Assertion
endLease lg o =
  sql lg ("UPDATE lockstep_effect_intents SET lease_until = now() - interval '1 second' WHERE operation_id = '" <> T.unpack (opText o) <> "'")

intentOf :: Ledger -> OperationId -> IO Intent
intentOf lg o =
  ok "load intent" (loadIntent (lgRuntime lg) o)

-- | Polls through the ledger's own pool (one query per poll) every 100 ms for up to 20 s.
eventually :: String -> IO Bool -> Assertion
eventually what check =
  go (200 :: Int)
 where
  go n = do
    done <- check
    if done
      then pure ()
      else
        if n <= 0
          then assertFailure ("not within 20 s: " <> what)
          else threadDelay 100000 >> go (n - 1)

-- The external destination (R8) ----------------------------------------------

createDestination :: Ledger -> Assertion
createDestination lg = do
  sql lg "CREATE TABLE p27_applications (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, operation_id uuid NOT NULL, parameters text NOT NULL, worker text NOT NULL)"
  sql lg "CREATE TABLE p27_keys (operation_id uuid PRIMARY KEY, parameters text NOT NULL)"

{- | Adapters for every spec that apply by inserting a row, after the delay.
The idempotent one inserts its key first and applies only if the key is new,
in one statement: a primary key shared by every process.
-}
dbAdapters :: AdminSettings -> T.Text -> String -> Int -> IO [EffectAdapter]
dbAdapters admin db worker delayMs =
  fmap (fmap adapter) specs
 where
  adapter s =
    EffectAdapter s $ \o parameters -> do
      threadDelay (delayMs * 1000)
      let
        values = "'" <> T.unpack (opText o) <> "', '" <> T.unpack parameters <> "', '" <> worker <> "'"
      adminExecute admin (T.unpack db) $
        if effectSpecName s == "bravo"
          then
            "WITH k AS (INSERT INTO p27_keys VALUES ('"
              <> T.unpack (opText o)
              <> "', '"
              <> T.unpack parameters
              <> "') ON CONFLICT DO NOTHING RETURNING operation_id) INSERT INTO p27_applications (operation_id, parameters, worker) SELECT operation_id, '"
              <> T.unpack parameters
              <> "', '"
              <> worker
              <> "' FROM k"
          else "INSERT INTO p27_applications (operation_id, parameters, worker) VALUES (" <> values <> ")"
      pure (AnswerApplied "ok")

-- | Lookups for the three queryable specs: applied if any row has the operation id.
dbReconcilers :: AdminSettings -> T.Text -> IO [EffectReconciler]
dbReconcilers admin db =
  fmap (fmap reconciler . L.filter queryable) specs
 where
  reconciler s =
    EffectReconciler s $ \o _ -> do
      n <- queryInts admin db ("SELECT count(*)::integer AS v FROM p27_applications WHERE operation_id = '" <> T.unpack (opText o) <> "'")
      pure (if n == [0] then LookupAbsent else LookupApplied "ok")

dbApplications :: Ledger -> OperationId -> IO Int
dbApplications lg o =
  count lg ("p27_applications WHERE operation_id = '" <> T.unpack (opText o) <> "'")

adapterNamed :: T.Text -> [EffectAdapter] -> IO EffectAdapter
adapterNamed name adapters =
  maybe (assertFailure ("no adapter " <> T.unpack name)) pure (L.find ((== name) . effectSpecName . adapterSpec) adapters)

reconcilerNamed :: T.Text -> [EffectReconciler] -> IO EffectReconciler
reconcilerNamed name reconcilers =
  maybe (assertFailure ("no reconciler " <> T.unpack name)) pure (L.find ((== name) . effectSpecName . reconcilerSpec) reconcilers)

-- Worker processes (R8) ------------------------------------------------------

-- | (role, operation, owner, adapter delay in ms)
type WorkerSpec = (String, OperationId, String, Int)

data Worker
  = Worker
  { workerHandle :: Process.ProcessHandle
  , workerOut :: FilePath
  , workerLog :: FilePath
  }

spawnWorker :: Ledger -> FilePath -> WorkerSpec -> IO Worker
spawnWorker lg tmp (role, o, owner, delayMs) = do
  exe <- getExecutablePath
  base <- getEnvironment
  let
    out = tmp <> "/" <> owner <> ".out"
    logPath = tmp <> "/" <> owner <> ".log"
    extra =
      [ ("LOCKSTEP_P27_ROLE", role)
      , ("LOCKSTEP_P27_DB", T.unpack (lgDb lg))
      , ("LOCKSTEP_P27_OP", T.unpack (opText o))
      , ("LOCKSTEP_P27_OWNER", owner)
      , ("LOCKSTEP_P27_DELAY_MS", show delayMs)
      , ("LOCKSTEP_P27_OUT", out)
      ]
    env = extra <> L.filter (\(k, _) -> k `L.notElem` fmap fst extra) base
  logHandle <- openFile logPath WriteMode
  (_, _, _, handle) <-
    Process.createProcess
      (Process.proc exe ["-p", "/contention worker role/"])
        { Process.env = Just env
        , Process.std_out = Process.UseHandle logHandle
        , Process.std_err = Process.UseHandle logHandle
        }
  pure (Worker handle out logPath)

-- | Waits up to 60 s for the worker to exit 0 and returns its one-line outcome.
awaitWorker :: Worker -> IO String
awaitWorker worker = do
  code <- timeout 60000000 (Process.waitForProcess (workerHandle worker))
  logText <- readFile (workerLog worker)
  case code of
    Just ExitSuccess -> do
      out <- readFile (workerOut worker)
      pure (L.takeWhile (/= '\n') out)
    other -> do
      Process.terminateProcess (workerHandle worker)
      assertFailure ("worker " <> show other <> ":\n" <> logText)

-- | Starts every worker at once, then waits for all of them.
runWorkers :: Ledger -> FilePath -> [WorkerSpec] -> IO [String]
runWorkers lg tmp specs' = do
  workers <- traverse (spawnWorker lg tmp) specs'
  traverse awaitWorker workers

drainedCount :: String -> Int
drainedCount outcome =
  case L.words outcome of
    "drained" : n : _ -> fromMaybe 0 (readInt n)
    _ -> 0

readInt :: String -> Maybe Int
readInt digits =
  if not (L.null digits) && L.all (`L.elem` ("0123456789" :: String)) digits
    then Just (L.foldl' (\acc d -> acc * 10 + fromMaybe 0 (L.elemIndex d "0123456789")) 0 digits)
    else Nothing

-- | The child side: runs the role named in the environment and writes its outcome.
workerRole :: String -> Assertion
workerRole role = do
  db <- T.pack <$> env "LOCKSTEP_P27_DB"
  o <- env "LOCKSTEP_P27_OP" >>= either (const (assertFailure "operation id")) (pure . OperationId) . parseUuid . T.pack
  owner <- T.pack <$> env "LOCKSTEP_P27_OWNER"
  delayMs <- fromMaybe 0 . readInt <$> env "LOCKSTEP_P27_DELAY_MS"
  out <- env "LOCKSTEP_P27_OUT"
  admin <- requireAdmin
  config <- databaseConfigFor admin db
  adapters <- dbAdapters admin db (T.unpack owner) delayMs
  outcome <-
    withRuntime config $ \runtime ->
      case role of
        "probe" -> either (\f -> "refused " <> T.unpack (ledgerFailureCode f)) (\i -> "probe " <> T.unpack (intentStateName (intentState i))) <$> loadIntent runtime o
        "drain" -> drain runtime (exec owner adapters) {executorTimeoutMs = 5000} (0 :: Int) (50 :: Int)
        "recover" -> outcomeText <$> recoverAndExecute runtime (exec owner adapters) {executorTimeoutMs = 5000} noExecutorFaults o
        "stall" -> do
          let
            fenced = eventually "fenced" ((> 1) . either (const 0) intentGeneration <$> loadIntent runtime o)
          outcomeText <$> executeIntent runtime (exec owner adapters) {executorLeaseSeconds = 1, executorTimeoutMs = 900} noExecutorFaults {faultAfterDispatch = fenced} o
        other -> assertFailure ("unknown role " <> other)
  writeFile out (outcome <> "\n")
 where
  env name = lookupEnv name >>= maybe (assertFailure ("missing " <> name)) pure
  drain runtime executor done budget
    | budget <= 0 = pure ("drained " <> show done <> " (budget spent)")
    | otherwise = do
        result <- executeOnce runtime executor noExecutorFaults
        case result of
          Right Nothing -> pure ("drained " <> show done)
          Right (Just _) -> drain runtime executor (done + 1) (budget - 1)
          Left _ -> drain runtime executor done (budget - 1)

outcomeText :: Either LedgerFailure RunOutcome -> String
outcomeText result =
  case result of
    Right (RanApplied r) -> "applied " <> T.unpack r
    Right (RanNotApplied r) -> "not-applied " <> T.unpack r
    Right (RanExhausted r) -> "exhausted " <> T.unpack r
    Right (RanUnknown r) -> "unknown " <> T.unpack r
    Left f -> "refused " <> T.unpack (ledgerFailureCode f)

-- Ledger helpers (as in the C-P2.5 and C-P2.6 tests) --------------------------

ok :: String -> IO (Either LedgerFailure a) -> IO a
ok what action =
  action >>= either (\failure -> assertFailure (what <> ": " <> show failure)) pure

refused :: T.Text -> IO (Either LedgerFailure a) -> Assertion
refused code action = do
  result <- action
  case result of
    Left failure -> ledgerFailureCode failure @?= code
    Right _ -> assertFailure ("expected refusal " <> T.unpack code)

immutable :: Ledger -> String -> Assertion
immutable lg statement = do
  result <- try (sql lg statement) :: IO (Either SomeException ())
  case result of
    Left e -> assertBool (statement <> ": failed, but not by the trigger: " <> show e) ("rows are immutable" `L.isInfixOf` show e)
    Right () -> assertFailure ("statement succeeded: " <> statement)

isException :: Either SomeException a -> Bool
isException =
  either (const True) (const False)

opText :: OperationId -> T.Text
opText (OperationId u) =
  uuidText u

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
