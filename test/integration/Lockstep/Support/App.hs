{-# LANGUAGE OverloadedStrings #-}

{- | Fixtures for the hand-over tests (contract C-P3.4 A3): a throwaway checkout
with the real helper and @scripts/service@, a migrated real database, the real
service, and a @docker@ stub that answers container questions itself but runs
@operator sign-in@ and @db status@ with the real @lockstep@ binary against that
database, so the token the helper hands over is one the real service accepts.
Nothing touches the operator's installation, configuration or containers.
-}
module Lockstep.Support.App
  ( AEnv (..)
  , aPane
  , aHelper
  , withAppEnv
  , setService
  , withAppHelper
  , appLog
  ) where

import Control.Exception (bracket)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Flipstone.Prelude
import System.Directory (copyFile, createDirectoryIfMissing)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath, IOMode (AppendMode), openFile, readFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty.HUnit (assertBool, assertFailure)
import Text.Show (show)

import Lockstep.Foundation.ControlProtocol (ChannelKey, parseChannelKey)
import Lockstep.Support.Postgres (AdminSettings (..), requireAdmin, withFreshDatabase, writeConfigFile)
import Lockstep.Support.Process (freePort, runLockstep, withService)

data AEnv
  = AEnv
  { aRoot :: FilePath
  , aState :: FilePath
  , aKey :: ChannelKey
  , aStub :: FilePath
  , aServicePort :: Int
  , aServiceEnv :: [(String, String)]
  }

aPane :: AEnv -> FilePath
aPane env =
  aState env <> "/pane"

aHelper :: AEnv -> FilePath
aHelper env =
  aState env <> "/helper"

keyHex :: BS.ByteString
keyHex =
  "aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9"

dockerStub :: String
dockerStub =
  L.unlines
    [ "#!/bin/sh"
    , "# docker stand-in for the hand-over tests (C-P3.4): the CLI calls go to the real binary"
    , "here=$(dirname \"$0\")/.."
    , "echo \"docker $*\" >> \"$here/log\""
    , "svc=$(cat \"$here/svc\" 2>/dev/null || echo running)"
    , "case \"$1 $2\" in"
    , "  'container inspect')"
    , "    case \"$*\" in *lockstep-postgres*) st=running ;; *) st=$svc ;; esac"
    , "    [ \"$st\" = absent ] && exit 1"
    , "    case \"$*\" in"
    , "      *State.Status*) if [ \"$st\" = running ]; then echo running; else echo exited; fi ;;"
    , "      *State.Running*) if [ \"$st\" = running ]; then echo true; else echo false; fi ;;"
    , "      *'range .Args'*) echo \"serve --port $(cat \"$here/port\")\" ;;"
    , "      *) echo 0 ;;"
    , "    esac"
    , "    exit 0 ;;"
    , "esac"
    , "case \"$1\" in"
    , "  version) echo 29.4.0; exit 0 ;;"
    , "  run)"
    , "    case \"$*\" in"
    , "      *'operator sign-in --port '*)"
    , "        port=$(printf '%s' \"$*\" | sed -n 's/.*operator sign-in --port \\([0-9]*\\).*/\\1/p')"
    , "        LOCKSTEP_CONFIG=$(cat \"$here/config\") exec lockstep operator sign-in --port \"$port\" ;;"
    , "      *'db status'*) LOCKSTEP_CONFIG=$(cat \"$here/config\") exec lockstep db status ;;"
    , "    esac ;;"
    , "esac"
    , "echo \"docker stub: unexpected $*\" >&2"
    , "exit 2"
    ]

writeText :: FilePath -> String -> IO ()
writeText path =
  BS.writeFile path . BS8.pack

{- | A migrated database, the real service on a free port, and a throwaway
checkout whose stub sends CLI calls to that database.
-}
withAppEnv :: (AEnv -> IO a) -> IO a
withAppEnv action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-handover" $ \base -> do
      config <- writeConfigFile base admin db (adminPassword admin)
      let
        serviceEnv = [("LOCKSTEP_CONFIG", config)]
        root = base <> "/checkout"
        state = root <> "/.local/control"
        stub = base <> "/stub"
      (code, _, err) <- runLockstep serviceEnv ["db", "migrate"]
      assertBool ("db migrate failed: " <> err) (code == ExitSuccess)
      traverse_ (createDirectoryIfMissing True) [root <> "/scripts", root <> "/.local/install/bin", root <> "/.local/config", stub <> "/bin"]
      traverse_
        (\f -> copyFile ("scripts/" <> f) (root <> "/scripts/" <> f) >> setFileMode (root <> "/scripts/" <> f) 0o755)
        ["control-helper", "service"]
      writeText (root <> "/.local/install/bin/lockstep") "#!/bin/sh\nexit 0\n"
      setFileMode (root <> "/.local/install/bin/lockstep") 0o755
      writeText (root <> "/.local/install/VERSION") "commit 0123456789abcdef0123456789abcdef01234567\ndirty false\nsha256 00\ninstalled_at 2026-10-26T00:00:00Z\n"
      writeText (root <> "/.local/config/lockstep.json") "{\"database\":{\"host\":\"lockstep-postgres\",\"port\":5432,\"name\":\"lockstep\",\"username\":\"lockstep\",\"password\":\"x\"}}\n"
      writeText (stub <> "/bin/docker") dockerStub
      setFileMode (stub <> "/bin/docker") 0o755
      port <- freePort
      traverse_ (\(f, v) -> writeText (stub <> "/" <> f) (v <> "\n")) [("svc", "running"), ("port", show port)]
      writeText (stub <> "/config") config
      writeText (stub <> "/log") ""
      writeText (stub <> "/helper.out") ""
      setFileMode (root <> "/.local") 0o700
      traverse_
        (\d -> createDirectoryIfMissing True d >> setFileMode d 0o700)
        [state, state <> "/pane", state <> "/helper", state <> "/pane/requests", state <> "/pane/results", state <> "/pane/signin"]
      BS.writeFile (state <> "/pane/pane.id") "c0ffee00c0ffee00c0ffee00c0ffee03\n"
      traverse_
        (\f -> BS.writeFile f (keyHex <> "\n") >> setFileMode f 0o600)
        [state <> "/pane/channel.key", state <> "/helper/channel.key"]
      key <- maybe (assertFailure "test key") pure (parseChannelKey keyHex)
      (result, _) <- withService serviceEnv port (base <> "/serve.log") (action (AEnv root state key stub port serviceEnv))
      pure result

-- | running or absent, as the stub reports the service container.
setService :: AEnv -> String -> IO ()
setService env value =
  writeText (aStub env <> "/svc") (value <> "\n")

appLog :: AEnv -> IO String
appLog env =
  readFile (aStub env <> "/helper.out")

withAppHelper :: AEnv -> IO a -> IO a
withAppHelper env action = do
  base <- getEnvironment
  let
    path = fromMaybe "/usr/bin:/bin" (L.lookup "PATH" base)
    vars = [("PATH", aStub env <> "/bin:" <> path)] <> L.filter (\(k, _) -> k `L.notElem` ["PATH", "LOCKSTEP_CONFIG", "LOCKSTEP_HELPER_TIMEOUT"]) base
    args = ["--state", aState env, "--service-port", show (aServicePort env)]
  bracket
    ( do
        logHandle <- openFile (aStub env <> "/helper.out") AppendMode
        (_, _, _, handle) <-
          Process.createProcess
            (Process.proc (aRoot env <> "/scripts/control-helper") args)
              { Process.env = Just vars
              , Process.cwd = Just (aStub env)
              , Process.std_out = Process.UseHandle logHandle
              , Process.std_err = Process.UseHandle logHandle
              }
        pure handle
    )
    (\h -> Process.terminateProcess h >> void (timeout 15000000 (Process.waitForProcess h)))
    (const action)
