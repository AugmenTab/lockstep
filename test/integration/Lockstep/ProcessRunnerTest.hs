{-# LANGUAGE OverloadedStrings #-}

{- | The direct finite runner against real processes (contract C-P4.2 R2):
exit codes and streams, too much output, the wall clock, a descendant that
outlives the program, cancellation, failures, refusals before anything
starts, and the restricted environment, input and descriptors.
-}
module Lockstep.ProcessRunnerTest
  ( tests
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import System.Directory (doesFileExist)
import System.IO (FilePath)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Signals (nullSignal, signalProcess)
import System.Posix.Types (CPid (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Read (readMaybe)
import Text.Show (show)

import Lockstep.Effects.Process (RunResult (..), cancelRun, newCancel, runDirect)
import Lockstep.Kernel.Runner (Limits (..), RunOutcome (..), RunSpec (..), Stream (..), outcomeSucceeded, runnerEnvironment)

tests :: TestTree
tests =
  testGroup
    "C-P4.2 direct finite runner (real processes)"
    [ testCase "exit code and both streams are reported as they were" exitAndStreams
    , testCase "too much standard output ends the run: output-limit, the first bytes kept" tooMuchStdout
    , testCase "too much standard error ends the run: output-limit" tooMuchStderr
    , testCase "the wall clock ends a run: timed-out, and the whole group is gone" wallClock
    , testCase "a descendant that outlives the program is killed with the group" lingeringDescendant
    , testCase "a cancelled run ends promptly: cancelled, and the group is gone" cancellation
    , testCase "a failing or killed program is never a success" failures
    , testCase "malformed requests are refused before anything starts" refusals
    , testCase "only the given environment reaches the program" environmentOnly
    , testCase "standard input is empty and no descriptor of Lockstep is inherited" inputAndDescriptors
    , testCase "a bare program name is looked up in the run's own PATH only" barePath
    ]

limits :: Limits
limits =
  Limits {limitWallMillis = 20000, limitStdoutBytes = 1048576, limitStderrBytes = 1048576}

specIn :: FilePath -> [T.Text] -> RunSpec
specIn dir argv =
  RunSpec
    { runArgv = argv
    , runDirectory = T.pack dir
    , runEnvironment = runnerEnvironment (T.pack dir)
    , runLimits = limits
    }

run :: RunSpec -> IO RunResult
run spec = do
  cancel <- newCancel
  result <- runDirect cancel spec
  case result of
    Right r -> pure r
    Left code -> assertFailure ("refused: " <> T.unpack code)

inTemp :: (FilePath -> Assertion) -> Assertion
inTemp =
  withSystemTempDirectory "lockstep-runner"

-- | The process id the program printed first, if it is still alive.
alive :: BS.ByteString -> IO Bool
alive out =
  case readMaybe (BS8.unpack (BS8.takeWhile (/= '\n') out)) of
    Nothing -> assertFailure ("no process id printed: " <> show out)
    Just n -> do
      probed <- try (signalProcess nullSignal (CPid n)) :: IO (Either IOException ())
      pure (either (const False) (const True) probed)

exitAndStreams :: Assertion
exitAndStreams =
  inTemp $ \dir -> do
    r <- run (specIn dir ["/bin/sh", "-c", "printf out; printf err >&2; exit 3"])
    resultOutcome r @?= Exited 3
    resultStdout r @?= "out"
    resultStderr r @?= "err"
    resultStdoutBytes r @?= 3
    resultDescendantsKilled r @?= False

tooMuchStdout :: Assertion
tooMuchStdout =
  inTemp $ \dir -> do
    r <- run (specIn dir ["/usr/bin/yes"]) {runLimits = limits {limitStdoutBytes = 65536}}
    resultOutcome r @?= OutputLimit Stdout
    BS.length (resultStdout r) @?= 65536
    assertBool "more was produced than kept" (resultStdoutBytes r > 65536)
    assertBool "it ended well before the wall clock" (resultMillis r < 10000)
    outcomeSucceeded (resultOutcome r) @?= False

tooMuchStderr :: Assertion
tooMuchStderr =
  inTemp $ \dir -> do
    r <- run (specIn dir ["/bin/sh", "-c", "yes >&2"]) {runLimits = limits {limitStderrBytes = 4096}}
    resultOutcome r @?= OutputLimit Stderr
    BS.length (resultStderr r) @?= 4096

wallClock :: Assertion
wallClock =
  inTemp $ \dir -> do
    r <- run (specIn dir ["/bin/sh", "-c", "sleep 30 & echo $!; wait"]) {runLimits = limits {limitWallMillis = 500}}
    resultOutcome r @?= TimedOut
    assertBool ("ended promptly: " <> show (resultMillis r)) (resultMillis r < 5000)
    still <- alive (resultStdout r)
    assertBool "the sleeping descendant is gone" (not still)

lingeringDescendant :: Assertion
lingeringDescendant =
  inTemp $ \dir -> do
    r <- run (specIn dir ["/bin/sh", "-c", "sleep 30 & echo $!"])
    resultOutcome r @?= Exited 0
    resultDescendantsKilled r @?= True
    assertBool ("ended promptly: " <> show (resultMillis r)) (resultMillis r < 5000)
    still <- alive (resultStdout r)
    assertBool "the descendant is gone" (not still)

cancellation :: Assertion
cancellation =
  inTemp $ \dir -> do
    cancel <- newCancel
    box <- newEmptyMVar
    _ <- forkIO (runDirect cancel (specIn dir ["/bin/sh", "-c", "sleep 30 & echo $!; wait"]) >>= putMVar box)
    threadDelay 300000
    cancelRun cancel
    result <- takeMVar box
    case result of
      Left code -> assertFailure ("refused: " <> T.unpack code)
      Right r -> do
        resultOutcome r @?= Cancelled
        assertBool ("ended promptly: " <> show (resultMillis r)) (resultMillis r < 5000)
        still <- alive (resultStdout r)
        assertBool "the descendant is gone" (not still)

failures :: Assertion
failures =
  inTemp $ \dir -> do
    r1 <- run (specIn dir ["/bin/false"])
    resultOutcome r1 @?= Exited 1
    outcomeSucceeded (resultOutcome r1) @?= False
    r2 <- run (specIn dir ["/bin/sh", "-c", "kill -9 $$"])
    assertBool ("killed: " <> show (resultOutcome r2)) (resultOutcome r2 /= Exited 0)
    outcomeSucceeded (resultOutcome r2) @?= False
    r3 <- run (specIn dir ["/bin/true"])
    outcomeSucceeded (resultOutcome r3) @?= True

refusals :: Assertion
refusals =
  inTemp $ \dir -> do
    let
      marker = dir <> "/marker"
      touch = specIn dir ["/bin/sh", "-c", "touch marker"]
      refused spec = do
        cancel <- newCancel
        r <- runDirect cancel spec
        pure (fromLeft "ran" r)
    cases <-
      traverse
        (\(name, spec) -> (,) name <$> refused spec)
        [ ("empty argv" :: T.Text, touch {runArgv = []})
        , ("empty program", touch {runArgv = [""]})
        , ("NUL in an argument", touch {runArgv = ["/bin/sh", "-c", "touch\NULmarker"]})
        , ("too many arguments", touch {runArgv = "/bin/sh" : L.replicate 1024 "x"})
        , ("relative program with a slash", touch {runArgv = ["bin/sh", "-c", "touch marker"]})
        , ("relative directory", touch {runDirectory = "relative"})
        , ("directory with ..", touch {runDirectory = T.pack dir <> "/../x"})
        , ("bad variable name", touch {runEnvironment = [("1X", "y")]})
        , ("repeated variable", touch {runEnvironment = [("A", "1"), ("A", "2")]})
        , ("NUL in a value", touch {runEnvironment = [("A", "x\NULy")]})
        , ("zero wall clock", touch {runLimits = limits {limitWallMillis = 0}})
        , ("negative output limit", touch {runLimits = limits {limitStdoutBytes = -1}})
        , ("missing directory", touch {runDirectory = T.pack dir <> "/missing"})
        , ("missing program", touch {runArgv = ["/no/such/program"]})
        , ("unknown bare name", touch {runArgv = ["no-such-program-lockstep"]})
        , ("bare name without PATH", touch {runArgv = ["sh", "-c", "touch marker"], runEnvironment = []})
        ]
    cases
      @?= [ ("empty argv", "argv-empty")
          , ("empty program", "argv-invalid")
          , ("NUL in an argument", "argv-invalid")
          , ("too many arguments", "argv-invalid")
          , ("relative program with a slash", "executable-not-absolute")
          , ("relative directory", "directory-invalid")
          , ("directory with ..", "directory-invalid")
          , ("bad variable name", "environment-invalid")
          , ("repeated variable", "environment-invalid")
          , ("NUL in a value", "environment-invalid")
          , ("zero wall clock", "limits-invalid")
          , ("negative output limit", "limits-invalid")
          , ("missing directory", "directory-missing")
          , ("missing program", "executable-missing")
          , ("unknown bare name", "executable-missing")
          , ("bare name without PATH", "executable-missing")
          ]
    started <- doesFileExist marker
    assertBool "nothing was started" (not started)

environmentOnly :: Assertion
environmentOnly =
  inTemp $ \dir -> do
    r <- run (specIn dir ["/usr/bin/env"])
    resultOutcome r @?= Exited 0
    L.sort (BS8.lines (resultStdout r))
      @?= L.sort
        [ "PATH=/usr/local/bin:/usr/bin:/bin"
        , BS8.pack ("HOME=" <> dir)
        , "LANG=C.UTF-8"
        , "LC_ALL=C.UTF-8"
        , "TZ=UTC"
        ]

inputAndDescriptors :: Assertion
inputAndDescriptors =
  inTemp $ \dir -> do
    r <- run (specIn dir ["/bin/sh", "-c", "cat; ls /proc/self/fd"])
    resultOutcome r @?= Exited 0
    -- ls's own directory handle is the fourth; nothing else is open.
    BS8.lines (resultStdout r) @?= ["0", "1", "2", "3"]

barePath :: Assertion
barePath =
  inTemp $ \dir -> do
    r <- run (specIn dir ["sh", "-c", "printf ok"])
    resultOutcome r @?= Exited 0
    resultStdout r @?= "ok"
