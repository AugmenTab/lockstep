{-# LANGUAGE OverloadedStrings #-}

{- | The C-C.R1 addendum against real PostgreSQL and Git (§3b: Review 3
findings 3 and 4, and migration 17's rule for rows made before it): the
operations run in this process; the narrow test hook after a connection
attempt's commit stands for an interruption there, or for a COMMIT whose answer
was lost.
-}
module Lockstep.GateCRemediationAddendumTest
  ( tests
  ) where

import Control.Exception (SomeException, throwIO, try)
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import System.Directory (createDirectory, doesDirectoryExist, listDirectory)
import System.IO (FilePath)
import System.IO.Error (userError)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason (..), runMigrations)
import Lockstep.Application.Projects (NewProject (..), ProjectFaults (..), ProjectFolders (..), ProjectView (..), connectProjectWith, createProject, findProject)
import Lockstep.Application.Tasks (NewTask (..), TaskEdit (..), TaskView (..), createTask, editTask)
import Lockstep.Kernel.Project (FolderChoice (..), SetupState (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (AdminSettings, adminExecute, databaseConfigFor, requireAdmin, withFreshDatabase, withRuntime)

data Scenario
  = Scenario
  { scAdmin :: AdminSettings
  , scDb :: T.Text
  , scRuntime :: DatabaseRuntime
  , scRoot :: FilePath
  }

withScenario :: (Scenario -> IO a) -> IO a
withScenario action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-cr1-addendum" $ \tmp -> do
      config <- databaseConfigFor admin db
      withRuntime config $ \runtime -> do
        migrated <- runMigrations migrations runtime
        assertBool "migrations failed" (either (const False) (const True) migrated)
        createDirectory (tmp <> "/projects")
        action (Scenario admin db runtime (tmp <> "/projects"))

rootFolders :: Scenario -> ProjectFolders
rootFolders sc =
  ProjectFolders (Just (scRoot sc)) []

key :: T.Text -> IO IdempotencyKey
key text =
  either (const (assertFailure ("creation key " <> T.unpack text))) pure (mkIdempotencyKey ("test-addendum-creation-" <> text))

ready :: Show e => IO (Either e a) -> IO a
ready action =
  action >>= either (\e -> assertFailure ("not ready: " <> show e)) pure

createWith :: Scenario -> T.Text -> T.Text -> FolderChoice -> IO (Either T.Text ProjectView)
createWith sc k name choice = do
  ik <- key k
  ready (createProject (scRuntime sc) (rootFolders sc) (NewProject ik name "What it should achieve." choice))

made :: Scenario -> T.Text -> T.Text -> FolderChoice -> IO ProjectView
made sc k name choice =
  createWith sc k name choice >>= either (\c -> assertFailure ("project refused: " <> T.unpack c)) pure

taskWith :: Scenario -> T.Text -> T.Text -> T.Text -> IO (Either T.Text TaskView)
taskWith sc k project title = do
  ik <- key ("task-" <> k)
  ready (createTask (scRuntime sc) (NewTask ik project title "Done when done." Normal []))

execute :: Scenario -> String -> IO ()
execute sc =
  adminExecute (scAdmin sc) (T.unpack (scDb sc))

-- | The project as the database now records it: its setup and folder.
recorded :: Scenario -> ProjectView -> IO (Maybe (SetupState, Maybe T.Text))
recorded sc view =
  fmap (\v -> (projectSetup v, projectFolder v)) <$> ready (findProject (scRuntime sc) (projectId view))

tests :: TestTree
tests =
  testGroup
    "Gate C remediation addendum (C-C.R1 §3b; real PostgreSQL)"
    [ testGroup
        "a connected project's folder is never removed (Review 3 findings 3, 4)"
        [ testCase "an interruption right after the commit leaves the connected project and its new folder" $
            withScenario $ \sc -> do
              view <- made sc "garden" "Garden" DecideLater
              let
                interrupt _ = throwIO (userError "injected: interrupted after the commit")
              result <- try (connectProjectWith (ProjectFaults interrupt) (scRuntime sc) (rootFolders sc) (projectId view) 1 NewFolder) :: IO (Either SomeException (Either NotReadyReason (Either T.Text ProjectView)))
              assertBool ("the interrupted connect reported success: " <> show (fmap (fmap (fmap projectId)) result)) (either (const True) (either (const True) (const False)) result)
              let
                folder = scRoot sc <> "/garden"
              recorded sc view >>= (@?= Just (Connected, Just (T.pack folder)))
              kept <- doesDirectoryExist folder
              assertBool "the connected project's folder was removed" kept
        , testCase "a COMMIT whose answer was lost leaves the connected project and its new folder, and nothing else is touched" $
            withScenario $ \sc -> do
              createDirectory (scRoot sc <> "/notes")
              view <- made sc "garden" "Garden" DecideLater
              let
                lost _ = pure (Left DatabaseError)
              result <- connectProjectWith (ProjectFaults lost) (scRuntime sc) (rootFolders sc) (projectId view) 1 NewFolder
              fmap (fmap projectId) result @?= Left DatabaseError
              let
                folder = scRoot sc <> "/garden"
              recorded sc view >>= (@?= Just (Connected, Just (T.pack folder)))
              listDirectory (scRoot sc) >>= (@?= ["garden", "notes"]) . L.sort
        , testCase "a failed attempt keeps the folder it made and records nothing (R6-1)" $
            withScenario $ \sc -> do
              createDirectory (scRoot sc <> "/notes")
              view <- made sc "garden" "Garden" DecideLater
              execute sc "CREATE FUNCTION addendum_fail() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected failure'; END $$"
              execute sc "CREATE TRIGGER addendum_fail BEFORE UPDATE ON lockstep_projects FOR EACH ROW EXECUTE FUNCTION addendum_fail()"
              result <- connectProjectWith (ProjectFaults pure) (scRuntime sc) (rootFolders sc) (projectId view) 1 NewFolder
              assertBool ("not a failure: " <> show (fmap (fmap projectId) result)) (either (const True) (const False) result)
              recorded sc view >>= (@?= Just (Organized, Nothing))
              listDirectory (scRoot sc) >>= (@?= ["garden", "notes"]) . L.sort
        ]
    , testGroup
        "rows made before migration 17 replay only when the request is shown equal (A-C.R1-1)"
        [ testCase "a project without a creation digest" $
            withScenario $ \sc -> do
              first <- made sc "later" "Notes" DecideLater
              execute sc "UPDATE lockstep_projects SET creation_digest = NULL"
              again <- made sc "later" "Notes" DecideLater
              projectId again @?= projectId first
              createWith sc "later" "Other notes" DecideLater >>= (@?= Left "key-conflict") . fmap projectId
              createWith sc "later" "Notes" NewFolder >>= (@?= Left "key-conflict") . fmap projectId
              listDirectory (scRoot sc) >>= (@?= [])
        , testCase "a task without a creation digest, before and after an edit" $
            withScenario $ \sc -> do
              p <- made sc "kitchen" "Kitchen" DecideLater
              first <- taskWith sc "1" (projectId p) "Buy bread" >>= either (assertFailure . T.unpack) pure
              execute sc "UPDATE lockstep_project_tasks SET creation_digest = NULL"
              again <- taskWith sc "1" (projectId p) "Buy bread" >>= either (assertFailure . T.unpack) pure
              taskId again @?= taskId first
              taskWith sc "1" (projectId p) "Buy rye bread" >>= (@?= Left "key-conflict") . fmap taskId
              _ <- ready (editTask (scRuntime sc) (taskId first) 1 (TaskEdit "Buy bread" "Done when done, and paid for." Normal []))
              taskWith sc "1" (projectId p) "Buy bread" >>= (@?= Left "key-conflict") . fmap taskId
        ]
    ]
