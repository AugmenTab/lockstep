{-# LANGUAGE OverloadedStrings #-}

{- | The third remediation (contract C-P4.R3), from the final review of
C-P4.R2 (R2F-M1): a stage belongs to the engine that is running it. A second
engine on the same database that comes to the transaction meanwhile is told
it is busy, and never settles the first engine's run as unfinished; once the
owner has gone, the run it left is settled as before (uncertain, never run
again by itself). Real PostgreSQL, Git and processes.
-}
module Lockstep.EngineOwnershipTest
  ( tests
  ) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Data.ByteString qualified as BS
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import System.Directory (createDirectory)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath, writeFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Database (DatabaseRuntime, runMigrations)
import Lockstep.Application.Engine (Engine (..), StepReport (..), TransactionView (..), advance, startTransaction)
import Lockstep.Application.Execution (Admission (..), admitBug, enableExecution)
import Lockstep.Application.ProjectChecks (ExpectedChecks (..))
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks (NewTask (..), TaskDecision (..), TaskView (..), createTask, decideTask)
import Lockstep.Effects.Process (newCancel)
import Lockstep.Effects.Roles (Adapter, Runner, directRunner, scriptedAdapter)
import Lockstep.Foundation.SystemConfig (DatabaseConfig)
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Roles (Role (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (AdminSettings, databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime)

tests :: TestTree
tests =
  testGroup
    "C-P4.R3 a stage belongs to the engine running it"
    [ testCase "R3-O a second engine that comes to a transaction while another runs its role is told busy, and the role's answer stands" ownedStage
    , testCase "R3-R once the engine running a role has gone, another settles the run it left as uncertain and runs nothing again" ownerGone
    ]

-- Fixtures ---------------------------------------------------------------------------------------

data Scenario
  = Scenario
  { scAdmin :: AdminSettings
  , scDb :: T.Text
  , scConfig :: DatabaseConfig
  , scRuntime :: DatabaseRuntime
  , scTmp :: FilePath
  }

withScenario :: (Scenario -> IO a) -> IO a
withScenario action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-p4r3" $ \tmp -> do
      config <- databaseConfigFor admin db
      withRuntime config $ \runtime -> do
        migrated <- runMigrations migrations runtime
        assertBool "migrations failed" (either (const False) (const True) migrated)
        createDirectory (tmp <> "/projects")
        createDirectory (tmp <> "/work")
        action (Scenario admin db config runtime tmp)

accepted :: Show e => IO (Either e a) -> IO a
accepted action =
  action >>= either (\e -> assertFailure ("refused: " <> show e)) pure

ready :: Show e => IO (Either e a) -> IO a
ready action =
  action >>= either (\e -> assertFailure ("not ready: " <> show e)) pure

key :: T.Text -> IO IdempotencyKey
key text =
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-ownership-" <> text))

gitIn :: FilePath -> [String] -> IO ()
gitIn dir args = do
  let
    identity = ["-c", "user.name=Person", "-c", "user.email=person@example.invalid", "-c", "init.defaultBranch=main"]
  finished <- timeout 30000000 (Process.readCreateProcessWithExitCode ((Process.proc "git" (identity <> args)) {Process.cwd = Just dir}) "")
  case finished of
    Just (ExitSuccess, _, _) -> pure ()
    other -> assertFailure ("git " <> show args <> ": " <> show other)

-- | A project with the buggy calc.py, Lockstep allowed, the bug handed over and its transaction started.
startedBug :: Scenario -> T.Text -> IO TransactionView
startedBug sc name = do
  let
    folders = ProjectFolders (Just (scTmp sc <> "/projects")) []
  pk <- key ("project-" <> name)
  view <- accepted (ready (createProject (scRuntime sc) folders (NewProject pk name "" NewFolder)))
  folder <- maybe (assertFailure "no folder") (pure . T.unpack) (projectFolder view)
  writeFile (folder <> "/calc.py") "def add(a, b):\n    return a - b\n"
  gitIn folder ["add", "calc.py"]
  gitIn folder ["commit", "-q", "-m", "calc"]
  ek <- key ("enable-" <> name)
  _ <- accepted (ready (enableExecution (scRuntime sc) folders ek (projectId view) ExpectNothing))
  tk <- key ("task-" <> name)
  t <- accepted (ready (createTask (scRuntime sc) (NewTask tk (projectId view) "add subtracts" "add(2, 2) is 4" Normal [])))
  readied <- accepted (ready (decideTask (scRuntime sc) "test-session" (taskId t) (taskTicketRevision t) MarkReady))
  ak <- key ("admit-" <> name)
  admission <- accepted (ready (admitBug (scRuntime sc) folders ak (taskId readied) (taskTicketRevision readied)))
  accepted (ready (startTransaction (scRuntime sc) (admissionWorkOrder admission)))

count :: Scenario -> String -> IO Int
count sc query = do
  rows <- queryInts (scAdmin sc) (scDb sc) query
  case rows of
    [n] -> pure n
    _ -> assertFailure ("count: " <> query)

waitFor :: Int -> IO Bool -> IO Bool
waitFor ticks check = do
  ok <- check
  if ok || ticks <= 0 then pure ok else threadDelay 100000 >> waitFor (ticks - 1) check

inputOf :: StepReport -> T.Text
inputOf report =
  case report of
    Stepped i _ -> i
    Idle why _ -> "idle " <> why

viewAfter :: StepReport -> TransactionView
viewAfter report =
  case report of
    Stepped _ v -> v
    Idle _ v -> v

discovery :: T.Text
discovery =
  "{\"result\":{\"kind\":\"discovery\",\"summary\":\"add subtracts\",\"hypothesis\":\"calc.add uses minus\","
    <> "\"citations\":[{\"path\":\"calc.py\",\"first\":1,\"last\":2}],"
    <> "\"reproduction\":{\"argv\":[\"python3\",\"-c\",\"import calc; assert calc.add(2, 2) == 4, 'add is wrong'\"],\"signature\":\"add is wrong\"},"
    <> "\"allowed_paths\":[\"calc.py\"]}}"

script :: T.Text -> BS.ByteString
script steps =
  TE.encodeUtf8 ("{\"steps\":[" <> steps <> "]}")

-- | The Planner answers with these steps; no other role answers.
plannerWith :: Runner -> T.Text -> Engine
plannerWith runner steps =
  let
    adapter :: Role -> Int -> Maybe Adapter
    adapter role _ =
      case role of
        Planner -> Just (scriptedAdapter "scripts/runner/scripted-role" (script steps))
        _ -> Nothing
  in
    Engine runner adapter

unfinishedPlanner :: Scenario -> IO Bool
unfinishedPlanner sc =
  (== 1) <$> count sc "SELECT count(*)::integer AS v FROM lockstep_invocations WHERE what = 'planner' AND finished_at IS NULL"

-- Cases ------------------------------------------------------------------------------------------------

ownedStage :: Assertion
ownedStage =
  withScenario $ \sc -> do
    view <- startedBug sc "owned"
    cancel <- newCancel
    runner <- directRunner cancel (scTmp sc <> "/work")
    first <- accepted (ready (advance (scRuntime sc) (plannerWith runner discovery) (viewId view)))
    inputOf first @?= "basis-ready"
    doneA <- newEmptyMVar
    -- Engine A, on its own connections: a Planner that takes 12 s to answer.
    _ <- forkIO (withRuntime (scConfig sc) (\rt -> advance rt (plannerWith runner ("{\"sleep\":12}," <> discovery)) (viewId view)) >>= putMVar doneA . fmap (fmap inputOf))
    started <- waitFor 100 (unfinishedPlanner sc)
    assertBool "engine A's Planner never started" started
    -- Engine B, on its own connections, comes to the same transaction while A's Planner runs.
    b <- withRuntime (scConfig sc) (\rt -> advance rt (plannerWith runner discovery) (viewId view))
    fmap (fmap inputOf) b @?= Right (Left "busy")
    count sc "SELECT count(*)::integer AS v FROM lockstep_invocations WHERE outcome = 'uncertain'" >>= (@?= 0)
    a <- takeMVar doneA
    a @?= Right (Right "discovery-answered")
    count sc "SELECT count(*)::integer AS v FROM lockstep_invocations WHERE what = 'planner'" >>= (@?= 1)
    count sc "SELECT count(*)::integer AS v FROM lockstep_invocations WHERE what = 'planner' AND outcome = 'answered'" >>= (@?= 1)
    after <- accepted (ready (advance (scRuntime sc) (plannerWith runner discovery) (viewId view)))
    viewHalt (viewAfter after) @?= Nothing

ownerGone :: Assertion
ownerGone =
  withScenario $ \sc -> do
    view <- startedBug sc "gone"
    cancel <- newCancel
    runner <- directRunner cancel (scTmp sc <> "/work")
    _ <- accepted (ready (advance (scRuntime sc) (plannerWith runner discovery) (viewId view)))
    -- Engine A's thread is stopped while its Planner runs: it leaves the run unfinished.
    thread <- forkIO (void (withRuntime (scConfig sc) (\rt -> advance rt (plannerWith runner ("{\"sleep\":30}," <> discovery)) (viewId view))))
    started <- waitFor 100 (unfinishedPlanner sc)
    assertBool "engine A's Planner never started" started
    killThread thread
    threadDelay 1500000
    b <- accepted (ready (advance (scRuntime sc) (plannerWith runner discovery) (viewId view)))
    (viewState (viewAfter b), viewHalt (viewAfter b)) @?= ("halted", Just "uncertain-invocation unfinished-invocation")
    count sc "SELECT count(*)::integer AS v FROM lockstep_invocations WHERE what = 'planner'" >>= (@?= 1)
    count sc "SELECT count(*)::integer AS v FROM lockstep_invocations WHERE what = 'planner' AND outcome = 'uncertain'" >>= (@?= 1)
