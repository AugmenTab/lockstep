{- | The background dispatcher of @lockstep serve@ (contract C-P1.5 E4, E5).
It claims queued model-free no-op jobs and progresses them step by step, each
step in its own short transaction. Admission never waits for it.

The claim, lease and resume rules here are provisional skeleton behaviour for
the no-op kind only, which has no effect outside its job row; they are not the
DG-04 claim/replay protocol and must not be reused for a kind with an
external effect.
-}
module Lockstep.Application.Dispatcher
  ( JobState (..)
  , jobStateCode
  , Job (..)
  , findJob
  , findJobForReceipt
  , Dispatcher
  , startDispatcher
  , stopDispatcher
  , requestStop
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, tryPutMVar)
import Control.Exception (SomeException, try)
import Control.Monad (unless)
import Crypto.Random (getRandomBytes)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString qualified as BS
import Data.Maybe (isJust)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import System.Timeout (timeout)
import Text.Show (Show, show)

import Lockstep.Application.Database (DatabaseRuntime, withDatabase)
import Lockstep.Persistence.Jobs qualified as Jobs

data JobState
  = JobQueued
  | JobRunning
  | JobSucceeded
  | JobFailed
  deriving (Eq, Show)

jobStateCode :: JobState -> T.Text
jobStateCode state =
  T.pack $
    case state of
      JobQueued -> "queued"
      JobRunning -> "running"
      JobSucceeded -> "succeeded"
      JobFailed -> "failed"

parseJobState :: T.Text -> Maybe JobState
parseJobState code =
  case T.unpack code of
    "queued" -> Just JobQueued
    "running" -> Just JobRunning
    "succeeded" -> Just JobSucceeded
    "failed" -> Just JobFailed
    _ -> Nothing

data Job
  = Job
  { jobId :: Int64
  , jobReceiptId :: Int64
  , jobState :: JobState
  , jobStepsDone :: Int
  , jobStepsTotal :: Int
  , jobAttempts :: Int
  , jobRecovered :: Int
  , jobError :: Maybe T.Text
  }
  deriving (Eq, Show)

fromRow :: Jobs.JobRow -> Maybe Job
fromRow row = do
  state <- parseJobState (Jobs.jobRowState row)
  pure
    Job
      { jobId = Jobs.jobRowId row
      , jobReceiptId = Jobs.jobRowReceipt row
      , jobState = state
      , jobStepsDone = fromIntegral (Jobs.jobRowStepsDone row)
      , jobStepsTotal = fromIntegral (Jobs.jobRowStepsTotal row)
      , jobAttempts = fromIntegral (Jobs.jobRowAttempts row)
      , jobRecovered = fromIntegral (Jobs.jobRowRecovered row)
      , jobError = Jobs.jobRowError row
      }

findJob :: DatabaseRuntime -> Int64 -> IO (Maybe Job)
findJob runtime ident = do
  result <- withDatabase runtime (Jobs.findJobById ident)
  pure (either (const Nothing) (>>= fromRow) result)

findJobForReceipt :: DatabaseRuntime -> Int64 -> IO (Maybe Job)
findJobForReceipt runtime receipt = do
  result <- withDatabase runtime (Jobs.findJobByReceipt receipt)
  pure (either (const Nothing) (>>= fromRow) result)

data Dispatcher
  = Dispatcher
  { stopSignal :: MVar ()
  , finished :: MVar ()
  }

pollMicros :: Int
pollMicros =
  200000

{- | Starts the dispatcher thread. @logLine@ receives fixed lines only (job
ids and states, never request data).
-}
startDispatcher :: DatabaseRuntime -> (String -> IO ()) -> IO Dispatcher
startDispatcher runtime logLine = do
  stop <- newEmptyMVar
  done <- newEmptyMVar
  ownerBytes <- getRandomBytes 8 :: IO BS.ByteString
  let
    owner = TE.decodeLatin1 (convertToBase Base16 ownerBytes)
    dispatcher = Dispatcher stop done
  _ <- forkIO (loop dispatcher runtime logLine owner >> putMVar done ())
  pure dispatcher

-- | Signals the thread to stop between steps without waiting.
requestStop :: Dispatcher -> IO ()
requestStop dispatcher =
  void (tryPutMVar (stopSignal dispatcher) ())

-- | Signals the thread to stop between steps and waits for it (at most 10 s).
stopDispatcher :: Dispatcher -> IO ()
stopDispatcher dispatcher = do
  _ <- tryPutMVar (stopSignal dispatcher) ()
  void (timeout 10000000 (readMVar (finished dispatcher)))

-- | Waits up to the given time; 'True' if a stop was signalled meanwhile.
waitOrStop :: Dispatcher -> Int -> IO Bool
waitOrStop dispatcher micros =
  isJust <$> timeout micros (readMVar (stopSignal dispatcher))

loop :: Dispatcher -> DatabaseRuntime -> (String -> IO ()) -> T.Text -> IO ()
loop dispatcher runtime logLine owner = do
  outcome <- try (withDatabase runtime (Jobs.claimJob owner))
  stopped <-
    case outcome of
      Right (Right (Just row)) -> do
        result <- try (runJob dispatcher runtime logLine owner row)
        case result of
          Right stop -> pure stop
          Left err -> do
            logLine ("Dispatcher: job " <> show (Jobs.jobRowId row) <> " stopped by an error (" <> exceptionKind err <> ")")
            waitOrStop dispatcher pollMicros
      Right _ -> waitOrStop dispatcher pollMicros
      Left err -> do
        logLine ("Dispatcher: claim failed (" <> exceptionKind err <> ")")
        waitOrStop dispatcher pollMicros
  unless stopped (loop dispatcher runtime logLine owner)

exceptionKind :: SomeException -> String
exceptionKind _ =
  "exception"

{- | Runs the claimed job from its next step. Returns 'True' when a stop was
signalled (the job was released back to the queue).
-}
runJob :: Dispatcher -> DatabaseRuntime -> (String -> IO ()) -> T.Text -> Jobs.JobRow -> IO Bool
runJob dispatcher runtime logLine owner row =
  let
    ident = Jobs.jobRowId row
    total = Jobs.jobRowStepsTotal row
    micros = fromIntegral (Jobs.jobRowStepMillis row) * 1000
    finish state lastError = do
      _ <- withDatabase runtime (Jobs.finishJob ident owner (T.pack state) lastError)
      logLine ("Dispatcher: job " <> show ident <> " " <> state)
      pure False
    go step
      | step > total =
          finish "succeeded" Nothing
      | Just step == Jobs.jobRowFailAt row =
          finish "failed" (Just (T.pack ("deterministic failure injected at step " <> show step)))
      | otherwise = do
          stop <- waitOrStop dispatcher micros
          if stop
            then do
              _ <- withDatabase runtime (Jobs.releaseJob ident owner)
              logLine ("Dispatcher: job " <> show ident <> " returned to the queue at shutdown")
              pure True
            else do
              kept <- withDatabase runtime (Jobs.recordStep ident owner step)
              case kept of
                Right True -> go (step + 1)
                _ -> do
                  logLine ("Dispatcher: job " <> show ident <> " lost its lease")
                  pure False
  in
    do
      logLine ("Dispatcher: job " <> show ident <> " claimed (attempt " <> show (Jobs.jobRowAttempts row) <> ")")
      go (Jobs.jobRowStepsDone row + 1)
