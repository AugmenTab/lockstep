{-# LANGUAGE OverloadedStrings #-}

{- | The C-C.R1 third addendum against real PostgreSQL and Git (§3d: Review 5,
R5-1 to R5-3): a folder's identity is what is on disk, not how its path is
spelled; a folder replaced while an attempt waits is not connected; a new
project folder is never offered or published before Git has initialized it,
and never replaces anything. The test-only hooks run where the other request
acts.
-}
module Lockstep.GateCRemediationIdentityTest
  ( tests
  ) where

import Control.Concurrent.MVar (newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Exception (SomeException, throwIO, try)
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import System.Directory (createDirectory, doesDirectoryExist, doesFileExist, listDirectory, renameDirectory)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath, readFile, writeFile)
import System.IO.Error (userError)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (createSymbolicLink)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason, runMigrations)
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), connectProject, connectProjectAround, createProject, findProject, noProjectFaults, offeredFolders)
import Lockstep.Effects.ProjectFolders (isProjectFolder, makeProjectFolderWith)
import Lockstep.Kernel.Project (FolderChoice (..), SetupState (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (AdminSettings, databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime)

data Scenario
  = Scenario
  { scAdmin :: AdminSettings
  , scDb :: T.Text
  , scRuntime :: DatabaseRuntime
  , scRoot :: FilePath
  , scDir :: FilePath
  }

withScenario :: (Scenario -> IO a) -> IO a
withScenario action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-cr1-identity" $ \tmp -> do
      config <- databaseConfigFor admin db
      withRuntime config $ \runtime -> do
        migrated <- runMigrations migrations runtime
        assertBool "migrations failed" (either (const False) (const True) migrated)
        createDirectory (tmp <> "/projects")
        createDirectory (tmp <> "/w")
        action (Scenario admin db runtime (tmp <> "/projects") (tmp <> "/w"))

rootFolders :: Scenario -> ProjectFolders
rootFolders sc =
  ProjectFolders (Just (scRoot sc)) []

key :: T.Text -> IO IdempotencyKey
key text =
  either (const (assertFailure ("creation key " <> T.unpack text))) pure (mkIdempotencyKey ("test-identity-creation-" <> text))

ready :: Show e => IO (Either e a) -> IO a
ready action =
  action >>= either (\e -> assertFailure ("not ready: " <> show e)) pure

made :: Scenario -> T.Text -> T.Text -> IO ProjectView
made sc k name = do
  ik <- key k
  ready (createProject (scRuntime sc) (rootFolders sc) (NewProject ik name "" DecideLater)) >>= either (\c -> assertFailure ("project refused: " <> T.unpack c)) pure

recorded :: Scenario -> ProjectView -> IO (Maybe (SetupState, Maybe T.Text, Maybe T.Text))
recorded sc view =
  fmap (\v -> (projectSetup v, projectFolder v, projectRefusal v)) <$> ready (findProject (scRuntime sc) (projectId view))

repositories :: Scenario -> IO [Int]
repositories sc =
  queryInts (scAdmin sc) (scDb sc) "SELECT count(*)::integer AS v FROM lockstep_repositories"

git :: FilePath -> [String] -> Assertion
git dir args = do
  base <- getEnvironment
  let
    identity = ["-c", "user.name=Lockstep Test", "-c", "user.email=test@example.invalid", "-c", "init.defaultBranch=main"]
    env = ("GIT_CONFIG_NOSYSTEM", "1") : L.filter ((/= "GIT_CONFIG_NOSYSTEM") . fst) base
  result <-
    timeout 30000000 $
      Process.readCreateProcessWithExitCode ((Process.proc "git" (identity <> args)) {Process.cwd = Just dir, Process.env = Just env}) ""
  case result of
    Just (ExitSuccess, _, _) -> pure ()
    other -> assertFailure ("git " <> show args <> ": " <> show other)

-- | A repository with one commit at @dir/name@.
newRepo :: FilePath -> String -> IO FilePath
newRepo dir name = do
  git dir ["init", "-q", name]
  git (dir <> "/" <> name) ["commit", "-q", "--allow-empty", "-m", "first"]
  pure (dir <> "/" <> name)

type Outcome = Either NotReadyReason (Either T.Text ProjectView)

tests :: TestTree
tests =
  testGroup
    "Gate C remediation third addendum (C-C.R1 §3d; real PostgreSQL)"
    [ testCase "R5-1: another project connected the made folder under another spelling; the failed attempt keeps it" $
        withScenario $ \sc -> do
          createSymbolicLink (scRoot sc) (scDir sc <> "/alias")
          a <- made sc "a" "Garden"
          b <- made sc "b" "Orchard"
          other <- newEmptyMVar
          let
            aliasPath = scDir sc <> "/alias/garden"
            meanwhile _ = connectProject (scRuntime sc) (ProjectFolders (Just (scRoot sc)) [aliasPath]) (projectId b) 1 (ExistingFolder (T.pack aliasPath)) >>= putMVar other
          ra <- connectProjectAround meanwhile noProjectFaults (scRuntime sc) (rootFolders sc) (projectId a) 1 NewFolder
          rb <- readMVar other :: IO Outcome
          fmap (fmap projectSetup) rb @?= Right (Right Connected)
          assertBool ("the first attempt connected too: " <> show (fmap (fmap projectId) ra)) (fmap (fmap projectSetup) ra /= Right (Right Connected))
          recorded sc b >>= (@?= Just (Connected, Just (T.pack aliasPath), Nothing))
          kept <- doesDirectoryExist (scRoot sc <> "/garden/.git")
          assertBool "the folder another project is connected to (under another spelling) was removed" kept
    , testCase "R5-2: a folder replaced while the attempt waits is not connected, and the replacement is not registered" $
        withScenario $ \sc -> do
          b <- made sc "b" "Orchard"
          site <- newRepo (scRoot sc) "site"
          let
            -- The old folder is moved away first, so the new one cannot reuse its inode.
            replace _ = do
              renameDirectory site (scDir sc <> "/old-site")
              _ <- newRepo (scRoot sc) "site"
              pure ()
          rb <- connectProjectAround replace noProjectFaults (scRuntime sc) (rootFolders sc) (projectId b) 1 (ExistingFolder (T.pack site))
          assertBool ("connected to the replaced folder: " <> show (fmap (fmap projectFolder) rb)) (fmap (fmap projectSetup) rb /= Right (Right Connected))
          recorded sc b >>= (@?= Just (SetupFailed, Nothing, Just "folder-not-offered"))
          repositories sc >>= (@?= [0])
    , testCase "R5-3: a folder being initialized is not offered to any project" $
        withScenario $ \sc -> do
          seen <- newEmptyMVar
          result <- makeProjectFolderWith (\_ -> offeredFolders (scRuntime sc) (rootFolders sc) >>= putMVar seen) (scRoot sc) ["garden"]
          offered <- takeMVar seen
          offered @?= []
          result @?= Right (scRoot sc <> "/garden")
          isProjectFolder (scRoot sc <> "/garden") >>= assertBool "the published folder is not a project folder"
          listDirectory (scRoot sc) >>= (@?= ["garden"])
    , testCase "R5-3: a destination that appears during initialization is never replaced; the next free name is used" $
        withScenario $ \sc -> do
          let
            theirs = scRoot sc <> "/garden"
            claim _ = createDirectory theirs >> writeFile (theirs <> "/notes.txt") "mine"
          result <- try (makeProjectFolderWith claim (scRoot sc) ["garden", "garden-2"]) :: IO (Either SomeException (Either T.Text FilePath))
          case result of
            Right (Right path) -> path @?= scRoot sc <> "/garden-2"
            other -> assertFailure ("no folder was published: " <> show other)
          readFile (theirs <> "/notes.txt") >>= (@?= "mine")
          doesDirectoryExist (theirs <> "/.git") >>= assertBool "Git was put into a folder the attempt did not make" . not
          isProjectFolder (scRoot sc <> "/garden-2") >>= assertBool "the published folder is not a project folder"
          listDirectory (scRoot sc) >>= (@?= ["garden", "garden-2"]) . L.sort
    , testCase "R5-3: a failure after initialization removes only what the attempt made" $
        withScenario $ \sc -> do
          createDirectory (scRoot sc <> "/notes")
          writeFile (scRoot sc <> "/notes/keep.txt") "keep"
          result <- try (makeProjectFolderWith (\_ -> throwIO (userError "injected: interrupted after git init")) (scRoot sc) ["garden"]) :: IO (Either SomeException (Either T.Text FilePath))
          assertBool ("a folder was published: " <> show result) (either (const True) (either (const True) (const False)) result)
          listDirectory (scRoot sc) >>= (@?= ["notes"])
          doesFileExist (scRoot sc <> "/notes/keep.txt") >>= assertBool "a file the attempt did not make was removed"
    ]
