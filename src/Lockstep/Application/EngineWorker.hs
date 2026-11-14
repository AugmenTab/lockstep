{- | The engine worker (contract C-P4.15 W1; C-P4.R1 R-W1, R-W2): one thread
that keeps coding transactions moving. Each pass first starts a transaction
for every handed-over bug that has none, in hand-over order (an Engineer whose
one writer is busy is tried again next pass), then advances every running or
halted transaction once, in the order they were started; a halted one only
moves when a person has answered its request. One pass at a time, one step
per transaction per pass: there is never a second writer.

An error in a pass is logged and the next pass runs; an asynchronous
exception (the worker being stopped or the service shutting down) is never
swallowed. However the thread ends, it signals that it is done. A stop is
seen between transactions; a bounded stop that runs out of time stops the
thread, which kills a role it was running with its process group (or cancels
it through the helper): that run stays unfinished, so after a restart it is
uncertain and never run again by itself.
-}
module Lockstep.Application.EngineWorker
  ( EngineWorker
  , startEngineWorker
  , stopEngineWorker
  , stopEngineWorkerWithin
  , requestEngineStop
  , engineOnce
  , PassFailure (..)
  ) where

import Control.Concurrent (ThreadId, forkFinally, killThread, threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, readMVar, tryPutMVar, tryReadMVar)
import Control.Exception (SomeAsyncException, SomeException, displayException, fromException, throwIO, try)
import Control.Monad (unless)
import Data.Maybe (catMaybes, isJust)
import Data.Text qualified as T
import Flipstone.Prelude
import System.Timeout (timeout)
import Text.Show (Show)

import Lockstep.Application.Clarification (ClarificationOutcome (..), ClarificationReport (..), answerClarificationsUntil, clarificationOutcomeCode)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason, reasonDiagnosis)
import Lockstep.Application.Engine (Engine, StepReport (..), activeTransactionIds, advanceTransaction, pendingWorkOrders, startTransactionFor)
import Lockstep.Kernel.Identity (TransactionId (..), WorkOrderId (..), identityText)

data EngineWorker
  = EngineWorker
  { workerStop :: MVar ()
  , workerDone :: MVar ()
  , workerThread :: ThreadId
  }

-- | Why a step of a pass did not happen.
data PassFailure
  = -- | The engine refused the step, with its code.
    PassRefused T.Text
  | -- | The database could not be used, or holds data that does not read.
    PassDatabase NotReadyReason
  deriving (Eq, Show)

{- | One pass: the pending bugs started, then each active transaction
advanced once; what each advance did. A list that could not be read is
reported under its name, never taken as empty.
-}
engineOnce :: DatabaseRuntime -> Engine -> IO [(T.Text, Either PassFailure T.Text)]
engineOnce runtime engine =
  enginePass runtime engine (pure False)

-- | A pass that ends early, between transactions, once the check says so.
enginePass :: DatabaseRuntime -> Engine -> IO Bool -> IO [(T.Text, Either PassFailure T.Text)]
enginePass runtime engine stopping = do
  pending <- pendingWorkOrders runtime
  started <-
    case pending of
      Left reason -> pure [(T.pack "pending work orders", Left (PassDatabase reason))]
      Right workOrders -> catMaybes <$> traverse start workOrders
  active <- activeTransactionIds runtime
  advanced <-
    case active of
      Left reason -> pure (started <> [(T.pack "active transactions", Left (PassDatabase reason))])
      Right ids -> (started <>) <$> each ids
  -- C-P6.3 I4, I8: then the questions people asked, each answered once; nothing is reported when there are none.
  stop <- stopping
  if stop
    then pure advanced
    else do
      clarified <- answerClarificationsUntil runtime engine stopping
      pure $
        advanced
          <> case clarified of
            Left reason -> [(T.pack "clarifications", Left (PassDatabase reason))]
            -- A question left at the limit stays so every pass; it is not reported again each time.
            Right reports -> [(T.pack "clarify " <> reportRequest r, clarificationResult (reportOutcome r)) | r <- reports, reportOutcome r /= ClarifiedLimit]
 where
  -- R-P6.3: a question no answer came for is a refusal the worker logs; an answer, or no helper, is not.
  clarificationResult outcome =
    case outcome of
      ClarifiedFailed _ -> Left (PassRefused (clarificationOutcomeCode outcome))
      ClarifiedUncertain -> Left (PassRefused (clarificationOutcomeCode outcome))
      _ -> Right (clarificationOutcomeCode outcome)
  -- A start that happened is seen as its transaction's advance; one that did not is reported
  -- (a refusal, such as an Engineer whose writer is busy, is tried again next pass).
  start workOrder = do
    started <- startTransactionFor runtime workOrder
    pure $
      case started of
        Left reason -> Just (T.pack "start " <> identityText workOrder, Left (PassDatabase reason))
        Right (Left code) -> Just (T.pack "start " <> identityText workOrder, Left (PassRefused code))
        Right (Right _) -> Nothing
  each ids =
    case ids of
      [] -> pure []
      txId : rest -> do
        stop <- stopping
        if stop
          then pure []
          else do
            stepped <- one txId
            (stepped :) <$> each rest
  one txId = do
    stepped <- advanceTransaction runtime engine txId
    pure
      ( identityText txId
      , case stepped of
          Left reason -> Left (PassDatabase reason)
          Right (Left code) -> Left (PassRefused code)
          Right (Right (Stepped input _)) -> Right input
          Right (Right (Idle why _)) -> Right (T.pack "idle " <> why)
      )

-- | Starts the worker: a pass every interval (milliseconds) until stopped.
startEngineWorker :: DatabaseRuntime -> Engine -> Int -> (String -> IO ()) -> IO EngineWorker
startEngineWorker runtime engine interval logLine = do
  stop <- newEmptyMVar
  done <- newEmptyMVar
  let
    stopping = isJust <$> tryReadMVar stop
    loop = do
      halt <- stopping
      unless halt $ do
        passed <- try (enginePass runtime engine stopping)
        case passed of
          Left (e :: SomeException)
            | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
            | otherwise -> quietly (logLine ("engine pass failed: " <> displayException e))
          Right results ->
            -- A database failure is logged with its diagnosis; refusals are the engine's own record.
            traverse_ (\(what, failure) -> quietly (logLine ("engine pass: " <> T.unpack what <> ": " <> T.unpack (reasonDiagnosis failure)))) [(what, r) | (what, Left (PassDatabase r)) <- results]
              -- R-P6.3: a question Lockstep could not answer is logged too (the database keeps its code).
              >> traverse_ (\(what, code) -> quietly (logLine ("engine pass: " <> T.unpack what <> ": " <> T.unpack code))) [(what, c) | (what, Left (PassRefused c)) <- results, T.pack "clarify " `T.isPrefixOf` what]
        threadDelay (interval * 1000)
        loop
    -- A log that fails is not a reason to stop working; a stop still is.
    quietly action = do
      logged <- try action
      case logged of
        Left (e :: SomeException) | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
        _ -> pure ()
  thread <- forkFinally loop (\_ -> void (tryPutMVar done ()))
  pure (EngineWorker stop done thread)

-- | Stops the worker after the transaction it is advancing and waits for it.
stopEngineWorker :: EngineWorker -> IO ()
stopEngineWorker worker = do
  _ <- tryPutMVar (workerStop worker) ()
  readMVar (workerDone worker)

{- | Stops the worker, waiting at most this many seconds for the transaction it
is advancing; then stops the thread (see the module note). True when it had
stopped by itself in time.
-}
stopEngineWorkerWithin :: Int -> EngineWorker -> IO Bool
stopEngineWorkerWithin seconds worker = do
  _ <- tryPutMVar (workerStop worker) ()
  finished <- timeout (seconds * 1000000) (readMVar (workerDone worker))
  case finished of
    Just () -> pure True
    Nothing -> do
      -- C-P4.R2 R2-W: the stopped thread's clean-up is bounded too.
      killThread (workerThread worker)
      _ <- timeout 2000000 (readMVar (workerDone worker))
      pure False

{- | C-P4.R2 R2-W: asks the worker to stop after the transaction it is
advancing, without waiting (the service calls it as soon as it starts to shut
down).
-}
requestEngineStop :: EngineWorker -> IO ()
requestEngineStop worker =
  void (tryPutMVar (workerStop worker) ())
