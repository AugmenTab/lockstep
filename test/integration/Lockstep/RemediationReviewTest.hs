{-# LANGUAGE OverloadedStrings #-}

{- | C-P2.9-R1 §4.2 integration regressions, after the second review, against
real PostgreSQL: no re-dispatch past an idempotency key's guarantee (N1),
carry conflicts (N2), stale carries (N3), the acknowledgment for an attested
"not applied" (N4), the superseded recovery (N6) and the Human's abandonment
halt (N8). Scripted actions here are test actions; none is a decision by the
human owner.
-}
module Lockstep.RemediationReviewTest
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

import Lockstep.Application.Executor (Executor (..), ExecutorFaults (..), RunOutcome (..), executeIntent, noExecutorFaults)
import Lockstep.Application.Ledger
  ( LedgerFailure (..)
  , NewWorkOrder (..)
  , Receipt (..)
  , ScheduleReceipt (..)
  , StoredRecovery (..)
  , StoredResolution (..)
  , WorkOrderView (..)
  , abandonIntent
  , carryIntent
  , carryIntentChecked
  , claimForExecution
  , createTicket
  , createWorkOrder
  , decideTicket
  , decideWorkOrder
  , intentActivation
  , intentRecoveries
  , intentResolutions
  , ledgerFailureCode
  , loadIntent
  , noFaults
  , recordGateEvidence
  , recoverDispatched
  , resolveOutcome
  , scheduleOnce
  , showWorkOrder
  )
import Lockstep.Effects.Executor (EffectAdapter (..))
import Lockstep.Effects.Scripted (Application (..), ScriptStep (..), ScriptedDestination, destinationApplications, newScriptedDestination, scriptedAdapter)
import Lockstep.Kernel.Effect
  ( ClassTerms (..)
  , EffectSpec
  , IdempotencyTerms (..)
  , Intent (..)
  , IntentRequest (..)
  , IntentState (..)
  , LookupTerms (..)
  , OperationId (..)
  , effectSpecName
  , mkEffectKey
  , mkEffectSpec
  )
import Lockstep.Kernel.Identity (TicketId, WorkOrderId (..), uuidText)
import Lockstep.Kernel.Profile (Approval (..), ArtifactKind (..), GateEvidence (..), VerifierKind (..), mkContentDigest)
import Lockstep.Kernel.Reconciliation (Resolution (..))
import Lockstep.Kernel.Ticket (TicketInput (..))
import Lockstep.Kernel.Transition (Command (..), Principal (..))
import Lockstep.Kernel.WorkOrder (Claim, WorkOrderInput (..), WorkOrderKind (..), WorkOrderState (..))
import Lockstep.Support.Ledger (Ledger (..), count, sql, withLedger)

tests :: TestTree
tests =
  testGroup
    "Gate B remediation, second review (C-P2.9-R1 §4.2; real PostgreSQL)"
    [ testCase "N1: a re-dispatch past the key guarantee is refused, unknown and halted; nothing is sent" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- scripted dest [("bravo", [StepRefuse "busy"])]
          ok "execute bravo" (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults (opB ops)) >>= (@?= RanNotApplied "busy")
          shiftKey lg (opB ops)
          refused "idempotency-key-expired" (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults (opB ops))
          intentOf lg (opB ops) >>= (@?= IntentUnknown "dispatch-interrupted: idempotency key may have expired") . intentState
          haltedFor lg wo ("outcome-unknown operation=" <> opText (opB ops))
          scriptedApplications dest (opB ops) >>= (@?= 0)
    , testCase "N1 control: inside the guarantee the retry is dispatched and applied once" $
        withLedger $ \lg -> do
          (_, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- scripted dest [("bravo", [StepRefuse "busy"])]
          ok "execute bravo" (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults (opB ops)) >>= (@?= RanNotApplied "busy")
          ok "retry bravo" (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults (opB ops)) >>= (@?= RanApplied "ok")
          scriptedApplications dest (opB ops) >>= (@?= 1)
    , testCase "N1: a recovery's claim that lapses is not re-dispatched once the key guarantee ends" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- scripted dest []
          crashed <- try (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults {faultAfterDispatch = crash} (opB ops))
          assertBool "the crash propagates" (isException crashed)
          endLease lg (opB ops)
          recovered <- ok "recover" (recoverDispatched (lgRuntime lg) "w2" 60 (opB ops))
          assertBool ("not re-claimed: " <> show (intentState recovered)) (isClaimed (intentState recovered))
          endLease lg (opB ops)
          shiftKey lg (opB ops)
          refused "idempotency-key-expired" (executeIntent (lgRuntime lg) (exec "w3" adapters) noExecutorFaults (opB ops))
          intentOf lg (opB ops) >>= (@?= IntentUnknown "dispatch-interrupted: idempotency key may have expired") . intentState
          haltedFor lg wo ("outcome-unknown operation=" <> opText (opB ops))
          scriptedApplications dest (opB ops) >>= (@?= 0)
    , testCase "N1: a lapsed claim of an idempotent intent past its key guarantee is not carried" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- scripted dest [("bravo", [StepRefuse "busy"])]
          ok "execute bravo" (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults (opB ops)) >>= (@?= RanNotApplied "busy")
          _ <- ok "claim bravo" (claimForExecution (lgRuntime lg) "w1" 60 (opB ops))
          restartOrder lg wo
          endLease lg (opB ops)
          shiftKey lg (opB ops)
          refused "idempotency-key-expired" (carryIntentChecked (lgRuntime lg) Human (opB ops) (Just (1, 2)) False)
          ok "activation" (intentActivation (lgRuntime lg) (opB ops)) >>= (@?= 1)
          scriptedApplications dest (opB ops) >>= (@?= 0)
    , testCase "N2: a carry is refused while the target activation has a live intent with the same effect key" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          requests <- requestsFor ["alpha"]
          again <- restartWith lg wo requests
          alpha2 <-
            case again of
              [o] -> pure o
              other -> assertFailure ("expected one new intent: " <> show other)
          refused "carry-conflict" (carryIntent (lgRuntime lg) (opA ops))
          refused "carry-conflict" (carryIntentChecked (lgRuntime lg) Human (opA ops) (Just (1, 2)) False)
          ok "activation" (intentActivation (lgRuntime lg) (opA ops)) >>= (@?= 1)
          _ <- ok "abandon the new alpha" (abandonIntent (lgRuntime lg) alpha2 "duplicate of the carried one")
          restartOrder lg wo
          _ <- ok "carry alpha" (carryIntentChecked (lgRuntime lg) Human (opA ops) (Just (1, 3)) False)
          ok "activation" (intentActivation (lgRuntime lg) (opA ops)) >>= (@?= 3)
    , testCase "N3: a carry naming other activations is stale-carry and writes nothing" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          restartOrder lg wo
          refused "stale-carry" (carryIntentChecked (lgRuntime lg) Human (opA ops) (Just (1, 3)) False)
          refused "stale-carry" (carryIntentChecked (lgRuntime lg) Human (opA ops) (Just (2, 2)) False)
          refused "not-authorized" (carryIntentChecked (lgRuntime lg) Supervisor (opA ops) (Just (1, 2)) False)
          ok "resolutions" (intentResolutions (lgRuntime lg) (opA ops)) >>= (@?= [])
          _ <- ok "carry" (carryIntentChecked (lgRuntime lg) Human (opA ops) (Just (1, 2)) False)
          ok "resolutions" (intentResolutions (lgRuntime lg) (opA ops))
            >>= (@?= [StoredResolution 0 "human-carry" "carried principal=human from-generation=1 to-generation=2" False])
          refused "carry-not-needed" (carryIntentChecked (lgRuntime lg) Human (opA ops) (Just (1, 2)) False)
    , testCase "N4: an attested 'not applied' is carried only with the duplication-risk acknowledgment, which is recorded" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- scripted dest [("alpha", [StepHang])]
          ok "execute alpha" (executeIntent (lgRuntime lg) (exec "w1" adapters) {executorTimeoutMs = 200} noExecutorFaults (opA ops)) >>= (@?= RanUnknown "timeout")
          _ <- ok "attest" (resolveOutcome (lgRuntime lg) (opA ops) 1 (AttestNotApplied "nothing at the destination"))
          restartOrder lg wo
          refused "duplication-risk-not-acknowledged" (carryIntent (lgRuntime lg) (opA ops))
          refused "duplication-risk-not-acknowledged" (carryIntentChecked (lgRuntime lg) Human (opA ops) (Just (1, 2)) False)
          _ <- ok "carry" (carryIntentChecked (lgRuntime lg) Human (opA ops) (Just (1, 2)) True)
          resolutions <- ok "resolutions" (intentResolutions (lgRuntime lg) (opA ops))
          L.drop 1 resolutions @?= [StoredResolution 1 "human-carry" "carried principal=human from-generation=1 to-generation=2" True]
    , testCase "N6: recovering a superseded intent records 'activation superseded' and leaves the new activation running" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- scripted dest []
          crashed <- try (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults {faultAfterDispatch = crash} (opA ops))
          assertBool "the crash propagates" (isException crashed)
          restartOrder lg wo
          endLease lg (opA ops)
          recovered <- ok "recover" (recoverDispatched (lgRuntime lg) "w2" 60 (opA ops))
          intentState recovered @?= IntentUnknown "dispatch-interrupted: activation superseded"
          ok "recoveries" (intentRecoveries (lgRuntime lg) (opA ops))
            >>= (@?= [StoredRecovery 1 "unknown reason=\"dispatch-interrupted: activation superseded\""])
          ok "show" (showWorkOrder (lgRuntime lg) wo) >>= (@?= True) . isActive . woState
          scriptedApplications dest (opA ops) >>= (@?= 0)
    , testCase "N8: the abandonment halt is the Human's event" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          _ <- ok "abandon" (abandonIntent (lgRuntime lg) (opA ops) "operator stop")
          haltedFor lg wo ("abandoned operation=" <> opText (opA ops))
          count lg ("lockstep_events WHERE subject_id = '" <> T.unpack (woText wo) <> "' AND principal = 'human' AND state_after = 'halted'") >>= (@?= 1)
          count lg ("lockstep_events WHERE subject_id = '" <> T.unpack (woText wo) <> "' AND principal = 'supervisor' AND state_after = 'halted'") >>= (@?= 0)
    ]

-- Scenario -------------------------------------------------------------------

data Ops
  = Ops
  { opA :: OperationId
  , opB :: OperationId
  }

specTable :: [(T.Text, ClassTerms, Int)]
specTable =
  [ ("alpha", TermsRepeatable, 1)
  , ("bravo", TermsIdempotent (IdempotencyTerms 3600 True), 1)
  , ("charlie", TermsQueryable (LookupTerms True True), 1)
  ]

specNamed :: T.Text -> IO EffectSpec
specNamed name =
  case L.find (\(n, _, _) -> n == name) specTable of
    Just (n, t, b) -> either (assertFailure . show) pure (mkEffectSpec n t b)
    Nothing -> assertFailure ("no spec " <> T.unpack name)

requestsFor :: [T.Text] -> IO [IntentRequest]
requestsFor =
  traverse
    ( \name -> do
        s <- specNamed name
        k <- either (assertFailure . show) pure (mkEffectKey name)
        pure (IntentRequest k s ("p=" <> name))
    )

scripted :: ScriptedDestination -> [(T.Text, [ScriptStep])] -> IO [EffectAdapter]
scripted dest scripts =
  traverse (\(n, _, _) -> specNamed n) specTable
    >>= traverse (\s -> scriptedAdapter s dest (fromMaybe [] (L.lookup (effectSpecName s) scripts)))

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
  requests <- requestsFor [n | (n, _, _) <- specTable]
  started <- ok "start" (decideWorkOrder (lgRuntime lg) noFaults wo 3 (Command Supervisor (WoStart c)) requests)
  case receiptOperations started of
    [a, b, _] -> pure (wo, Ops a b)
    other -> assertFailure ("expected three intents: " <> show other)

scheduled :: Ledger -> WorkOrderId -> IO Claim
scheduled lg wo = do
  receipt <- ok "schedule" (scheduleOnce (lgRuntime lg))
  case scheduleClaimed receipt of
    Just (claimed, c) | claimed == wo -> pure c
    other -> assertFailure ("not claimed: " <> show other <> "\n" <> T.unpack (scheduleRendering receipt))

restartOrder :: Ledger -> WorkOrderId -> Assertion
restartOrder lg wo =
  () <$ restartWith lg wo []

-- | A Human halts (unless halted) and requeues the order; it is claimed again and started with the given intents.
restartWith :: Ledger -> WorkOrderId -> [IntentRequest] -> IO [OperationId]
restartWith lg wo requests = do
  view <- ok "show" (showWorkOrder (lgRuntime lg) wo)
  case woState view of
    Halted _ -> pure ()
    _ -> () <$ ok "halt" (decideWorkOrder (lgRuntime lg) noFaults wo (woRevision view) (Command Human (WoHalt "operator stop")) [])
  view' <- ok "show" (showWorkOrder (lgRuntime lg) wo)
  _ <- ok "requeue" (decideWorkOrder (lgRuntime lg) noFaults wo (woRevision view') (Command Human WoRequeue) [])
  c <- scheduled lg wo
  claimedView <- ok "show" (showWorkOrder (lgRuntime lg) wo)
  receiptOperations <$> ok "start" (decideWorkOrder (lgRuntime lg) noFaults wo (woRevision claimedView) (Command Supervisor (WoStart c)) requests)

isActive :: WorkOrderState -> Bool
isActive state =
  case state of
    Active _ -> True
    _ -> False

isClaimed :: IntentState -> Bool
isClaimed state =
  case state of
    IntentClaimed _ -> True
    _ -> False

haltedFor :: Ledger -> WorkOrderId -> T.Text -> Assertion
haltedFor lg wo reason = do
  view <- ok "show" (showWorkOrder (lgRuntime lg) wo)
  woState view @?= Halted reason

endLease :: Ledger -> OperationId -> Assertion
endLease lg o =
  sql lg ("UPDATE lockstep_effect_intents SET lease_until = now() - interval '1 second' WHERE operation_id = '" <> opString o <> "'")

-- | Moves the first dispatch back past the one-hour key guarantee.
shiftKey :: Ledger -> OperationId -> Assertion
shiftKey lg o =
  sql lg ("UPDATE lockstep_effect_intents SET first_dispatched_at = first_dispatched_at - interval '4000 seconds' WHERE operation_id = '" <> opString o <> "'")

intentOf :: Ledger -> OperationId -> IO Intent
intentOf lg o =
  ok "load intent" (loadIntent (lgRuntime lg) o)

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

woText :: WorkOrderId -> T.Text
woText (WorkOrderId u) =
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
