{-# LANGUAGE OverloadedStrings #-}

{- | The service's runner client against the real host helper (contract C-P4.2
R3, R4). The helper is the real @scripts/control-helper@ with @--runner@ in a
throwaway state directory; @docker@ is a stand-in on its PATH that runs the
requested program directly in the run's tree, so the protocol, signatures,
refusals, cancellation and results are exercised end to end. The container
boundary itself is checked on the host by @scripts/lib/check-runner@.
-}
module Lockstep.HelperRunnerTest
  ( tests
  ) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracket)
import Control.Monad (unless)
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import System.Directory (copyFile, createDirectory, createDirectoryIfMissing, doesFileExist, listDirectory)
import System.Environment (getEnvironment)
import System.IO (FilePath, writeFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Process qualified as Process
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Effects.HelperRunner
  ( HelperFailure (..)
  , PreparedRun (..)
  , RunnerChannel
  , openRunnerChannel
  , prepareRun
  , requestCancel
  , submitRun
  )
import Lockstep.Effects.Process (RunResult (..))
import Lockstep.Foundation.RunnerProtocol (RunProfile (..))
import Lockstep.Kernel.Runner (RunOutcome (..))

tests :: TestTree
tests =
  testGroup
    "C-P4.2 runner client and the real host helper"
    [ testCase "a run through the helper: exit code, streams and signed digests" throughHelper
    , testCase "the helper's refusal reaches the caller and nothing runs" helperRefusal
    , testCase "a cancelled run is reported cancelled" cancelled
    , testCase "without a helper there is no result: an unknown outcome, not a failure" noHelper
    , testCase "an invalid request is refused before anything is sent" invalidRequest
    ]

dockerStub :: String
dockerStub =
  L.unlines
    [ "#!/bin/sh"
    , "# docker stand-in for the runner client tests (C-P4.2): runs the program directly in the tree"
    , "here=$(cd \"$(dirname \"$0\")/..\" && pwd)"
    , "echo \"$*\" >> \"$here/log\""
    , "case \"$1\" in"
    , "  image) echo sha256:stub; exit 0 ;;"
    , "  ps) exit 0 ;;"
    , "  kill) [ -f \"$here/pid\" ] && kill \"$(cat \"$here/pid\")\" 2>/dev/null; exit 0 ;;"
    , "  rm) exit 0 ;;"
    , "  run)"
    , "    shift"
    , "    dir=''"
    , "    while [ $# -gt 0 ]; do"
    , "      case \"$1\" in"
    , "        --mount)"
    , "          case \"$2\" in type=bind,source=*,target=/work/tree|type=bind,source=*,target=/work/tree,readonly) dir=${2#type=bind,source=}; dir=${dir%%,target=*} ;; esac"
    , "          shift 2 ;;"
    , "        sha256:stub) shift; break ;;"
    , "        *) shift ;;"
    , "      esac"
    , "    done"
    , "    cd \"$dir\" || exit 125"
    , "    echo $$ > \"$here/pid\""
    , "    exec \"$@\" ;;"
    , "esac"
    , "exit 2"
    ]

-- | A real helper with --runner on a throwaway state directory, and its channel.
withHelper :: (FilePath -> RunnerChannel -> Assertion) -> Assertion
withHelper body =
  withSystemTempDirectory "lockstep-helper-runner" $ \tmp -> do
    let
      state = tmp <> "/state"
      stub = tmp <> "/stub"
    createDirectoryIfMissing True (tmp <> "/scripts")
    copyFile "scripts/control-helper" (tmp <> "/scripts/control-helper")
    setFileMode (tmp <> "/scripts/control-helper") 0o755
    traverse_ (\d -> createDirectory d >> setFileMode d 0o700) [state, state <> "/helper", state <> "/pane"]
    writeFile (state <> "/helper/channel.key") (L.replicate 64 'a')
    createDirectoryIfMissing True (stub <> "/bin")
    writeFile (stub <> "/bin/docker") dockerStub
    setFileMode (stub <> "/bin/docker") 0o755
    base <- getEnvironment
    let
      path = stub <> "/bin:" <> fromMaybe "/usr/bin:/bin" (L.lookup "PATH" base)
      env = ("PATH", path) : L.filter ((/= "PATH") . fst) base
      start =
        Process.createProcess
          (Process.proc (tmp <> "/scripts/control-helper") ["--state", state, "--instance", "p42t", "--runner"])
            { Process.env = Just env
            , Process.std_in = Process.NoStream
            , Process.std_out = Process.NoStream
            , Process.std_err = Process.NoStream
            }
      stop (_, _, _, handle) = Process.terminateProcess handle >> void (Process.waitForProcess handle)
    bracket start stop $ \_ -> do
      ready <- waitForFile 100 (state <> "/runner/channel.key")
      unless ready (assertFailure "the helper did not make the runner key")
      channel <- openRunnerChannel (state <> "/runner")
      case channel of
        Left code -> assertFailure ("channel: " <> T.unpack code)
        Right c -> body tmp c

waitForFile :: Int -> FilePath -> IO Bool
waitForFile ticks path = do
  present <- doesFileExist path
  if present || ticks <= 0
    then pure present
    else threadDelay 100000 >> waitForFile (ticks - 1) path

throughHelper :: Assertion
throughHelper =
  withHelper $ \_ channel -> do
    prepared <- prepareRun channel
    result <- submitRun channel prepared ProfileVerify ["/bin/sh", "-c", "echo hi; echo err >&2; exit 3"] [] 30
    case result of
      Left failure -> assertFailure ("failed: " <> show failure)
      Right r -> do
        resultOutcome r @?= Exited 3
        resultStdout r @?= "hi\n"
        resultStderr r @?= "err\n"
        resultStdoutBytes r @?= 3

helperRefusal :: Assertion
helperRefusal =
  withHelper $ \_ channel -> do
    prepared <- prepareRun channel
    result <- submitRun channel prepared ProfileWrite ["/bin/sh", "-c", "touch ran"] ["tests/missing.py"] 30
    result @?= Left (HelperRefused "protected-invalid")
    ran <- doesFileExist (preparedTree prepared <> "/ran")
    ran @?= False

cancelled :: Assertion
cancelled =
  withHelper $ \_ channel -> do
    prepared <- prepareRun channel
    box <- newEmptyMVar
    _ <- forkIO (submitRun channel prepared ProfileVerify ["/bin/sleep", "30"] [] 60 >>= putMVar box)
    threadDelay 1500000
    cancel <- requestCancel channel (preparedName prepared)
    cancel @?= Right ()
    result <- takeMVar box
    fmap resultOutcome result @?= Right Cancelled

noHelper :: Assertion
noHelper =
  withSystemTempDirectory "lockstep-no-helper" $ \tmp -> do
    traverse_ (\d -> createDirectory (tmp <> d)) ["/requests", "/results", "/work"]
    writeFile (tmp <> "/channel.key") (L.replicate 64 'b')
    channel <- openRunnerChannel tmp
    case channel of
      Left code -> assertFailure ("channel: " <> T.unpack code)
      Right c -> do
        prepared <- prepareRun c
        result <- submitRun c prepared ProfileVerify ["/bin/true"] [] 1
        result @?= Left HelperNoResult
    missing <- openRunnerChannel (tmp <> "/absent")
    fromLeft "opened" missing @?= "runner-unavailable"

invalidRequest :: Assertion
invalidRequest =
  withSystemTempDirectory "lockstep-invalid-run" $ \tmp -> do
    traverse_ (\d -> createDirectory (tmp <> d)) ["/requests", "/results", "/work"]
    writeFile (tmp <> "/channel.key") (L.replicate 64 'c')
    channel <- openRunnerChannel tmp
    case channel of
      Left code -> assertFailure ("channel: " <> T.unpack code)
      Right c -> do
        prepared <- prepareRun c
        r1 <- submitRun c prepared ProfileVerify [] [] 1
        r1 @?= Left (HelperRequestInvalid "argv-empty")
        r2 <- submitRun c prepared ProfileWrite ["/bin/true"] ["../outside"] 1
        r2 @?= Left (HelperRequestInvalid "protected-invalid")
        r3 <- submitRun c prepared ProfileWrite ["/bin/true"] ["/etc/passwd"] 1
        r3 @?= Left (HelperRequestInvalid "protected-invalid")
        sent <- listDirectory (tmp <> "/requests")
        sent @?= []
