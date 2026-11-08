{-# LANGUAGE OverloadedStrings #-}

{- | C-P2.9-R1 integration regressions, against real PostgreSQL: the expiring
idempotency key (M1), activation fencing and the human carry-forward (M2,
§2.1), consistent reads and rollback (M3), abandonment and attestation (M4),
real overlap between two worker processes (M5), and the remaining findings
(M6).

The overlap case starts this test binary again as worker processes, selecting
only the "remediation worker role" case with a tasty pattern (as C-P2.7 R8).
Scripted actions here are test actions; none is a decision by the human owner.
-}
module Lockstep.RemediationTest
  ( tests
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (SomeException, throwIO, try)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
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
  , carryIntent
  , carryIntentAs
  , createTicket
  , createWorkOrder
  , decideTicket
  , decideWorkOrder
  , intentActivation
  , intentObservations
  , intentResolutions
  , ledgerFailureCode
  , loadIntent
  , noFaults
  , probeIntegrityRollback
  , recordGateEvidence
  , resolveOutcome
  , reviseTicket
  , scheduleOnce
  , showWorkOrder
  )
import Lockstep.Application.LedgerView (EffectLine (..), LedgerProjection (..), OrderLine (..), projectLedger)
import Lockstep.Application.Reconciler (ReconcileOutcome (..), Reconciliation (..), reconcileOnce)
import Lockstep.Effects.Executor (DestinationAnswer (..), EffectAdapter (..))
import Lockstep.Effects.Scripted (Application (..), ScriptStep (..), ScriptedDestination, destinationApplications, newScriptedDestination, scriptedAdapter, scriptedReconciler)
import Lockstep.Kernel.Effect
  ( ClassTerms (..)
  , EffectSpec
  , IdempotencyTerms (..)
  , Intent (..)
  , IntentRequest (..)
  , IntentState (..)
  , Lease (..)
  , LookupTerms (..)
  , OperationId (..)
  , effectSpecName
  , intentStateName
  , mkEffectKey
  , mkEffectSpec
  )
import Lockstep.Kernel.EffectView (EffectStatus (..))
import Lockstep.Kernel.Identity (TicketId, WorkOrderId (..), parseUuid, uuidText)
import Lockstep.Kernel.Profile (Approval (..), ArtifactKind (..), GateEvidence (..), VerifierKind (..), mkContentDigest)
import Lockstep.Kernel.Reconciliation (Resolution (..))
import Lockstep.Kernel.Ticket (TicketInput (..))
import Lockstep.Kernel.Transition (Command (..), Principal (..))
import Lockstep.Kernel.WorkOrder (Claim, WorkOrderInput (..), WorkOrderKind (..), WorkOrderState (..))
import Lockstep.Support.Ledger (Ledger (..), count, sql, withLedger)
import Lockstep.Support.Postgres (AdminSettings, adminExecute, databaseConfigFor, queryBool, queryInts, requireAdmin, withRuntime)

tests :: TestTree
tests =
  testGroup
    "Gate B remediation (C-P2.9-R1; real PostgreSQL)"
    [ testCase "remediation worker role (the role of a child worker process; nothing to do in the suite itself)" $ do
        role <- lookupEnv "LOCKSTEP_P29_ROLE"
        maybe (pure ()) workerRole role
    , testCase "scenario setup: five intents, restart, the expiring-key fixture, the destination tables, a child worker" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          intents <- traverse (intentOf lg) (allOps ops)
          fmap (intentStateName . intentState) intents @?= L.replicate 5 "pending"
          haltByHuman lg wo
          restartOrder lg wo
          view <- ok "show" (showWorkOrder (lgRuntime lg) wo)
          isActive (woState view) @?= True
          fixture <- newExpiring
          spec' <- specNamed "bravo-short"
          let
            adapter = expiringAdapter spec' 40 fixture
          _ <- adapterRun adapter (opBs ops) "p"
          _ <- adapterRun adapter (opBs ops) "p"
          expiringCount fixture (opBs ops) >>= (@?= 1)
          advance fixture 45
          _ <- adapterRun adapter (opBs ops) "p"
          expiringCount fixture (opBs ops) >>= (@?= 2)
          createDestination lg
          withSystemTempDirectory "lockstep-p29" $ \tmp -> do
            w <- spawnWorker lg tmp ("probe", opA ops, "w-probe")
            out <- awaitWorker w
            out @?= "probe pending"
          eventually "the engineer exists" ((== 1) <$> count lg "lockstep_engineers")
    , testCase "expiring key: past the guarantee recovery gives unknown and no second application" $
        withLedger $ \lg -> do
          (_, ops) <- activeOrder lg
          fixture <- newExpiring
          short <- specNamed "bravo-short"
          long <- specNamed "bravo"
          let
            adapters = [expiringAdapter short 40 fixture, expiringAdapter long 3600 fixture]
          crashedShort <- try (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults {faultAfterEffect = crash} (opBs ops)) :: IO (Either SomeException (Either LedgerFailure RunOutcome))
          assertBool "the crash propagates" (isException crashedShort)
          advance fixture 45
          sql lg ("UPDATE lockstep_effect_intents SET first_dispatched_at = first_dispatched_at - interval '45 seconds' WHERE operation_id = '" <> opString (opBs ops) <> "'")
          endLease lg (opBs ops)
          recovered <- ok "recover" (recoverAndExecute (lgRuntime lg) (exec "w2" adapters) noExecutorFaults (opBs ops))
          recovered @?= RanUnknown "dispatch-interrupted: idempotency key may have expired"
          expiringCount fixture (opBs ops) >>= (@?= 1)
          -- control: the destination would have applied it again
          _ <- adapterRun (expiringAdapter short 40 fixture) (opBs ops) "p=bravo-short"
          expiringCount fixture (opBs ops) >>= (@?= 2)
          intentOf lg (opBs ops) >>= (@?= IntentUnknown "dispatch-interrupted: idempotency key may have expired") . intentState
    , testCase "expiring key: inside the guarantee recovery re-dispatches the same operation id; the destination deduplicates" $
        withLedger $ \lg -> do
          (_, ops) <- activeOrder lg
          fixture <- newExpiring
          long <- specNamed "bravo"
          let
            adapters = [expiringAdapter long 3600 fixture]
          crashed <- try (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults {faultAfterEffect = crash} (opB ops))
          assertBool "the crash propagates" (isException crashed)
          endLease lg (opB ops)
          ok "recover" (recoverAndExecute (lgRuntime lg) (exec "w2" adapters) noExecutorFaults (opB ops)) >>= (@?= RanApplied "ok")
          expiringCount fixture (opB ops) >>= (@?= 1)
    , testCase "activation fencing: after a restart an earlier intent is refused, skipped and kept, until a Human carries it" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- scripted dest []
          haltByHuman lg wo
          restartOrder lg wo
          refused "activation-superseded" (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults (opA ops))
          ok "pass" (executeOnce (lgRuntime lg) (exec "w1" adapters) noExecutorFaults) >>= (@?= Nothing)
          before <- intentOf lg (opA ops)
          intentState before @?= IntentPending
          ok "activation" (intentActivation (lgRuntime lg) (opA ops)) >>= (@?= 1)
          refused "not-authorized" (carryIntentAs (lgRuntime lg) Supervisor (opA ops))
          refused "agent-assertion" (carryIntentAs (lgRuntime lg) Agent (opA ops))
          carried <- ok "carry" (carryIntent (lgRuntime lg) (opA ops))
          carried @?= before
          ok "activation" (intentActivation (lgRuntime lg) (opA ops)) >>= (@?= 2)
          ok "resolutions" (intentResolutions (lgRuntime lg) (opA ops))
            >>= (@?= [StoredResolution 0 "human-carry" "carried principal=human from-generation=1 to-generation=2" False])
          refused "carry-not-needed" (carryIntent (lgRuntime lg) (opA ops))
          ok "execute" (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults (opA ops)) >>= (@?= RanApplied "ok")
          after <- intentOf lg (opA ops)
          intentDispatches after @?= 1
          intentGeneration after @?= 1
          scriptedApplications dest (opA ops) >>= (@?= 1)
    , testCase "carry refusals: an inactive order, an unknown outcome until a retry is acknowledged, an expired key, an effect in flight" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- scripted dest [("delta", [StepHang]), ("bravo", [StepHang])]
          haltByHuman lg wo
          refused "subject-not-active" (carryIntent (lgRuntime lg) (opA ops))
          restartOrder lg wo
          -- delta: unknown, refused until a human retry acknowledges the duplication risk
          carriedD <- ok "carry delta" (carryIntent (lgRuntime lg) (opD ops))
          intentState carriedD @?= IntentPending
          ok "execute delta" (executeIntent (lgRuntime lg) (exec "w1" adapters) {executorTimeoutMs = 200} noExecutorFaults (opD ops)) >>= (@?= RanUnknown "timeout")
          restartOrder lg wo
          refused "outcome-unknown" (carryIntent (lgRuntime lg) (opD ops))
          _ <- ok "retry" (resolveOutcome (lgRuntime lg) (opD ops) 1 (RetryAcknowledgingDuplication True))
          _ <- ok "carry delta after the retry" (carryIntent (lgRuntime lg) (opD ops))
          -- bravo: dispatched before, then a human retry; its key guarantee is shifted past its end
          _ <- ok "carry bravo" (carryIntent (lgRuntime lg) (opB ops))
          ok "execute bravo" (executeIntent (lgRuntime lg) (exec "w1" adapters) {executorTimeoutMs = 200} noExecutorFaults (opB ops)) >>= (@?= RanUnknown "timeout")
          _ <- ok "retry bravo" (resolveOutcome (lgRuntime lg) (opB ops) 1 (RetryAcknowledgingDuplication True))
          sql lg ("UPDATE lockstep_effect_intents SET first_dispatched_at = first_dispatched_at - interval '4000 seconds' WHERE operation_id = '" <> opString (opB ops) <> "'")
          restartOrder lg wo
          refused "idempotency-key-expired" (carryIntent (lgRuntime lg) (opB ops))
          -- alpha: dispatched under this activation, then the order restarted
          _ <- ok "carry alpha" (carryIntent (lgRuntime lg) (opA ops))
          crashed <- try (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults {faultAfterDispatch = crash} (opA ops))
          assertBool "the crash propagates" (isException crashed)
          haltByHuman lg wo
          restartOrder lg wo
          refused "dispatched-needs-recovery" (carryIntent (lgRuntime lg) (opA ops))
          scriptedApplications dest (opA ops) >>= (@?= 0)
    , testCase "late workers cannot bypass fencing: no dispatch after a restart; a late not-applied answer leaves the intent fenced" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- scripted dest [("alpha", [StepRefuse "busy"])]
          let
            restart = haltByHuman lg wo >> restartOrder lg wo
          refused "activation-superseded" (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults {faultAfterClaim = restart} (opB ops))
          scriptedApplications dest (opB ops) >>= (@?= 0)
          _ <- ok "carry alpha" (carryIntent (lgRuntime lg) (opA ops))
          late <- ok "execute alpha" (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults {faultAfterDispatch = restart} (opA ops))
          late @?= RanNotApplied "busy"
          ok "observations" (intentObservations (lgRuntime lg) (opA ops)) >>= (@?= [StoredObservation 1 "not-applied reason=\"busy\"" True Nothing])
          refused "activation-superseded" (executeIntent (lgRuntime lg) (exec "w2" adapters) noExecutorFaults (opA ops))
          ok "pass" (executeOnce (lgRuntime lg) (exec "w2" adapters) noExecutorFaults) >>= (@?= Nothing)
          scriptedApplications dest (opA ops) >>= (@?= 0)
    , testCase "a ledger read concurrent with decisions never reports an integrity failure" $
        withLedger $ \lg -> do
          _ <- activeOrder lg
          t <- readyTicket lg
          done <- newEmptyMVar
          _ <-
            forkIO $ do
              r <- try (traverse_ (\n -> reviseTicket (lgRuntime lg) t (n + 1) ("Fix login, take " <> T.pack (show n))) [2 .. 41 :: Int]) :: IO (Either SomeException ())
              putMVar done r
          reads' <- traverse (const (projectLedger (lgRuntime lg))) [1 .. 40 :: Int]
          revised <- takeMVar done
          assertBool ("the revisions failed: " <> show revised) (either (const False) (const True) revised)
          assertBool ("a read failed: " <> show [ledgerFailureCode f | Left f <- reads']) (L.all (either (const False) (const True)) reads')
    , testCase "an integrity failure after a write rolls the write back" $
        withLedger $ \lg -> do
          before <- count lg "lockstep_decision_refusals"
          r <- probeIntegrityRollback (lgRuntime lg)
          either ledgerFailureCode (const "none") r @?= "integrity"
          count lg "lockstep_decision_refusals" >>= (@?= before)
    , testCase "abandonment halts the order and is recorded; an invalid reason is refused" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          refused "invalid-record" (abandonIntent (lgRuntime lg) (opB ops) "a\nb")
          abandoned <- ok "abandon" (abandonIntent (lgRuntime lg) (opA ops) "operator stop")
          intentState abandoned @?= IntentAbandoned "operator stop"
          haltedFor lg wo ("abandoned operation=" <> opText (opA ops))
          ok "resolutions" (intentResolutions (lgRuntime lg) (opA ops))
            >>= (@?= [StoredResolution 0 "human-abandon" "abandoned reason=\"operator stop\"" False])
          intentOf lg (opB ops) >>= \i -> intentState i @?= IntentPending
    , testCase "a human 'not applied' is ATTESTED in the projection, not BLOCKED; an invalid halt reason is refused" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- scripted dest [("bravo", [StepHang])]
          _ <- ok "execute" (executeIntent (lgRuntime lg) (exec "w1" adapters) {executorTimeoutMs = 200} noExecutorFaults (opB ops))
          _ <- ok "attest" (resolveOutcome (lgRuntime lg) (opB ops) 1 (AttestNotApplied "nothing at the destination"))
          projection <- ok "project" (projectLedger (lgRuntime lg))
          let
            lines' = [e | o <- projectionOrders projection, e <- orderLineEffects o, intentOperation (effectLineIntent e) == opB ops]
          fmap effectLineStatus lines' @?= [StatusAttested]
          (wo2, _) <- activeOrder lg
          view <- ok "show" (showWorkOrder (lgRuntime lg) wo2)
          refused "invalid-record" (decideWorkOrder (lgRuntime lg) noFaults wo2 (woRevision view) (Command Human (WoHalt "a\nb")) [])
          ok "show" (showWorkOrder (lgRuntime lg) wo2) >>= (@?= True) . isActive . woState
          haltedFor lg wo ("outcome-unknown operation=" <> opText (opB ops))
    , testCase "dispatch renews the lease; execute-once leaves a queryable recovery to reconciliation" $
        withLedger $ \lg -> do
          (_, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- scripted dest []
          leases <- newIORef []
          let
            note' = queryInts (lgAdmin lg) (lgDb lg) ("SELECT (extract(epoch from lease_until - timestamptz '2026-01-01') * 10)::integer AS v FROM lockstep_effect_intents WHERE operation_id = '" <> opString (opA ops) <> "'") >>= \v -> modifyIORef' leases (<> v)
          _ <- ok "execute" (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults {faultAfterClaim = note' >> threadDelay 1500000, faultAfterDispatch = note'} (opA ops))
          noted <- readIORef leases
          case noted of
            [claimedAt, dispatchedAt] -> assertBool ("lease not renewed: " <> show noted) (dispatchedAt >= claimedAt + 10)
            other -> assertFailure ("leases: " <> show other)
          crashed <- try (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults {faultAfterDispatch = crash} (opC ops))
          assertBool "the crash propagates" (isException crashed)
          endLease lg (opC ops)
          pass <- ok "pass" (executeOnce (lgRuntime lg) (exec "w2" adapters) noExecutorFaults)
          assertBool ("execute-once took the queryable recovery: " <> show pass) (fmap fst pass /= Just (opC ops))
          intentOf lg (opC ops) >>= (@?= "dispatched") . intentStateName . intentState
          charlie <- specNamed "charlie"
          reconciler <- scriptedReconciler charlie dest []
          ok "reconcile" (reconcileOnce (lgRuntime lg) (Reconciliation 2000 [reconciler])) >>= (@?= Just (opC ops, ReconciledNotApplied "lookup: not found"))
    , testCase "two worker processes really overlap: the second is refused while the first's claim is active; one application" $
        withLedger $ \lg -> do
          (_, ops) <- activeOrder lg
          createDestination lg
          (contended, held) <- withSystemTempDirectory "lockstep-p29" $ \tmp -> do
            holder <- spawnWorker lg tmp ("hold", opA ops, "w-hold")
            eventually "the first worker holds the claim" $ do
              i <- intentOf lg (opA ops)
              pure $
                case intentState i of
                  IntentClaimed l -> leaseOwner l == "w-hold"
                  _ -> False
            contender <- spawnWorker lg tmp ("contend", opA ops, "w-contend")
            out2 <- awaitWorker contender
            stillHeld <- intentOf lg (opA ops)
            active <- queryBool (lgAdmin lg) (lgDb lg) ("SELECT lease_until > now() AS v FROM lockstep_effect_intents WHERE operation_id = '" <> opString (opA ops) <> "'")
            assertBool "the first claim's lease is still active" active
            adminExecute (lgAdmin lg) (T.unpack (lgDb lg)) "INSERT INTO p29_release DEFAULT VALUES"
            out1 <- awaitWorker holder
            pure ((out2, intentState stillHeld), out1)
          fst contended @?= "refused claim-held"
          case snd contended of
            IntentClaimed l -> (leaseOwner l, leaseGeneration l) @?= ("w-hold", 1)
            other -> assertFailure ("not held during the contention: " <> show other)
          held @?= "applied ok"
          count lg ("p29_applications WHERE operation_id = '" <> opString (opA ops) <> "'") >>= (@?= 1)
    ]

-- Scenario -------------------------------------------------------------------

data Ops
  = Ops
  { opA :: OperationId
  , opB :: OperationId
  , opBs :: OperationId
  , opC :: OperationId
  , opD :: OperationId
  }

allOps :: Ops -> [OperationId]
allOps ops =
  [opA ops, opB ops, opBs ops, opC ops, opD ops]

specTable :: [(T.Text, ClassTerms, Int)]
specTable =
  [ ("alpha", TermsRepeatable, 1)
  , ("bravo", TermsIdempotent (IdempotencyTerms 3600 True), 1)
  , ("bravo-short", TermsIdempotent (IdempotencyTerms 40 True), 1)
  , ("charlie", TermsQueryable (LookupTerms True True), 1)
  , ("delta", TermsUnqueryable, 0)
  ]

specNamed :: T.Text -> IO EffectSpec
specNamed name =
  case L.find (\(n, _, _) -> n == name) specTable of
    Just (n, t, b) -> either (assertFailure . show) pure (mkEffectSpec n t b)
    Nothing -> assertFailure ("no spec " <> T.unpack name)

specs :: IO [EffectSpec]
specs =
  traverse (\(n, _, _) -> specNamed n) specTable

scripted :: ScriptedDestination -> [(T.Text, [ScriptStep])] -> IO [EffectAdapter]
scripted dest scripts =
  specs >>= traverse (\s -> scriptedAdapter s dest (fromMaybe [] (L.lookup (effectSpecName s) scripts)))

scriptedApplications :: ScriptedDestination -> OperationId -> IO Int
scriptedApplications dest o =
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
      ( \(name, _, _) -> do
          s <- specNamed name
          k <- either (assertFailure . show) pure (mkEffectKey name)
          pure (IntentRequest k s ("p=" <> name))
      )
      specTable
  started <- ok "start" (decideWorkOrder (lgRuntime lg) noFaults wo 3 (Command Supervisor (WoStart c)) requests)
  case receiptOperations started of
    [a, b, bs, c', d] -> pure (wo, Ops a b bs c' d)
    other -> assertFailure ("expected five intents: " <> show other)

scheduled :: Ledger -> WorkOrderId -> IO Claim
scheduled lg wo = do
  receipt <- ok "schedule" (scheduleOnce (lgRuntime lg))
  case scheduleClaimed receipt of
    Just (claimed, c) | claimed == wo -> pure c
    other -> assertFailure ("not claimed: " <> show other <> "\n" <> T.unpack (scheduleRendering receipt))

-- | A halted order requeued by a Human, claimed again and started without new intents.
restartOrder :: Ledger -> WorkOrderId -> Assertion
restartOrder lg wo = do
  view <- ok "show" (showWorkOrder (lgRuntime lg) wo)
  case woState view of
    Halted _ -> pure ()
    _ -> haltByHuman lg wo
  view' <- ok "show" (showWorkOrder (lgRuntime lg) wo)
  _ <- ok "requeue" (decideWorkOrder (lgRuntime lg) noFaults wo (woRevision view') (Command Human WoRequeue) [])
  c <- scheduled lg wo
  claimedView <- ok "show" (showWorkOrder (lgRuntime lg) wo)
  _ <- ok "start" (decideWorkOrder (lgRuntime lg) noFaults wo (woRevision claimedView) (Command Supervisor (WoStart c)) [])
  pure ()

haltByHuman :: Ledger -> WorkOrderId -> Assertion
haltByHuman lg wo = do
  view <- ok "show" (showWorkOrder (lgRuntime lg) wo)
  case woState view of
    Halted _ -> pure ()
    _ -> () <$ ok "halt" (decideWorkOrder (lgRuntime lg) noFaults wo (woRevision view) (Command Human (WoHalt "operator stop")) [])

isActive :: WorkOrderState -> Bool
isActive state =
  case state of
    Active _ -> True
    _ -> False

haltedFor :: Ledger -> WorkOrderId -> T.Text -> Assertion
haltedFor lg wo reason = do
  view <- ok "show" (showWorkOrder (lgRuntime lg) wo)
  woState view @?= Halted reason

endLease :: Ledger -> OperationId -> Assertion
endLease lg o =
  sql lg ("UPDATE lockstep_effect_intents SET lease_until = now() - interval '1 second' WHERE operation_id = '" <> opString o <> "'")

intentOf :: Ledger -> OperationId -> IO Intent
intentOf lg o =
  ok "load intent" (loadIntent (lgRuntime lg) o)

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

-- The expiring-key destination fixture (M1) ----------------------------------

{- | An idempotent destination whose keys really expire: a repeat of an
operation id within the lifetime answers applied without applying; after it,
the destination applies again. Its clock is advanced by the test.
-}
data Expiring
  = Expiring
  { expiringClock :: IORef Integer
  , expiringKeys :: IORef [(OperationId, Integer)]
  , expiringApplied :: IORef [OperationId]
  }

newExpiring :: IO Expiring
newExpiring =
  Expiring <$> newIORef 0 <*> newIORef [] <*> newIORef []

advance :: Expiring -> Integer -> IO ()
advance fixture seconds =
  modifyIORef' (expiringClock fixture) (+ seconds)

expiringAdapter :: EffectSpec -> Integer -> Expiring -> EffectAdapter
expiringAdapter s lifetime fixture =
  EffectAdapter s $ \o _ -> do
    now <- readIORef (expiringClock fixture)
    keys <- readIORef (expiringKeys fixture)
    case L.lookup o keys of
      Just keyedAt | now < keyedAt + lifetime -> pure (AnswerApplied "ok")
      _ -> do
        modifyIORef' (expiringKeys fixture) ((o, now) :)
        modifyIORef' (expiringApplied fixture) (o :)
        pure (AnswerApplied "ok")

expiringCount :: Expiring -> OperationId -> IO Int
expiringCount fixture o =
  L.length . L.filter (== o) <$> readIORef (expiringApplied fixture)

-- The external destination for worker processes ------------------------------

createDestination :: Ledger -> Assertion
createDestination lg = do
  sql lg "CREATE TABLE p29_applications (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, operation_id uuid NOT NULL)"
  sql lg "CREATE TABLE p29_release (id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY)"

dbAdapters :: AdminSettings -> T.Text -> IO [EffectAdapter]
dbAdapters admin db =
  fmap (fmap adapter) specs
 where
  adapter s =
    EffectAdapter s $ \o _ -> do
      adminExecute admin (T.unpack db) ("INSERT INTO p29_applications (operation_id) VALUES ('" <> opString o <> "')")
      pure (AnswerApplied "ok")

-- Worker processes -----------------------------------------------------------

type WorkerSpec = (String, OperationId, String)

data Worker
  = Worker
  { workerHandle :: Process.ProcessHandle
  , workerOut :: FilePath
  , workerLog :: FilePath
  }

spawnWorker :: Ledger -> FilePath -> WorkerSpec -> IO Worker
spawnWorker lg tmp (role, o, owner) = do
  exe <- getExecutablePath
  base <- getEnvironment
  let
    out = tmp <> "/" <> owner <> ".out"
    logPath = tmp <> "/" <> owner <> ".log"
    extra =
      [ ("LOCKSTEP_P29_ROLE", role)
      , ("LOCKSTEP_P29_DB", T.unpack (lgDb lg))
      , ("LOCKSTEP_P29_OP", opString o)
      , ("LOCKSTEP_P29_OWNER", owner)
      , ("LOCKSTEP_P29_OUT", out)
      ]
    env = extra <> L.filter (\(k, _) -> k `L.notElem` fmap fst extra) base
  logHandle <- openFile logPath WriteMode
  (_, _, _, handle) <-
    Process.createProcess
      (Process.proc exe ["-p", "/remediation worker role/"])
        { Process.env = Just env
        , Process.std_out = Process.UseHandle logHandle
        , Process.std_err = Process.UseHandle logHandle
        }
  pure (Worker handle out logPath)

awaitWorker :: Worker -> IO String
awaitWorker worker = do
  code <- timeout 90000000 (Process.waitForProcess (workerHandle worker))
  logText <- readFile (workerLog worker)
  case code of
    Just ExitSuccess -> L.takeWhile (/= '\n') <$> readFile (workerOut worker)
    other -> do
      Process.terminateProcess (workerHandle worker)
      assertFailure ("worker " <> show other <> ":\n" <> logText)

-- | The child side: runs the role named in the environment and writes its outcome.
workerRole :: String -> Assertion
workerRole role = do
  db <- T.pack <$> env "LOCKSTEP_P29_DB"
  o <- env "LOCKSTEP_P29_OP" >>= either (const (assertFailure "operation id")) (pure . OperationId) . parseUuid . T.pack
  owner <- T.pack <$> env "LOCKSTEP_P29_OWNER"
  out <- env "LOCKSTEP_P29_OUT"
  admin <- requireAdmin
  config <- databaseConfigFor admin db
  adapters <- dbAdapters admin db
  outcome <-
    withRuntime config $ \runtime ->
      case role of
        "probe" -> either (\f -> "refused " <> T.unpack (ledgerFailureCode f)) (\i -> "probe " <> T.unpack (intentStateName (intentState i))) <$> loadIntent runtime o
        "hold" -> do
          let
            released = do
              n <- queryInts admin db "SELECT count(*)::integer AS v FROM p29_release"
              pure (n /= [0])
            hold = waitFor 600 released
          outcomeText <$> executeIntent runtime (exec owner adapters) noExecutorFaults {faultAfterClaim = hold} o
        "contend" -> outcomeText <$> executeIntent runtime (exec owner adapters) noExecutorFaults o
        other -> assertFailure ("unknown role " <> other)
  writeFile out (outcome <> "\n")
 where
  env name = lookupEnv name >>= maybe (assertFailure ("missing " <> name)) pure
  waitFor n check
    | n <= (0 :: Int) = assertFailure "never released"
    | otherwise = do
        done <- check
        if done then pure () else threadDelay 100000 >> waitFor (n - 1) check

outcomeText :: Either LedgerFailure RunOutcome -> String
outcomeText result =
  case result of
    Right (RanApplied r) -> "applied " <> T.unpack r
    Right (RanNotApplied r) -> "not-applied " <> T.unpack r
    Right (RanExhausted r) -> "exhausted " <> T.unpack r
    Right (RanUnknown r) -> "unknown " <> T.unpack r
    Left f -> "refused " <> T.unpack (ledgerFailureCode f)

-- Ledger helpers -------------------------------------------------------------

ok :: String -> IO (Either LedgerFailure a) -> IO a
ok what action =
  action >>= either (\failure -> assertFailure (what <> ": " <> show failure)) pure

refused :: T.Text -> IO (Either LedgerFailure a) -> Assertion
refused code action = do
  result <- action
  case result of
    Left failure -> ledgerFailureCode failure @?= code
    Right _ -> assertFailure ("expected refusal " <> T.unpack code)

isException :: Either SomeException a -> Bool
isException =
  either (const True) (const False)

opText :: OperationId -> T.Text
opText (OperationId u) =
  uuidText u

opString :: OperationId -> String
opString =
  T.unpack . opText

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
