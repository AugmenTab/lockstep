{-# LANGUAGE OverloadedStrings #-}

{- | Tasks in projects against real PostgreSQL (contract C-P3.6 K1–K5): the
operations run in this process; every task is a C-P2.2 Ticket with its events,
and nothing is ever scheduled or run.
-}
module Lockstep.TasksTest
  ( tests
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Database (DatabaseRuntime, runMigrations)
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks
  ( NewTask (..)
  , TaskDecision (..)
  , TaskEdit (..)
  , TaskView (..)
  , createTask
  , decideTask
  , editTask
  , findTask
  , listTasks
  , mostImportantReadyTask
  )
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Task (Priority (..), TaskReadiness (..))
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
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-p36" $ \_ -> do
      config <- databaseConfigFor admin db
      withRuntime config $ \runtime -> do
        migrated <- runMigrations migrations runtime
        assertBool "migrations failed" (either (const False) (const True) migrated)
        action (Scenario admin db runtime)

key :: T.Text -> IO IdempotencyKey
key text =
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-task-creation-" <> text))

-- | A project without a folder ("decide later").
project :: Scenario -> T.Text -> IO T.Text
project sc name = do
  k <- key ("project-" <> T.filter (/= ' ') name)
  result <- createProject (scRuntime sc) (ProjectFolders Nothing []) (NewProject k name "" DecideLater)
  case result of
    Right (Right view) -> pure (projectId view)
    other -> assertFailure ("project: " <> show (fmap (fmap projectId) other))

ready :: Show e => IO (Either e a) -> IO a
ready action =
  action >>= either (\e -> assertFailure ("not ready: " <> show e)) pure

new :: Scenario -> T.Text -> T.Text -> T.Text -> Priority -> [T.Text] -> IO (Either T.Text TaskView)
new sc k projectId title priority deps = do
  ik <- key k
  ready (createTask (scRuntime sc) (NewTask ik projectId title "It is done when it is done." priority deps))

made :: Scenario -> T.Text -> T.Text -> T.Text -> Priority -> [T.Text] -> IO TaskView
made sc k projectId title priority deps =
  new sc k projectId title priority deps >>= either (\c -> assertFailure ("refused: " <> T.unpack c)) pure

decide :: Scenario -> TaskView -> TaskDecision -> IO (Either T.Text TaskView)
decide sc view decision =
  ready (decideTask (scRuntime sc) "test-session" (taskId view) (taskTicketRevision view) decision)

decided :: Scenario -> TaskView -> TaskDecision -> IO TaskView
decided sc view decision =
  decide sc view decision >>= either (\c -> assertFailure ("refused: " <> T.unpack c)) pure

found :: Scenario -> TaskView -> IO TaskView
found sc view =
  ready (findTask (scRuntime sc) (taskId view)) >>= maybe (assertFailure "the task is gone") pure

count :: Scenario -> String -> IO Int
count sc table = do
  rows <- queryInts (scAdmin sc) (scDb sc) ("SELECT count(*)::integer AS v FROM " <> table)
  case rows of
    [n] -> pure n
    _ -> assertFailure ("count " <> table)

nothingRuns :: Scenario -> Assertion
nothingRuns sc =
  traverse_
    (\t -> count sc t >>= \n -> assertBool (t <> " has " <> show n <> " rows") (n == 0))
    ["lockstep_work_orders", "lockstep_schedule_decisions", "lockstep_jobs", "lockstep_effect_intents", "lockstep_work_units"]

edit :: TaskView -> TaskEdit
edit view =
  TaskEdit (taskTitle view) (taskAcceptance view) (if taskPriority view >= 700 then High else if taskPriority view >= 400 then Normal else Low) (taskDependencies view)

tests :: TestTree
tests =
  testGroup
    "tasks in projects (C-P3.6; real PostgreSQL)"
    [ testCase "a task is a proposed Ticket with one event, in a project that has no folder" $
        withScenario $ \sc -> do
          p <- project sc "Kitchen"
          view <- made sc "1" p "  Write the menu  " High []
          (taskTitle view, taskState view, taskReadinessOf view, taskPriority view) @?= ("Write the menu", "proposed", NotYetReady, 800)
          (taskRevision view, taskTicketRevision view, taskProject view) @?= (1, 1, p)
          taskAcceptance view @?= "It is done when it is done."
          count sc "lockstep_tickets" >>= (@?= 1)
          count sc "lockstep_project_tasks" >>= (@?= 1)
          count sc ("lockstep_events WHERE subject_id = '" <> T.unpack (taskId view) <> "'") >>= (@?= 1)
          nothingRuns sc
    , testCase "rules come first, and a refused task creates nothing" $
        withScenario $ \sc -> do
          p <- project sc "Kitchen"
          traverse_
            (\(n, title, code) -> new sc (T.pack ("r" <> show (n :: Int))) p title Normal [] >>= (@?= Left code) . fmap taskId)
            [(1, "   ", "title-empty"), (2, T.replicate 201 "t", "title-too-long"), (3, "a\nb", "title-control")]
          ik <- key "r4"
          long <- createTask (scRuntime sc) (NewTask ik p "Fine" (T.replicate 4001 "a") Normal [])
          fmap (fmap taskId) long @?= Right (Left "acceptance-too-long")
          ik5 <- key "r5"
          noProject <- createTask (scRuntime sc) (NewTask ik5 "00000000-0000-4000-8000-000000000000" "Fine" "" Normal [])
          fmap (fmap taskId) noProject @?= Right (Left "unknown-project")
          ik6 <- key "r6"
          badDep <- createTask (scRuntime sc) (NewTask ik6 p "Fine" "" Normal ["00000000-0000-4000-8000-000000000001"])
          fmap (fmap taskId) badDep @?= Right (Left "unknown-dependency")
          count sc "lockstep_tickets" >>= (@?= 0)
          count sc "lockstep_project_tasks" >>= (@?= 0)
    , testCase "a repeated creation key returns the first task and creates nothing" $
        withScenario $ \sc -> do
          p <- project sc "Kitchen"
          first <- made sc "same" p "Buy bread" Normal []
          again <- made sc "same" p "Buy bread" Normal []
          other <- made sc "same" p "Something else" Low []
          (taskId again, taskId other) @?= (taskId first, taskId first)
          count sc "lockstep_tickets" >>= (@?= 1)
    , testCase "an edit changes the task, a new title is a revision event, and a stale edit changes nothing" $
        withScenario $ \sc -> do
          p <- project sc "Kitchen"
          view <- made sc "1" p "Write the menu" Normal []
          edited <-
            ready (editTask (scRuntime sc) (taskId view) 1 (TaskEdit "Write the winter menu" "Printed and on the wall." Low []))
              >>= either (assertFailure . T.unpack) pure
          (taskTitle edited, taskAcceptance edited, taskPriority edited, taskRevision edited) @?= ("Write the winter menu", "Printed and on the wall.", 200, 2)
          taskTicketRevision edited @?= 2
          count sc ("lockstep_events WHERE subject_id = '" <> T.unpack (taskId view) <> "'") >>= (@?= 2)
          sameTitle <-
            ready (editTask (scRuntime sc) (taskId view) 2 (TaskEdit "Write the winter menu" "Printed." High []))
              >>= either (assertFailure . T.unpack) pure
          (taskRevision sameTitle, taskTicketRevision sameTitle, taskPriority sameTitle) @?= (3, 2, 800)
          stale <- ready (editTask (scRuntime sc) (taskId view) 1 (TaskEdit "Overwritten" "" Low []))
          fmap taskId stale @?= Left "stale-revision"
          now <- found sc view
          (taskTitle now, taskAcceptance now, taskPriority now, taskRevision now) @?= ("Write the winter menu", "Printed.", 800, 3)
          badTitle <- ready (editTask (scRuntime sc) (taskId view) 3 (TaskEdit "" "" Low []))
          fmap taskId badTitle @?= Left "title-empty"
          found sc view >>= (@?= 3) . taskRevision
    , testCase "dependencies stay inside the project and never loop" $
        withScenario $ \sc -> do
          p <- project sc "Kitchen"
          q <- project sc "Garden"
          a <- made sc "a" p "Buy paper" Normal []
          b <- made sc "b" p "Print the menu" Normal [taskId a]
          taskDependencies b @?= [taskId a]
          elsewhere <- made sc "e" q "Dig" Normal []
          new sc "x" p "Cross" Normal [taskId elsewhere] >>= (@?= Left "unknown-dependency") . fmap taskId
          selfish <- ready (editTask (scRuntime sc) (taskId a) 1 ((edit a) {editDependencies = [taskId a]}))
          fmap taskId selfish @?= Left "dependency-self"
          loop <- ready (editTask (scRuntime sc) (taskId a) 1 ((edit a) {editDependencies = [taskId b]}))
          fmap taskId loop @?= Left "dependency-cycle"
          found sc a >>= (@?= []) . taskDependencies
          c <- made sc "c" p "Hang the menu" Normal [taskId b, taskId a]
          L.sort (taskDependencies c) @?= L.sort [taskId a, taskId b]
          tooMany <- new sc "m" p "Many" Normal (L.replicate 21 (taskId a))
          fmap taskId tooMany @?= Left "too-many-dependencies"
    , testCase "ready, block, unblock and cancel are Ticket decisions with their revision; stale and illegal ones are refused" $
        withScenario $ \sc -> do
          p <- project sc "Kitchen"
          view <- made sc "1" p "Write the menu" Normal []
          readyNow <- decided sc view MarkReady
          (taskState readyNow, taskReadinessOf readyNow, taskTicketRevision readyNow) @?= ("ready", ReadyToWork, 2)
          decide sc view MarkReady >>= (@?= Left "stale-revision") . fmap taskId
          decide sc readyNow (BlockTask "  ") >>= (@?= Left "reason-empty") . fmap taskId
          blocked <- decided sc readyNow (BlockTask "the printer is broken")
          (taskState blocked, taskBlockReason blocked, taskReadinessOf blocked) @?= ("blocked", Just "the printer is broken", BlockedBecause "the printer is broken")
          decide sc blocked MarkReady >>= (@?= Left "not-allowed-now") . fmap taskId
          unblocked <- decided sc blocked UnblockTask
          (taskState unblocked, taskReadinessOf unblocked) @?= ("ready", ReadyToWork)
          canceled <- decided sc unblocked CancelTask
          (taskState canceled, taskReadinessOf canceled) @?= ("canceled", TaskCanceled)
          decide sc canceled UnblockTask >>= (@?= Left "not-allowed-now") . fmap taskId
          found sc view >>= (@?= 5) . taskTicketRevision
          nothingRuns sc
    , testCase "readiness comes from stored facts: waiting, cannot start, and the most important ready task" $
        withScenario $ \sc -> do
          p <- project sc "Kitchen"
          paper <- made sc "paper" p "Buy paper" Low []
          printIt <- made sc "print" p "Print the menu" High [taskId paper]
          urgent <- made sc "urgent" p "Fix the oven" High []
          calm <- made sc "calm" p "Water the plants" Normal []
          traverse_ (\v -> void (decided sc v MarkReady)) [paper, printIt, calm]
          urgentReady <- decided sc urgent MarkReady
          _ <- decided sc urgentReady (BlockTask "waiting for a part")
          listed <- ready (listTasks (scRuntime sc) p)
          let
            readinessOf v = taskReadinessOf <$> L.find ((== taskId v) . taskId) listed
          readinessOf printIt @?= Just (WaitingFor ["Buy paper"])
          readinessOf urgent @?= Just (BlockedBecause "waiting for a part")
          fmap taskTitle listed @?= ["Print the menu", "Fix the oven", "Water the plants", "Buy paper"]
          fmap taskTitle (mostImportantReadyTask listed) @?= Just "Water the plants"
          paperNow <- found sc paper
          _ <- decided sc paperNow CancelTask
          again <- ready (listTasks (scRuntime sc) p)
          (taskReadinessOf <$> L.find ((== taskId printIt) . taskId) again) @?= Just (CannotStart ["Buy paper"])
          nothingRuns sc
    , testCase "tasks of other projects are not listed, and unknown tasks are refused" $
        withScenario $ \sc -> do
          p <- project sc "Kitchen"
          q <- project sc "Garden"
          _ <- made sc "1" p "Write the menu" Normal []
          _ <- made sc "2" q "Dig" Normal []
          ready (listTasks (scRuntime sc) p) >>= (@?= ["Write the menu"]) . fmap taskTitle
          ready (findTask (scRuntime sc) "00000000-0000-4000-8000-000000000000") >>= (@?= Nothing) . fmap taskId
          gone <- ready (decideTask (scRuntime sc) "test-session" "00000000-0000-4000-8000-000000000000" 1 MarkReady)
          fmap taskId gone @?= Left "unknown-task"
          lost <- ready (editTask (scRuntime sc) "not-a-uuid" 1 (TaskEdit "x" "" Low []))
          fmap taskId lost @?= Left "unknown-task"
    ]
