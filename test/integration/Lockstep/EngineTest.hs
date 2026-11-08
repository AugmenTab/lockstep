{-# LANGUAGE OverloadedStrings #-}

{- | The coding transaction's first stages against real PostgreSQL, real Git
and real processes (contract C-P4.6 E1–E7): a project in a new folder
(C-P3.5), allowed and handed a ready task as a bug (C-P4.1), a small Python
repository with a real bug, the scripted Planner (C-P4.5) on the direct
runner (C-P4.2). A restart is a new runtime over the same database.
-}
module Lockstep.EngineTest
  ( tests
  ) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Exception (SomeException, try)
import Data.ByteString qualified as BS
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import System.Directory (createDirectory, doesFileExist)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath, writeFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Conversation (StoredRequest (..), openRequests)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason, runMigrations)
import Lockstep.Application.Engine
  ( Engine (..)
  , InvocationView (..)
  , RecordView (..)
  , StepReport (..)
  , TransactionView (..)
  , advance
  , startTransaction
  , transactionForWorkOrder
  )
import Lockstep.Application.Execution (Admission (..), admitBug, enableExecution)
import Lockstep.Application.ProjectChecks (ExpectedChecks (..))
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks (NewTask (..), TaskDecision (..), TaskView (..), createTask, decideTask)
import Lockstep.Effects.Process (newCancel)
import Lockstep.Effects.Roles (Adapter, directRunner, scriptedAdapter)
import Lockstep.Foundation.SystemConfig (DatabaseConfig)
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Roles (Role (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (AdminSettings, adminExecute, databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime)

tests :: TestTree
tests =
  testGroup
    "C-P4.6 the coding transaction: start, basis, discovery, reproduction (real Git, processes, PostgreSQL)"
    [ testCase "an admitted bug starts one transaction at the basis; not admitted and a busy Engineer are refused" starting
    , testCase "the basis is the clean HEAD and the work branch is made at it; the person's checkout is untouched" basis
    , testCase "a dirty repository halts at the basis with one decision request to a person" dirty
    , testCase "discovery: the Planner's answer is recorded as data, with its invocation" discovery
    , testCase "a citation outside the source halts at discovery" badCitation
    , testCase "reproduction: the bug's own command fails with its signature at the basis" reproduced
    , testCase "a command that passes, or none at all, is reproduction-missing; only then is accepting it offered" notReproduced
    , testCase "a role that crashes, or no coding agent at all, halts with its reason" roleFailures
    , testCase "an invocation cut short is never run again: after a restart it is uncertain and halts" cutShort
    , testCase "records and invocations cannot be changed afterwards" immutable
    ]

-- Fixtures ---------------------------------------------------------------------------

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
    withSystemTempDirectory "lockstep-p46" $ \tmp -> do
      config <- databaseConfigFor admin db
      withRuntime config $ \runtime -> do
        migrated <- runMigrations migrations runtime
        assertBool "migrations failed" (either (const False) (const True) migrated)
        createDirectory (tmp <> "/projects")
        createDirectory (tmp <> "/work")
        action (Scenario admin db config runtime tmp)

folders :: Scenario -> ProjectFolders
folders sc =
  ProjectFolders (Just (scTmp sc <> "/projects")) []

ready :: Show e => IO (Either e a) -> IO a
ready action =
  action >>= either (\e -> assertFailure ("not ready: " <> show e)) pure

accepted :: Show e => IO (Either e a) -> IO a
accepted action =
  action >>= either (\e -> assertFailure ("refused: " <> show e)) pure

key :: T.Text -> IO IdempotencyKey
key text =
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-engine-key-" <> text))

gitIn :: FilePath -> [String] -> IO String
gitIn dir args = do
  base <- getEnvironment
  let
    identity = ["-c", "user.name=Person", "-c", "user.email=person@example.invalid", "-c", "init.defaultBranch=main"]
    env = ("GIT_CONFIG_NOSYSTEM", "1") : L.filter ((/= "GIT_CONFIG_NOSYSTEM") . fst) base
  result <-
    timeout 30000000 $
      Process.readCreateProcessWithExitCode ((Process.proc "git" (identity <> args)) {Process.cwd = Just dir, Process.env = Just env}) ""
  case result of
    Nothing -> assertFailure ("git " <> show args <> " did not finish within 30 s")
    Just (code, out, err) -> do
      assertBool ("git " <> show args <> " failed: " <> out <> err) (code == ExitSuccess)
      pure out

buggyCalc :: String
buggyCalc =
  "def add(a, b):\n    return a - b\n\n\ndef double(a):\n    return add(a, a)\n"

-- | A project in a new folder, allowed, with the buggy file committed, and one bug handed over.
data Bug
  = Bug
  { bugFolder :: FilePath
  , bugWorkOrder :: T.Text
  }

admittedBug :: Scenario -> T.Text -> IO Bug
admittedBug sc name = do
  pk <- key ("project-" <> name)
  view <- accepted (ready (createProject (scRuntime sc) (folders sc) (NewProject pk name "" NewFolder)))
  folder <- maybe (assertFailure "no folder") (pure . T.unpack) (projectFolder view)
  writeFile (folder <> "/calc.py") buggyCalc
  _ <- gitIn folder ["add", "calc.py"]
  _ <- gitIn folder ["commit", "-q", "-m", "calc"]
  ek <- key ("enable-" <> name)
  _ <- accepted (ready (enableExecution (scRuntime sc) (folders sc) ek (projectId view) ExpectNothing))
  tk <- key ("task-" <> name)
  t <- accepted (ready (createTask (scRuntime sc) (NewTask tk (projectId view) "add subtracts" "add(2, 2) is 4" Normal [])))
  readied <- accepted (ready (decideTask (scRuntime sc) "test-session" (taskId t) (taskTicketRevision t) MarkReady))
  ak <- key ("admit-" <> name)
  admission <- accepted (ready (admitBug (scRuntime sc) (folders sc) ak (taskId readied) (taskTicketRevision readied)))
  pure (Bug folder (admissionWorkOrder admission))

-- Scripts for the scripted Planner ---------------------------------------------------------

discoveryAnswer :: T.Text -> T.Text -> T.Text
discoveryAnswer citations reproduction =
  "{\"result\":{\"kind\":\"discovery\",\"summary\":\"add subtracts instead of adding\",\"hypothesis\":\"calc.add uses minus\","
    <> "\"citations\":["
    <> citations
    <> "],"
    <> reproduction
    <> "\"allowed_paths\":[\"calc.py\"]}}"

goodCitation :: T.Text
goodCitation =
  "{\"path\":\"calc.py\",\"first\":1,\"last\":2}"

failingCheck :: T.Text
failingCheck =
  "\"reproduction\":{\"argv\":[\"python3\",\"-c\",\"import calc; assert calc.add(2, 2) == 4, 'add is wrong'\"],\"signature\":\"add is wrong\"},"

script :: [T.Text] -> BS.ByteString
script steps =
  TE.encodeUtf8 ("{\"steps\":[" <> T.intercalate "," steps <> "]}")

-- | An engine whose Planner answers each invocation with the next script.
engineWith :: Scenario -> [[T.Text]] -> IO Engine
engineWith sc planner = do
  cancel <- newCancel
  runner <- directRunner cancel (scTmp sc <> "/work")
  let
    adapter :: Role -> Int -> Maybe Adapter
    adapter role n =
      case role of
        Planner -> scriptedAdapter "scripts/runner/scripted-role" . script <$> L.lookup n (L.zip [0 ..] planner)
        _ -> Nothing
  pure (Engine runner adapter)

start :: Scenario -> Bug -> IO TransactionView
start sc bug =
  accepted (ready (startTransaction (scRuntime sc) (bugWorkOrder bug)))

step :: Scenario -> Engine -> TransactionView -> IO StepReport
step sc engine view =
  accepted (ready (advance (scRuntime sc) engine (viewId view)))

viewAfter :: StepReport -> TransactionView
viewAfter report =
  case report of
    Stepped _ v -> v
    Idle _ v -> v

inputOf :: StepReport -> T.Text
inputOf report =
  case report of
    Stepped i _ -> i
    Idle why _ -> "idle " <> why

kinds :: TransactionView -> [T.Text]
kinds =
  fmap recordKind . viewRecords

requestsFor :: Scenario -> Bug -> IO [StoredRequest]
requestsFor sc bug =
  L.filter ((== bugWorkOrder bug) . storedWorkOrder) <$> ready (openRequests (scRuntime sc))

-- Cases ----------------------------------------------------------------------------------

starting :: Assertion
starting =
  withScenario $ \sc -> do
    bug <- admittedBug sc "starting"
    view <- start sc bug
    (viewState view, viewStage view, viewWorkOrder view) @?= ("running", "basis", bugWorkOrder bug)
    kinds view @?= ["started"]
    again <- start sc bug
    viewId again @?= viewId view
    unknown <- ready (startTransaction (scRuntime sc) "not-a-uuid")
    unknown @?= Left "unknown-work-order"
    stranger <- ready (startTransaction (scRuntime sc) "00000000-0000-4000-8000-000000000001")
    stranger @?= Left "not-admitted"
    count <- queryInts (scAdmin sc) (scDb sc) "SELECT count(*)::int AS v FROM lockstep_transactions"
    count @?= [1]

basis :: Assertion
basis =
  withScenario $ \sc -> do
    bug <- admittedBug sc "basis"
    engine <- engineWith sc []
    view <- start sc bug
    report <- step sc engine view
    inputOf report @?= "basis-ready"
    head' <- T.strip . T.pack <$> gitIn (bugFolder bug) ["rev-parse", "HEAD"]
    viewBasis (viewAfter report) @?= Just head'
    viewBranch (viewAfter report) @?= Just ("lockstep/" <> bugWorkOrder bug)
    branch <- T.strip . T.pack <$> gitIn (bugFolder bug) ["rev-parse", "refs/heads/lockstep/" <> T.unpack (bugWorkOrder bug)]
    branch @?= head'
    viewStage (viewAfter report) @?= "discovery"
    current <- gitIn (bugFolder bug) ["symbolic-ref", "HEAD"]
    current @?= "refs/heads/main\n"
    status <- gitIn (bugFolder bug) ["status", "--porcelain"]
    status @?= ""
    L.take 3 (kinds (viewAfter report)) @?= ["started", "basis", "input"]

dirty :: Assertion
dirty =
  withScenario $ \sc -> do
    bug <- admittedBug sc "dirty"
    writeFile (bugFolder bug <> "/notes.txt") "uncommitted\n"
    engine <- engineWith sc []
    view <- start sc bug
    report <- step sc engine view
    inputOf report @?= "basis-refused"
    (viewState (viewAfter report), viewHalt (viewAfter report)) @?= ("halted", Just "repository-dirty")
    requests <- requestsFor sc bug
    fmap storedChoices requests @?= [["retry", "stop"]]
    idle <- step sc engine view
    inputOf idle @?= "idle halted"
    stillOne <- requestsFor sc bug
    L.length stillOne @?= 1

reachDiscovery :: Scenario -> Bug -> Engine -> IO TransactionView
reachDiscovery sc bug engine = do
  view <- start sc bug
  r <- step sc engine view
  inputOf r @?= "basis-ready"
  pure (viewAfter r)

discovery :: Assertion
discovery =
  withScenario $ \sc -> do
    bug <- admittedBug sc "discovery"
    engine <- engineWith sc [[discoveryAnswer goodCitation failingCheck]]
    view <- reachDiscovery sc bug engine
    report <- step sc engine view
    inputOf report @?= "discovery-answered"
    viewStage (viewAfter report) @?= "reproduction"
    let
      recorded = [recordBody r | r <- viewRecords (viewAfter report), recordKind r == "discovery"]
    L.length recorded @?= 1
    assertBool "the summary is kept as text" (L.all ("add subtracts instead of adding" `T.isInfixOf`) recorded)
    case viewInvocations (viewAfter report) of
      [i] -> do
        (invocationWhat i, invocationStage i, invocationRunner i, invocationAdapter i, invocationOutcome i, invocationExit i)
          @?= ("planner", "discovery", "direct", "scripted", Just "answered", Just 0)
        assertBool "the argv is recorded" ("scripted-role" `T.isInfixOf` invocationArgv i)
      other -> assertFailure ("invocations: " <> show other)

badCitation :: Assertion
badCitation =
  withScenario $ \sc -> do
    bug <- admittedBug sc "citation"
    engine <- engineWith sc [[discoveryAnswer "{\"path\":\"calc.py\",\"first\":50,\"last\":60}" failingCheck]]
    view <- reachDiscovery sc bug engine
    report <- step sc engine view
    (viewState (viewAfter report), viewHalt (viewAfter report)) @?= ("halted", Just "role-failed citation-outside-source")
    engine2 <- engineWith sc [[discoveryAnswer "{\"path\":\"missing.py\",\"first\":1,\"last\":1}" failingCheck]]
    bug2 <- admittedBugElsewhere sc
    view2 <- reachDiscovery sc bug2 engine2
    report2 <- step sc engine2 view2
    viewHalt (viewAfter report2) @?= Just "role-failed citation-outside-source"
 where
  admittedBugElsewhere sc = admittedBug sc "citation-two"

reproduced :: Assertion
reproduced =
  withScenario $ \sc -> do
    bug <- admittedBug sc "reproduced"
    engine <- engineWith sc [[discoveryAnswer goodCitation failingCheck]]
    view <- reachDiscovery sc bug engine
    _ <- step sc engine view
    report <- step sc engine view
    inputOf report @?= "reproduced"
    (viewState (viewAfter report), viewStage (viewAfter report)) @?= ("running", "candidate")
    let
      body = [recordBody r | r <- viewRecords (viewAfter report), recordKind r == "reproduction"]
    assertBool ("reproduced, exit 1: " <> show body) (L.any (\b -> "\"reproduced\":true" `T.isInfixOf` b && "\"exit\":1" `T.isInfixOf` b && "add is wrong" `T.isInfixOf` b) body)
    case [i | i <- viewInvocations (viewAfter report), invocationWhat i == "reproduction"] of
      [i] -> (invocationAdapter i, invocationOutcome i, invocationExit i) @?= ("supervisor", Just "exited", Just 1)
      other -> assertFailure ("reproduction invocations: " <> show other)

notReproduced :: Assertion
notReproduced =
  withScenario $ \sc -> do
    bug <- admittedBug sc "passes"
    engine <- engineWith sc [[discoveryAnswer goodCitation "\"reproduction\":{\"argv\":[\"python3\",\"-c\",\"print(1)\"],\"signature\":\"add is wrong\"},"]]
    view <- reachDiscovery sc bug engine
    _ <- step sc engine view
    report <- step sc engine view
    inputOf report @?= "not-reproduced"
    (viewState (viewAfter report), viewStage (viewAfter report), viewHalt (viewAfter report)) @?= ("halted", "reproduction", Just "reproduction-missing")
    requests <- requestsFor sc bug
    fmap storedChoices requests @?= [["accept-non-reproduction", "retry", "stop"]]
    bug2 <- admittedBug sc "no-command"
    engine2 <- engineWith sc [[discoveryAnswer goodCitation ""]]
    view2 <- reachDiscovery sc bug2 engine2
    _ <- step sc engine2 view2
    report2 <- step sc engine2 view2
    viewHalt (viewAfter report2) @?= Just "reproduction-missing"

roleFailures :: Assertion
roleFailures =
  withScenario $ \sc -> do
    bug <- admittedBug sc "crash"
    engine <- engineWith sc [["{\"exit\":3}"]]
    view <- reachDiscovery sc bug engine
    report <- step sc engine view
    (viewState (viewAfter report), viewHalt (viewAfter report)) @?= ("halted", Just "role-failed role-crashed")
    case viewInvocations (viewAfter report) of
      [i] -> (invocationOutcome i, invocationExit i) @?= (Just "role-crashed", Just 3)
      other -> assertFailure ("invocations: " <> show other)
    bug2 <- admittedBug sc "no-agent"
    nobody <- engineWith sc []
    view2 <- reachDiscovery sc bug2 nobody
    report2 <- step sc nobody view2
    viewHalt (viewAfter report2) @?= Just "role-failed no-coding-agent"
    viewInvocations (viewAfter report2) @?= []

cutShort :: Assertion
cutShort =
  withScenario $ \sc -> do
    bug <- admittedBug sc "cut-short"
    let
      marker = scTmp sc <> "/ran"
    engine <- engineWith sc [["{\"append\":{\"path\":\"" <> T.pack marker <> "\",\"content\":\"ran\\n\"}}", "{\"sleep\":30}"]]
    view <- reachDiscovery sc bug engine
    -- The service dies while the Planner runs: the thread doing the step is killed.
    thread <- forkIO (void (try (advance (scRuntime sc) engine (viewId view)) :: IO (Either SomeException (Either NotReadyReason (Either T.Text StepReport)))))
    waitUntil 100 (doesFileExist marker)
    killThread thread
    threadDelay 500000
    started <- queryInts (scAdmin sc) (scDb sc) "SELECT count(*)::int AS v FROM lockstep_invocations WHERE finished_at IS NULL"
    started @?= [1]
    -- a restart: a new runtime over the same database
    withRuntime (scConfig sc) $ \runtime2 -> do
      report <- accepted (ready (advance runtime2 engine (viewId view)))
      (viewState (viewAfter report), viewHalt (viewAfter report)) @?= ("halted", Just "uncertain-invocation unfinished-invocation")
      fmap invocationOutcome (viewInvocations (viewAfter report)) @?= [Just "uncertain"]
      again <- accepted (ready (advance runtime2 engine (viewId view)))
      inputOf again @?= "idle halted"
    ran <- BS.readFile marker
    ran @?= "ran\n"
    requests <- requestsFor sc bug
    fmap storedChoices requests @?= [["retry", "stop"]]
 where
  waitUntil :: Int -> IO Bool -> IO ()
  waitUntil n check = do
    ok <- check
    if ok || n <= 0 then pure () else threadDelay 100000 >> waitUntil (n - 1) check

immutable :: Assertion
immutable =
  withScenario $ \sc -> do
    bug <- admittedBug sc "immutable"
    engine <- engineWith sc [[discoveryAnswer goodCitation failingCheck]]
    view <- reachDiscovery sc bug engine
    _ <- step sc engine view
    changed <- try (adminExecute (scAdmin sc) (T.unpack (scDb sc)) "UPDATE lockstep_transaction_records SET body = 'x'") :: IO (Either SomeException ())
    assertBool "records cannot be updated" (either (const True) (const False) changed)
    removed <- try (adminExecute (scAdmin sc) (T.unpack (scDb sc)) "DELETE FROM lockstep_transaction_records") :: IO (Either SomeException ())
    assertBool "records cannot be deleted" (either (const True) (const False) removed)
    refinished <- try (adminExecute (scAdmin sc) (T.unpack (scDb sc)) "UPDATE lockstep_invocations SET outcome = 'answered', finished_at = now()") :: IO (Either SomeException ())
    assertBool "a finished invocation cannot be finished again" (either (const True) (const False) refinished)
    gone <- try (adminExecute (scAdmin sc) (T.unpack (scDb sc)) "DELETE FROM lockstep_invocations") :: IO (Either SomeException ())
    assertBool "invocations cannot be deleted" (either (const True) (const False) gone)
    after <- ready (transactionForWorkOrder (scRuntime sc) (bugWorkOrder bug))
    fmap (fmap recordKind . viewRecords) after @?= Just ["started", "basis", "input", "discovery", "input"]
