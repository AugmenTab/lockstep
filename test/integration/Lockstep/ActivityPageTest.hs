{-# LANGUAGE OverloadedStrings #-}

{- | The Activity view over real HTTP (contract C-P3.9 N2–N5): the real service
on a 'Lockstep.Support.Ledger.withLedger' database; the steps are taken through
the real C-P2.5 ledger in this process, so every status shown is one the
database holds. The service is restarted to show the page does not change.
-}
module Lockstep.ActivityPageTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import System.Exit (ExitCode (ExitSuccess))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

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
  , resolveOutcome
  , scheduleOnce
  , settleIntent
  )
import Lockstep.Kernel.Effect (ClassTerms (..), IntentRequest (..), Observation (..), OperationId (..), mkEffectKey, mkEffectSpec)
import Lockstep.Kernel.Identity (WorkOrderId (..), uuidText)
import Lockstep.Kernel.Profile (Approval (..), ArtifactKind (..), GateEvidence (..), VerifierKind (..), mkContentDigest)
import Lockstep.Kernel.Reconciliation (Resolution (..))
import Lockstep.Kernel.Ticket (TicketInput (..))
import Lockstep.Kernel.Transition (Command (..), Principal (..))
import Lockstep.Kernel.WorkOrder (WorkOrderInput (..), WorkOrderKind (..))
import Lockstep.Support.Decisions (ok, stoppedWork)
import Lockstep.Support.Http (HttpResponse (..), httpRequest)
import Lockstep.Support.Ledger (Ledger (..), withLedger)
import Lockstep.Support.Process (freePort, runLockstep, withService)

-- | The five steps of one started piece of work, in the order they were requested.
data Steps
  = Steps
  { passedStep :: OperationId
  , attestedStep :: OperationId
  , unknownStep' :: OperationId
  , failedStep :: OperationId
  , notRunStep :: OperationId
  }

{- | Work stopped by a person (no steps), then started work for the ticket
"Send the <b>invoices</b>" with five repeatable steps (one retry each): one
settled from the destination's answer, one a person attested, one with no
answer, one refused twice, one never sent. A stale request is refused too.
-}
mixedWork :: Ledger -> IO (WorkOrderId, WorkOrderId, Steps)
mixedWork lg = do
  let
    rt = lgRuntime lg
  stopped <- stoppedWork lg "Print the menu" "the printer jammed"
  _ <- decideWorkOrder rt noFaults stopped 1 (Command Human WoCancel) []
  t <- ok "create ticket" (createTicket rt "Send the <b>invoices</b>")
  _ <- ok "accept ticket" (decideTicket rt noFaults t 1 (Command Human TicketAccept))
  wo <- ok "create work order" (createWorkOrder rt (NewWorkOrder t "alice" Engineering 5 [] [] ["source"] Nothing))
  digest <- maybe (assertFailure "digest") pure (mkContentDigest (T.replicate 64 "a"))
  ok "evidence" (recordGateEvidence rt Human wo (GateEvidence ImpactAssessment digest [VerifyHumanInspection] ApprovalSupervisor))
  receipt <- ok "schedule" (scheduleOnce rt)
  c <-
    case scheduleClaimed receipt of
      Just (w, c) | w == wo -> pure c
      other -> assertFailure ("not claimed: " <> show other)
  spec <- either (assertFailure . show) pure (mkEffectSpec "send-invoice" TermsRepeatable 1)
  requests <-
    traverse
      (\n -> either (assertFailure . show) (\k -> pure (IntentRequest k spec ("n=" <> n))) (mkEffectKey ("invoice-" <> n)))
      ["1", "2", "3", "4", "5"]
  started <- ok "start" (decideWorkOrder rt noFaults wo 3 (Command Supervisor (WoStart c)) requests)
  steps <-
    case receiptOperations started of
      [a, b, u, f, n] -> pure (Steps a b u f n)
      other -> assertFailure ("expected five steps: " <> show other)
  let
    send op generation observation = do
      _ <- ok "claim" (claimIntent rt "worker-1" 60 op)
      _ <- ok "send" (dispatchIntent rt op generation)
      ok "observe" (observeIntent rt op generation observation)
  _ <- send (passedStep steps) 1 (DestinationApplied "delivered")
  _ <- ok "settle" (settleIntent rt (passedStep steps) 1)
  _ <- send (attestedStep steps) 1 (NoAnswer "timed out")
  _ <- ok "attest" (resolveOutcome rt (attestedStep steps) 1 (AttestApplied "the customer replied"))
  _ <- send (unknownStep' steps) 1 (NoAnswer "the mail server timed out")
  _ <- send (failedStep steps) 1 (DestinationNotApplied "mailbox full")
  _ <- send (failedStep steps) 2 (DestinationNotApplied "mailbox full")
  pure (stopped, wo, steps)

opId :: OperationId -> BS.ByteString
opId (OperationId u) =
  BS8.pack (T.unpack (uuidText u))

woId :: WorkOrderId -> BS.ByteString
woId (WorkOrderId u) =
  BS8.pack (T.unpack (uuidText u))

origin :: Int -> BS.ByteString
origin port =
  "http://127.0.0.1:" <> BS8.pack (show port)

signIn :: Int -> [(String, String)] -> IO BS.ByteString
signIn port env = do
  (code, out, err) <- runLockstep env ["operator", "sign-in", "--port", show port]
  code @?= ExitSuccess
  token <-
    case L.stripPrefix "=" (L.dropWhile (/= '=') (L.filter (/= '\n') out)) of
      Just t | L.length t == 43 -> pure (BS8.pack t)
      _ -> assertFailure ("unexpected sign-in output: " <> out <> err)
  resp <- httpRequest port "POST" "/app/api/session" [("Origin", origin port)] token
  responseStatus resp @?= 200
  pure (BS.take 43 (BS.drop 11 (snd (BS.breakSubstring "\"session\":\"" (responseBody resp)))))

-- | The Activity section, read by a freshly started service.
activity :: Ledger -> IO BS.ByteString
activity lg = do
  port <- freePort
  (body, _) <-
    withService (lgEnv lg) port (lgDir lg <> "/serve-" <> show port <> ".log") $ do
      session <- signIn port (lgEnv lg)
      resp <- httpRequest port "GET" "/app/fragments/activity" [("X-Lockstep-Session", session)] ""
      responseStatus resp @?= 200
      pure (responseBody resp)
  pure body

contains :: BS.ByteString -> BS.ByteString -> Bool
contains needle haystack =
  not (BS.null (snd (BS.breakSubstring needle haystack)))

has :: BS.ByteString -> [BS.ByteString] -> IO ()
has body =
  traverse_ (\needle -> assertBool ("missing " <> show needle <> ": " <> show body) (contains needle body))

at :: BS.ByteString -> BS.ByteString -> Int
at needle body =
  BS.length (fst (BS.breakSubstring needle body))

occurrences :: BS.ByteString -> BS.ByteString -> Int
occurrences needle body =
  case BS.breakSubstring needle body of
    (_, rest)
      | BS.null rest -> 0
      | otherwise -> 1 + occurrences needle (BS.drop (BS.length needle) rest)

-- | The page without any Technical details block.
withoutDetails :: BS.ByteString -> BS.ByteString
withoutDetails body =
  case BS.breakSubstring "<details" body of
    (before, rest)
      | BS.null rest -> before
      | otherwise -> before <> withoutDetails (BS.drop 10 (snd (BS.breakSubstring "</details>" rest)))

-- | The page up to the final raw evidence (which carries the time it was read).
beforeRaw :: BS.ByteString -> BS.ByteString
beforeRaw =
  fst . BS.breakSubstring "id=\"activity-raw\""

tests :: TestTree
tests =
  testGroup
    "activity and evidence over HTTP (C-P3.9)"
    [ testCase "with no work, Activity says nothing has happened yet" $
        withLedger $ \lg -> do
          body <- activity lg
          has body ["Activity", "Nothing has happened yet."]
          assertBool "a PASSED with nothing done" (not (contains "PASSED" body))
    , testCase "each status is shown with its label and meaning; only PASSED looks passed; attention first" $
        withLedger $ \lg -> do
          (stopped, _, steps) <- mixedWork lg
          body <- activity lg
          has
            body
            [ ">PASSED<"
            , ">ATTESTED<"
            , ">UNKNOWN<"
            , ">NOT_APPLIED<"
            , ">NOT_RUN<"
            , "confirmed by the destination"
            , "a person said what happened; Lockstep did not check it"
            , "Failed: the destination said it did not take effect, and no tries are left."
            , "Not started yet."
            , "Stopped: the printer jammed"
            , "Refused because it was based on an out-of-date view"
            ]
          occurrences "ls-effect-passed" body @?= 1
          occurrences ">PASSED<" body @?= 1
          let
            unknownLink = "href=\"/app/decisions/" <> opId (unknownStep' steps) <> "\""
            stoppedLink = "href=\"/app/decisions/" <> woId stopped <> "\""
          has body [unknownLink, stoppedLink, "Needs attention", "All work"]
          assertBool "attention is not first" (at "Needs attention" body < at "All work" body)
          assertBool "the unknown step is not in Needs attention" (at unknownLink body < at "All work" body)
          assertBool "the failed step is not in Needs attention" (at "Failed:" body < at "All work" body)
          assertBool "a passed step needs attention" (at "confirmed by the destination" body > at "All work" body)
    , testCase "work with no recorded step is never shown as passed" $
        withLedger $ \lg -> do
          _ <- stoppedWork lg "Print the menu" "the printer jammed"
          body <- activity lg
          has body ["Print the menu", "No steps recorded."]
          assertBool "a PASSED with no steps" (not (contains "PASSED" body))
    , testCase "the raw evidence is under Technical details, and the page is the same after a restart" $
        withLedger $ \lg -> do
          (_, _, steps) <- mixedWork lg
          first <- activity lg
          has first ["id=\"activity-raw\"", "status=UNKNOWN", opId (unknownStep' steps), opId (notRunStep steps), "no-answer reason=", "attested-applied"]
          assertBool "the raw ledger text is outside Technical details" (at "status=UNKNOWN" first > at "<details" first)
          second <- activity lg
          beforeRaw second @?= beforeRaw first
    , testCase "no form or button; typed text is escaped; no internal words outside Technical details" $
        withLedger $ \lg -> do
          _ <- mixedWork lg
          body <- activity lg
          assertBool "a form on Activity" (not (contains "<form" body))
          assertBool "a button on Activity" (not (contains "<button" body))
          assertBool "markup was not escaped" (not (contains "<b>invoices" body))
          has body ["Send the &lt;b&gt;invoices&lt;/b&gt;"]
          traverse_
            (\word -> assertBool ("internal word " <> show word) (not (contains word (BS8.map Char.toLower (withoutDetails body)))))
            ["work order", "ticket", "intent", "generation", "supervisor", "scheduler"]
    ]
