{-# LANGUAGE OverloadedStrings #-}

{- | The C-C.R1 second addendum against real PostgreSQL and Git (§3c: Review 4):
a folder one project's attempt made, and another project connected meanwhile,
in both orders; and a task's dependencies in its creation digest. The test-only
hook runs right before an attempt's transaction, where the other request acts.
-}
module Lockstep.GateCRemediationFolderRaceTest
  ( tests
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar (MVar, newEmptyMVar, putMVar, readMVar, takeMVar)
import Control.Exception (SomeException, throwIO, try)
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import System.Directory (createDirectory, doesDirectoryExist)
import System.IO (FilePath)
import System.IO.Error (userError)
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason, runMigrations)
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), connectProject, connectProjectAround, createProject, findProject, noProjectFaults)
import Lockstep.Application.Tasks (NewTask (..), TaskView (..), createTask)
import Lockstep.Kernel.Project (FolderChoice (..), SetupState (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (AdminSettings, databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime)

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
    withSystemTempDirectory "lockstep-cr1-race" $ \tmp -> do
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
  either (const (assertFailure ("creation key " <> T.unpack text))) pure (mkIdempotencyKey ("test-race-creation-" <> text))

ready :: Show e => IO (Either e a) -> IO a
ready action =
  action >>= either (\e -> assertFailure ("not ready: " <> show e)) pure

made :: Scenario -> T.Text -> T.Text -> IO ProjectView
made sc k name = do
  ik <- key k
  ready (createProject (scRuntime sc) (rootFolders sc) (NewProject ik name "" DecideLater)) >>= either (\c -> assertFailure ("project refused: " <> T.unpack c)) pure

recorded :: Scenario -> ProjectView -> IO (Maybe (SetupState, Maybe T.Text))
recorded sc view =
  fmap (\v -> (projectSetup v, projectFolder v)) <$> ready (findProject (scRuntime sc) (projectId view))

repositories :: Scenario -> IO [Int]
repositories sc =
  queryInts (scAdmin sc) (scDb sc) "SELECT count(*)::integer AS v FROM lockstep_repositories"

type Outcome = Either NotReadyReason (Either T.Text ProjectView)

background :: IO a -> IO (MVar (Either SomeException a))
background action = do
  box <- newEmptyMVar
  _ <- forkIO (try action >>= putMVar box)
  pure box

await :: String -> MVar (Either SomeException a) -> IO a
await what box = do
  result <- timeout 60000000 (takeMVar box)
  case result of
    Nothing -> assertFailure (what <> ": did not finish within 60 s")
    Just (Left e) -> assertFailure (what <> ": " <> show e)
    Just (Right a) -> pure a

tests :: TestTree
tests =
  testGroup
    "Gate C remediation second addendum (C-C.R1 §3c; real PostgreSQL)"
    [ testCase "another project connects the folder an attempt made; the attempt fails, and the folder stays with the connected project" $
        withScenario $ \sc -> do
          a <- made sc "a" "Garden"
          b <- made sc "b" "Orchard"
          other <- newEmptyMVar
          let
            meanwhile path = connectProject (scRuntime sc) (rootFolders sc) (projectId b) 1 (ExistingFolder (T.pack path)) >>= putMVar other
          ra <- connectProjectAround meanwhile noProjectFaults (scRuntime sc) (rootFolders sc) (projectId a) 1 NewFolder
          rb <- readMVar other :: IO Outcome
          let
            folder = scRoot sc <> "/garden"
          fmap (fmap projectSetup) rb @?= Right (Right Connected)
          assertBool ("the first attempt connected too: " <> show (fmap (fmap projectId) ra)) (fmap (fmap projectSetup) ra /= Right (Right Connected))
          recorded sc b >>= (@?= Just (Connected, Just (T.pack folder)))
          kept <- doesDirectoryExist folder
          assertBool "the folder another project is connected to was removed" kept
    , testCase "an attempt waits with a folder another attempt made and then removed; it is not recorded as connected to a missing folder" $
        withScenario $ \sc -> do
          a <- made sc "a" "Garden"
          b <- made sc "b" "Orchard"
          chosen <- newEmptyMVar
          resume <- newEmptyMVar
          second <- newEmptyMVar
          let
            waitForA _ = putMVar chosen () >> takeMVar resume
            interruptA path = do
              box <- background (connectProjectAround waitForA noProjectFaults (scRuntime sc) (rootFolders sc) (projectId b) 1 (ExistingFolder (T.pack path)))
              putMVar second box
              takeMVar chosen
              throwIO (userError "injected: the first attempt is interrupted before its transaction")
          ra <- try (connectProjectAround interruptA noProjectFaults (scRuntime sc) (rootFolders sc) (projectId a) 1 NewFolder) :: IO (Either SomeException Outcome)
          assertBool ("the interrupted attempt connected: " <> show (fmap (fmap (fmap projectId)) ra)) (either (const True) (either (const True) (const False)) ra)
          gone <- not <$> doesDirectoryExist (scRoot sc <> "/garden")
          assertBool "the first attempt's own folder was not removed" gone
          putMVar resume ()
          box <- takeMVar second
          rb <- await "the second attempt" box
          assertBool ("recorded as connected to a missing folder: " <> show (fmap (fmap projectFolder) rb)) (fmap (fmap projectSetup) rb /= Right (Right Connected))
          recorded sc b >>= assertBool "the second project is recorded as connected" . (/= Just Connected) . fmap fst
          repositories sc >>= (@?= [0])
    , testCase "a task's dependencies are part of its creation digest one by one, so joined text is not the same request" $
        withScenario $ \sc -> do
          p <- made sc "kitchen" "Kitchen"
          let
            taskWith k title deps = do
              ik <- key ("task-" <> k)
              ready (createTask (scRuntime sc) (NewTask ik (projectId p) title "" Normal deps))
          t1 <- taskWith "1" "Buy flour" [] >>= either (assertFailure . T.unpack) pure
          t2 <- taskWith "2" "Buy eggs" [] >>= either (assertFailure . T.unpack) pure
          t3 <- taskWith "3" "Bake" [taskId t1, taskId t2] >>= either (assertFailure . T.unpack) pure
          again <- taskWith "3" "Bake" [taskId t2, taskId t1] >>= either (assertFailure . T.unpack) pure
          taskId again @?= taskId t3
          taskWith "3" "Bake" [T.intercalate "," (L.sort [taskId t1, taskId t2])] >>= (@?= Left "key-conflict") . fmap taskId
    ]
