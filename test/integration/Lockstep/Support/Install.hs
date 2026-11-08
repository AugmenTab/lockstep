{-# LANGUAGE OverloadedStrings #-}

{- | Fixtures for the install and upgrade tests (contract C-P3.3 §3): a
throwaway checkout that is a real Git repository, with the real helper,
@scripts/service@ and @scripts/db@, and stateful @docker@ and @curl@ stubs. A
fake @lockstep@ binary names the schema revision it knows (@# rev N@); the stub
database has an applied revision; @db status@, @db migrate@, backups and
restores follow them. Nothing touches the operator's installation,
configuration or containers.

Stub files: @svc@ (running, stopped, absent), @applied@ (the database's applied
revision), @next@ (the revision the next build knows), @flags@ (any of
build-fail, backup-empty, backup-corrupt, migrate-fail, start-fail,
slow-migrate), @log@ (every call).
-}
module Lockstep.Support.Install
  ( IEnv (..)
  , iPane
  , iHelper
  , iInstall
  , iStaging
  , withInstallEnv
  , setFile
  , readFileTrim
  , stubCalls
  , withInstallHelper
  , startInstallHelper
  , installServicePort
  , fakeBinary
  ) where

import Control.Exception (SomeException, bracket, try)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Maybe (fromMaybe, isJust)
import Flipstone.Prelude
import System.Directory (copyFile, createDirectoryIfMissing)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath, IOMode (AppendMode), openFile, readFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty.HUnit (assertFailure)
import Text.Show (show)

import Lockstep.Foundation.ControlProtocol (ChannelKey, parseChannelKey)

data IEnv
  = IEnv
  { iRoot :: FilePath
  , iState :: FilePath
  , iKey :: ChannelKey
  , iStub :: FilePath
  , iInstance :: Maybe String
  }

iPane :: IEnv -> FilePath
iPane env =
  iState env <> "/pane"

iHelper :: IEnv -> FilePath
iHelper env =
  iState env <> "/helper"

-- | The active installation directory.
iInstall :: IEnv -> FilePath
iInstall env =
  iRoot env <> "/.local/" <> maybe "install" (<> "-install") (iInstance env)

-- | The staging installation directory (C-P3.3 U2).
iStaging :: IEnv -> FilePath
iStaging env =
  iRoot env <> "/.local/" <> maybe "staging-install" (<> "-staging-install") (iInstance env)

installServicePort :: Int
installServicePort =
  8156

keyHex :: BS.ByteString
keyHex =
  "9a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9"

-- | A fake installed binary that knows schema revision @n@.
fakeBinary :: Int -> String
fakeBinary n =
  "#!/bin/sh\n# rev " <> show n <> "\nexit 0\n"

dockerStub :: String
dockerStub =
  L.unlines
    [ "#!/bin/sh"
    , "# docker stand-in with an installation, a database and backups (C-P3.3 §3)"
    , "here=$(dirname \"$0\")/.."
    , "echo \"docker $*\" >> \"$here/log\""
    , "get() { cat \"$here/$1\" 2>/dev/null || echo \"$2\"; }"
    , "put() { echo \"$2\" > \"$here/$1\"; }"
    , "flag() { grep -qw \"$1\" \"$here/flags\" 2>/dev/null; }"
    , "last=''; for a in \"$@\"; do last=$a; done"
    , "# the revision known by the binary mounted at /opt/lockstep"
    , "known() {"
    , "  dir=$(printf '%s\\n' \"$@\" | sed -n 's#^\\(.*\\):/opt/lockstep:ro$#\\1#p' | head -n 1)"
    , "  sed -n 's/^# rev \\([0-9]*\\)$/\\1/p' \"$dir/bin/lockstep\" 2>/dev/null | head -n 1"
    , "}"
    , "case \"$1\" in"
    , "  version) echo 29.4.0; exit 0 ;;"
    , "  network) exit 0 ;;"
    , "  build) flag build-fail && { echo 'build failed' >&2; exit 1; }; exit 0 ;;"
    , "  container)"
    , "    shift 2; fmt=''"
    , "    while [ $# -gt 1 ]; do case \"$1\" in --format|-f) fmt=$2; shift 2 ;; *) shift ;; esac; done"
    , "    case \"$1\" in lockstep-postgres) st=running ;; *) st=$(get svc absent) ;; esac"
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
    , "      *'stack build --copy-bins'*)"
    , "        work=$(printf '%s\\n' \"$@\" | sed -n 's#^\\(.*\\):/work$#\\1#p' | head -n 1)"
    , "        dest=$(printf '%s' \"$*\" | sed -n \"s#.*--local-bin-path '\\([^']*\\)'.*#\\1#p\")"
    , "        flag build-fail && exit 1"
    , "        mkdir -p \"$work/$dest\""
    , "        printf '#!/bin/sh\\n# rev %s\\nexit 0\\n' \"$(get next 6)\" > \"$work/$dest/lockstep\""
    , "        chmod +x \"$work/$dest/lockstep\"; exit 0 ;;"
    , "    esac"
    , "    k=$(known \"$@\"); a=$(get applied 0)"
    , "    case \"$*\" in"
    , "      *'db status'*)"
    , "        if [ \"$a\" -gt \"$k\" ]; then printf 'readiness not_ready schema_invalid unknown_applied_migration %s\\nrevision %s\\npending 0\\n' \"$a\" \"$a\"; exit 0; fi"
    , "        if [ \"$a\" = 0 ]; then r=none; else r=$a; fi"
    , "        if [ \"$a\" = \"$k\" ]; then printf 'readiness ready %s\\nrevision %s\\npending 0\\n' \"$k\" \"$r\"; exit 0; fi"
    , "        printf 'readiness not_ready schema_behind %s\\nrevision %s\\npending %s\\n' $((k - a)) \"$r\" $((k - a)); exit 0 ;;"
    , "      *'db migrate'*)"
    , "        if flag slow-migrate; then sleep 30; flag slow-migrate || exit 1; fi"
    , "        if flag migrate-fail; then put applied $((a + 1)); echo 'lockstep: migration failed half-way' >&2; exit 70; fi"
    , "        if [ \"$a\" -gt 0 ]; then case \"$*\" in *--backup*|*--no-backup*) ;; *) echo 'lockstep: a backup is required' >&2; exit 75 ;; esac; fi"
    , "        put applied \"$k\"; echo \"applied migrations up to $k\"; exit 0 ;;"
    , "      *' serve '*)"
    , "        if flag start-fail; then echo 'docker: Error: port is already allocated' >&2; exit 125; fi"
    , "        put svc running; put serving \"$k\"; echo id; exit 0 ;;"
    , "    esac ;;"
    , "  stop) put svc stopped; exit 0 ;;"
    , "  rm) put svc absent; exit 0 ;;"
    , "  logs) echo 'service log'; exit 0 ;;"
    , "  start) exit 0 ;;"
    , "  exec)"
    , "    case \"$*\" in"
    , "      *pg_isready*) exit 0 ;;"
    , "      *to_regclass*) echo t; exit 0 ;;"
    , "      *pg_dump*)"
    , "        flag backup-empty && exit 0"
    , "        if flag backup-corrupt; then echo GARBAGE; exit 0; fi"
    , "        echo \"DUMP rev $(get applied 0)\"; exit 0 ;;"
    , "      *'pg_restore --list'*) read -r first; case \"$first\" in DUMP*) exit 0 ;; *) echo 'pg_restore: not a valid archive' >&2; exit 1 ;; esac ;;"
    , "      *pg_restore*) read -r first; n=$(printf '%s' \"$first\" | sed -n 's/^DUMP rev \\([0-9]*\\)$/\\1/p'); [ -n \"$n\" ] || exit 1; put applied \"$n\"; exit 0 ;;"
    , "      *'DROP SCHEMA public CASCADE'*) put applied 0; exit 0 ;;"
    , "      *psql*) get applied 0; exit 0 ;;"
    , "    esac ;;"
    , "esac"
    , "echo \"docker stub: unexpected $*\" >&2"
    , "exit 2"
    ]

curlStub :: String
curlStub =
  L.unlines
    [ "#!/bin/sh"
    , "here=$(dirname \"$0\")/.."
    , "echo \"curl $*\" >> \"$here/log\""
    , "[ \"$(cat \"$here/svc\" 2>/dev/null)\" = running ] || exit 7"
    , "case \"$*\" in *http_code*) printf 204 ;; esac"
    , "exit 0"
    ]

writeText :: FilePath -> String -> IO ()
writeText path =
  BS.writeFile path . BS8.pack

git :: FilePath -> [String] -> IO ()
git root args = do
  (code, _, err) <- Process.readCreateProcessWithExitCode (Process.proc "git" (["-C", root, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] <> args)) ""
  when (code /= ExitSuccess) (assertFailure ("git " <> show args <> ": " <> err))

{- | A throwaway checkout (a Git repository with one commit) whose active
installation knows revision @installed@ (or none) and whose database has
@applied@ migrations; @Just name@ makes it an instance.
-}
withInstallEnv :: Maybe String -> Maybe Int -> Int -> (IEnv -> IO a) -> IO a
withInstallEnv instanceName installed applied action =
  withSystemTempDirectory "lockstep-install" $ \base -> do
    let
      root = base <> "/checkout"
      state = root <> "/.local/control" <> maybe "" ("-" <>) instanceName
      stub = base <> "/stub"
      install = root <> "/.local/" <> maybe "install" (<> "-install") instanceName
      config = root <> "/.local/config/" <> maybe "lockstep.json" (\n -> "lockstep-" <> n <> ".json") instanceName
    traverse_ (createDirectoryIfMissing True) [root <> "/scripts/lib", root <> "/.local/config", stub <> "/bin"]
    traverse_
      (\f -> copyFile ("scripts/" <> f) (root <> "/scripts/" <> f) >> setFileMode (root <> "/scripts/" <> f) 0o755)
      ["control-helper", "service", "db"]
    copyFile "scripts/lib/postgres-image" (root <> "/scripts/lib/postgres-image")
    writeText (root <> "/.gitignore") ".local/\n"
    writeText (root <> "/README") "throwaway checkout\n"
    git root ["init", "-q"]
    git root ["add", "-A"]
    git root ["commit", "-q", "-m", "fixture"]
    traverse_
      ( \n -> do
          createDirectoryIfMissing True (install <> "/bin")
          writeText (install <> "/bin/lockstep") (fakeBinary n)
          setFileMode (install <> "/bin/lockstep") 0o755
          writeText (install <> "/VERSION") "commit 1111111111111111111111111111111111111111\ndirty false\nsha256 00\ninstalled_at 2026-10-25T00:00:00Z\n"
      )
      installed
    writeText config "{\"database\":{\"host\":\"lockstep-postgres\",\"port\":5432,\"name\":\"lockstep\",\"username\":\"lockstep\",\"password\":\"x\"}}\n"
    writeText (stub <> "/bin/docker") dockerStub
    writeText (stub <> "/bin/curl") curlStub
    traverse_ (\f -> setFileMode (stub <> "/bin/" <> f) 0o755) ["docker", "curl"]
    traverse_
      (\(f, v) -> writeText (stub <> "/" <> f) (v <> "\n"))
      [("svc", if isJust installed then "running" else "absent"), ("applied", show applied), ("next", "6"), ("flags", "")]
    writeText (stub <> "/log") ""
    writeText (stub <> "/helper.out") ""
    setFileMode (root <> "/.local") 0o700
    traverse_
      (\d -> createDirectoryIfMissing True d >> setFileMode d 0o700)
      [state, state <> "/pane", state <> "/helper", state <> "/pane/requests", state <> "/pane/results", state <> "/pane/signin"]
    BS.writeFile (state <> "/pane/pane.id") "c0ffee00c0ffee00c0ffee00c0ffee02\n"
    traverse_
      (\f -> BS.writeFile f (keyHex <> "\n") >> setFileMode f 0o600)
      [state <> "/pane/channel.key", state <> "/helper/channel.key"]
    key <- maybe (assertFailure "test key") pure (parseChannelKey keyHex)
    action (IEnv root state key stub instanceName)

setFile :: IEnv -> String -> String -> IO ()
setFile env name value =
  writeText (iStub env <> "/" <> name) (value <> "\n")

readFileTrim :: FilePath -> IO String
readFileTrim path = do
  r <- try (readFile path) :: IO (Either SomeException String)
  pure (L.filter (/= '\n') (fromRight "" r))

stubCalls :: IEnv -> IO [String]
stubCalls env =
  L.lines <$> readFile (iStub env <> "/log")

startInstallHelper :: IEnv -> [(String, String)] -> IO Process.ProcessHandle
startInstallHelper env extra = do
  base <- getEnvironment
  let
    path = fromMaybe "/usr/bin:/bin" (L.lookup "PATH" base)
    overridden = ["PATH", "LOCKSTEP_HELPER_TIMEOUT", "LOCKSTEP_HELPER_LONG_TIMEOUT"] <> fmap fst extra
    vars = extra <> [("PATH", iStub env <> "/bin:" <> path)] <> L.filter (\(k, _) -> k `L.notElem` overridden) base
    args = ["--state", iState env, "--service-port", show installServicePort] <> maybe [] (\n -> ["--instance", n]) (iInstance env)
  logHandle <- openFile (iStub env <> "/helper.out") AppendMode
  (_, _, _, handle) <-
    Process.createProcess
      (Process.proc (iRoot env <> "/scripts/control-helper") args)
        { Process.env = Just vars
        , Process.cwd = Just (iStub env)
        , Process.std_out = Process.UseHandle logHandle
        , Process.std_err = Process.UseHandle logHandle
        }
  pure handle

withInstallHelper :: IEnv -> [(String, String)] -> IO a -> IO a
withInstallHelper env extra action =
  bracket
    (startInstallHelper env extra)
    (\h -> Process.terminateProcess h >> void (timeout 15000000 (Process.waitForProcess h)))
    (const action)
