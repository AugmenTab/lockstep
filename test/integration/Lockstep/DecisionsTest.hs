{-# LANGUAGE OverloadedStrings #-}

{- | Human decisions with durable receipts against real PostgreSQL (contract
C-P3.8 M1, M3, M4): the operations run in this process over the C-P2.5 ledger;
every choice is applied as a Human with the expected revision or generation.
-}
module Lockstep.DecisionsTest
  ( tests
  ) where

import Control.Exception (SomeException, try)
import Data.List qualified as L
import Data.Maybe (isJust, isNothing)
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Decisions (DecisionReceipt (..), OpenDecision (..), StoppedFacts (..), UnknownFacts (..), applyDecision, findDecision, listDecisions)
import Lockstep.Application.Ledger (loadIntent)
import Lockstep.Kernel.Decision (DecisionRequest (..))
import Lockstep.Kernel.Effect (Intent (..), IntentState (..), OperationId (..))
import Lockstep.Kernel.Identity (WorkOrderId (..), uuidText)
import Lockstep.Support.Decisions (ok, stepWithUnknownOutcome, stoppedWork)
import Lockstep.Support.Ledger (Ledger (..), count, queryTexts, sql, withLedger)

key :: T.Text -> IO IdempotencyKey
key text =
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-decision-key-" <> text))

apply :: Ledger -> T.Text -> DecisionRequest -> IO (Either T.Text DecisionReceipt)
apply lg k request = do
  ik <- key k
  ok "apply" (applyDecision (lgRuntime lg) ik request)

applied :: Ledger -> T.Text -> DecisionRequest -> IO DecisionReceipt
applied lg k request = do
  result <- apply lg k request
  case result of
    Right r | receiptOutcome r == "applied" -> pure r
    other -> assertFailure ("not applied: " <> show other)

refusedWith :: T.Text -> Either T.Text DecisionReceipt -> Assertion
refusedWith code result =
  case result of
    Right r -> (receiptOutcome r, receiptRefusal r) @?= ("refused", Just code)
    Left other -> assertFailure ("no receipt: " <> T.unpack other)

woText :: WorkOrderId -> T.Text
woText (WorkOrderId u) =
  uuidText u

opText :: OperationId -> T.Text
opText (OperationId u) =
  uuidText u

-- | The work order's state name and revision, from its subject row.
subject :: Ledger -> WorkOrderId -> IO [T.Text]
subject lg wo =
  queryTexts lg ("SELECT state || ' ' || revision AS v FROM lockstep_subjects WHERE id = '" <> T.unpack (woText wo) <> "'")

events :: Ledger -> WorkOrderId -> IO [T.Text]
events lg wo =
  queryTexts lg ("SELECT principal || ' ' || state_after AS v FROM lockstep_events WHERE subject_id = '" <> T.unpack (woText wo) <> "' ORDER BY sequence")

immutable :: Ledger -> String -> Assertion
immutable lg statement = do
  result <- try (sql lg statement) :: IO (Either SomeException ())
  case result of
    Left e -> assertBool (statement <> ": failed, but not by the trigger: " <> show e) ("rows are immutable" `L.isInfixOf` show e)
    Right () -> assertFailure ("statement succeeded: " <> statement)

tests :: TestTree
tests =
  testGroup
    "human decisions with durable receipts (C-P3.8; real PostgreSQL)"
    [ testCase "open decisions: stopped work and a step whose outcome is unknown, with what each expects" $
        withLedger $ \lg -> do
          ok "nothing open" (listDecisions (lgRuntime lg)) >>= (@?= [])
          stopped <- stoppedWork lg "Print the menu" "the printer jammed"
          (started, op) <- stepWithUnknownOutcome lg "Send the invoice"
          open <- ok "list" (listDecisions (lgRuntime lg))
          case open of
            [UnknownOutcome u, StoppedWork s] -> do
              (unknownOperation u, unknownGeneration u, unknownStep u, unknownOrder u, unknownTitle u) @?= (op, 1, "send-invoice", started, "Send the invoice")
              assertBool ("the reason: " <> T.unpack (unknownReason u)) ("the mail server timed out" `T.isInfixOf` unknownReason u)
              (stoppedOrder s, stoppedRevision s, stoppedReason s, stoppedTitle s) @?= (stopped, 4, "the printer jammed", "Print the menu")
            other -> assertFailure ("open decisions: " <> show other)
          ok "find" (findDecision (lgRuntime lg) (woText stopped)) >>= assertBool "the stopped work is not found" . isJust
          ok "find" (findDecision (lgRuntime lg) (woText started)) >>= assertBool "running work is a decision" . isNothing
    , testCase "put back in line: a Human event and one receipt; a replay returns it and appends nothing" $
        withLedger $ \lg -> do
          wo <- stoppedWork lg "Print the menu" "the printer jammed"
          first <- applied lg "1" (PutBackInLine wo 4)
          (receiptSubject first, receiptChoice first, receiptReplayed first) @?= (woText wo, "put-back", False)
          subject lg wo >>= (@?= ["pending 5"])
          history <- events lg wo
          L.take 1 (L.reverse history) @?= ["human pending"]
          again <- apply lg "1" (PutBackInLine wo 4)
          fmap (\r -> (receiptOutcome r, receiptReplayed r)) again @?= Right ("applied", True)
          events lg wo >>= (@?= history)
          count lg "lockstep_decision_receipts" >>= (@?= 1)
          conflict <- apply lg "1" (CancelWork wo 5)
          conflict @?= Left "key-conflict"
          count lg "lockstep_decision_receipts" >>= (@?= 1)
          ok "list" (listDecisions (lgRuntime lg)) >>= (@?= [])
    , testCase "a stale revision or generation is refused with a receipt and changes nothing" $
        withLedger $ \lg -> do
          wo <- stoppedWork lg "Print the menu" "the printer jammed"
          apply lg "1" (CancelWork wo 3) >>= refusedWith "stale-revision"
          subject lg wo >>= (@?= ["halted 4"])
          (_, op) <- stepWithUnknownOutcome lg "Send the invoice"
          apply lg "2" (ItHappened op 2 "I saw it arrive") >>= refusedWith "stale-claim"
          apply lg "3" (GiveUp op 0 "not needed" True) >>= refusedWith "stale-revision"
          intent <- ok "intent" (loadIntent (lgRuntime lg) op)
          intentState intent @?= IntentUnknown "the mail server timed out"
          count lg "lockstep_decision_receipts WHERE outcome = 'refused'" >>= (@?= 3)
          replay <- apply lg "1" (CancelWork wo 3)
          fmap (\r -> (receiptOutcome r, receiptRefusal r, receiptReplayed r)) replay @?= Right ("refused", Just "stale-revision", True)
    , testCase "cancel stops the work for good" $
        withLedger $ \lg -> do
          wo <- stoppedWork lg "Print the menu" "the printer jammed"
          _ <- applied lg "1" (CancelWork wo 4)
          subject lg wo >>= (@?= ["canceled 5"])
          apply lg "2" (PutBackInLine wo 5) >>= refusedWith "already-terminal"
    , testCase "it happened: a person's attestation is recorded, and the decision closes" $
        withLedger $ \lg -> do
          (_, op) <- stepWithUnknownOutcome lg "Send the invoice"
          _ <- applied lg "1" (ItHappened op 1 "The customer replied to it")
          intent <- ok "intent" (loadIntent (lgRuntime lg) op)
          assertBool ("not settled: " <> show (intentState intent)) (case intentState intent of IntentSettled _ -> True; _ -> False)
          bases <- queryTexts lg ("SELECT basis AS v FROM lockstep_effect_resolutions WHERE operation_id = '" <> T.unpack (opText op) <> "'")
          bases @?= ["human-attested"]
          ok "list" (listDecisions (lgRuntime lg)) >>= (@?= [])
    , testCase "try again needs the duplication risk accepted" $
        withLedger $ \lg -> do
          (_, op) <- stepWithUnknownOutcome lg "Send the invoice"
          apply lg "1" (TryAgain op 1 False) >>= refusedWith "duplication-risk-not-acknowledged"
          _ <- applied lg "2" (TryAgain op 1 True)
          intent <- ok "intent" (loadIntent (lgRuntime lg) op)
          assertBool ("still unknown: " <> show (intentState intent)) (case intentState intent of IntentUnknown _ -> False; _ -> True)
    , testCase "give up abandons the step, and its work then waits for a person" $
        withLedger $ \lg -> do
          (wo, op) <- stepWithUnknownOutcome lg "Send the invoice"
          _ <- applied lg "1" (GiveUp op 1 "We sent it by post instead" True)
          intent <- ok "intent" (loadIntent (lgRuntime lg) op)
          intentState intent @?= IntentAbandoned "We sent it by post instead"
          open <- ok "list" (listDecisions (lgRuntime lg))
          fmap (\d -> case d of StoppedWork s -> Just (stoppedOrder s); _ -> Nothing) open @?= [Just wo]
    , testCase "text rules come first and leave no receipt" $
        withLedger $ \lg -> do
          (_, op) <- stepWithUnknownOutcome lg "Send the invoice"
          apply lg "1" (ItHappened op 1 "   ") >>= (@?= Left "text-empty")
          apply lg "2" (GiveUp op 1 (T.replicate 501 "x") True) >>= (@?= Left "text-too-long")
          count lg "lockstep_decision_receipts" >>= (@?= 0)
    , testCase "receipts cannot be changed or deleted" $
        withLedger $ \lg -> do
          wo <- stoppedWork lg "Print the menu" "the printer jammed"
          _ <- applied lg "1" (PutBackInLine wo 4)
          actors <- queryTexts lg "SELECT actor || ' ' || choice || ' ' || expected AS v FROM lockstep_decision_receipts"
          actors @?= ["application-session put-back 4"]
          immutable lg "UPDATE lockstep_decision_receipts SET outcome = 'refused', refusal_code = 'x'"
          immutable lg "DELETE FROM lockstep_decision_receipts"
          immutable lg "TRUNCATE lockstep_decision_receipts"
    ]
