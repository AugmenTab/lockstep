{-# LANGUAGE OverloadedStrings #-}

{- | Fixtures for the control-pane tests (contract C-P3.1 §5): a throwaway copy
of the checkout holding the real @scripts/control-helper@ and
@scripts/service@, a fake installation, a stub for @docker@ on @PATH@, and the
real pane binary. Nothing here touches the operator's installation,
configuration or containers.
-}
module Lockstep.Support.Control
  ( Env (..)
  , paneDir
  , helperDir
  , withEnv
  , setStubMode
  , helperEnvironment
  , startHelper
  , stopHelper
  , withHelper
  , paneEnvironment
  , withPaneOn
  , issueSignIn
  , currentSeconds
  , writeFileText
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket, try)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Flipstone.Prelude
import Network.HTTP.Client qualified as HTTPClient
import System.Directory (copyFile, createDirectoryIfMissing)
import System.Environment (getEnvironment)
import System.IO (FilePath, IOMode (AppendMode, WriteMode), openFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty.HUnit (Assertion, assertFailure)
import Text.Show (show)

import Lockstep.Foundation.ControlProtocol (ChannelKey, parseChannelKey, signInDigestHex)
import Lockstep.Foundation.OperatorToken (encodeToken, generateToken)
import Lockstep.Support.Http (HttpResponse (..), httpRequest)
import Lockstep.Support.Process (freePort)

data Env
  = Env
  { envRoot :: FilePath
  -- ^ the throwaway checkout
  , envState :: FilePath
  -- ^ the state root, holding @pane/@ and @helper/@
  , envKey :: ChannelKey
  , envKeyHex :: BS.ByteString
  , envStub :: FilePath
  -- ^ the stub's directory: @bin/docker@, @mode@, @log@, @pid@
  }

paneDir :: Env -> FilePath
paneDir env =
  envState env <> "/pane"

helperDir :: Env -> FilePath
helperDir env =
  envState env <> "/helper"

keyHex :: BS.ByteString
keyHex =
  "5a5b5c5d5e5f606162636465666768696a6b6c6d6e6f70717273747576777879"

{- | The stub for @docker@. Its behaviour is chosen by the file @mode@: normal,
slow (sleeps 30 s), delay (sleeps 1 s), markup, absent.
-}
dockerStub :: String
dockerStub =
  L.unlines
    [ "#!/bin/sh"
    , "# docker stand-in for the control-pane tests (C-P3.1 §5)"
    , "here=$(dirname \"$0\")/.."
    , "echo \"$*\" >> \"$here/log\""
    , "mode=$(cat \"$here/mode\" 2>/dev/null || echo normal)"
    , "case \"$1 $2\" in"
    , "  'container inspect')"
    , "    [ \"$mode\" = absent ] && exit 1"
    , "    case \"$*\" in"
    , "      *State.Running*) echo true ;;"
    , "      *State.Status*) echo 'running $(touch /tmp/lockstep-helper-pwned)' ;;"
    , "      *) echo '[]' ;;"
    , "    esac"
    , "    exit 0 ;;"
    , "esac"
    , "case \"$1\" in"
    , "  run)"
    , "    echo $$ > \"$here/pid\""
    , "    case \"$mode\" in"
    , "      slow) sleep 30 ;;"
    , "      delay) sleep 1 ;;"
    , "    esac"
    , "    if [ \"$mode\" = markup ]; then"
    , "      echo 'readiness <img src=x onerror=alert(1)>'"
    , "      exit 69"
    , "    fi"
    , "    printf 'readiness ready 5\\nrevision 5\\npending 0\\n'"
    , "    exit 0 ;;"
    , "esac"
    , "echo \"docker stub: unexpected $*\" >&2"
    , "exit 2"
    ]

-- | A throwaway checkout with the real helper and service scripts, a fake installation and the state layout the launcher leaves (C-P3.1 L2, L4, L7).
withEnv :: (Env -> IO a) -> IO a
withEnv action =
  withSystemTempDirectory "lockstep-control" $ \base -> do
    let
      root = base <> "/checkout"
      state = root <> "/.local/control"
      stub = base <> "/stub"
    traverse_ (createDirectoryIfMissing True) [root <> "/scripts", root <> "/.local/install/bin", root <> "/.local/config", stub <> "/bin"]
    traverse_
      (\f -> copyFile ("scripts/" <> f) (root <> "/scripts/" <> f) >> setFileMode (root <> "/scripts/" <> f) 0o755)
      ["control-helper", "service"]
    writeFileText (root <> "/.local/install/bin/lockstep") "#!/bin/sh\nexit 0\n"
    setFileMode (root <> "/.local/install/bin/lockstep") 0o755
    writeFileText (root <> "/.local/install/VERSION") "commit 0123456789abcdef0123456789abcdef01234567\ndirty false\nsha256 00\ninstalled_at 2026-10-25T00:00:00Z\n"
    writeFileText (root <> "/.local/config/lockstep.json") "{\"database\":{\"host\":\"lockstep-postgres\",\"port\":5432,\"name\":\"lockstep\",\"username\":\"lockstep\",\"password\":\"x\"}}\n"
    writeFileText (stub <> "/bin/docker") dockerStub
    setFileMode (stub <> "/bin/docker") 0o755
    writeFileText (stub <> "/mode") "normal\n"
    writeFileText (stub <> "/helper.out") ""
    createDirectoryIfMissing True state
    setFileMode (root <> "/.local") 0o700
    setFileMode state 0o700
    traverse_
      (\d -> createDirectoryIfMissing True d >> setFileMode d 0o700)
      [state <> "/pane", state <> "/helper", state <> "/pane/requests", state <> "/pane/results", state <> "/pane/signin"]
    BS.writeFile (state <> "/pane/pane.id") "c0ffee00c0ffee00c0ffee00c0ffee00\n"
    traverse_
      (\f -> BS.writeFile f (keyHex <> "\n") >> setFileMode f 0o600)
      [state <> "/pane/channel.key", state <> "/helper/channel.key"]
    key <- maybe (assertFailure "test key") pure (parseChannelKey keyHex)
    action (Env root state key keyHex stub)

writeFileText :: FilePath -> String -> IO ()
writeFileText path =
  BS.writeFile path . BS8.pack

setStubMode :: Env -> String -> IO ()
setStubMode env mode =
  writeFileText (envStub env <> "/mode") (mode <> "\n")

-- | This process's environment with the stub first on @PATH@ and the given overrides.
helperEnvironment :: Env -> [(String, String)] -> IO [(String, String)]
helperEnvironment env extra = do
  base <- getEnvironment
  let
    path = fromMaybe "/usr/bin:/bin" (L.lookup "PATH" base)
    overridden = ["PATH", "LOCKSTEP_HELPER_TIMEOUT"] <> fmap fst extra
  pure (extra <> [("PATH", envStub env <> "/bin:" <> path)] <> L.filter (\(k, _) -> k `L.notElem` overridden) base)

startHelper :: Env -> [(String, String)] -> IO Process.ProcessHandle
startHelper env extra = do
  vars <- helperEnvironment env extra
  logHandle <- openFile (envStub env <> "/helper.out") AppendMode
  (_, _, _, handle) <-
    Process.createProcess
      (Process.proc (envRoot env <> "/scripts/control-helper") ["--state", envState env])
        { Process.env = Just vars
        , Process.cwd = Just (envStub env)
        , Process.std_out = Process.UseHandle logHandle
        , Process.std_err = Process.UseHandle logHandle
        }
  pure handle

stopHelper :: Process.ProcessHandle -> IO ()
stopHelper handle = do
  Process.terminateProcess handle
  void (timeout 10000000 (Process.waitForProcess handle))

withHelper :: Env -> [(String, String)] -> IO a -> IO a
withHelper env extra action =
  bracket (startHelper env extra) stopHelper (const action)

-- | This process's environment without any database configuration.
paneEnvironment :: IO [(String, String)]
paneEnvironment =
  L.filter (\(k, _) -> k /= "LOCKSTEP_CONFIG") <$> getEnvironment

{- | Runs @lockstep control serve@ on a free port with the given pane state
directory, waits for @/api/health@, runs the action with the port, then stops
the pane with SIGTERM.
-}
withPaneOn :: FilePath -> [(String, String)] -> (Int -> IO a) -> IO a
withPaneOn dir extraEnv action = do
  port <- freePort
  env <- paneEnvironment
  logHandle <- openFile (dir <> ".log") WriteMode
  bracket
    ( do
        (_, _, _, handle) <-
          Process.createProcess
            (Process.proc "lockstep" ["control", "serve", "--port", show port, "--state", dir])
              { Process.env = Just (extraEnv <> env)
              , Process.std_out = Process.UseHandle logHandle
              , Process.std_err = Process.UseHandle logHandle
              }
        pure handle
    )
    (\handle -> Process.terminateProcess handle >> void (timeout 5000000 (Process.waitForProcess handle)))
    (\handle -> waitHealthy handle port >> action port)

waitHealthy :: Process.ProcessHandle -> Int -> Assertion
waitHealthy handle port =
  let
    attempt :: Int -> Assertion
    attempt remaining = do
      exited <- Process.getProcessExitCode handle
      case exited of
        Just code -> assertFailure ("the pane exited before answering: " <> show code)
        Nothing -> do
          r <- try (httpRequest port "GET" "/api/health" [] "") :: IO (Either HTTPClient.HttpException HttpResponse)
          case r of
            Right resp | responseStatus resp == 204 -> pure ()
            _ ->
              if remaining <= 0
                then assertFailure "the pane did not answer /api/health with 204 within 10 s"
                else threadDelay 100000 >> attempt (remaining - 1)
  in
    attempt 100

-- | Issues a sign-in token the way the launcher does (C-P3.1 L5); returns its text.
issueSignIn :: FilePath -> Integer -> IO T.Text
issueSignIn dir lifetime = do
  token <- encodeToken <$> generateToken
  now <- currentSeconds
  let
    path = dir <> "/signin/" <> T.unpack (signInDigestHex token)
  BS.writeFile path ("expires " <> BS8.pack (show (now + lifetime)) <> "\n")
  setFileMode path 0o600
  pure token

currentSeconds :: IO Integer
currentSeconds =
  floor <$> getPOSIXTime
