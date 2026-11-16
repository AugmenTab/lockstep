{-# LANGUAGE OverloadedStrings #-}

{- | Gate D (P6.11) D-10, model-free: the operator's pages, served by the real
@lockstep serve@ over HTTP from the same PostgreSQL the engine wrote, after a
two-unit chain ran through the scheduler and the engine with scripted roles.
The plan page shows the dependency graph and what runs next; the progress
page shows both units checked and committed and not Done, with the commits
and records they rest on, and what the usage evidence establishes; the task
page shows the checks the work runs under; the summary says the same.
-}
module Lockstep.GateDPagesTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import System.Directory (createDirectory)
import System.Exit (ExitCode (ExitSuccess))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Engine (TransactionView (..))
import Lockstep.Application.Projects (ProjectView (..))
import Lockstep.Application.Summary (ProjectSummary (..), SummaryItem (..), projectSummary)
import Lockstep.Application.Tasks (TaskView (..))
import Lockstep.Kernel.Plan (EdgeKind (..), PlanEdge (..), PlanMode (..))
import Lockstep.Kernel.Summary (UsageStanding (..), categoryCode)
import Lockstep.Support.Http (HttpResponse (..), httpRequest)
import Lockstep.Support.Postgres (AdminSettings (..), databaseConfigFor, requireAdmin, withFreshDatabase, withRuntime, writeConfigFile)
import Lockstep.Support.Process (freePort, runLockstep, withService)
import Lockstep.Support.Scheduling (Scenario (..), acceptedCount, approveIn, engineFor, fixOfTask, headOf, k, passesUntil, planOf, projectWith, ready, taskOfUnit, valueFiles, valueScripts, valueUnit)

tests :: TestTree
tests =
  testGroup
    "Gate D the operator's pages (lockstep serve over HTTP, real PostgreSQL, Git, processes; scripted roles)"
    [ testCase "the plan, progress, task and decisions pages and the summary show the graph, technical acceptance (not Done), the evidence, the checks and the usage truthfully (D-10)" pages
    ]

-- Fixtures ---------------------------------------------------------------------------------------

prefix :: T.Text
prefix =
  "test-gate-d-pages-"

data Env
  = Env
  { envScenario :: Scenario
  , envCli :: [(String, String)]
  , envPort :: Int
  }

-- | A migrated database, a running @lockstep serve@ on it, and the scenario the engine runs in-process on the same database.
withEnv :: (Env -> IO a) -> IO a
withEnv action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-gate-d-pages" $ \dir -> do
      path <- writeConfigFile dir admin db (adminPassword admin)
      let
        cli = [("LOCKSTEP_CONFIG", path)]
      (code, _, err) <- runLockstep cli ["db", "migrate"]
      assertBool ("db migrate failed: " <> err) (code == ExitSuccess)
      createDirectory (dir <> "/projects")
      createDirectory (dir <> "/work")
      config <- databaseConfigFor admin db
      withRuntime config $ \runtime -> do
        port <- freePort
        (result, _) <- withService cli port (dir <> "/serve.log") (action (Env (Scenario admin db runtime dir) cli port))
        pure result

session :: Env -> IO BS.ByteString
session env = do
  (code, out, err) <- runLockstep (envCli env) ["operator", "sign-in", "--port", show (envPort env)]
  code @?= ExitSuccess
  token <-
    case L.stripPrefix "=" (L.dropWhile (/= '=') (L.filter (/= '\n') out)) of
      Just t | L.length t == 43 -> pure t
      _ -> assertFailure ("unexpected sign-in output: " <> out <> err)
  resp <- httpRequest (envPort env) "POST" "/app/api/session" [("Origin", "http://127.0.0.1:" <> BS8.pack (show (envPort env)))] (BS8.pack token)
  responseStatus resp @?= 200
  pure (BS.take 43 (BS.drop 11 (snd (BS.breakSubstring "\"session\":\"" (responseBody resp)))))

page :: Env -> BS.ByteString -> String -> IO BS.ByteString
page env s path = do
  resp <- httpRequest (envPort env) "GET" ("/app/fragments/" <> path) [("X-Lockstep-Session", s)] ""
  responseStatus resp @?= 200
  pure (responseBody resp)

has :: String -> BS.ByteString -> T.Text -> Assertion
has which body needle =
  assertBool ("the " <> which <> " page lacks " <> show needle) (not (BS.null (snd (BS.breakSubstring (TE.encodeUtf8 needle) body))))

-- Case -------------------------------------------------------------------------------------------

pages :: Assertion
pages =
  withEnv $ \env -> do
    let
      sc = envScenario env
    (view, folder) <- projectWith sc prefix "pages" (valueFiles 2) True
    r <- approveIn sc prefix view "pages" (planOf "Values" Brownfield [valueUnit 1, valueUnit 2] [PlanEdge (k "f2") (k "f1") Technical])
    engine <- engineFor sc (fmap valueScripts [1, 2])
    passesUntil sc engine 120 ((== 2) <$> acceptedCount sc)
    t2 <- taskOfUnit sc view r "f2"
    f2 <- fixOfTask sc (taskId t2)
    s <- session env
    let
      pid = T.unpack (projectId view)
    -- The plan page: the graph and where each unit stands.
    plan <- page env s ("project-plan/" <> pid)
    traverse_ (has "plan" plan) ["What runs next", "Make f1 return 1", "Make f2 return 2", "needs it working", "checked and waiting for your Done"]
    -- The progress page: both checked and committed, not Done; the commit and records a line rests on; the usage standing.
    progress <- page env s ("project-progress/" <> pid)
    traverse_ (has "progress" progress) ["Checked and committed, waiting for your Done", "Make f1 return 1", "Make f2 return 2", "Nothing is published", "Usage is unavailable"]
    branch <- maybe (assertFailure "no branch") (pure . T.unpack) (viewBranch f2)
    acceptedCommit <- headOf folder branch
    has "progress" progress (T.take 12 (T.pack acceptedCommit))
    -- The task page: the checks the work runs under, as they are.
    task <- page env s ("task/" <> T.unpack (taskId t2))
    traverse_ (has "task" task) ["Checks this work runs under", "lockstep-bug-fix, version 1", "held as required"]
    -- Nothing waits for the person's answer; Done stays theirs.
    decisions <- page env s "decisions"
    has "decisions" decisions "No fix is waiting for your answer."
    -- The summary says the same.
    summary <- ready (projectSummary (scRuntime sc) (projectId view)) >>= maybe (assertFailure "no summary") pure
    L.sort (fmap (categoryCode . summaryCategory) (summaryItems summary)) @?= ["verified", "verified"]
    summaryUsageStanding summary @?= UsageUnavailable
