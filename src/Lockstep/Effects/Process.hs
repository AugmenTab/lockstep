{- | The direct finite runner (contract C-P4.2 R2). Runs one checked
'RunSpec' as a local process group: the argument vector as given (no shell),
exactly the given environment, standard input from @/dev/null@, no inherited
file descriptors, standard output and error captured up to their limits.

The run ends at the first of: the program exits, the wall clock runs out,
a stream passes its limit, or the caller cancels. Whatever ends it, every
process still in the group is terminated (TERM, then KILL after 2 s), so a
descendant that outlives the program, or keeps its output open, does not
outlive the run.

What this runner does not give: a network or filesystem boundary, or control
of a descendant that leaves the process group. Those come from the container
runner (DG-17 D-17.1(a)); the direct runner is for model-free roles,
deterministic commands and the test suite.
-}
module Lockstep.Effects.Process
  ( Cancel
  , newCancel
  , cancelRun
  , RunResult (..)
  , runDirect
  ) where

import Control.Concurrent (ThreadId, forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (MVar, newEmptyMVar, readMVar, tryPutMVar, tryReadMVar)
import Control.Exception (IOException, displayException, finally, onException, try)
import Data.ByteString qualified as BS
import Data.List qualified as L
import Data.Maybe (fromMaybe, isNothing)
import Data.Text qualified as T
import Flipstone.Prelude
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (doesDirectoryExist, doesFileExist, executable, getPermissions)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.IO (FilePath, Handle, IOMode (ReadMode), hClose, openFile)
import System.Posix.Signals (Signal, nullSignal, sigKILL, sigTERM, signalProcessGroup)
import System.Posix.Types (ProcessGroupID)
import System.Process qualified as Process
import Text.Show (Show)

import Lockstep.Kernel.Runner (Limits (..), RunOutcome (..), RunSpec (..), Stream (..), checkSpec)

-- | A cancellation the caller can trigger once, from any thread.
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
  -- ^ at most the limit
  , resultStderr :: BS.ByteString
  , resultStdoutBytes :: Int
  -- ^ bytes observed; more than the limit means the output was cut
  , resultStderrBytes :: Int
  , resultMillis :: Int
  , resultDescendantsKilled :: Bool
  -- ^ processes of the group were still running when the program ended
  }
  deriving (Eq, Show)

data Event
  = EventExit
  | EventTimeout
  | EventCancel
  | EventOverflow Stream

{- | Refuses before starting with a 'checkSpec' code, @directory-missing@ or
@executable-missing@; otherwise runs once.
-}
runDirect :: Cancel -> RunSpec -> IO (Either T.Text RunResult)
runDirect cancel spec =
  case checkSpec spec of
    Left code -> pure (Left code)
    Right checked -> do
      directoryExists <- doesDirectoryExist (T.unpack (runDirectory checked))
      program <- resolve checked
      case (directoryExists, program) of
        (False, _) -> pure (Left (T.pack "directory-missing"))
        (_, Nothing) -> pure (Left (T.pack "executable-missing"))
        (True, Just path) -> Right <$> launch cancel checked path

-- | An absolute program as it is; a bare name in the run's own PATH.
resolve :: RunSpec -> IO (Maybe FilePath)
resolve spec =
  case runArgv spec of
    [] -> pure Nothing
    program : _
      | T.isPrefixOf (T.pack "/") program -> runnable (T.unpack program)
      | otherwise -> firstRunnable [d <> "/" <> T.unpack program | d <- searchPath, not (L.null d)]
 where
  searchPath =
    maybe [] (fmap T.unpack . T.splitOn (T.pack ":")) (L.lookup (T.pack "PATH") (runEnvironment spec))
  firstRunnable candidates =
    case candidates of
      [] -> pure Nothing
      c : rest -> runnable c >>= maybe (firstRunnable rest) (pure . Just)
  runnable path = do
    -- A file that disappears or cannot be inspected between the checks is not runnable.
    permissions <- try (doesFileExist path >>= \isFile -> if isFile then Just <$> getPermissions path else pure Nothing)
    pure $ case permissions of
      Right (Just p) | executable p -> Just path
      Right _ -> Nothing
      Left (_ :: IOException) -> Nothing

launch :: Cancel -> RunSpec -> FilePath -> IO RunResult
launch (Cancel cancelled) spec program = do
  started <- getMonotonicTimeNSec
  opened <- try (openFile "/dev/null" ReadMode)
  case opened of
    Left (e :: IOException) -> failedLaunch (T.take 200 (T.pack (displayException e))) <$> since started
    Right devNull -> spawn cancelled spec program started devNull

spawn :: MVar () -> RunSpec -> FilePath -> Word64 -> Handle -> IO RunResult
spawn cancelled spec program started devNull = do
  created <-
    try $
      Process.createProcess
        (Process.proc program (fmap T.unpack (L.drop 1 (runArgv spec))))
          { Process.cwd = Just (T.unpack (runDirectory spec))
          , Process.env = Just [(T.unpack k, T.unpack v) | (k, v) <- runEnvironment spec]
          , Process.std_in = Process.UseHandle devNull
          , Process.std_out = Process.CreatePipe
          , Process.std_err = Process.CreatePipe
          , Process.close_fds = True
          , Process.create_group = True
          , Process.delegate_ctlc = False
          }
  case created of
    Left (e :: IOException) -> do
      hClose devNull
      failedLaunch (T.take 200 (T.pack (displayException e))) <$> since started
    Right (_, Just out, Just err, handle) -> do
      pid <- Process.getPid handle
      case pid of
        Nothing -> do
          -- The program was already reaped: nothing is left to supervise.
          code <- Process.waitForProcess handle
          exitedEarly code <$> since started
        Just p -> supervise cancelled (runLimits spec) started p handle out err
    Right _ -> failedLaunch (T.pack "no pipes") <$> since started

-- | Milliseconds since a monotonic start.
since :: Word64 -> IO Int
since started =
  millisBetween started <$> getMonotonicTimeNSec

supervise :: MVar () -> Limits -> Word64 -> ProcessGroupID -> Process.ProcessHandle -> Handle -> Handle -> IO RunResult
supervise cancelled limits started group handle out err = do
  events <- newEmptyMVar
  exitCode <- newEmptyMVar
  stdoutDone <- newEmptyMVar
  stderrDone <- newEmptyMVar
  outReader <- forkIO (readCapped out (limitStdoutBytes limits) Stdout events stdoutDone)
  errReader <- forkIO (readCapped err (limitStderrBytes limits) Stderr events stderrDone)
  helpers <-
    traverse
      forkIO
      [ do
          -- A failure to wait is an unknown exit, never a success.
          code <- try (Process.waitForProcess handle)
          void (tryPutMVar exitCode (either (\(_ :: IOException) -> ExitFailure (-1)) id code))
          void (tryPutMVar events EventExit)
      , threadDelay (limitWallMillis limits * 1000) >> void (tryPutMVar events EventTimeout)
      , readMVar cancelled >> void (tryPutMVar events EventCancel)
      ]
  let
    body = do
      event <- readMVar events
      leftovers <- groupAlive group
      descendants <-
        case event of
          EventExit -> do
            when leftovers (terminate group exitCode)
            pure leftovers
          _ -> do
            terminate group exitCode
            pure False
      _ <- waitFor 5000 (readMVar exitCode)
      outRead <- finishReader 2000 outReader out stdoutDone
      errRead <- finishReader 2000 errReader err stderrDone
      code <- tryReadMVar exitCode
      finished <- getMonotonicTimeNSec
      traverse_ killThread helpers
      let
        (outBytes, outTotal) = fromMaybe (BS.empty, 0) outRead
        (errBytes, errTotal) = fromMaybe (BS.empty, 0) errRead
        outcome =
          case event of
            EventTimeout -> TimedOut
            EventCancel -> Cancelled
            EventOverflow stream -> OutputLimit stream
            EventExit
              | isNothing outRead -> OutputHeld Stdout
              | isNothing errRead -> OutputHeld Stderr
              | outTotal > limitStdoutBytes limits -> OutputLimit Stdout
              | errTotal > limitStderrBytes limits -> OutputLimit Stderr
              | otherwise -> Exited (maybe (-1) exitNumber code)
      pure
        RunResult
          { resultOutcome = outcome
          , resultStdout = outBytes
          , resultStderr = errBytes
          , resultStdoutBytes = outTotal
          , resultStderrBytes = errTotal
          , resultMillis = millisBetween started finished
          , resultDescendantsKilled = descendants
          }
  body `onException` (killIfAlive group >> traverse_ killThread (outReader : errReader : helpers))

{- | Reads in chunks, keeping at most the limit; past the limit it reports the
overflow and stops reading (the run is ended by the supervisor).
-}
readCapped :: Handle -> Int -> Stream -> MVar Event -> MVar (BS.ByteString, Int) -> IO ()
readCapped h limit stream events done =
  loop [] 0
 where
  loop chunks total = do
    chunk <- fromRight BS.empty <$> (try (BS.hGetSome h 65536) :: IO (Either IOException BS.ByteString))
    if BS.null chunk
      then void (tryPutMVar done (keep chunks, total))
      else do
        let
          total' = total + BS.length chunk
        if total' > limit
          then do
            void (tryPutMVar done (keep (chunk : chunks), total'))
            void (tryPutMVar events (EventOverflow stream))
          else loop (chunk : chunks) total'
  keep chunks =
    BS.take limit (BS.concat (L.reverse chunks))

{- | TERM to the group, up to 2 s for it to end, then KILL if it is still
there. A group is signalled only while it exists: a group id is not reused
while any process (even an unreaped leader) still belongs to it, so a group
that has ended is never signalled again (its id could belong to another).
-}
terminate :: ProcessGroupID -> MVar ExitCode -> IO ()
terminate group exitCode = do
  signalIfAlive sigTERM group
  ended <-
    waitFor 2000 $
      let
        settle = do
          exited <- tryReadMVar exitCode
          alive <- groupAlive group
          case (exited, alive) of
            (Just _, False) -> pure ()
            _ -> threadDelay 50000 >> settle
      in
        settle
  when (isNothing ended) (killIfAlive group)

killIfAlive :: ProcessGroupID -> IO ()
killIfAlive =
  signalIfAlive sigKILL

signalIfAlive :: Signal -> ProcessGroupID -> IO ()
signalIfAlive signal group = do
  alive <- groupAlive group
  when alive (void (try (signalProcessGroup signal group) :: IO (Either IOException ())))

groupAlive :: ProcessGroupID -> IO Bool
groupAlive group =
  either (const False) (const True) <$> (try (signalProcessGroup nullSignal group) :: IO (Either IOException ()))

-- | The reader's result, or nothing if the stream is still open after the grace period.
finishReader :: Int -> ThreadId -> Handle -> MVar (BS.ByteString, Int) -> IO (Maybe (BS.ByteString, Int))
finishReader millis reader h done = do
  result <- waitFor millis (readMVar done)
  when (isNothing result) (killThread reader)
  void (try (hClose h) :: IO (Either IOException ()))
  pure result

-- | The action's result within the time, or nothing; its threads never outlive the call.
waitFor :: Int -> IO a -> IO (Maybe a)
waitFor millis action = do
  box <- newEmptyMVar
  worker <- forkIO (action >>= void . tryPutMVar box . Just)
  timer <- forkIO (threadDelay (millis * 1000) >> void (tryPutMVar box Nothing))
  readMVar box `finally` (killThread worker >> killThread timer)

exitNumber :: ExitCode -> Int
exitNumber code =
  case code of
    ExitSuccess -> 0
    ExitFailure n -> n

millisBetween :: Word64 -> Word64 -> Int
millisBetween started finished =
  fromIntegral ((finished - started) `div` 1000000)

failedLaunch :: T.Text -> Int -> RunResult
failedLaunch reason millis =
  RunResult (LaunchFailed reason) BS.empty BS.empty 0 0 millis False

exitedEarly :: ExitCode -> Int -> RunResult
exitedEarly code millis =
  RunResult (Exited (exitNumber code)) BS.empty BS.empty 0 0 millis False
