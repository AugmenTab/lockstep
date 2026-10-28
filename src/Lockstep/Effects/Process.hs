{- | The direct finite runner (contract C-P4.2 R2). Pre-freeze stub: the final
types, every run refused with @not-implemented@.
-}
module Lockstep.Effects.Process
  ( Cancel
  , newCancel
  , cancelRun
  , RunResult (..)
  , runDirect
  ) where

import Control.Concurrent.MVar (MVar, newEmptyMVar, tryPutMVar)
import Data.ByteString qualified as BS
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Runner (RunOutcome, RunSpec)

newtype Cancel
  = Cancel (MVar ())

newCancel :: IO Cancel
newCancel =
  Cancel <$> newEmptyMVar

cancelRun :: Cancel -> IO ()
cancelRun (Cancel signal) =
  void (tryPutMVar signal ())

data RunResult
  = RunResult
  { resultOutcome :: RunOutcome
  , resultStdout :: BS.ByteString
  , resultStderr :: BS.ByteString
  , resultStdoutBytes :: Int
  , resultStderrBytes :: Int
  , resultMillis :: Int
  , resultDescendantsKilled :: Bool
  }
  deriving (Eq, Show)

runDirect :: Cancel -> RunSpec -> IO (Either T.Text RunResult)
runDirect _ _ =
  pure (Left (T.pack "not-implemented"))
