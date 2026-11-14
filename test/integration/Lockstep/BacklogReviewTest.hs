{-# LANGUAGE OverloadedStrings #-}

{- | Review remediation of C-P6.1 (R-P6.1-1 to R-P6.1-4), against real
PostgreSQL: a cycle through a person's own dependency refuses only the items
on it; a dependency a person removed is not counted; an export imported and
exported again is the same document; a Jira file that is one page of a larger
search is refused.
-}
module Lockstep.BacklogReviewTest
  ( tests
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Backlog (ImportReport (..), exportBacklog, importBacklog, importJiraSearch)
import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Database (DatabaseRuntime, runMigrations)
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks (NewTask (..), TaskEdit (..), TaskView (..), createTask, editTask, listTasks)
import Lockstep.Kernel.Backlog (ImportDecision (..), ItemOutcome (..), ItemRefusal (..), sourceKeyText)
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (AdminSettings, databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime)

data Scenario
  = Scenario
  { scAdmin :: AdminSettings
  , scDb :: T.Text
  , scRuntime :: DatabaseRuntime
  }

withScenario :: (Scenario -> IO a) -> IO a
withScenario action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db -> do
    config <- databaseConfigFor admin db
    withRuntime config $ \runtime -> do
      migrated <- runMigrations migrations runtime
      assertBool "migrations failed" (either (const False) (const True) migrated)
      action (Scenario admin db runtime)

ready :: Show e => IO (Either e a) -> IO a
ready action =
  action >>= either (\e -> assertFailure ("not ready: " <> show e)) pure

key :: T.Text -> IO IdempotencyKey
key text =
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-backlog-review-" <> text))

project :: Scenario -> T.Text -> IO ProjectView
project sc name = do
  k <- key ("project-" <> name)
  made <- ready (createProject (scRuntime sc) (ProjectFolders Nothing []) (NewProject k name "" DecideLater))
  either (\c -> assertFailure ("refused: " <> T.unpack c)) pure made

item :: T.Text -> Int -> T.Text -> [T.Text] -> T.Text
item k r title blockers =
  "{\"key\":\""
    <> k
    <> "\",\"revision\":"
    <> T.pack (show r)
    <> ",\"title\":\""
    <> title
    <> "\",\"acceptance\":[{\"text\":\"It works for "
    <> k
    <> "\",\"ref\":\""
    <> k
    <> " AC1\"}],\"blockers\":["
    <> T.intercalate "," (fmap (\b -> "\"" <> b <> "\"") blockers)
    <> "]}"

document :: Int -> [T.Text] -> LBS.ByteString
document r items =
  LBS.fromStrict . TE.encodeUtf8 $
    "{\"format\":\"lockstep-backlog\",\"version\":1,\"source\":{\"provider\":\"canonical\",\"locator\":\"review\"},\"revision\":"
      <> T.pack (show r)
      <> ",\"items\":["
      <> T.intercalate "," items
      <> "]}"

imported :: Scenario -> ProjectView -> LBS.ByteString -> IO ImportReport
imported sc view bytes =
  ready (importBacklog (scRuntime sc) (projectId view) bytes) >>= either (\c -> assertFailure ("import refused: " <> T.unpack c)) pure

outcomesOf :: ImportReport -> [(T.Text, ItemOutcome)]
outcomesOf report =
  [(sourceKeyText k, o) | (k, o) <- decisionItems (reportDecision report)]

titled :: Scenario -> ProjectView -> T.Text -> IO TaskView
titled sc view title = do
  ts <- ready (listTasks (scRuntime sc) (projectId view))
  case L.filter ((== title) . taskTitle) ts of
    [t] -> pure t
    other -> assertFailure ("tasks titled " <> T.unpack title <> ": " <> show (L.length other))

setDependencies :: Scenario -> TaskView -> [T.Text] -> IO ()
setDependencies sc t deps = do
  edited <- ready (editTask (scRuntime sc) (taskId t) (taskRevision t) (TaskEdit (taskTitle t) (taskAcceptance t) Normal deps))
  assertBool ("edit refused: " <> show (fmap taskTitle edited)) (isRight edited)

tests :: TestTree
tests =
  testGroup
    "backlog intake review remediation (C-P6.1 R-P6.1-1 to R-P6.1-4; real PostgreSQL)"
    [ testCase "a cycle through a dependency a person added refuses only the item that closes it (R-P6.1-1)" $
        withScenario $ \sc -> do
          view <- project sc "Cycle"
          _ <- imported sc view (document 1 [item "X" 1 "Task X" [], item "Y" 1 "Task Y" []])
          x <- titled sc view "Task X"
          y <- titled sc view "Task Y"
          -- The person makes X depend on Y in Lockstep (X is now locally edited).
          setDependencies sc x [taskId y]
          r <- imported sc view (document 2 [item "X" 1 "Task X" [], item "Y" 2 "Task Y" ["X"], item "Z" 1 "Task Z" []])
          outcomesOf r @?= [("X", ItemUnchanged), ("Y", ItemRefused BlockerCycle), ("Z", ItemCreated)]
          _ <- titled sc view "Task Z"
          pure ()
    , testCase "a cycle through a person's internal task is found too (R-P6.1-1)" $
        withScenario $ \sc -> do
          view <- project sc "Internal"
          _ <- imported sc view (document 1 [item "A" 1 "Task A" [], item "B" 1 "Task B" []])
          b <- titled sc view "Task B"
          ik <- key "internal"
          internal <- ready (createTask (scRuntime sc) (NewTask ik (projectId view) "Internal" "" Normal [taskId b])) >>= either (assertFailure . T.unpack) pure
          a <- titled sc view "Task A"
          setDependencies sc a [taskId internal]
          -- A -> internal -> B; the source now says B is blocked by A: a cycle.
          r <- imported sc view (document 2 [item "B" 2 "Task B" ["A"]])
          outcomesOf r @?= [("B", ItemRefused BlockerCycle)]
    , testCase "a dependency a person removed is not counted: no false cycle (R-P6.1-2)" $
        withScenario $ \sc -> do
          view <- project sc "Removed"
          _ <- imported sc view (document 1 [item "A" 1 "Task A" [], item "B" 1 "Task B" ["A"]])
          b <- titled sc view "Task B"
          setDependencies sc b []
          r <- imported sc view (document 2 [item "A" 2 "Task A" ["B"]])
          outcomesOf r @?= [("A", ItemUpdated)]
    , testCase "an export imported elsewhere and exported again is the same document, item by item (R-P6.1-3)" $
        withScenario $ \sc -> do
          first <- project sc "First"
          _ <- imported sc first (document 1 [item "A" 1 "Task A" [], item "B" 1 "Task B" ["A"]])
          ik <- key "slider"
          _ <- ready (createTask (scRuntime sc) (NewTask ik (projectId first) "Slider" "It moves.\nIt stops." Normal []))
          exported1 <- ready (exportBacklog (scRuntime sc) (projectId first)) >>= either (assertFailure . T.unpack) pure
          second <- project sc "Second"
          _ <- imported sc second (LBS.fromStrict (TE.encodeUtf8 exported1))
          exported2 <- ready (exportBacklog (scRuntime sc) (projectId second)) >>= either (assertFailure . T.unpack) pure
          third <- project sc "Third"
          _ <- imported sc third (LBS.fromStrict (TE.encodeUtf8 exported2))
          let
            acceptances v = fmap (L.sort . fmap taskAcceptance) (ready (listTasks (scRuntime sc) (projectId v)))
          a2 <- acceptances second
          a3 <- acceptances third
          a3 @?= a2
          assertBool ("references pile up: " <> show a3) (not (L.any (T.isInfixOf "- - ") a3))
          slider <- titled sc third "Slider"
          L.length (T.lines (taskAcceptance slider)) @?= 2
    , testCase "a Jira file that is one page of a larger search is refused, and records nothing (R-P6.1-4)" $
        withScenario $ \sc -> do
          view <- project sc "Jira"
          let
            page = "{\"startAt\":50,\"maxResults\":50,\"total\":120,\"issues\":[{\"key\":\"CAE-51\",\"fields\":{\"summary\":\"S\",\"updated\":\"2026-11-10T09:15:00.000+0000\"}}]}"
            partial = "{\"startAt\":0,\"maxResults\":1,\"total\":2,\"issues\":[{\"key\":\"CAE-1\",\"fields\":{\"summary\":\"S\",\"updated\":\"2026-11-10T09:15:00.000+0000\"}}]}"
          ready (importJiraSearch (scRuntime sc) (projectId view) "acme" page) >>= (@?= Left "jira-unreadable")
          ready (importJiraSearch (scRuntime sc) (projectId view) "acme" partial) >>= (@?= Left "jira-unreadable")
          rows <- queryInts (scAdmin sc) (scDb sc) "SELECT count(*)::integer AS v FROM lockstep_backlog_sources"
          rows @?= [0]
    ]
