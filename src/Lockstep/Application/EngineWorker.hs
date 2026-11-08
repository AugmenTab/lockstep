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
  ) where

import Control.Concurrent (ThreadId, forkFinally, killThread, threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, readMVar, tryPutMVar, tryReadMVar)
import Control.Exception (SomeAsyncException, SomeException, displayException, fromException, throwIO, try)
import Control.Monad (unless)
import Data.Maybe (isJust)
import Data.Text qualified as T
import Flipstone.Prelude
import System.Timeout (timeout)

import Lockstep.Application.Database (DatabaseRuntime)
import Lockstep.Application.Engine (Engine, StepReport (..), activeTransactionIds, advance, pendingWorkOrders, startTransaction)

data EngineWorker
  = EngineWorker
  { workerStop :: MVar ()
  , workerDone :: MVar ()
  , workerThread :: ThreadId
  }

{- | One pass: the pending bugs started, then each active transaction
advanced once; what each advance did ('Left' for a refusal or an unready
database).
-}
engineOnce :: DatabaseRuntime -> Engine -> IO [(T.Text, Either T.Text T.Text)]
engineOnce runtime engine =
  enginePass runtime engine (pure False)

-- | A pass that ends early, between transactions, once the check says so.
enginePass :: DatabaseRuntime -> Engine -> IO Bool -> IO [(T.Text, Either T.Text T.Text)]
enginePass runtime engine stopping = do
  pending <- pendingWorkOrders runtime
  traverse_ (startTransaction runtime) (fromRight [] pending)
  active <- activeTransactionIds runtime
  each (fromRight [] active)
 where
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
    stepped <- advance runtime engine txId
    pure
      ( txId
      , case stepped of
          Left _ -> Left (T.pack "database-not-ready")
          Right (Left code) -> Left code
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
          Right _ -> pure ()
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
