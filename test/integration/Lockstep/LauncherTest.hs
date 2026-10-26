{- | The root launcher's host-independent behaviour (contract C-P3.1 L16, L17):
@lockstep help@ through a symlink from another directory, and @lockstep
setup-path@ with a temporary @HOME@. Nothing here needs Docker, and nothing is
written outside the temporary directory.
-}
module Lockstep.LauncherTest
  ( tests
  ) where

import Data.List qualified as L
import Flipstone.Prelude
import System.Directory (createDirectoryIfMissing, doesFileExist, doesPathExist, getCurrentDirectory, listDirectory)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.IO (FilePath, readFile, writeFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (createSymbolicLink, getSymbolicLinkStatus, isSymbolicLink, readSymbolicLink)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

marker :: String
marker =
  "# Added by Lockstep (lockstep setup-path)"

-- | Runs the launcher with a temporary HOME, the given SHELL and PATH, standard input and working directory.
runLauncher :: FilePath -> FilePath -> String -> String -> [String] -> String -> IO (ExitCode, String, String)
runLauncher launcher home shell path args input = do
  base <- getEnvironment
  let
    env = [("HOME", home), ("SHELL", shell), ("PATH", path)] <> L.filter (\(k, _) -> k `L.notElem` ["HOME", "SHELL", "PATH"]) base
  result <-
    timeout 30000000 $
      Process.readCreateProcessWithExitCode ((Process.proc launcher args) {Process.env = Just env, Process.cwd = Just home}) input
  maybe (assertFailure ("lockstep " <> show args <> " did not finish within 30 s")) pure result

withHome :: (FilePath -> FilePath -> IO a) -> IO a
withHome action = do
  checkout <- getCurrentDirectory
  withSystemTempDirectory "lockstep-home" $ \home -> action (checkout <> "/lockstep") home

plainPath :: String
plainPath =
  "/usr/local/bin:/usr/bin:/bin"

readOr :: FilePath -> IO String
readOr path = do
  exists <- doesFileExist path
  if exists then readFile path else pure ""

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
    "root launcher (C-P3.1 L16, L17)"
    [ testCase "help works through a symlink from another directory and names the checkout" $
        withHome $ \launcher home -> do
          createDirectoryIfMissing True (home <> "/bin")
          createSymbolicLink launcher (home <> "/bin/lockstep")
          (code, out, _) <- runLauncher (home <> "/bin/lockstep") home "/bin/sh" plainPath ["help"] ""
          code @?= ExitSuccess
          checkout <- getCurrentDirectory
          assertBool ("help does not name the checkout " <> checkout <> ":\n" <> out) (checkout `L.isInfixOf` out)
          traverse_ (\w -> assertBool ("help lacks " <> w) (w `L.isInfixOf` out)) ["lockstep stop", "lockstep setup-path"]
    , testCase "setup-path for zsh: with consent, a symlink and one marked line in ~/.zprofile" $
        withHome $ \launcher home -> do
          (code, out, _) <- runLauncher launcher home "/bin/zsh" plainPath ["setup-path"] "y\ny\n"
          code @?= ExitSuccess
          target <- linkTarget (home <> "/.local/bin/lockstep")
          target @?= Just launcher
          profile <- readOr (home <> "/.zprofile")
          L.length (L.filter (== marker) (L.lines profile)) @?= 1
          assertBool ("no PATH line: " <> profile) ("export PATH=\"$HOME/.local/bin:$PATH\"" `L.isInfixOf` profile)
          assertBool ("does not tell to open a new terminal: " <> out) ("new terminal" `L.isInfixOf` out)
    , testCase "setup-path for bash on Linux uses ~/.bashrc" $
        withHome $ \launcher home -> do
          (code, _, _) <- runLauncher launcher home "/bin/bash" plainPath ["setup-path"] "y\ny\n"
          code @?= ExitSuccess
          profile <- readOr (home <> "/.bashrc")
          L.length (L.filter (== marker) (L.lines profile)) @?= 1
          zprofile <- doesFileExist (home <> "/.zprofile")
          assertBool "wrote ~/.zprofile for bash" (not zprofile)
    , testCase "declining changes nothing" $
        withHome $ \launcher home -> do
          (code, _, _) <- runLauncher launcher home "/bin/zsh" plainPath ["setup-path"] "n\n"
          code @?= ExitSuccess
          entries <- listDirectory home
          entries @?= []
    , testCase "a symlink but no start-up change: the exact line is printed instead" $
        withHome $ \launcher home -> do
          (code, out, _) <- runLauncher launcher home "/bin/zsh" plainPath ["setup-path"] "y\nn\n"
          code @?= ExitSuccess
          target <- linkTarget (home <> "/.local/bin/lockstep")
          target @?= Just launcher
          zprofile <- doesFileExist (home <> "/.zprofile")
          assertBool "wrote ~/.zprofile after a no" (not zprofile)
          assertBool ("the line to add is not shown: " <> out) ("export PATH=\"$HOME/.local/bin:$PATH\"" `L.isInfixOf` out)
    , testCase "another shell: the symlink with consent, start-up files untouched, instructions shown" $
        withHome $ \launcher home -> do
          (code, out, _) <- runLauncher launcher home "/usr/bin/fish" plainPath ["setup-path"] "y\ny\n"
          code @?= ExitSuccess
          target <- linkTarget (home <> "/.local/bin/lockstep")
          target @?= Just launcher
          entries <- listDirectory home
          entries @?= [".local"]
          assertBool ("no instructions: " <> out) (".local/bin" `L.isInfixOf` out && "fish" `L.isInfixOf` out)
    , testCase "an existing ~/.local/bin/lockstep that Lockstep did not create is left alone" $
        withHome $ \launcher home -> do
          createDirectoryIfMissing True (home <> "/.local/bin")
          writeFile (home <> "/.local/bin/lockstep") "#!/bin/sh\necho mine\n"
          (code, out, _) <- runLauncher launcher home "/bin/zsh" plainPath ["setup-path"] "y\ny\n"
          code @?= ExitFailure 73
          content <- readFile (home <> "/.local/bin/lockstep")
          content @?= "#!/bin/sh\necho mine\n"
          assertBool ("does not explain: " <> out) ("already" `L.isInfixOf` out)
    , testCase "running setup-path again changes nothing" $
        withHome $ \launcher home -> do
          _ <- runLauncher launcher home "/bin/zsh" plainPath ["setup-path"] "y\ny\n"
          before <- readOr (home <> "/.zprofile")
          (code, out, _) <- runLauncher launcher home "/bin/zsh" plainPath ["setup-path"] "y\ny\n"
          code @?= ExitSuccess
          after <- readOr (home <> "/.zprofile")
          after @?= before
          assertBool ("does not say it is set up: " <> out) ("already" `L.isInfixOf` out)
    , testCase "with ~/.local/bin already on PATH only the symlink is offered" $
        withHome $ \launcher home -> do
          (code, _, _) <- runLauncher launcher home "/bin/zsh" (home <> "/.local/bin:" <> plainPath) ["setup-path"] "y\n"
          code @?= ExitSuccess
          zprofile <- doesFileExist (home <> "/.zprofile")
          assertBool "wrote ~/.zprofile although ~/.local/bin is on PATH" (not zprofile)
          target <- linkTarget (home <> "/.local/bin/lockstep")
          target @?= Just launcher
    , testCase "a bad instance name is a usage error" $
        withHome $ \launcher home -> do
          (code, _, err) <- runLauncher launcher home "/bin/sh" plainPath ["--instance", "Bad!"] ""
          code @?= ExitFailure 64
          assertBool ("no reason: " <> err) ("--instance" `L.isInfixOf` err)
    ]
