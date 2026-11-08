{-# LANGUAGE OverloadedStrings #-}

{- | Recovery of the coding transaction (contract C-P4.R1): no role is run
again by itself after a restart, wherever its stage was cut short; a
cut-short role is marked uncertain and halted in one step or not at all; a
stopped thread is never taken for a database failure; the freeze settles
once; the database enforces one writer per Engineer; the worker always stops,
within a bound, without leaving a role running; finished stages leave no
workspace behind. Real PostgreSQL (a database failure is injected with a
test-only trigger that refuses every change to the transaction rows), real
Git and processes, the scripted roles on the direct runner. A restart is a new
runtime over the same database.
-}
module Lockstep.EngineRecoveryTest
  ( tests
  ) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, tryTakeMVar)
import Control.Exception (SomeException, throwIO, try)
import Data.ByteString qualified as BS
import Data.List qualified as L
import Data.Maybe (isJust)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Flipstone.Prelude
import System.Directory (createDirectory, doesDirectoryExist, doesFileExist, getFileSize, listDirectory)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath, writeFile)
import System.IO.Error (userError)
import System.IO.Temp (withSystemTempDirectory)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Conversation (Channel (..), Sender (..), StoredRequest (..), openRequests, postMessage)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason, runMigrations, withDatabase)
import Lockstep.Application.Engine (Engine (..), RecordView (..), StepReport (..), TransactionView (..), advance, startTransaction)
import Lockstep.Application.EngineWorker (startEngineWorker, stopEngineWorker, stopEngineWorkerWithin)
import Lockstep.Application.Execution (Admission (..), admitBug, enableExecution)
import Lockstep.Application.ProjectChecks (ExpectedChecks (..))
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks (NewTask (..), TaskDecision (..), TaskView (..), createTask, decideTask)
import Lockstep.Effects.Process (newCancel)
import Lockstep.Effects.Roles (Adapter, Runner (..), View (..), Workspace (..), directRunner, scriptedAdapter)
import Lockstep.Foundation.SystemConfig (DatabaseConfig)
import Lockstep.Kernel.Conversation (RequestInput (..))
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Roles (Role (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (AdminSettings, adminExecute, databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime)

tests :: TestTree
tests =
  testGroup
    "C-P4.R1 recovery: no role is run again by itself; uncertain and halted together; the freeze once; one writer; the worker stops"
    [ testCase "R-I2 discovery: the Planner answered but the step could not be recorded; after a restart its answer is used, it is not run again" discoveryKept
    , testCase "R-I2 candidate: cut short during the baseline; after a restart the baseline runs again, the Planner does not" baselineCut
    , testCase "R-I2 challenge before the freeze: cut short during a mutant run; the challenger is not run again" mutantCut
    , testCase "R-I2 challenge after the change: cut short during a counterexample; the challenger is not run again" counterexampleCut
    , testCase "R-I2 review: the Reviewer's verdict could not be recorded; after a restart it is used, once" reviewKept
    , testCase "R-I3 implement: the Implementer's step could not be recorded; it halts for a person and only their retry runs it again" implementHalts
    , testCase "R-U1 a cut-short role whose halt cannot be recorded stays unfinished and runs nowhere; it halts once the database is back" uncertainAtomic
    , testCase "R-U2 a stopped thread is never reported as a database failure and goes no further" asyncPasses
    , testCase "R-F1 the freeze moved the branch but could not be recorded: recorded after a restart with the same commit, once; another commit still halts" freezeOnce
    , testCase "R-O1 the database refuses a second running transaction for one Engineer; concurrent starts give one" oneWriter
    , testCase "R-W1 the worker signals done even when its thread ends by an exception" workerDone
    , testCase "R-W2 a bounded stop does not wait for a long role, kills it, and leaves it uncertain, never run again" boundedStop
    , testCase "R-K1 finished stages leave no workspace; a cut-short one keeps its own; nothing outside the root is removed" workspaces
    ]

-- Fixtures ---------------------------------------------------------------------------------

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
    withSystemTempDirectory "lockstep-p4r1" $ \tmp -> do
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

accepted :: Show e => IO (Either e a) -> IO a
accepted action =
  action >>= either (\e -> assertFailure ("refused: " <> show e)) pure

ready :: Show e => IO (Either e a) -> IO a
ready action =
  action >>= either (\e -> assertFailure ("not ready: " <> show e)) pure

key :: T.Text -> IO IdempotencyKey
key text =
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-recovery-key-" <> text))

gitIn :: FilePath -> [String] -> IO String
gitIn dir args = do
  base <- getEnvironment
  let
    identity = ["-c", "user.name=Person", "-c", "user.email=person@example.invalid", "-c", "init.defaultBranch=main"]
    env = ("GIT_CONFIG_NOSYSTEM", "1") : L.filter ((/= "GIT_CONFIG_NOSYSTEM") . fst) base
  finished <-
    timeout 30000000 $
      Process.readCreateProcessWithExitCode ((Process.proc "git" (identity <> args)) {Process.cwd = Just dir, Process.env = Just env}) ""
  case finished of
    Nothing -> assertFailure ("git " <> show args <> " did not finish within 30 s")
    Just (code, out, err) -> do
      assertBool ("git " <> show args <> " failed: " <> out <> err) (code == ExitSuccess)
      pure out

gitLine :: FilePath -> [String] -> IO T.Text
gitLine dir args =
  T.strip . T.pack <$> gitIn dir args

buggy :: T.Text
buggy =
  "def add(a, b):\n    return a - b\n"

fixed :: T.Text
fixed =
  "def add(a, b):\n    return a + b\n"

data Bug
  = Bug
  { bugFolder :: FilePath
  , bugWorkOrder :: T.Text
  }

-- | A project with the buggy calc.py, Lockstep allowed in it, and these tasks handed over as bugs.
admittedBugs :: Scenario -> T.Text -> [T.Text] -> IO [Bug]
admittedBugs sc name titles = do
  pk <- key ("project-" <> name)
  view <- accepted (ready (createProject (scRuntime sc) (folders sc) (NewProject pk name "" NewFolder)))
  folder <- maybe (assertFailure "no folder") (pure . T.unpack) (projectFolder view)
  writeFile (folder <> "/calc.py") (T.unpack buggy)
  _ <- gitIn folder ["add", "calc.py"]
  _ <- gitIn folder ["commit", "-q", "-m", "calc"]
  ek <- key ("enable-" <> name)
  _ <- accepted (ready (enableExecution (scRuntime sc) (folders sc) ek (projectId view) ExpectNothing))
  traverse
    ( \title -> do
        tk <- key ("task-" <> name <> "-" <> T.replace " " "-" title)
        t <- accepted (ready (createTask (scRuntime sc) (NewTask tk (projectId view) title "add(2, 2) is 4 and add(1, 2) is 3" Normal [])))
        readied <- accepted (ready (decideTask (scRuntime sc) "test-session" (taskId t) (taskTicketRevision t) MarkReady))
        ak <- key ("admit-" <> name <> "-" <> T.replace " " "-" title)
        admission <- accepted (ready (admitBug (scRuntime sc) (folders sc) ak (taskId readied) (taskTicketRevision readied)))
        pure (Bug folder (admissionWorkOrder admission))
    )
    titles

admittedBug :: Scenario -> T.Text -> IO Bug
admittedBug sc name = do
  bugs <- admittedBugs sc name ["add subtracts"]
  case bugs of
    [b] -> pure b
    _ -> assertFailure "one bug expected"

-- Role scripts ----------------------------------------------------------------------------------

jsonString :: T.Text -> T.Text
jsonString text =
  "\"" <> T.concatMap escape text <> "\""
 where
  escape c =
    case c of
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\n' -> "\\n"
      _ -> T.singleton c

result :: T.Text -> T.Text
result roleAnswer =
  "{\"result\":" <> roleAnswer <> "}"

discovery :: T.Text
discovery =
  result
    ( "{\"kind\":\"discovery\",\"summary\":\"add subtracts\",\"hypothesis\":\"calc.add uses minus\","
        <> "\"citations\":[{\"path\":\"calc.py\",\"first\":1,\"last\":2}],"
        <> "\"reproduction\":{\"argv\":[\"python3\",\"-c\",\"import calc; assert calc.add(2, 2) == 4, 'add is wrong'\"],\"signature\":\"add is wrong\"},"
        <> "\"allowed_paths\":[\"calc.py\"]}"
    )

-- | A program that, while the gate file exists, removes it, marks it hit and sleeps 30 s; then runs the rest.
gated :: T.Text -> T.Text
gated rest =
  "import os, sys, time\ng = sys.argv[1]\nif os.path.exists(g):\n    os.remove(g)\n    open(g + '.hit', 'w').close()\n    time.sleep(30)\n" <> rest

testSource :: T.Text
testSource =
  "import unittest\nimport calc\n\n\nclass TestAdd(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(calc.add(2, 2), 4, 'add is wrong')\n"

-- | The candidate: one RED test, run through the gate.
candidate :: FilePath -> T.Text
candidate gate =
  result
    ( "{\"kind\":\"candidate\",\"criteria\":[{\"id\":\"add-adds\",\"text\":\"add returns the sum\",\"ticket_quote\":\"add(1, 2) is 3\","
        <> "\"citations\":[{\"path\":\"calc.py\",\"first\":1,\"last\":2}]}],\"allowed_paths\":[\"calc.py\"],"
        <> "\"verification\":[[\"python3\",\"-m\",\"unittest\",\"test_calc\"]],\"tests\":[{\"path\":\"test_calc.py\",\"content\":"
        <> jsonString testSource
        <> ",\"expect\":\"red\",\"argv\":[\"python3\",\"-c\","
        <> jsonString (gated "import unittest\nunittest.main(module='test_calc', argv=['test'])\n")
        <> ","
        <> jsonString (T.pack gate)
        <> "],\"signature\":\"add is wrong\"}]}"
    )

noFindings :: T.Text
noFindings =
  result "{\"kind\":\"challenge\",\"findings\":[]}"

-- | A finding whose mutant (add always 0) the tests kill.
mutantFinding :: T.Text
mutantFinding =
  result
    ( "{\"kind\":\"challenge\",\"findings\":[{\"requirement\":\"add-adds\",\"claim\":\"a constant add would pass\","
        <> "\"basis\":[{\"path\":\"calc.py\",\"first\":1,\"last\":2}],"
        <> "\"mutant\":[{\"path\":\"calc.py\",\"content\":\"def add(a, b):\\n    return 0\\n\"}]}]}"
    )

-- | A counterexample, run through the gate, that the fixed add does not show.
counterFinding :: FilePath -> T.Text
counterFinding gate =
  result
    ( "{\"kind\":\"challenge\",\"findings\":[{\"requirement\":\"add-adds\",\"claim\":\"add(1, 2) may still be wrong\","
        <> "\"basis\":[{\"path\":\"calc.py\",\"first\":1,\"last\":2}],"
        <> "\"test\":{\"path\":\"test_counter.py\",\"content\":\"import calc\\n\",\"argv\":[\"python3\",\"-c\","
        <> jsonString (gated "import calc\nassert calc.add(1, 2) == 3, 'add still wrong'\n")
        <> ","
        <> jsonString (T.pack gate)
        <> "],\"signature\":\"add still wrong\"}}]}"
    )

fixes :: T.Text
fixes =
  "{\"write\":{\"path\":\"calc.py\",\"content\":" <> jsonString fixed <> "}}," <> result "{\"kind\":\"implementation\",\"summary\":\"add now adds\"}"

approve :: T.Text
approve =
  result "{\"kind\":\"review\",\"verdict\":\"approve\",\"reasons\":[\"the one-line change makes add add\"]}"

data Scripts
  = Scripts
  { planner :: [T.Text]
  , challenger :: [T.Text]
  , implementer :: [T.Text]
  , reviewer :: [T.Text]
  }

-- | Every role answers once more than the happy path needs, so a role run again by itself would be seen running.
happy :: FilePath -> Scripts
happy gate =
  Scripts [discovery, candidate gate, candidate gate] [noFindings, noFindings, noFindings] [fixes, fixes] [approve, approve]

script :: T.Text -> BS.ByteString
script steps =
  TE.encodeUtf8 ("{\"steps\":[" <> steps <> "]}")

engineWith :: Scenario -> Scripts -> IO Engine
engineWith sc scripts = do
  cancel <- newCancel
  runner <- directRunner cancel (scTmp sc <> "/work")
  let
    pick answers n = scriptedAdapter "scripts/runner/scripted-role" . script <$> L.lookup n (L.zip [0 ..] answers)
    adapter :: Role -> Int -> Maybe Adapter
    adapter role =
      case role of
        Planner -> pick (planner scripts)
        Challenger -> pick (challenger scripts)
        Implementer -> pick (implementer scripts)
        Reviewer -> pick (reviewer scripts)
  pure (Engine runner adapter)

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

-- | Starts the bug's transaction and advances it n times; the transaction after the last step.
reach :: Scenario -> Engine -> Bug -> Int -> IO TransactionView
reach sc engine bug n = do
  view <- accepted (ready (startTransaction (scRuntime sc) (bugWorkOrder bug)))
  reports <- traverse (const (accepted (ready (advance (scRuntime sc) engine (viewId view))))) [1 .. n]
  pure (maybe view viewAfter (lastMay reports))

lastMay :: [a] -> Maybe a
lastMay xs =
  case L.reverse xs of
    x : _ -> Just x
    [] -> Nothing

-- | One advance on another runtime over the same database (a restart).
afterRestart :: Scenario -> Engine -> TransactionView -> IO (Either T.Text StepReport)
afterRestart sc engine view =
  withRuntime (scConfig sc) $ \runtime -> ready (advance runtime engine (viewId view))

count :: Scenario -> String -> IO Int
count sc query = do
  rows <- queryInts (scAdmin sc) (scDb sc) query
  case rows of
    [n] -> pure n
    _ -> assertFailure ("count: " <> query)

runsOf :: Scenario -> String -> IO Int
runsOf sc what =
  count sc ("SELECT count(*)::integer AS v FROM lockstep_invocations WHERE what = '" <> what <> "'")

unfinished :: Scenario -> IO Int
unfinished sc =
  count sc "SELECT count(*)::integer AS v FROM lockstep_invocations WHERE finished_at IS NULL"

recordsOf :: T.Text -> TransactionView -> [T.Text]
recordsOf kind view =
  [recordBody r | r <- viewRecords view, recordKind r == kind]

-- | From now on the database refuses every change to a transaction row (an injected failure).
refuseWrites :: Scenario -> IO ()
refuseWrites sc = do
  adminExecute (scAdmin sc) (T.unpack (scDb sc)) "CREATE OR REPLACE FUNCTION lockstep_test_refuse() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'test: this write is refused'; END $$"
  adminExecute (scAdmin sc) (T.unpack (scDb sc)) "CREATE TRIGGER lockstep_test_refuse BEFORE UPDATE ON lockstep_transactions FOR EACH ROW EXECUTE FUNCTION lockstep_test_refuse()"

allowWrites :: Scenario -> IO ()
allowWrites sc =
  adminExecute (scAdmin sc) (T.unpack (scDb sc)) "DROP TRIGGER lockstep_test_refuse ON lockstep_transactions"

waitUntil :: Int -> IO Bool -> IO Bool
waitUntil n check = do
  ok <- check
  if ok || n <= 0 then pure ok else threadDelay 100000 >> waitUntil (n - 1) check

-- | The service dies while the step runs: armed gate, the step in a thread, killed once the gate is hit.
cutShortAt :: Scenario -> Engine -> TransactionView -> FilePath -> IO ()
cutShortAt sc engine view gate = do
  writeFile gate "armed\n"
  thread <- forkIO (void (try (advance (scRuntime sc) engine (viewId view)) :: IO (Either SomeException (Either NotReadyReason (Either T.Text StepReport)))))
  hit <- waitUntil 300 (doesFileExist (gate <> ".hit"))
  assertBool "the gated command never ran" hit
  killThread thread
  threadDelay 500000

-- Cases ------------------------------------------------------------------------------------------

discoveryKept :: Assertion
discoveryKept =
  withScenario $ \sc -> do
    bug <- admittedBug sc "discovery"
    engine <- engineWith sc (happy (scTmp sc <> "/gate"))
    view <- reach sc engine bug 1
    refuseWrites sc
    lost <- ready (advance (scRuntime sc) engine (viewId view))
    either id inputOf lost @?= "database-unavailable"
    runsOf sc "planner" >>= (@?= 1)
    allowWrites sc
    report <- afterRestart sc engine view >>= either (assertFailure . T.unpack) pure
    inputOf report @?= "discovery-answered"
    runsOf sc "planner" >>= (@?= 1)
    L.length (recordsOf "discovery" (viewAfter report)) @?= 1

baselineCut :: Assertion
baselineCut =
  withScenario $ \sc -> do
    bug <- admittedBug sc "baseline"
    let
      gate = scTmp sc <> "/gate"
    engine <- engineWith sc (happy gate)
    view <- reach sc engine bug 3
    viewStage view @?= "candidate"
    cutShortAt sc engine view gate
    unfinished sc >>= (@?= 1)
    runsOf sc "planner" >>= (@?= 2)
    report <- afterRestart sc engine view >>= either (assertFailure . T.unpack) pure
    inputOf report @?= "candidate-classified"
    runsOf sc "planner" >>= (@?= 2)
    runsOf sc "baseline" >>= (@?= 2)
    viewStage (viewAfter report) @?= "challenge-pre"

mutantCut :: Assertion
mutantCut =
  withScenario $ \sc -> do
    bug <- admittedBug sc "mutant"
    let
      gate = scTmp sc <> "/gate"
    engine <- engineWith sc (happy gate) {challenger = [mutantFinding, noFindings, noFindings]}
    view <- reach sc engine bug 4
    viewStage view @?= "challenge-pre"
    cutShortAt sc engine view gate
    runsOf sc "challenger" >>= (@?= 1)
    report <- afterRestart sc engine view >>= either (assertFailure . T.unpack) pure
    inputOf report @?= "challenge-disposed"
    runsOf sc "challenger" >>= (@?= 1)
    case recordsOf "finding" (viewAfter report) of
      [f] -> assertBool ("the mutant was killed: " <> T.unpack f) ("\"disposition\":\"DISPROVED\"" `T.isInfixOf` f)
      other -> assertFailure ("findings: " <> show other)

counterexampleCut :: Assertion
counterexampleCut =
  withScenario $ \sc -> do
    bug <- admittedBug sc "counter"
    let
      gate = scTmp sc <> "/gate"
    engine <- engineWith sc (happy gate) {challenger = [noFindings, counterFinding gate, noFindings]}
    view <- reach sc engine bug 8
    viewStage view @?= "challenge-post"
    cutShortAt sc engine view gate
    runsOf sc "challenger" >>= (@?= 2)
    report <- afterRestart sc engine view >>= either (assertFailure . T.unpack) pure
    inputOf report @?= "challenge-disposed"
    runsOf sc "challenger" >>= (@?= 2)
    viewStage (viewAfter report) @?= "review"

reviewKept :: Assertion
reviewKept =
  withScenario $ \sc -> do
    bug <- admittedBug sc "review"
    engine <- engineWith sc (happy (scTmp sc <> "/gate"))
    view <- reach sc engine bug 9
    viewStage view @?= "review"
    refuseWrites sc
    lost <- ready (advance (scRuntime sc) engine (viewId view))
    either id inputOf lost @?= "database-unavailable"
    allowWrites sc
    report <- afterRestart sc engine view >>= either (assertFailure . T.unpack) pure
    inputOf report @?= "review-approved"
    runsOf sc "reviewer" >>= (@?= 1)
    L.length (recordsOf "review" (viewAfter report)) @?= 1
    final <- accepted (ready (advance (scRuntime sc) engine (viewId view)))
    inputOf final @?= "commit-accepted"

implementHalts :: Assertion
implementHalts =
  withScenario $ \sc -> do
    bug <- admittedBug sc "implement"
    engine <- engineWith sc (happy (scTmp sc <> "/gate"))
    view <- reach sc engine bug 6
    viewStage view @?= "implement"
    refuseWrites sc
    lost <- ready (advance (scRuntime sc) engine (viewId view))
    either id inputOf lost @?= "database-unavailable"
    allowWrites sc
    report <- afterRestart sc engine view >>= either (assertFailure . T.unpack) pure
    (viewState (viewAfter report), viewHalt (viewAfter report)) @?= ("halted", Just "uncertain-invocation answer-not-recoverable")
    runsOf sc "implementer" >>= (@?= 1)
    idle <- accepted (ready (advance (scRuntime sc) engine (viewId view)))
    inputOf idle @?= "idle halted"
    runsOf sc "implementer" >>= (@?= 1)
    requests <- L.filter ((== bugWorkOrder bug) . storedWorkOrder) <$> ready (openRequests (scRuntime sc))
    request <-
      case requests of
        [r] -> pure r
        other -> assertFailure ("open requests: " <> show (fmap storedChoices other))
    storedChoices request @?= ["retry", "stop"]
    ik <- key "implement-retry"
    _ <- accepted (ready (postMessage (scRuntime sc) ik (storedRequestId request) (SenderHuman ApplicationChannel) (HumanDecides (storedRevision request) "retry" "run it again")))
    resumed <- accepted (ready (advance (scRuntime sc) engine (viewId view)))
    inputOf resumed @?= "human-retry"
    again <- accepted (ready (advance (scRuntime sc) engine (viewId view)))
    inputOf again @?= "implemented"
    runsOf sc "implementer" >>= (@?= 2)

uncertainAtomic :: Assertion
uncertainAtomic =
  withScenario $ \sc -> do
    bug <- admittedBug sc "atomic"
    let
      marker = scTmp sc <> "/ran"
      sleeper = "{\"append\":{\"path\":" <> jsonString (T.pack marker) <> ",\"content\":\"ran\\n\"}},{\"sleep\":30}"
    engine <- engineWith sc (happy (scTmp sc <> "/gate")) {planner = [sleeper, discovery]}
    view <- reach sc engine bug 1
    thread <- forkIO (void (try (advance (scRuntime sc) engine (viewId view)) :: IO (Either SomeException (Either NotReadyReason (Either T.Text StepReport)))))
    ran <- waitUntil 300 (doesFileExist marker)
    assertBool "the Planner never started" ran
    killThread thread
    threadDelay 500000
    unfinished sc >>= (@?= 1)
    refuseWrites sc
    lost <- afterRestart sc engine view
    either id inputOf lost @?= "database-unavailable"
    unfinished sc >>= (@?= 1)
    count sc "SELECT count(*)::integer AS v FROM lockstep_transactions WHERE state = 'running'" >>= (@?= 1)
    stillLost <- afterRestart sc engine view
    either id inputOf stillLost @?= "database-unavailable"
    runsOf sc "planner" >>= (@?= 1)
    allowWrites sc
    report <- afterRestart sc engine view >>= either (assertFailure . T.unpack) pure
    (viewState (viewAfter report), viewHalt (viewAfter report)) @?= ("halted", Just "uncertain-invocation unfinished-invocation")
    runsOf sc "planner" >>= (@?= 1)
    unfinished sc >>= (@?= 0)

asyncPasses :: Assertion
asyncPasses =
  withScenario $ \sc -> do
    wentOn <- newEmptyMVar
    thread <- forkIO (withDatabase (scRuntime sc) (liftIO (threadDelay 5000000)) >> putMVar wentOn ())
    threadDelay 300000
    killThread thread
    threadDelay 1000000
    went <- tryTakeMVar wentOn
    went @?= Nothing

freezeOnce :: Assertion
freezeOnce =
  withScenario $ \sc -> do
    bug <- admittedBug sc "freeze"
    other <- admittedBug sc "freeze-elsewhere"
    engine <- engineWith sc (happy (scTmp sc <> "/gate"))
    view <- reach sc engine bug 5
    viewStage view @?= "freeze"
    basis <- maybe (assertFailure "no basis") pure (viewBasis view)
    let
      branch = "refs/heads/lockstep/" <> T.unpack (bugWorkOrder bug)
    refuseWrites sc
    lost <- ready (advance (scRuntime sc) engine (viewId view))
    either id inputOf lost @?= "database-unavailable"
    moved <- gitLine (bugFolder bug) ["rev-parse", branch]
    assertBool "the branch was moved before the failure" (moved /= basis)
    allowWrites sc
    report <- afterRestart sc engine view >>= either (assertFailure . T.unpack) pure
    inputOf report @?= "tests-frozen"
    head' <- gitLine (bugFolder bug) ["rev-parse", branch]
    head' @?= moved
    commits <- gitLine (bugFolder bug) ["rev-list", "--count", T.unpack basis <> ".." <> branch]
    commits @?= "1"
    assertBool "the freeze record names that commit" (L.any (head' `T.isInfixOf`) (recordsOf "freeze" (viewAfter report)))
    -- Another fix whose branch someone moved to another commit before its freeze still halts.
    otherView <- reach sc engine other 5
    viewStage otherView @?= "freeze"
    otherBasis <- maybe (assertFailure "no basis") pure (viewBasis otherView)
    let
      otherBranch = "refs/heads/lockstep/" <> T.unpack (bugWorkOrder other)
    tree <- gitLine (bugFolder other) ["rev-parse", T.unpack otherBasis <> "^{tree}"]
    elsewhere <- gitLine (bugFolder other) ["commit-tree", T.unpack tree, "-p", T.unpack otherBasis, "-m", "someone else"]
    _ <- gitIn (bugFolder other) ["update-ref", otherBranch, T.unpack elsewhere, T.unpack otherBasis]
    halted <- accepted (ready (advance (scRuntime sc) engine (viewId otherView)))
    (viewState (viewAfter halted), viewHalt (viewAfter halted)) @?= ("halted", Just "supervisor-failed branch-moved")

oneWriter :: Assertion
oneWriter =
  withScenario $ \sc -> do
    bugs <- admittedBugs sc "writer" ["first", "second", "third"]
    (one, two, three) <-
      case bugs of
        [a, b, c] -> pure (a, b, c)
        _ -> assertFailure "three bugs expected"
    -- Two of the Engineer's bugs started at once, on separate runtimes: one transaction, the other busy.
    doneA <- newEmptyMVar
    doneB <- newEmptyMVar
    _ <- forkIO (withRuntime (scConfig sc) (\rt -> startTransaction rt (bugWorkOrder one)) >>= putMVar doneA . fmap (fmap viewState))
    _ <- forkIO (withRuntime (scConfig sc) (\rt -> startTransaction rt (bugWorkOrder two)) >>= putMVar doneB . fmap (fmap viewState))
    a <- waitTake doneA
    b <- waitTake doneB
    L.sort [show a, show b] @?= L.sort [show (Right (Left "engineer-busy") :: Either NotReadyReason (Either T.Text T.Text)), show (Right (Right "running") :: Either NotReadyReason (Either T.Text T.Text))]
    count sc "SELECT count(*)::integer AS v FROM lockstep_transactions WHERE state IN ('running', 'halted')" >>= (@?= 1)
    -- A second running row for the Engineer, written past the engine, is refused by the database itself.
    forged <-
      try
        ( adminExecute
            (scAdmin sc)
            (T.unpack (scDb sc))
            ( "INSERT INTO lockstep_transactions (id, work_order_id, task_id, engineer_name, folder, state, stage, revision) SELECT gen_random_uuid(), '"
                <> T.unpack (bugWorkOrder three)
                <> "'::uuid, task_id, engineer_name, folder, 'running', 'basis', 1 FROM lockstep_transactions WHERE state = 'running'"
            )
        ) ::
        IO (Either SomeException ())
    assertBool "the database refused a second running transaction for the Engineer" (either (const True) (const False) forged)
    busy <- ready (startTransaction (scRuntime sc) (bugWorkOrder three))
    fmap viewId busy @?= Left "engineer-busy"
    count sc "SELECT count(*)::integer AS v FROM lockstep_transactions" >>= (@?= 1)
 where
  waitTake box = do
    got <- timeout 30000000 (waitFor box)
    maybe (assertFailure "a start did not finish within 30 s") pure got
  waitFor box = do
    v <- tryTakeMVar box
    maybe (threadDelay 50000 >> waitFor box) pure v

workerDone :: Assertion
workerDone =
  withScenario $ \sc -> do
    bug <- admittedBug sc "done"
    engine <- engineWith sc (happy (scTmp sc <> "/gate"))
    _ <- reach sc engine bug 1
    let
      exploding = engine {engineRunner = (engineRunner engine) {runnerPrepare = throwIO (userError "the runner fails")}}
      failingLog _ = throwIO (userError "the log is gone")
    worker <- startEngineWorker (scRuntime sc) exploding 50 failingLog
    threadDelay 1500000
    stopped <- timeout 10000000 (stopEngineWorker worker)
    stopped @?= Just ()

boundedStop :: Assertion
boundedStop =
  withScenario $ \sc -> do
    bug <- admittedBug sc "bounded"
    let
      ticks = scTmp sc <> "/ticks"
      busy = "{\"run\":[\"sh\",\"-c\"," <> jsonString ("for i in $(seq 1 150); do date >> " <> T.pack ticks <> "; sleep 0.2; done") <> "]}"
    engine <- engineWith sc (happy (scTmp sc <> "/gate")) {planner = [busy, discovery]}
    view <- reach sc engine bug 1
    worker <- startEngineWorker (scRuntime sc) engine 50 (const (pure ()))
    running <- waitUntil 300 (doesFileExist ticks)
    assertBool "the Planner never started" running
    t0 <- getCurrentTime
    stopped <- timeout 20000000 (stopEngineWorkerWithin 2 worker)
    t1 <- getCurrentTime
    assertBool ("the stop returned in time: " <> show stopped) (isJust stopped)
    assertBool ("the stop took " <> show (diffUTCTime t1 t0)) (diffUTCTime t1 t0 < 10)
    threadDelay 500000
    s1 <- getFileSize ticks
    threadDelay 1500000
    s2 <- getFileSize ticks
    assertBool "the role's processes were stopped with it" (s1 == s2)
    unfinished sc >>= (@?= 1)
    report <- afterRestart sc engine view >>= either (assertFailure . T.unpack) pure
    (viewState (viewAfter report), viewHalt (viewAfter report)) @?= ("halted", Just "uncertain-invocation unfinished-invocation")
    runsOf sc "planner" >>= (@?= 1)

workspaces :: Assertion
workspaces =
  withScenario $ \sc -> do
    bug <- admittedBug sc "workspaces"
    engine <- engineWith sc (happy (scTmp sc <> "/gate"))
    final <- reach sc engine bug 11
    viewState final @?= "accepted"
    left <- listDirectory (scTmp sc <> "/work")
    left @?= []
    -- A Planner cut short keeps its workspace (it may still be in use).
    other <- admittedBug sc "workspaces-cut"
    let
      marker = scTmp sc <> "/ran"
      sleeper = "{\"append\":{\"path\":" <> jsonString (T.pack marker) <> ",\"content\":\"ran\\n\"}},{\"sleep\":30}"
    engine2 <- engineWith sc (happy (scTmp sc <> "/gate")) {planner = [sleeper]}
    view <- reach sc engine2 other 1
    thread <- forkIO (void (try (advance (scRuntime sc) engine2 (viewId view)) :: IO (Either SomeException (Either NotReadyReason (Either T.Text StepReport)))))
    ran <- waitUntil 300 (doesFileExist marker)
    assertBool "the Planner never started" ran
    killThread thread
    threadDelay 500000
    kept <- listDirectory (scTmp sc <> "/work")
    L.length kept @?= 1
    -- A workspace outside the runner's root is never removed.
    let
      outside = scTmp sc <> "/outside"
    createDirectory outside
    createDirectory (outside <> "/tree")
    writeFile (outside <> "/tree/keep.txt") "keep\n"
    runnerRelease
      (engineRunner engine)
      Workspace
        { workspaceTree = outside <> "/tree"
        , workspaceInput = outside <> "/input"
        , workspaceOutput = outside <> "/output"
        , workspaceView = View "/x/tree" "/x/input" "/x/output"
        , workspaceName = "0123456789abcdef0123456789abcdef"
        }
    stillThere <- doesDirectoryExist (outside <> "/tree")
    stillThere @?= True
