{-# LANGUAGE OverloadedStrings #-}

{- | Fixtures for the decision tests (contract C-P3.8): a piece of work a person
stopped, and a step whose outcome is unknown, made through the C-P2.5 ledger
operations on a 'Lockstep.Support.Ledger.withLedger' database (Engineer
@alice@, the @team@ profile with its before-execution @impact@ check).
-}
module Lockstep.Support.Decisions
  ( stoppedWork
  , stepWithUnknownOutcome
  , ok
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty.HUnit (assertFailure)
import Text.Show (Show, show)

import Lockstep.Application.Ledger
  ( NewWorkOrder (..)
  , Receipt (..)
  , ScheduleReceipt (..)
  , claimIntent
  , createTicket
  , createWorkOrder
  , decideTicket
  , decideWorkOrder
  , dispatchIntent
  , noFaults
  , observeIntent
  , recordGateEvidence
  , scheduleOnce
  )
import Lockstep.Kernel.Effect (ClassTerms (..), IntentRequest (..), Observation (..), OperationId, mkEffectKey, mkEffectSpec)
import Lockstep.Kernel.Identity (TicketId, WorkOrderId)
import Lockstep.Kernel.Profile (Approval (..), ArtifactKind (..), GateEvidence (..), VerifierKind (..), mkContentDigest)
import Lockstep.Kernel.Ticket (TicketInput (..))
import Lockstep.Kernel.Transition (Command (..), Principal (..))
import Lockstep.Kernel.WorkOrder (Claim, WorkOrderInput (..), WorkOrderKind (..))
import Lockstep.Support.Ledger (Ledger (..))

ok :: Show e => String -> IO (Either e a) -> IO a
ok what action =
  action >>= either (\failure -> assertFailure (what <> ": " <> show failure)) pure

readyTicket :: Ledger -> T.Text -> IO TicketId
readyTicket lg title = do
  t <- ok "create ticket" (createTicket (lgRuntime lg) title)
  _ <- ok "accept ticket" (decideTicket (lgRuntime lg) noFaults t 1 (Command Human TicketAccept))
  pure t

-- | A ready Ticket's order with its impact evidence, claimed by the scheduler: revision 3.
claimed :: Ledger -> T.Text -> IO (WorkOrderId, Claim)
claimed lg title = do
  t <- readyTicket lg title
  wo <- ok "create work order" (createWorkOrder (lgRuntime lg) (NewWorkOrder t "alice" Engineering 5 [] [] ["source"] Nothing))
  digest <- maybe (assertFailure "digest") pure (mkContentDigest (T.replicate 64 "a"))
  ok "evidence" (recordGateEvidence (lgRuntime lg) Human wo (GateEvidence ImpactAssessment digest [VerifyHumanInspection] ApprovalSupervisor))
  receipt <- ok "schedule" (scheduleOnce (lgRuntime lg))
  case scheduleClaimed receipt of
    Just (w, c) | w == wo -> pure (wo, c)
    other -> assertFailure ("not claimed: " <> show other <> "\n" <> T.unpack (scheduleRendering receipt))

-- | Work a person stopped with this reason: halted, revision 4.
stoppedWork :: Ledger -> T.Text -> T.Text -> IO WorkOrderId
stoppedWork lg title reason = do
  (wo, _) <- claimed lg title
  _ <- ok "halt" (decideWorkOrder (lgRuntime lg) noFaults wo 3 (Command Human (WoHalt reason)) [])
  pure wo

{- | Started work whose one step ("send-invoice", repeatable, one retry) was
sent and never answered: its outcome is unknown at generation 1, and the work
stays active (revision 4).
-}
stepWithUnknownOutcome :: Ledger -> T.Text -> IO (WorkOrderId, OperationId)
stepWithUnknownOutcome lg title = do
  (wo, c) <- claimed lg title
  spec <- either (assertFailure . show) pure (mkEffectSpec "send-invoice" TermsRepeatable 1)
  k <- either (assertFailure . show) pure (mkEffectKey "invoice-1")
  receipt <- ok "start" (decideWorkOrder (lgRuntime lg) noFaults wo 3 (Command Supervisor (WoStart c)) [IntentRequest k spec "to=customer"])
  op <-
    case receiptOperations receipt of
      [o] -> pure o
      other -> assertFailure ("expected one step: " <> show other)
  _ <- ok "claim step" (claimIntent (lgRuntime lg) "worker-1" 60 op)
  _ <- ok "send step" (dispatchIntent (lgRuntime lg) op 1)
  _ <- ok "no answer" (observeIntent (lgRuntime lg) op 1 (NoAnswer "the mail server timed out"))
  pure (wo, op)
