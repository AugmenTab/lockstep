{-# LANGUAGE OverloadedStrings #-}

{- | The live Claude Code adapter through the real engine (contract C-P4.L L1,
L5): real PostgreSQL, Git and the engine; the runner is a stand-in for the
helper's live container that records what it was asked to run and plays the
CLI's part (it writes the role's answer, or something else, to the output).
Nothing here runs the CLI or reaches a provider: the CLI itself, the
container, the proxy and the network are qualified by
@scripts/lib/check-live-runner@ on the host.

Covered: an answer through the adapter (its argument vector, model, effort,
session, instructions); a run the egress boundary stopped (budget, unknown
usage) halts and is never run again by itself; malformed, absent, oversized
and wrong-kind answers are refused; an unknown outcome halts and a restart runs
nothing again; an answer whose recording failed is kept, not asked for again;
the service's wiring (a provider line turns the live engine on and the first
role request is a live one with the CLI's arguments; a line that cannot be used
turns the worker off with its reason).
-}
module Lockstep.LiveAdapterTest
  ( tests
  ) where

import Control.Concurrent (threadDelay)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import System.Directory (createDirectory, listDirectory)
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
import Lockstep.Effects.Process (RunResult (..), newCancel)
import Lockstep.Effects.Provider.Claude (ProviderConfig (..), claudeAdapter)
import Lockstep.Effects.Roles (Runner (..), RunnerFailure (..), Workspace (..), directRunner)
import Lockstep.Foundation.RunnerProtocol (RunProfile (..))
import Lockstep.Foundation.SystemConfig (DatabaseConfig)
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Runner (RunOutcome (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (AdminSettings (..), adminExecute, databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime, writeConfigFile)
import Lockstep.Support.Process (freePort, runLockstep, withService)

tests :: TestTree
tests =
  testGroup
    "C-P4.L the live Claude Code adapter through the engine (a stand-in for the live container; no CLI, no provider)"
    [ testCase "L5-A an answer through the adapter: the CLI's argument vector with the model, effort and session, the role's instructions, the answer checked" answered
    , testCase "L5-B a run the egress boundary stopped (budget, unknown usage) halts the fix, and is not run again by itself" stopped
    , testCase "L5-C malformed, absent, oversized and wrong-kind answers are refused, never taken" refusedAnswers
    , testCase "L5-D an unknown outcome halts the fix, and a restart runs nothing again" unknownOutcome
    , testCase "L5-E an answer whose recording failed is kept: after a restart it is used, the CLI not run again" keptAnswer
    , testCase "L5-F lockstep serve with the helper's provider line runs roles live: the first role request is run-live-readonly with the CLI's arguments" serveLive
    , testCase "L5-G lockstep serve with a provider line it cannot use runs no engine and says why" serveRefused
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
    withSystemTempDirectory "lockstep-p4l" $ \tmp -> do
      config <- databaseConfigFor admin db
      withRuntime config $ \runtime -> do
        migrated <- runMigrations migrations runtime
        assertBool "migrations failed" (either (const False) (const True) migrated)
        createDirectory (tmp <> "/projects")
        createDirectory (tmp <> "/work")
        action (Scenario admin db config runtime tmp)

accepted :: Show e => IO (Either e a) -> IO a
accepted =
  acceptedAs "refused"

acceptedAs :: Show e => String -> IO (Either e a) -> IO a
acceptedAs what action =
  action >>= either (\e -> assertFailure (what <> ": " <> show e)) pure

ready :: Show e => IO (Either e a) -> IO a
ready action =
  action >>= either (\e -> assertFailure ("not ready: " <> show e)) pure

key :: T.Text -> IO IdempotencyKey
key text =
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-live-" <> text))

gitIn :: FilePath -> [String] -> IO ()
gitIn dir args = do
  let
    identity = ["-c", "user.name=Person", "-c", "user.email=person@example.invalid", "-c", "init.defaultBranch=main"]
  finished <- timeout 30000000 (Process.readCreateProcessWithExitCode ((Process.proc "git" (identity <> args)) {Process.cwd = Just dir}) "")
  case finished of
    Just (ExitSuccess, _, _) -> pure ()
    other -> assertFailure ("git " <> show args <> ": " <> show other)

-- | A project with the buggy calc.py, Lockstep allowed and the bug handed over: its work order.
handedOver :: DatabaseRuntime -> FilePath -> T.Text -> IO T.Text
handedOver runtime tmp name = do
  let
    folders = ProjectFolders (Just (tmp <> "/projects")) []
  pk <- key ("project-" <> name)
  view <- acceptedAs "project" (ready (createProject runtime folders (NewProject pk name "" NewFolder)))
  folder <- maybe (assertFailure "no folder") (pure . T.unpack) (projectFolder view)
  writeFile (folder <> "/calc.py") "def add(a, b):\n    return a - b\n"
  gitIn folder ["add", "calc.py"]
  gitIn folder ["commit", "-q", "-m", "calc"]
  ek <- key ("enable-" <> name)
  _ <- acceptedAs "enable" (ready (enableExecution runtime folders ek (projectId view) ExpectNothing))
  tk <- key ("task-" <> name)
  t <- acceptedAs "task" (ready (createTask runtime (NewTask tk (projectId view) "add subtracts" "add(2, 2) is 4" Normal [])))
  readied <- acceptedAs "ready" (ready (decideTask runtime "test-session" (taskId t) (taskTicketRevision t) MarkReady))
  ak <- key ("admit-" <> name)
  admission <- acceptedAs "admit" (ready (admitBug runtime folders ak (taskId readied) (taskTicketRevision readied)))
  pure (admissionWorkOrder admission)

-- | The transaction started and its basis taken: the next step is the Planner's.
atDiscovery :: Scenario -> Engine -> T.Text -> IO TransactionView
atDiscovery sc engine name = do
  workOrder <- handedOver (scRuntime sc) (scTmp sc) name
  view <- ready (startTransaction (scRuntime sc) workOrder) >>= either (\e -> assertFailure ("start refused: " <> show e)) pure
  first <- ready (advance (scRuntime sc) engine (viewId view)) >>= either (\e -> assertFailure ("basis refused: " <> show e)) pure
  inputOf first @?= "basis-ready"
  pure view

count :: Scenario -> String -> IO Int
count sc query = do
  rows <- queryInts (scAdmin sc) (scDb sc) query
  case rows of
    [n] -> pure n
    _ -> assertFailure ("count: " <> query)

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

discovery :: BS.ByteString
discovery =
  "{\"kind\":\"discovery\",\"summary\":\"add subtracts\",\"hypothesis\":\"calc.add uses minus\","
    <> "\"citations\":[{\"path\":\"calc.py\",\"first\":1,\"last\":2}],"
    <> "\"reproduction\":{\"argv\":[\"python3\",\"-c\",\"import calc; assert calc.add(2, 2) == 4, 'add is wrong'\"],\"signature\":\"add is wrong\"},"
    <> "\"allowed_paths\":[\"calc.py\"]}"

provider :: ProviderConfig
provider =
  ProviderConfig "claude-sonnet-5-5" "medium"

-- | What the stand-in for the live container saw: the profile, the argument vector and the role's instructions.
data Seen
  = Seen RunProfile [T.Text] BS.ByteString

ran :: RunOutcome -> RunResult
ran outcome =
  RunResult
    { resultOutcome = outcome
    , resultStdout = "{\"type\":\"result\",\"subtype\":\"success\"}"
    , resultStderr = ""
    , resultStdoutBytes = 39
    , resultStderrBytes = 0
    , resultMillis = 1200
    , resultDescendantsKilled = False
    }

{- | The live engine with a stand-in for the helper's live container: workspaces as the direct runner makes
them; a run records what it was asked and then does what the case says (as the CLI would, in the output).
-}
liveEngine :: Scenario -> IORef [Seen] -> (FilePath -> IO (Either RunnerFailure RunResult)) -> IO Engine
liveEngine sc seen act = do
  cancel <- newCancel
  base <- directRunner cancel (scTmp sc <> "/work")
  let
    runner =
      base
        { runnerName = "container"
        , runnerRun = \workspace profile _ argv _ -> do
            instructions <- BS.readFile (workspaceInput workspace <> "/role.md")
            modifyIORef' seen (Seen profile argv instructions :)
            act (workspaceOutput workspace)
        }
  pure (Engine runner (\role _ -> Just (claudeAdapter provider role)))

answering :: BS.ByteString -> FilePath -> IO (Either RunnerFailure RunResult)
answering answer output = do
  BS.writeFile (output <> "/result.json") answer
  pure (Right (ran (Exited 0)))

-- Cases ------------------------------------------------------------------------------------------------

answered :: Assertion
answered =
  withScenario $ \sc -> do
    seen <- newIORef []
    engine <- liveEngine sc seen (answering discovery)
    view <- atDiscovery sc engine "answered"
    report <- accepted (ready (advance (scRuntime sc) engine (viewId view)))
    inputOf report @?= "discovery-answered"
    runs <- readIORef seen
    case runs of
      [Seen profile argv instructions] -> do
        profile @?= ProfileReadOnly
        L.take 7 argv @?= ["claude", "-p", "--bare", "--model", "claude-sonnet-5-5", "--effort", "medium"]
        case L.dropWhile (/= "--session-id") argv of
          _ : session : _ -> T.length session @?= 36
          _ -> assertFailure ("no session id: " <> show argv)
        assertBool "the Planner is told who it is" ("# Lockstep: you are the planner" `BS.isPrefixOf` instructions)
        assertBool "the Planner is told how to answer a discovery" (not (BS.null (snd (BS.breakSubstring "\"kind\": \"discovery\"" instructions))))
        assertBool "the tree is read-only for the Planner" (not (BS.null (snd (BS.breakSubstring "They are read-only for you." instructions))))
      other -> assertFailure ("expected one run, saw " <> show (L.length other))
    count sc "SELECT count(*)::integer AS v FROM lockstep_invocations WHERE what = 'planner' AND adapter = 'claude-code' AND runner = 'container' AND outcome = 'answered'" >>= (@?= 1)
    count sc "SELECT count(*)::integer AS v FROM lockstep_invocations WHERE what = 'planner' AND argv::text LIKE '%claude-sonnet-5-5%' AND argv::text LIKE '%--session-id%'" >>= (@?= 1)

stopped :: Assertion
stopped =
  withScenario $ \sc ->
    traverse_
      ( \code -> do
          seen <- newIORef []
          engine <- liveEngine sc seen (\_ -> pure (Right (ran (ProviderStopped code))))
          view <- atDiscovery sc engine code
          report <- accepted (ready (advance (scRuntime sc) engine (viewId view)))
          (viewState (viewAfter report), viewHalt (viewAfter report)) @?= ("halted", Just ("role-failed provider-stopped " <> code))
          again <- accepted (ready (advance (scRuntime sc) engine (viewId view)))
          viewState (viewAfter again) @?= "halted"
          L.length <$> readIORef seen >>= (@?= 1)
      )
      ["budget-exhausted", "usage-unknown", "egress-failed"]

refusedAnswers :: Assertion
refusedAnswers =
  withScenario $ \sc ->
    traverse_
      ( \(name, act, halt) -> do
          seen <- newIORef []
          engine <- liveEngine sc seen act
          view <- atDiscovery sc engine name
          report <- accepted (ready (advance (scRuntime sc) engine (viewId view)))
          viewState (viewAfter report) @?= "halted"
          -- The halt names the refusal (a malformed answer's own reason follows its code).
          assertBool (T.unpack name <> ": " <> show (viewHalt (viewAfter report))) (maybe False (halt `T.isPrefixOf`) (viewHalt (viewAfter report)))
          L.length <$> readIORef seen >>= (@?= 1)
      )
      [ ("malformed", answering "The answer is: add should add.", "role-failed malformed-output ")
      , ("absent", \_ -> pure (Right (ran (Exited 0))), "role-failed output-missing")
      , ("oversized", answering (BS8.replicate 300000 ' ' <> discovery), "role-failed output-too-large")
      , ("wrong-kind", answering "{\"kind\":\"review\",\"verdict\":\"approve\",\"reasons\":[\"fine\"]}", "role-failed answer-invalid wrong-kind")
      ]

unknownOutcome :: Assertion
unknownOutcome =
  withScenario $ \sc -> do
    seen <- newIORef []
    engine <- liveEngine sc seen (\_ -> pure (Left (RunnerUncertain "helper-no-result")))
    view <- atDiscovery sc engine "unknown"
    report <- accepted (ready (advance (scRuntime sc) engine (viewId view)))
    (viewState (viewAfter report), viewHalt (viewAfter report)) @?= ("halted", Just "uncertain-invocation helper-no-result")
    -- A restart: another runtime over the same database.
    again <- withRuntime (scConfig sc) $ \runtime -> accepted (ready (advance runtime engine (viewId view)))
    viewState (viewAfter again) @?= "halted"
    L.length <$> readIORef seen >>= (@?= 1)
    count sc "SELECT count(*)::integer AS v FROM lockstep_invocations WHERE what = 'planner'" >>= (@?= 1)

keptAnswer :: Assertion
keptAnswer =
  withScenario $ \sc -> do
    seen <- newIORef []
    engine <- liveEngine sc seen (answering discovery)
    view <- atDiscovery sc engine "kept"
    -- The database refuses to record the step after the CLI has answered.
    adminExecute (scAdmin sc) (T.unpack (scDb sc)) "CREATE OR REPLACE FUNCTION lockstep_test_refuse() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'test: this write is refused'; END $$"
    adminExecute (scAdmin sc) (T.unpack (scDb sc)) "CREATE TRIGGER lockstep_test_refuse BEFORE UPDATE ON lockstep_transactions FOR EACH ROW EXECUTE FUNCTION lockstep_test_refuse()"
    lost <- ready (advance (scRuntime sc) engine (viewId view))
    either id inputOf lost @?= "database-unavailable"
    adminExecute (scAdmin sc) (T.unpack (scDb sc)) "DROP TRIGGER lockstep_test_refuse ON lockstep_transactions"
    report <- withRuntime (scConfig sc) $ \runtime -> accepted (ready (advance runtime engine (viewId view)))
    inputOf report @?= "discovery-answered"
    L.length <$> readIORef seen >>= (@?= 1)
    count sc "SELECT count(*)::integer AS v FROM lockstep_invocations WHERE what = 'planner'" >>= (@?= 1)

-- The service ---------------------------------------------------------------------------------------

-- | A runner channel with no helper behind it: the key, the directories, and the given provider line.
channelWith :: FilePath -> BS.ByteString -> IO FilePath
channelWith tmp line = do
  let
    dir = tmp <> "/runner"
  traverse_ createDirectory [dir, dir <> "/work", dir <> "/requests", dir <> "/results"]
  writeFile (dir <> "/channel.key") (L.replicate 64 'd')
  BS.writeFile (dir <> "/provider") line
  pure dir

-- | A migrated database and the service over it with this runner channel; the service's log.
withServed :: FilePath -> FilePath -> (DatabaseRuntime -> IO a) -> IO String
withServed tmp runnerDir action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db -> do
    path <- writeConfigFile tmp admin db (adminPassword admin)
    createDirectory (tmp <> "/projects")
    let
      env = [("LOCKSTEP_CONFIG", path), ("LOCKSTEP_PROJECT_FOLDERS", tmp <> "/projects"), ("LOCKSTEP_RUNNER_DIR", runnerDir)]
    (code, _, err) <- runLockstep env ["db", "migrate"]
    assertBool ("db migrate failed: " <> err) (code == ExitSuccess)
    dbConfig <- databaseConfigFor admin db
    port <- freePort
    _ <- withService env port (tmp <> "/serve.log") (withRuntime dbConfig action)
    readFile' (tmp <> "/serve.log")
 where
  readFile' p = T.unpack . TE.decodeUtf8 <$> BS.readFile p

waitFor :: Int -> IO Bool -> IO Bool
waitFor ticks check = do
  ok <- check
  if ok || ticks <= 0 then pure ok else threadDelay 100000 >> waitFor (ticks - 1) check

serveLive :: Assertion
serveLive =
  withSystemTempDirectory "lockstep-p4l-serve" $ \tmp -> do
    runnerDir <- channelWith tmp "lockstep-provider 1 claude-code claude-sonnet-5-5 medium\n"
    serveLog <-
      withServed tmp runnerDir $ \runtime -> do
        _ <- handedOver runtime tmp "served"
        asked <- waitFor 300 (not . L.null . L.filter (".rreq" `L.isSuffixOf`) <$> listDirectory (runnerDir <> "/requests"))
        logged <- BS.readFile (tmp <> "/serve.log")
        assertBool ("the service never asked the helper to run a role: " <> show logged) asked
        requests <- L.filter (".rreq" `L.isSuffixOf`) <$> listDirectory (runnerDir <> "/requests")
        request <- case requests of
          [r] -> BS.readFile (runnerDir <> "/requests/" <> r)
          other -> assertFailure ("expected one request, found " <> show other)
        assertBool ("the role runs live: " <> show request) ("\nop run-live-readonly\n" `BS.isInfixOf` request)
        let
          run = BS8.unpack (BS.take 32 (BS.drop 11 (snd (BS.breakSubstring "expect run-" request))))
        argv <- BS.readFile (runnerDir <> "/work/" <> run <> "/argv")
        L.take 7 (BS.split 0 argv) @?= ["claude", "-p", "--bare", "--model", "claude-sonnet-5-5", "--effort", "medium"]
        instructions <- BS.readFile (runnerDir <> "/work/" <> run <> "/input/role.md")
        assertBool "the role's instructions are in its input" ("# Lockstep: you are the planner" `BS.isPrefixOf` instructions)
    assertBool ("the log names the live provider: " <> serveLog) ("Engine worker: on (live provider claude-code, model claude-sonnet-5-5, effort medium)" `L.isInfixOf` serveLog)

serveRefused :: Assertion
serveRefused =
  withSystemTempDirectory "lockstep-p4l-serve-off" $ \tmp -> do
    runnerDir <- channelWith tmp "lockstep-provider 1 claude-code claude-3-opus medium\n"
    serveLog <-
      withServed tmp runnerDir $ \runtime -> do
        _ <- handedOver runtime tmp "unserved"
        threadDelay 6000000
        requests <- listDirectory (runnerDir <> "/requests")
        requests @?= []
    assertBool ("the log says why the engine is off: " <> serveLog) ("Engine worker: off (provider-model-unsupported)" `L.isInfixOf` serveLog)
