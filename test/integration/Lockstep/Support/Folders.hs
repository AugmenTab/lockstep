{-# LANGUAGE OverloadedStrings #-}

{- | Fixtures for the Project folders tests (contract C-P3.5 J5, J6): a temporary
home folder holding a throwaway checkout with the real helper and
@scripts/service@, and a @docker@ stub that records every call. Nothing touches
the operator's home, installation, configuration or containers.
-}
module Lockstep.Support.Folders
  ( FEnv (..)
  , withFolderEnv
  , withFolderHelper
  , setSvc
  , stubLog
  , currentList
  , currentDigest
  , submitFolder
  , awaitFolderResult
  , runServiceScript
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, finally, try)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Flipstone.Prelude
import Numeric (showHex)
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist, renameFile)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath, IOMode (AppendMode), openFile, readFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Posix.Signals (sigTERM, signalProcess)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty.HUnit (assertFailure)
import Text.Read (readMaybe)
import Text.Show (show)

import Lockstep.Foundation.ControlProtocol (ChannelKey, ControlResult, decodeResult, parseChannelKey, parseRequestId)
import Lockstep.Foundation.FolderProtocol (FolderOp (..), FolderRequest (..), encodeFolderRequest, foldersDigest)
import Lockstep.Support.Postgres (AdminSettings (..), requireAdmin, withFreshDatabase, writeConfigFile)
import Lockstep.Support.Process (freePort, runLockstep)

data FEnv
  = FEnv
  { fBase :: FilePath
  , fHome :: FilePath
  , fRoot :: FilePath
  , fState :: FilePath
  , fKey :: ChannelKey
  , fStub :: FilePath
  , fProjects :: FilePath
  , fServicePort :: Int
  , fConfig :: Maybe FilePath
  }

keyHex :: BS.ByteString
keyHex =
  "b0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecf"

{- | Records every call. @run --detach@ starts the real @lockstep serve@ in this
filesystem view, with the port and @LOCKSTEP_PROJECT_FOLDERS@ the arguments
carry, as the container would; @stop@ ends it. @operator sign-in@ and @db status@
run the real binary against the fixture's database when there is one.
-}
dockerStub :: String
dockerStub =
  L.unlines
    [ "#!/bin/sh"
    , "# docker stand-in for the Project folders tests (C-P3.5)"
    , "here=$(dirname \"$0\")/.."
    , "echo \"docker $*\" >> \"$here/log\""
    , "svc=$(cat \"$here/svc\" 2>/dev/null || echo absent)"
    , "config=$(cat \"$here/config\" 2>/dev/null || true)"
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
    , "  stop)"
    , "    pid=$(cat \"$here/pid\" 2>/dev/null || true)"
    , "    if [ -n \"$pid\" ]; then kill \"$pid\" 2>/dev/null; for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 \"$pid\" 2>/dev/null || break; sleep 0.2; done; fi"
    , "    rm -f \"$here/pid\"; echo stopped > \"$here/svc\"; exit 0 ;;"
    , "  rm) echo absent > \"$here/svc\"; exit 0 ;;"
    , "  logs) exit 0 ;;"
    , "  run)"
    , "    folders=''; port=''; prev=''"
    , "    for a in \"$@\"; do"
    , "      case \"$prev\" in"
    , "        --env) case \"$a\" in LOCKSTEP_PROJECT_FOLDERS=*) folders=${a#LOCKSTEP_PROJECT_FOLDERS=} ;; esac ;;"
    , "        --port) port=$a ;;"
    , "      esac"
    , "      prev=$a"
    , "    done"
    , "    case \"$*\" in"
    , "      *' --detach '*)"
    , "        echo \"$port\" > \"$here/port\""
    , "        if [ -n \"$config\" ]; then"
    , "          LOCKSTEP_CONFIG=$config LOCKSTEP_PROJECT_FOLDERS=$folders lockstep serve --port \"$port\" >> \"$here/serve.log\" 2>&1 &"
    , "        else"
    , "          env -u LOCKSTEP_CONFIG LOCKSTEP_PROJECT_FOLDERS=$folders lockstep serve --port \"$port\" >> \"$here/serve.log\" 2>&1 &"
    , "        fi"
    , "        echo $! > \"$here/pid\"; echo running > \"$here/svc\"; exit 0 ;;"
    , "      *'operator sign-in --port '*) LOCKSTEP_CONFIG=$config exec lockstep operator sign-in --port \"$port\" ;;"
    , "      *'db status'*)"
    , "        if [ -n \"$config\" ]; then LOCKSTEP_CONFIG=$config exec lockstep db status; fi"
    , "        printf 'readiness ready 13\\nrevision 13\\npending 0\\n'; exit 0 ;;"
    , "    esac"
    , "    exit 0 ;;"
    , "esac"
    , "echo \"docker stub: unexpected $*\" >&2"
    , "exit 2"
    ]

writeText :: FilePath -> String -> IO ()
writeText path =
  BS.writeFile path . BS8.pack

{- | A temporary home folder with a throwaway checkout inside it, existing
folders @home/code/site@ and @home/code/other@, a folder outside the home, and
the stub; with a migrated real database when asked. A service the stub started
is stopped at the end.
-}
withFolderEnv :: Bool -> (FEnv -> IO a) -> IO a
withFolderEnv withDatabase action =
  if withDatabase
    then do
      admin <- requireAdmin
      withFreshDatabase admin $ \db ->
        withSystemTempDirectory "lockstep-folders" $ \base -> do
          createDirectoryIfMissing True (base <> "/db")
          config <- writeConfigFile (base <> "/db") admin db (adminPassword admin)
          (code, _, err) <- runLockstep [("LOCKSTEP_CONFIG", config)] ["db", "migrate"]
          when (code /= ExitSuccess) (assertFailure ("db migrate failed: " <> err))
          prepare base (Just config) action
    else withSystemTempDirectory "lockstep-folders" $ \base -> prepare base Nothing action

prepare :: FilePath -> Maybe FilePath -> (FEnv -> IO a) -> IO a
prepare base config action =
  flip finally (stopStubService (base <> "/stub")) $ do
    let
      home = base <> "/home"
      root = home <> "/checkout"
      state = root <> "/.local/control"
      stub = base <> "/stub"
    traverse_
      (createDirectoryIfMissing True)
      [root <> "/scripts", root <> "/.local/install/bin", root <> "/.local/config", stub <> "/bin", home <> "/code/site", home <> "/code/other", base <> "/outside"]
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
    traverse_ (\(f, v) -> writeText (stub <> "/" <> f) (v <> "\n")) [("svc", "absent"), ("port", show port)]
    writeText (stub <> "/log") ""
    writeText (stub <> "/helper.out") ""
    setFileMode (root <> "/.local") 0o700
    traverse_
      (\d -> createDirectoryIfMissing True d >> setFileMode d 0o700)
      [state, state <> "/pane", state <> "/helper", state <> "/pane/requests", state <> "/pane/results", state <> "/pane/signin"]
    BS.writeFile (state <> "/pane/pane.id") "c0ffee00c0ffee00c0ffee00c0ffee05\n"
    traverse_
      (\f -> BS.writeFile f (keyHex <> "\n") >> setFileMode f 0o600)
      [state <> "/pane/channel.key", state <> "/helper/channel.key"]
    traverse_ (writeText (stub <> "/config")) config
    key <- maybe (assertFailure "test key") pure (parseChannelKey keyHex)
    action (FEnv base home root state key stub (home <> "/lockstep-projects") port config)

-- | Ends a @lockstep serve@ the stub started, if one is still running.
stopStubService :: FilePath -> IO ()
stopStubService stub = do
  present <- doesFileExist (stub <> "/pid")
  when present $ do
    text <- readFile (stub <> "/pid")
    case readMaybe (L.filter (/= '\n') text) of
      Just pid -> void (try (signalProcess sigTERM pid) :: IO (Either IOException ()))
      Nothing -> pure ()

-- | The environment of the helper and of @scripts/service@: the stub first on PATH, the temporary home.
scriptEnvironment :: FEnv -> IO [(String, String)]
scriptEnvironment env = do
  base <- getEnvironment
  let
    path = fromMaybe "/usr/bin:/bin" (L.lookup "PATH" base)
    removed = ["PATH", "HOME", "LOCKSTEP_CONFIG", "LOCKSTEP_HELPER_TIMEOUT", "LOCKSTEP_SERVICE_FOLDERS", "LOCKSTEP_PROJECT_FOLDERS"]
  pure ([("PATH", fStub env <> "/bin:" <> path), ("HOME", fHome env)] <> L.filter (\(k, _) -> k `L.notElem` removed) base)

-- | Runs the helper with @--projects home/lockstep-projects@ (or the given arguments instead) around the action.
withFolderHelper :: FEnv -> Maybe [String] -> IO a -> IO a
withFolderHelper env projectsArgs action = do
  vars <- scriptEnvironment env
  let
    args = ["--state", fState env, "--service-port", show (fServicePort env)] <> fromMaybe ["--projects", fProjects env] projectsArgs
  bracket
    ( do
        logHandle <- openFile (fStub env <> "/helper.out") AppendMode
        (_, _, _, handle) <-
          Process.createProcess
            (Process.proc (fRoot env <> "/scripts/control-helper") args)
              { Process.env = Just vars
              , Process.cwd = Just (fStub env)
              , Process.std_out = Process.UseHandle logHandle
              , Process.std_err = Process.UseHandle logHandle
              }
        waitForList env 100
        pure handle
    )
    (\h -> Process.terminateProcess h >> void (timeout 15000000 (Process.waitForProcess h)))
    (const action)

-- | The helper has started once its folder list exists.
waitForList :: FEnv -> Int -> IO ()
waitForList env remaining = do
  present <- doesFileExist (fState env <> "/helper/folders")
  if present || remaining <= 0
    then pure ()
    else threadDelay 100000 >> waitForList env (remaining - 1)

-- | running, stopped or absent, as the stub reports the service container.
setSvc :: FEnv -> String -> IO ()
setSvc env value =
  writeText (fStub env <> "/svc") (value <> "\n")

stubLog :: FEnv -> IO String
stubLog env =
  readFile (fStub env <> "/log")

currentList :: FEnv -> IO BS.ByteString
currentList env =
  BS.readFile (fState env <> "/helper/folders")

currentDigest :: FEnv -> IO T.Text
currentDigest env =
  foldersDigest <$> currentList env

newId :: IO T.Text
newId = do
  t <- getPOSIXTime
  pure (T.justifyRight 32 '0' (T.pack (showHex (floor (t * 1000000) :: Integer) "")))

-- | Writes a signed add-folder request the way the pane does; returns its id.
submitFolder :: FEnv -> T.Text -> T.Text -> IO T.Text
submitFolder env expect path = do
  rid <- newId
  t <- getPOSIXTime
  r <- maybe (assertFailure "id") pure (parseRequestId rid)
  let
    tmp = fState env <> "/pane/requests/." <> T.unpack rid <> ".tmp"
  BS.writeFile tmp (encodeFolderRequest (fKey env) (FolderRequest r (floor t) AddFolder expect path))
  setFileMode tmp 0o600
  renameFile tmp (fState env <> "/pane/requests/" <> T.unpack rid <> ".freq")
  pure rid

awaitFolderResult :: FEnv -> T.Text -> IO ControlResult
awaitFolderResult env rid =
  let
    path = fState env <> "/pane/results/" <> T.unpack rid <> ".res"
    attempt :: Int -> IO ControlResult
    attempt remaining = do
      present <- doesFileExist path
      if present
        then BS.readFile path >>= either (\e -> assertFailure ("result does not verify: " <> show e)) pure . decodeResult (fKey env)
        else
          if remaining <= 0
            then readFile (fStub env <> "/helper.out") >>= \out -> assertFailure ("no result within 60 s:\n" <> out)
            else threadDelay 100000 >> attempt (remaining - 1)
  in
    attempt 600

-- | Runs the throwaway checkout's @scripts/service@ with the stub, the temporary home and extra variables.
runServiceScript :: FEnv -> [(String, String)] -> [String] -> IO (ExitCode, String, String)
runServiceScript env extra args = do
  vars <- scriptEnvironment env
  Process.readCreateProcessWithExitCode
    ((Process.proc (fRoot env <> "/scripts/service") args) {Process.env = Just (extra <> vars), Process.cwd = Just (fStub env)})
    ""
