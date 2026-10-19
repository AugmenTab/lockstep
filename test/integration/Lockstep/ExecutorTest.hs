{-# LANGUAGE OverloadedStrings #-}

{- | C-P2.6 integration: the typed executor, crash windows and restart
recovery, against real PostgreSQL and scripted in-process destinations.
-}
module Lockstep.ExecutorTest
  ( tests
  ) where

import Control.Exception (SomeException, throwIO, try)
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import System.IO.Error (userError)
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
  , StoredRecovery (..)
  , WorkOrderView (..)
  , abandonIntent
  , claimIntent
  , createTicket
  , createWorkOrder
  , decideTicket
  , decideWorkOrder
  , intentObservations
  , intentRecoveries
  , ledgerFailureCode
  , loadIntent
  , noFaults
  , recordGateEvidence
  , recoverDispatched
  , recoverableIntents
  , runnableIntents
  , scheduleOnce
  , showWorkOrder
  )
import Lockstep.Effects.Executor (EffectAdapter)
import Lockstep.Effects.Scripted
  ( Application (..)
  , ScriptStep (..)
  , ScriptedDestination
  , destinationApplications
  , newScriptedDestination
  , scriptedAdapter
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
  , mkEffectKey
  , mkEffectSpec
  )
import Lockstep.Kernel.Identity (TicketId, WorkOrderId (..), uuidFromWords, uuidText)
import Lockstep.Kernel.Profile (Approval (..), ArtifactKind (..), GateEvidence (..), VerifierKind (..), mkContentDigest)
import Lockstep.Kernel.Ticket (TicketInput (..))
import Lockstep.Kernel.Transition (Command (..), Principal (..))
import Lockstep.Kernel.WorkOrder (WorkOrderInput (..), WorkOrderKind (..), WorkOrderState (..))
import Lockstep.Support.Ledger (Ledger (..), count, queryTexts, sql, withLedger)

tests :: TestTree
tests =
  testGroup
    "Typed executor and dispatch recovery (C-P2.6; real PostgreSQL)"
    [ testCase "scenario setup: an active order with one intent of each class, through the real ledger" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          intents <- traverse (intentOf lg) (allOps ops)
          fmap (intentStateName' . intentState) intents @?= L.replicate 4 "pending"
          fmap intentGeneration intents @?= [0, 0, 0, 0]
          -- the lease-ending SQL, checked with the real C-P2.5 claim
          _ <- ok "claim" (claimIntent (lgRuntime lg) "w1" 60 (opA ops))
          refused "claim-held" (claimIntent (lgRuntime lg) "w2" 60 (opA ops))
          endLease lg (opA ops)
          again <- ok "reclaim" (claimIntent (lgRuntime lg) "w2" 60 (opA ops))
          intentGeneration again @?= 2
          -- a second order can be started once the first is halted; the halt-event query
          haltByHuman lg wo
          view1 <- ok "show" (showWorkOrder (lgRuntime lg) wo)
          woState view1 @?= Halted "operator stop"
          lastEvent lg wo >>= (@?= "human halt reason=\"operator stop\"")
          (wo2, ops2) <- activeOrder lg
          assertBool "a new order" (wo2 /= wo)
          view <- ok "show" (showWorkOrder (lgRuntime lg) wo2)
          isActive (woState view) @?= True
          intents2 <- traverse (intentOf lg) (allOps ops2)
          fmap (intentStateName' . intentState) intents2 @?= L.replicate 4 "pending"
          count lg "lockstep_effect_intents" >>= (@?= 8)
          -- the remaining helpers: adapters for every spec, the marker check, the trigger check
          dest <- newScriptedDestination
          adapters <- allAdapters dest [("alpha", [StepHang])]
          L.length adapters @?= 4
          markerHolds lg dest
          applications dest (opA ops2) >>= (@?= 0)
          immutable lg "UPDATE lockstep_events SET recorded_at = recorded_at"
    , testCase "each class applied: settled, generation 1, one dispatch, one application" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- allAdapters dest []
          traverse_
            ( \o -> do
                result <- ok "execute" (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults o)
                result @?= RanApplied "ok"
                i <- intentOf lg o
                intentState i @?= IntentSettled (SettledApplied "ok")
                intentGeneration i @?= 1
                intentDispatches i @?= 1
                observations <- ok "observations" (intentObservations (lgRuntime lg) o)
                observations @?= [StoredObservation 1 "applied result=\"ok\"" True Nothing]
                applications dest o >>= (@?= 1)
            )
            (allOps ops)
          view <- ok "show" (showWorkOrder (lgRuntime lg) wo)
          isActive (woState view) @?= True
          markerHolds lg dest
    , testCase "refusals before any write: no adapter, adapter mismatch, invalid executor, unknown intent" $
        withLedger $ \lg -> do
          (_, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- allAdapters dest []
          refused "no-adapter" (executeIntent (lgRuntime lg) (exec "w1" []) noExecutorFaults (opA ops))
          wrong <- spec "alpha" TermsUnqueryable 0
          mismatched <- scriptedAdapter wrong dest []
          refused "adapter-mismatch" (executeIntent (lgRuntime lg) (exec "w1" [mismatched]) noExecutorFaults (opA ops))
          refused "invalid-record" (executeIntent (lgRuntime lg) (exec "w1" adapters) {executorLeaseSeconds = 0} noExecutorFaults (opA ops))
          refused "invalid-record" (executeIntent (lgRuntime lg) (exec "w1" adapters) {executorLeaseSeconds = 1, executorTimeoutMs = 1000} noExecutorFaults (opA ops))
          refused "invalid-record" (executeIntent (lgRuntime lg) (exec "" adapters) noExecutorFaults (opA ops))
          refused "unknown-intent" (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults (OperationId (uuidFromWords 9 9)))
          i <- intentOf lg (opA ops)
          intentState i @?= IntentPending
          intentGeneration i @?= 0
          destinationApplications dest >>= (@?= [])
    , testCase "an order that is not active executes nothing, even when it halts after the claim" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- allAdapters dest []
          haltByHuman lg wo
          refused "subject-not-active" (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults (opA ops))
          i <- intentOf lg (opA ops)
          intentState i @?= IntentPending
          (wo2, ops2) <- activeOrder lg
          let
            faults = noExecutorFaults {faultAfterClaim = haltByHuman lg wo2}
          refused "subject-not-active" (executeIntent (lgRuntime lg) (exec "w1" adapters) faults (opA ops2))
          i2 <- intentOf lg (opA ops2)
          intentStateName' (intentState i2) @?= "claimed"
          intentDispatches i2 @?= 0
          destinationApplications dest >>= (@?= [])
    , testCase "crash before dispatch: claimed, nothing applied; reclaimed after the lease and applied once" $
        withLedger $ \lg -> do
          (_, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- allAdapters dest []
          crashed <- try (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults {faultAfterClaim = crash} (opA ops))
          assertBool "the crash propagates" (isException crashed)
          i <- intentOf lg (opA ops)
          intentStateName' (intentState i) @?= "claimed"
          intentDispatches i @?= 0
          destinationApplications dest >>= (@?= [])
          ok "recoverable" (recoverableIntents (lgRuntime lg)) >>= (@?= [])
          refused "claim-held" (executeIntent (lgRuntime lg) (exec "w2" adapters) noExecutorFaults (opA ops))
          endLease lg (opA ops)
          runnable <- ok "runnable" (runnableIntents (lgRuntime lg))
          assertBool "runnable after the lease ends" (opA ops `L.elem` runnable)
          result <- ok "execute" (executeIntent (lgRuntime lg) (exec "w2" adapters) noExecutorFaults (opA ops))
          result @?= RanApplied "ok"
          after <- intentOf lg (opA ops)
          intentGeneration after @?= 2
          intentDispatches after @?= 1
          applications dest (opA ops) >>= (@?= 1)
          markerHolds lg dest
    , testCase "crash after dispatch, repeatable: recovery redispatches under generation 2 and applies once" $
        withLedger $ \lg -> do
          (_, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- allAdapters dest []
          crashed <- try (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults {faultAfterDispatch = crash} (opA ops))
          assertBool "the crash propagates" (isException crashed)
          i <- intentOf lg (opA ops)
          intentStateName' (intentState i) @?= "dispatched"
          intentDispatches i @?= 1
          destinationApplications dest >>= (@?= [])
          refused "dispatched-needs-recovery" (executeIntent (lgRuntime lg) (exec "w2" adapters) noExecutorFaults (opA ops))
          refused "lease-active" (recoverAndExecute (lgRuntime lg) (exec "w2" adapters) noExecutorFaults (opA ops))
          ok "recoverable" (recoverableIntents (lgRuntime lg)) >>= (@?= [])
          endLease lg (opA ops)
          ok "recoverable" (recoverableIntents (lgRuntime lg)) >>= (@?= [opA ops])
          result <- ok "recover" (recoverAndExecute (lgRuntime lg) (exec "w2" adapters) noExecutorFaults (opA ops))
          result @?= RanApplied "ok"
          after <- intentOf lg (opA ops)
          intentGeneration after @?= 2
          intentDispatches after @?= 2
          applications dest (opA ops) >>= (@?= 1)
          records <- ok "recoveries" (intentRecoveries (lgRuntime lg) (opA ops))
          records @?= [StoredRecovery 1 "redispatch generation=2 owner=\"w2\""]
          markerHolds lg dest
    , testCase "crash after the effect, repeatable: recovery re-executes (class A permits it)" $
        withLedger $ \lg -> do
          (_, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- allAdapters dest []
          crashed <- try (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults {faultAfterEffect = crash} (opA ops))
          assertBool "the crash propagates" (isException crashed)
          applications dest (opA ops) >>= (@?= 1)
          ok "observations" (intentObservations (lgRuntime lg) (opA ops)) >>= (@?= [])
          endLease lg (opA ops)
          result <- ok "recover" (recoverAndExecute (lgRuntime lg) (exec "w2" adapters) noExecutorFaults (opA ops))
          result @?= RanApplied "ok"
          applications dest (opA ops) >>= (@?= 2)
          after <- intentOf lg (opA ops)
          intentState after @?= IntentSettled (SettledApplied "ok")
          markerHolds lg dest
    , testCase "crash after the effect, idempotent: the same operation id is deduplicated, one application" $
        withLedger $ \lg -> do
          (_, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- allAdapters dest [("bravo", [StepApply "first", StepApply "second"])]
          crashed <- try (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults {faultAfterEffect = crash} (opB ops))
          assertBool "the crash propagates" (isException crashed)
          applications dest (opB ops) >>= (@?= 1)
          endLease lg (opB ops)
          result <- ok "recover" (recoverAndExecute (lgRuntime lg) (exec "w2" adapters) noExecutorFaults (opB ops))
          result @?= RanApplied "first"
          applications dest (opB ops) >>= (@?= 1)
          after <- intentOf lg (opB ops)
          intentState after @?= IntentSettled (SettledApplied "first")
          intentGeneration after @?= 2
          markerHolds lg dest
    , testCase "crash after the effect, queryable and unqueryable: unknown, the order halted, never re-executed" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- allAdapters dest []
          crashed <- try (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults {faultAfterEffect = crash} (opC ops))
          assertBool "the crash propagates" (isException crashed)
          endLease lg (opC ops)
          result <- ok "recover" (recoverAndExecute (lgRuntime lg) (exec "w2" adapters) noExecutorFaults (opC ops))
          result @?= RanUnknown "dispatch-interrupted: lookup not available"
          haltedFor lg wo ("outcome-unknown operation=" <> opText (opC ops))
          (wo2, ops2) <- activeOrder lg
          crashed2 <- try (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults {faultAfterEffect = crash} (opD ops2))
          assertBool "the crash propagates" (isException crashed2)
          endLease lg (opD ops2)
          result2 <- ok "recover" (recoverAndExecute (lgRuntime lg) (exec "w2" adapters) noExecutorFaults (opD ops2))
          result2 @?= RanUnknown "dispatch-interrupted: unqueryable effect"
          haltedFor lg wo2 ("outcome-unknown operation=" <> opText (opD ops2))
          refused "outcome-unknown" (executeIntent (lgRuntime lg) (exec "w3" adapters) noExecutorFaults (opD ops2))
          refused "nothing-to-recover" (recoverAndExecute (lgRuntime lg) (exec "w3" adapters) noExecutorFaults (opD ops2))
          ok "pass" (executeOnce (lgRuntime lg) (exec "w3" adapters) noExecutorFaults) >>= (@?= Nothing)
          applications dest (opC ops) >>= (@?= 1)
          applications dest (opD ops2) >>= (@?= 1)
          records <- ok "recoveries" (intentRecoveries (lgRuntime lg) (opD ops2))
          records @?= [StoredRecovery 1 "unknown reason=\"dispatch-interrupted: unqueryable effect\""]
          markerHolds lg dest
    , testCase "unqueryable crash after dispatch: unknown and never executed" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- allAdapters dest []
          crashed <- try (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults {faultAfterDispatch = crash} (opD ops))
          assertBool "the crash propagates" (isException crashed)
          endLease lg (opD ops)
          result <- ok "recover" (recoverAndExecute (lgRuntime lg) (exec "w2" adapters) noExecutorFaults (opD ops))
          result @?= RanUnknown "dispatch-interrupted: unqueryable effect"
          i <- intentOf lg (opD ops)
          intentState i @?= IntentUnknown "dispatch-interrupted: unqueryable effect"
          haltedFor lg wo ("outcome-unknown operation=" <> opText (opD ops))
          destinationApplications dest >>= (@?= [])
    , testCase "ambiguous answers are unknown, recorded, and halt the order" $
        withLedger $ \lg -> do
          dest <- newScriptedDestination
          let
            ambiguous pick name steps expected appliedCount = do
              (wo, ops) <- activeOrder lg
              adapters <- allAdapters dest [(name, steps)]
              let
                o = pick ops
              result <- ok "execute" (executeIntent (lgRuntime lg) (exec "w1" adapters) {executorTimeoutMs = 200} noExecutorFaults o)
              result @?= RanUnknown expected
              observations <- ok "observations" (intentObservations (lgRuntime lg) o)
              observations @?= [StoredObservation 1 ("no-answer reason=\"" <> expected <> "\"") True Nothing]
              haltedFor lg wo ("outcome-unknown operation=" <> opText o)
              applications dest o >>= (@?= appliedCount)
          ambiguous opA "alpha" [StepHang] "timeout" 0
          ok "runnable" (runnableIntents (lgRuntime lg)) >>= (@?= [])
          ambiguous opD "delta" [StepApplyThenHang "late"] "timeout" 1
          ambiguous opA "alpha" [StepFail] "adapter-failed" 0
          ambiguous opB "bravo" [StepMalformed] "malformed-answer" 1
          markerHolds lg dest
    , testCase "not applied: retried within the budget; budget 0 settles not applied and halts" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- allAdapters dest [("alpha", [StepRefuse "busy"]), ("delta", [StepRefuse "busy"])]
          first <- ok "execute" (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults (opA ops))
          first @?= RanNotApplied "busy"
          i <- intentOf lg (opA ops)
          intentState i @?= IntentNotApplied "busy"
          runnable <- ok "runnable" (runnableIntents (lgRuntime lg))
          assertBool "a retry is left" (opA ops `L.elem` runnable)
          second <- ok "execute" (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults (opA ops))
          second @?= RanApplied "ok"
          after <- intentOf lg (opA ops)
          intentGeneration after @?= 2
          intentDispatches after @?= 2
          applications dest (opA ops) >>= (@?= 1)
          exhausted <- ok "execute" (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults (opD ops))
          exhausted @?= RanExhausted "busy"
          d <- intentOf lg (opD ops)
          intentState d @?= IntentSettled (SettledNotApplied "busy")
          haltedFor lg wo ("retries-exhausted operation=" <> opText (opD ops))
          markerHolds lg dest
    , testCase "duplicate claim: a second executor is refused claim-held and nothing runs twice" $
        withLedger $ \lg -> do
          (_, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- allAdapters dest []
          let
            second = refused "claim-held" (executeIntent (lgRuntime lg) (exec "w2" adapters) noExecutorFaults (opB ops))
          result <- ok "execute" (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults {faultAfterClaim = second} (opB ops))
          result @?= RanApplied "ok"
          applications dest (opB ops) >>= (@?= 1)
          refused "already-settled" (executeIntent (lgRuntime lg) (exec "w3" adapters) noExecutorFaults (opB ops))
          applications dest (opB ops) >>= (@?= 1)
          markerHolds lg dest
    , testCase "delayed worker: fenced out after a recovery, its observation kept as evidence" $
        withLedger $ \lg -> do
          (_, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- allAdapters dest []
          let
            overtaken = do
              endLease lg (opA ops)
              recovered <- ok "recover" (recoverDispatched (lgRuntime lg) "w2" 60 (opA ops))
              intentGeneration recovered @?= 2
          refused "stale-claim" (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults {faultAfterDispatch = overtaken} (opA ops))
          applications dest (opA ops) >>= (@?= 1)
          observations <- ok "observations" (intentObservations (lgRuntime lg) (opA ops))
          observations @?= [StoredObservation 1 "applied result=\"ok\"" False (Just "stale-claim")]
          i <- intentOf lg (opA ops)
          intentStateName' (intentState i) @?= "claimed"
          intentGeneration i @?= 2
          intentDispatches i @?= 1
          markerHolds lg dest
    , testCase "abandoned mid-flight: the applied observation is kept, refused already-settled" $
        withLedger $ \lg -> do
          (_, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- allAdapters dest []
          let
            abandon = () <$ ok "abandon" (abandonIntent (lgRuntime lg) (opA ops) "operator stop")
          refused "already-settled" (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults {faultAfterEffect = abandon} (opA ops))
          observations <- ok "observations" (intentObservations (lgRuntime lg) (opA ops))
          observations @?= [StoredObservation 1 "applied result=\"ok\"" False (Just "already-settled")]
          i <- intentOf lg (opA ops)
          intentState i @?= IntentAbandoned "operator stop"
          applications dest (opA ops) >>= (@?= 1)
    , testCase "restart pass: recover first, then execute, then nothing without an adapter" $
        withLedger $ \lg -> do
          (_, ops) <- activeOrder lg
          dest <- newScriptedDestination
          all' <- allAdapters dest []
          crashed <- try (executeIntent (lgRuntime lg) (exec "w1" all') noExecutorFaults {faultAfterDispatch = crash} (opA ops))
          assertBool "the crash propagates" (isException crashed)
          endLease lg (opA ops)
          sa <- spec "alpha" TermsRepeatable 1
          sb <- spec "bravo" idempotentTerms 1
          a <- scriptedAdapter sa dest []
          b <- scriptedAdapter sb dest []
          let
            restarted = exec "w2" [a, b]
          p1 <- ok "pass 1" (executeOnce (lgRuntime lg) restarted noExecutorFaults)
          p1 @?= Just (opA ops, RanApplied "ok")
          p2 <- ok "pass 2" (executeOnce (lgRuntime lg) restarted noExecutorFaults)
          p2 @?= Just (opB ops, RanApplied "ok")
          p3 <- ok "pass 3" (executeOnce (lgRuntime lg) restarted noExecutorFaults)
          p3 @?= Nothing
          rest <- traverse (intentOf lg) [opC ops, opD ops]
          fmap intentState rest @?= [IntentPending, IntentPending]
          markerHolds lg dest
    , testCase "recovery records are immutable" $
        withLedger $ \lg -> do
          (_, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- allAdapters dest []
          crashed <- try (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults {faultAfterDispatch = crash} (opA ops))
          assertBool "the crash propagates" (isException crashed)
          endLease lg (opA ops)
          _ <- ok "recover" (recoverAndExecute (lgRuntime lg) (exec "w2" adapters) noExecutorFaults (opA ops))
          count lg "lockstep_effect_recoveries" >>= (@?= 1)
          immutable lg "UPDATE lockstep_effect_recoveries SET recorded_at = recorded_at"
          immutable lg "DELETE FROM lockstep_effect_recoveries"
          immutable lg "TRUNCATE lockstep_effect_recoveries"
    ]

-- Scenario -------------------------------------------------------------------

data Ops
  = Ops
  { opA :: OperationId
  , opB :: OperationId
  , opC :: OperationId
  , opD :: OperationId
  }

allOps :: Ops -> [OperationId]
allOps ops =
  [opA ops, opB ops, opC ops, opD ops]

idempotentTerms :: ClassTerms
idempotentTerms =
  TermsIdempotent (IdempotencyTerms 86400 True)

-- | The four specs, by name: alpha (repeatable, 1), bravo (idempotent, 1), charlie (queryable, 1), delta (unqueryable, 0).
specTable :: [(T.Text, ClassTerms, Int)]
specTable =
  [ ("alpha", TermsRepeatable, 1)
  , ("bravo", idempotentTerms, 1)
  , ("charlie", TermsQueryable (LookupTerms True True), 1)
  , ("delta", TermsUnqueryable, 0)
  ]

spec :: T.Text -> ClassTerms -> Int -> IO EffectSpec
spec name terms budget =
  either (assertFailure . show) pure (mkEffectSpec name terms budget)

-- | One scripted adapter per spec, over one destination; the scripts default to [].
allAdapters :: ScriptedDestination -> [(T.Text, [ScriptStep])] -> IO [EffectAdapter]
allAdapters dest scripts =
  traverse
    ( \(name, terms, budget) -> do
        s <- spec name terms budget
        scriptedAdapter s dest (fromMaybe [] (L.lookup name scripts))
    )
    specTable

exec :: T.Text -> [EffectAdapter] -> Executor
exec owner adapters =
  Executor {executorOwner = owner, executorLeaseSeconds = 60, executorTimeoutMs = 2000, executorAdapters = adapters}

crash :: IO ()
crash =
  throwIO (userError "the worker died here")

{- | Starts the next order for alice: a new ready Ticket, its order with
evidence, claimed by the scheduler and started by the Supervisor with one
intent per spec (revision 4).
-}
activeOrder :: Ledger -> IO (WorkOrderId, Ops)
activeOrder lg = do
  t <- readyTicket lg
  wo <- ok "create work order" (createWorkOrder (lgRuntime lg) (order t))
  evidence lg wo
  receipt <- ok "schedule" (scheduleOnce (lgRuntime lg))
  c <- case scheduleClaimed receipt of
    Just (claimed, c) | claimed == wo -> pure c
    other -> assertFailure ("not claimed: " <> show other <> "\n" <> T.unpack (scheduleRendering receipt))
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
    [a, b, c', d] -> pure (wo, Ops a b c' d)
    other -> assertFailure ("expected four intents: " <> show other)

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

-- | The order is halted with the reason, by the Supervisor's halt event (X6).
haltedFor :: Ledger -> WorkOrderId -> T.Text -> Assertion
haltedFor lg wo reason = do
  view <- ok "show" (showWorkOrder (lgRuntime lg) wo)
  woState view @?= Halted reason
  lastEvent lg wo >>= (@?= "supervisor halt reason=\"" <> reason <> "\"")

-- | The order's last event: principal and canonical command.
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

intentStateName' :: IntentState -> T.Text
intentStateName' state =
  case state of
    IntentPending -> "pending"
    IntentClaimed _ -> "claimed"
    IntentDispatched _ -> "dispatched"
    IntentApplied _ -> "confirmed-applied"
    IntentNotApplied _ -> "confirmed-not-applied"
    IntentUnknown _ -> "outcome-unknown"
    IntentSettled _ -> "settled"
    IntentAbandoned _ -> "abandoned"

applications :: ScriptedDestination -> OperationId -> IO Int
applications dest o =
  L.length . L.filter ((== o) . appliedOperation) <$> destinationApplications dest

-- | X5: every application belongs to an intent with at least one committed dispatch.
markerHolds :: Ledger -> ScriptedDestination -> Assertion
markerHolds lg dest = do
  applied <- destinationApplications dest
  traverse_
    ( \a -> do
        i <- intentOf lg (appliedOperation a)
        assertBool ("an application without a dispatch marker: " <> show (appliedOperation a)) (intentDispatches i >= 1)
    )
    applied

-- Ledger helpers (as in the C-P2.5 tests) ------------------------------------

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
