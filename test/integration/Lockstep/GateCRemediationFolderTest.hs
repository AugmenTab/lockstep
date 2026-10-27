{- | The Gate C review remediation on the host (contract C-C.R1 R6, R12): the
real @scripts/service@ in a throwaway checkout with the C-P3.5 docker stub, and
the real root launcher with a temporary @HOME@. Nothing here needs Docker, and
nothing is written outside the temporary directories.
-}
module Lockstep.GateCRemediationFolderTest
  ( tests
  ) where

import Data.List qualified as L
import Flipstone.Prelude
import System.Directory (canonicalizePath, createDirectoryIfMissing, doesPathExist, getCurrentDirectory)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath, readFile, writeFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (createSymbolicLink, getSymbolicLinkStatus, isSymbolicLink, readSymbolicLink, setFileMode)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Support.Folders (FEnv (..), runServiceScript, stubLog, withFolderEnv)

-- | The last @docker run@ line the stub recorded.
lastRun :: FEnv -> IO String
lastRun env = do
  logText <- stubLog env
  pure (L.foldl' (\_ l -> l) "" [l | l <- L.lines logText, "docker run " `L.isPrefixOf` l])

contains :: String -> String -> Bool
contains =
  L.isInfixOf

runLauncher :: FilePath -> FilePath -> [(String, String)] -> [String] -> String -> IO (ExitCode, String, String)
runLauncher launcher home extra args input = do
  base <- getEnvironment
  let
    names = ["HOME", "SHELL", "PATH", "VIRTUAL_ENV"]
    env = [("HOME", home), ("SHELL", "/bin/zsh")] <> extra <> L.filter (\(k, _) -> k `L.notElem` names) base
  result <-
    timeout 30000000 $
      Process.readCreateProcessWithExitCode ((Process.proc launcher args) {Process.env = Just env, Process.cwd = Just home}) input
  maybe (assertFailure ("lockstep " <> show args <> " did not finish within 30 s")) pure result

linkTarget :: FilePath -> IO (Maybe FilePath)
linkTarget path = do
  exists <- doesPathExist path
  if not exists
    then pure Nothing
    else do
      status <- getSymbolicLinkStatus path
      if isSymbolicLink status then Just <$> readSymbolicLink path else pure Nothing

tests :: TestTree
tests =
  testGroup
    "Gate C review remediation on the host (C-C.R1 R6, R12)"
    [ testCase "scripts/service mounts a listed folder only when its real path is the listed path (R6)" $
        withFolderEnv False $ \env -> do
          home <- canonicalizePath (fHome env)
          site <- canonicalizePath (fHome env <> "/code/site")
          createSymbolicLink site (home <> "/site-link")
          createSymbolicLink (home <> "/code") (home <> "/code-link")
          let
            list = fBase env <> "/list"
          writeFile list (L.unlines ["ro " <> home <> "/site-link", "ro " <> home <> "/code-link/other", "ro " <> site])
          (code, _, err) <- runServiceScript env [("LOCKSTEP_SERVICE_FOLDERS", list)] ["cli", "db", "status"]
          assertBool ("cli failed: " <> err) (code == ExitSuccess)
          run <- lastRun env
          assertBool ("the real folder is not mounted: " <> run) (contains ("--volume " <> site <> ":" <> site <> ":ro ") run)
          assertBool ("a link was mounted: " <> run) (not (contains "site-link" run) && not (contains "code-link" run))
          assertBool ("the folder list names a link: " <> run) (contains ("--env LOCKSTEP_PROJECT_FOLDERS=:" <> site <> " ") run)
    , testCase "setup-path names another lockstep found first on PATH, and leaves it alone (R12)" $ do
        checkout <- getCurrentDirectory
        withSystemTempDirectory "lockstep-home" $ \home -> do
          let
            launcher = checkout <> "/lockstep"
            venv = home <> "/project/.venv"
            other = venv <> "/bin/lockstep"
            path = venv <> "/bin:" <> home <> "/.local/bin:/usr/local/bin:/usr/bin:/bin"
          createDirectoryIfMissing True (venv <> "/bin")
          writeFile other "#!/bin/sh\necho 'an older program'\n"
          setFileMode other 0o755
          before <- readFile other
          (code, out, _) <- runLauncher launcher home [("PATH", path), ("VIRTUAL_ENV", venv)] ["setup-path"] "y\n"
          code @?= ExitSuccess
          linkTarget (home <> "/.local/bin/lockstep") >>= (@?= Just launcher)
          traverse_
            (\w -> assertBool ("setup-path does not say " <> show w <> ":\n" <> out) (contains w out))
            [other, "virtual environment", launcher]
          assertBool ("setup-path claims lockstep now works:\n" <> out) (not (contains "You can now type lockstep" out))
          again <- runLauncher launcher home [("PATH", venv <> "/bin:" <> home <> "/.local/bin:/usr/bin:/bin")] ["setup-path"] ""
          let
            (againCode, againOut, _) = again
          againCode @?= ExitSuccess
          assertBool ("a second setup-path does not name the other program:\n" <> againOut) (contains other againOut)
          after <- readFile other
          L.length after @?= L.length before
          after @?= before
    ]
