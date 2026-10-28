{- | The engine worker (contract C-P4.15 W1): one thread that keeps coding
transactions moving. Each pass first starts a transaction for every
handed-over bug that has none, in hand-over order (an Engineer whose one
writer is busy is tried again next pass), then advances every running or
halted transaction once, in the order they were started; a halted one only
moves when a person has answered its request. One pass at a time, one step
per transaction per pass: there is never a second writer.

An error in a pass is logged and the next pass runs; an asynchronous
exception (the worker being stopped or the service shutting down) is never
swallowed.
-}
module Lockstep.Application.EngineWorker
  ( EngineWorker
  , startEngineWorker
  , stopEngineWorker
  , engineOnce
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, tryPutMVar, tryReadMVar)
import Control.Exception (SomeAsyncException, SomeException, displayException, fromException, throwIO, try)
import Data.Text qualified as T
import Flipstone.Prelude

import Lockstep.Application.Database (DatabaseRuntime)
import Lockstep.Application.Engine (Engine, StepReport (..), activeTransactionIds, advance, pendingWorkOrders, startTransaction)

data EngineWorker
  = EngineWorker
  { workerStop :: MVar ()
  , workerDone :: MVar ()
  }

{- | One pass: the pending bugs started, then each active transaction
advanced once; what each advance did ('Left' for a refusal or an unready
database).
-}
engineOnce :: DatabaseRuntime -> Engine -> IO [(T.Text, Either T.Text T.Text)]
engineOnce runtime engine = do
  pending <- pendingWorkOrders runtime
  traverse_ (startTransaction runtime) (fromRight [] pending)
  active <- activeTransactionIds runtime
  traverse one (fromRight [] active)
 where
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
    loop = do
      stopping <- tryReadMVar stop
      case stopping of
        Just () -> putMVar done ()
        Nothing -> do
          passed <- try (engineOnce runtime engine)
          case passed of
            Left (e :: SomeException)
              | Just (_ :: SomeAsyncException) <- fromException e -> putMVar done () >> throwIO e
              | otherwise -> logLine ("engine pass failed: " <> displayException e)
            Right _ -> pure ()
          threadDelay (interval * 1000)
          loop
  _ <- forkIO loop
  pure (EngineWorker stop done)

-- | Stops the worker after its current pass and waits for it.
stopEngineWorker :: EngineWorker -> IO ()
stopEngineWorker worker = do
  _ <- tryPutMVar (workerStop worker) ()
  readMVar (workerDone worker)
