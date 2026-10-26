{-# LANGUAGE OverloadedStrings #-}

{- | Fixtures for the lifecycle tests (contract C-P3.2 §4): like
"Lockstep.Support.Control", a throwaway checkout with the real helper,
@scripts/service@ and @scripts/db@, but with @docker@ and @curl@ stubs that keep
state, so a start, stop or restart can be observed afterwards. Nothing here
touches the operator's installation, configuration or containers.

Stub state files in the stub directory: @svc@ (running, stopped, absent), @db@
(running, stopped, absent), @ready@ (yes: the schema matches; no: behind) and
@mode@ (normal, fail-start, no-answer, slow). Every call is appended to @log@.
-}
module Lockstep.Support.Lifecycle
  ( LEnv (..)
  , lPane
  , lHelper
  , withLifecycleEnv
  , setStub
  , readStub
  , stubLog
  , startLifecycleHelper
  , withLifecycleHelper
  , servicePort
  ) where

import Control.Exception (SomeException, bracket, try)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Flipstone.Prelude
import System.Directory (copyFile, createDirectoryIfMissing)
import System.Environment (getEnvironment)
import System.IO (FilePath, IOMode (AppendMode), openFile, readFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty.HUnit (assertFailure)
import Text.Show (show)

import Lockstep.Foundation.ControlProtocol (ChannelKey, parseChannelKey)

data LEnv
  = LEnv
  { lRoot :: FilePath
  , lState :: FilePath
  , lKey :: ChannelKey
  , lStub :: FilePath
  , lInstance :: Maybe String
  }

lPane :: LEnv -> FilePath
lPane env =
  lState env <> "/pane"

lHelper :: LEnv -> FilePath
lHelper env =
  lState env <> "/helper"

-- | The service port the helper is started with.
servicePort :: Int
servicePort =
  8155

keyHex :: BS.ByteString
keyHex =
  "7a7b7c7d7e7f808182838485868788898a8b8c8d8e8f90919293949596979899"

dockerStub :: String
dockerStub =
  L.unlines
    [ "#!/bin/sh"
    , "# docker stand-in with state for the lifecycle tests (C-P3.2 §4)"
    , "here=$(dirname \"$0\")/.."
    , "echo \"docker $*\" >> \"$here/log\""
    , "get() { cat \"$here/$1\" 2>/dev/null || echo \"$2\"; }"
    , "put() { echo \"$2\" > \"$here/$1\"; }"
    , "mode=$(get mode normal)"
    , "state_of() { case \"$1\" in lockstep-postgres) get db running ;; *) get svc absent ;; esac; }"
    , "last=''; for a in \"$@\"; do last=$a; done"
    , "case \"$1\" in"
    , "  version) echo 29.4.0; exit 0 ;;"
    , "  network) exit 0 ;;"
    , "  container)"
    , "    shift 2; fmt=''"
    , "    while [ $# -gt 1 ]; do case \"$1\" in --format|-f) fmt=$2; shift 2 ;; *) shift ;; esac; done"
    , "    st=$(state_of \"$1\")"
    , "    [ \"$st\" = absent ] && exit 1"
    , "    case \"$fmt\" in"
    , "      *State.Status*) if [ \"$st\" = running ]; then echo running; else echo exited; fi ;;"
    , "      *State.Running*) if [ \"$st\" = running ]; then echo true; else echo false; fi ;;"
    , "      *ExitCode*) echo 0 ;;"
    , "      *) echo '[]' ;;"
    , "    esac"
    , "    exit 0 ;;"
    , "  run)"
    , "    case \"$*\" in"
    , "      *'db status'*)"
    , "        if [ \"$(get ready yes)\" = yes ]; then printf 'readiness ready 5\\nrevision 5\\npending 0\\n'; exit 0; fi"
    , "        printf 'readiness not_ready schema_behind 1\\nrevision 4\\npending 1\\n'; exit 69 ;;"
    , "      *lockstep-postgres*) put db running; echo id; exit 0 ;;"
    , "      *' serve '*)"
    , "        [ \"$mode\" = slow ] && sleep 30"
    , "        if [ \"$mode\" = fail-start ]; then echo 'docker: Error: port is already allocated' >&2; exit 125; fi"
    , "        put svc running; echo id; exit 0 ;;"
    , "    esac ;;"
    , "  start) [ \"$last\" = lockstep-postgres ] && put db running; exit 0 ;;"
    , "  stop) if [ \"$last\" = lockstep-postgres ]; then put db stopped; else put svc stopped; fi; exit 0 ;;"
    , "  rm) put svc absent; exit 0 ;;"
    , "  logs) echo 'service log'; exit 0 ;;"
    , "  exec)"
    , "    case \"$*\" in"
    , "      *pg_isready*) [ \"$(get db running)\" = running ]; exit $? ;;"
    , "      *to_regclass*) echo t; exit 0 ;;"
    , "      *psql*) echo 5; exit 0 ;;"
    , "    esac ;;"
    , "esac"
    , "echo \"docker stub: unexpected $*\" >&2"
    , "exit 2"
    ]

curlStub :: String
curlStub =
  L.unlines
    [ "#!/bin/sh"
    , "# curl stand-in for the lifecycle tests: the service answers only while running"
    , "here=$(dirname \"$0\")/.."
    , "echo \"curl $*\" >> \"$here/log\""
    , "mode=$(cat \"$here/mode\" 2>/dev/null || echo normal)"
    , "if [ \"$(cat \"$here/svc\" 2>/dev/null)\" != running ] || [ \"$mode\" = no-answer ]; then exit 7; fi"
    , "case \"$*\" in *http_code*) printf 204 ;; esac"
    , "exit 0"
    ]

writeText :: FilePath -> String -> IO ()
writeText path =
  BS.writeFile path . BS8.pack

-- | A throwaway checkout; @Just name@ makes it an instance (C-P3.1 L17).
withLifecycleEnv :: Maybe String -> (LEnv -> IO a) -> IO a
withLifecycleEnv instanceName action =
  withSystemTempDirectory "lockstep-lifecycle" $ \base -> do
    let
      root = base <> "/checkout"
      state = root <> "/.local/control" <> maybe "" ("-" <>) instanceName
      stub = base <> "/stub"
      install = root <> "/.local/" <> maybe "install" (<> "-install") instanceName
      config = root <> "/.local/config/" <> maybe "lockstep.json" (\n -> "lockstep-" <> n <> ".json") instanceName
    traverse_ (createDirectoryIfMissing True) [root <> "/scripts/lib", install <> "/bin", root <> "/.local/config", stub <> "/bin"]
    traverse_
      (\f -> copyFile ("scripts/" <> f) (root <> "/scripts/" <> f) >> setFileMode (root <> "/scripts/" <> f) 0o755)
      ["control-helper", "service", "db"]
    copyFile "scripts/lib/postgres-image" (root <> "/scripts/lib/postgres-image")
    writeText (install <> "/bin/lockstep") "#!/bin/sh\nexit 0\n"
    setFileMode (install <> "/bin/lockstep") 0o755
    writeText (install <> "/VERSION") "commit 0123456789abcdef0123456789abcdef01234567\ndirty false\nsha256 00\ninstalled_at 2026-10-25T00:00:00Z\n"
    writeText config "{\"database\":{\"host\":\"lockstep-postgres\",\"port\":5432,\"name\":\"lockstep\",\"username\":\"lockstep\",\"password\":\"x\"}}\n"
    writeText (stub <> "/bin/docker") dockerStub
    writeText (stub <> "/bin/curl") curlStub
    traverse_ (\f -> setFileMode (stub <> "/bin/" <> f) 0o755) ["docker", "curl"]
    traverse_ (\(f, v) -> writeText (stub <> "/" <> f) (v <> "\n")) [("mode", "normal"), ("svc", "running"), ("db", "running"), ("ready", "yes")]
    writeText (stub <> "/log") ""
    writeText (stub <> "/helper.out") ""
    setFileMode (root <> "/.local") 0o700
    traverse_
      (\d -> createDirectoryIfMissing True d >> setFileMode d 0o700)
      [state, state <> "/pane", state <> "/helper", state <> "/pane/requests", state <> "/pane/results", state <> "/pane/signin"]
    BS.writeFile (state <> "/pane/pane.id") "c0ffee00c0ffee00c0ffee00c0ffee01\n"
    traverse_
      (\f -> BS.writeFile f (keyHex <> "\n") >> setFileMode f 0o600)
      [state <> "/pane/channel.key", state <> "/helper/channel.key"]
    key <- maybe (assertFailure "test key") pure (parseChannelKey keyHex)
    action (LEnv root state key stub instanceName)

setStub :: LEnv -> String -> String -> IO ()
setStub env name value =
  writeText (lStub env <> "/" <> name) (value <> "\n")

readStub :: LEnv -> String -> IO String
readStub env name = do
  r <- try (readFile (lStub env <> "/" <> name)) :: IO (Either SomeException String)
  pure (L.filter (/= '\n') (fromRight "" r))

-- | Every docker and curl call so far, one per line.
stubLog :: LEnv -> IO [String]
stubLog env =
  L.lines <$> readFile (lStub env <> "/log")

startLifecycleHelper :: LEnv -> [(String, String)] -> IO Process.ProcessHandle
startLifecycleHelper env extra = do
  base <- getEnvironment
  let
    path = fromMaybe "/usr/bin:/bin" (L.lookup "PATH" base)
    overridden = ["PATH", "LOCKSTEP_HELPER_TIMEOUT"] <> fmap fst extra
    vars = extra <> [("PATH", lStub env <> "/bin:" <> path)] <> L.filter (\(k, _) -> k `L.notElem` overridden) base
    args = ["--state", lState env, "--service-port", show servicePort] <> maybe [] (\n -> ["--instance", n]) (lInstance env)
  logHandle <- openFile (lStub env <> "/helper.out") AppendMode
  (_, _, _, handle) <-
    Process.createProcess
      (Process.proc (lRoot env <> "/scripts/control-helper") args)
        { Process.env = Just vars
        , Process.cwd = Just (lStub env)
        , Process.std_out = Process.UseHandle logHandle
        , Process.std_err = Process.UseHandle logHandle
        }
  pure handle

withLifecycleHelper :: LEnv -> [(String, String)] -> IO a -> IO a
withLifecycleHelper env extra action =
  bracket
    (startLifecycleHelper env extra)
    (\h -> Process.terminateProcess h >> void (timeout 15000000 (Process.waitForProcess h)))
    (const action)
