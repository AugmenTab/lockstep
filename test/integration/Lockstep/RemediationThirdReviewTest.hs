{-# LANGUAGE OverloadedStrings #-}

{- | C-P2.9-R1 §4.5 integration regressions, after the third review, against
real PostgreSQL: no dispatch while another live intent of the order has the
same effect key (P1), a carry conflict with any such intent (P1), the
acknowledgment for a re-carried attested intent (P2), and no human retry past
an idempotency key's guarantee (P3). Scripted actions here are test actions;
none is a decision by the human owner.
-}
module Lockstep.RemediationThirdReviewTest
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
  , WorkOrderView (..)
  , abandonIntent
  , carryIntentChecked
  , claimForExecution
  , createTicket
  , createWorkOrder
  , decideTicket
  , decideWorkOrder
  , intentActivation
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
import Lockstep.Kernel.Identity (TicketId, uuidText)
import Lockstep.Kernel.Identity qualified as Identity
import Lockstep.Kernel.Profile (Approval (..), ArtifactKind (..), GateEvidence (..), VerifierKind (..), mkContentDigest)
import Lockstep.Kernel.Reconciliation (Resolution (..))
import Lockstep.Kernel.Ticket (TicketInput (..))
import Lockstep.Kernel.Transition (Command (..), Principal (..))
import Lockstep.Kernel.WorkOrder (Claim, WorkOrderInput (..), WorkOrderKind (..), WorkOrderState (..))
import Lockstep.Support.Ledger (Ledger (..), sql, withLedger)

tests :: TestTree
tests =
  testGroup
    "Gate B remediation, third review (C-P2.9-R1 §4.5; real PostgreSQL)"
    [ testCase "P1: a new intent is not dispatched while an earlier one with the same effect key may have applied" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- scripted dest []
          crashed <- try (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults {faultAfterDispatch = crash} (opA ops))
          assertBool "the crash propagates" (isException crashed)
          alpha2 <- restartWith lg wo ["alpha"] >>= single
          endLease lg (opA ops)
          refused "effect-key-in-use" (executeIntent (lgRuntime lg) (exec "w2" adapters) noExecutorFaults alpha2)
          haltedFor lg wo ("effect-key-in-use operation=" <> opText alpha2)
          intentOf lg alpha2 >>= (@?= IntentPending) . intentState
          scriptedApplications dest alpha2 >>= (@?= 0)
    , testCase "P1: the same after the earlier intent's recovery makes it unknown (the reviewer's sequence)" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- scripted dest []
          crashed <- try (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults {faultAfterDispatch = crash} (opA ops))
          assertBool "the crash propagates" (isException crashed)
          alpha2 <- restartWith lg wo ["alpha"] >>= single
          endLease lg (opA ops)
          recovered <- ok "recover" (recoverDispatched (lgRuntime lg) "w2" 60 (opA ops))
          intentState recovered @?= IntentUnknown "dispatch-interrupted: activation superseded"
          refused "effect-key-in-use" (executeIntent (lgRuntime lg) (exec "w2" adapters) noExecutorFaults alpha2)
          scriptedApplications dest alpha2 >>= (@?= 0)
    , testCase "P1 control: an abandoned earlier intent does not block the new one" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- scripted dest []
          _ <- ok "abandon" (abandonIntent (lgRuntime lg) (opA ops) "replaced")
          alpha2 <- restartWith lg wo ["alpha"] >>= single
          ok "execute" (executeIntent (lgRuntime lg) (exec "w1" adapters) noExecutorFaults alpha2) >>= (@?= RanApplied "ok")
          scriptedApplications dest alpha2 >>= (@?= 1)
    , testCase "P1: a carry conflicts with a live same-key intent of any activation" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          alpha2 <- restartWith lg wo ["alpha"] >>= single
          restartWith lg wo [] >>= (@?= [])
          refused "carry-conflict" (carryIntentChecked (lgRuntime lg) Human alpha2 (Just (2, 3)) False)
          refused "carry-conflict" (carryIntentChecked (lgRuntime lg) Human (opA ops) (Just (1, 3)) False)
          ok "activation" (intentActivation (lgRuntime lg) alpha2) >>= (@?= 2)
    , testCase "P2: re-carrying an attested intent from a lapsed claim needs the acknowledgment again" $
        withLedger $ \lg -> do
          (wo, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- scripted dest [("alpha", [StepHang])]
          ok "execute alpha" (executeIntent (lgRuntime lg) (exec "w1" adapters) {executorTimeoutMs = 200} noExecutorFaults (opA ops)) >>= (@?= RanUnknown "timeout")
          _ <- ok "attest" (resolveOutcome (lgRuntime lg) (opA ops) 1 (AttestNotApplied "nothing at the destination"))
          restartWith lg wo [] >>= (@?= [])
          _ <- ok "carry" (carryIntentChecked (lgRuntime lg) Human (opA ops) (Just (1, 2)) True)
          _ <- ok "claim" (claimForExecution (lgRuntime lg) "w1" 60 (opA ops))
          restartWith lg wo [] >>= (@?= [])
          endLease lg (opA ops)
          refused "duplication-risk-not-acknowledged" (carryIntentChecked (lgRuntime lg) Human (opA ops) (Just (2, 3)) False)
          _ <- ok "carry with the acknowledgment" (carryIntentChecked (lgRuntime lg) Human (opA ops) (Just (2, 3)) True)
          ok "activation" (intentActivation (lgRuntime lg) (opA ops)) >>= (@?= 3)
    , testCase "P3: a human retry is refused once the idempotency key's guarantee has ended" $
        withLedger $ \lg -> do
          (_, ops) <- activeOrder lg
          dest <- newScriptedDestination
          adapters <- scripted dest [("bravo", [StepHang])]
          ok "execute bravo" (executeIntent (lgRuntime lg) (exec "w1" adapters) {executorTimeoutMs = 200} noExecutorFaults (opB ops)) >>= (@?= RanUnknown "timeout")
          sql lg ("UPDATE lockstep_effect_intents SET first_dispatched_at = first_dispatched_at - interval '4000 seconds' WHERE operation_id = '" <> opString (opB ops) <> "'")
          refused "idempotency-key-expired" (resolveOutcome (lgRuntime lg) (opB ops) 1 (RetryAcknowledgingDuplication True))
          intentOf lg (opB ops) >>= (@?= IntentUnknown "timeout") . intentState
          _ <- ok "attest instead" (resolveOutcome (lgRuntime lg) (opB ops) 1 (AttestApplied "seen at the destination"))
          pure ()
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

single :: [OperationId] -> IO OperationId
single os =
  case os of
    [o] -> pure o
    other -> assertFailure ("expected one new intent: " <> show other)

activeOrder :: Ledger -> IO (Identity.WorkOrderId, Ops)
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

scheduled :: Ledger -> Identity.WorkOrderId -> IO Claim
scheduled lg wo = do
  receipt <- ok "schedule" (scheduleOnce (lgRuntime lg))
  case scheduleClaimed receipt of
    Just (claimed, c) | claimed == wo -> pure c
    other -> assertFailure ("not claimed: " <> show other <> "\n" <> T.unpack (scheduleRendering receipt))

-- | A Human halts (unless halted) and requeues the order; it is claimed again and started with intents of the named effects.
restartWith :: Ledger -> Identity.WorkOrderId -> [T.Text] -> IO [OperationId]
restartWith lg wo names = do
  requests <- requestsFor names
  view <- ok "show" (showWorkOrder (lgRuntime lg) wo)
  case woState view of
    Halted _ -> pure ()
    _ -> () <$ ok "halt" (decideWorkOrder (lgRuntime lg) noFaults wo (woRevision view) (Command Human (WoHalt "operator stop")) [])
  view' <- ok "show" (showWorkOrder (lgRuntime lg) wo)
  _ <- ok "requeue" (decideWorkOrder (lgRuntime lg) noFaults wo (woRevision view') (Command Human WoRequeue) [])
  c <- scheduled lg wo
  claimedView <- ok "show" (showWorkOrder (lgRuntime lg) wo)
  receiptOperations <$> ok "start" (decideWorkOrder (lgRuntime lg) noFaults wo (woRevision claimedView) (Command Supervisor (WoStart c)) requests)

haltedFor :: Ledger -> Identity.WorkOrderId -> T.Text -> Assertion
haltedFor lg wo reason = do
  view <- ok "show" (showWorkOrder (lgRuntime lg) wo)
  woState view @?= Halted reason

endLease :: Ledger -> OperationId -> Assertion
endLease lg o =
  sql lg ("UPDATE lockstep_effect_intents SET lease_until = now() - interval '1 second' WHERE operation_id = '" <> opString o <> "'")

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

evidence :: Ledger -> Identity.WorkOrderId -> Assertion
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
