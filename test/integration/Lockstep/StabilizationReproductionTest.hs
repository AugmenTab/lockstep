{-# LANGUAGE OverloadedStrings #-}

{- | Stabilization S2 (post-Phase-5 handoff §3): a separate reproduction command
may be omitted, a genuine RED baseline may not; no retry is offered that can
only repeat a known-impossible step, and a person's replan runs the Planner
again, across a restart. Real PostgreSQL, Git and processes; the scripted
Planner on the direct runner (the same project and bug as C-P4.7-9).
-}
module Lockstep.StabilizationReproductionTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import System.Directory (createDirectory)
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
import Lockstep.Application.Conversation (Channel (..), Sender (..), StoredRequest (..), openRequests, postMessage)
import Lockstep.Application.Database (DatabaseRuntime, runMigrations)
import Lockstep.Application.Engine (Engine (..), InvocationView (..), RecordView (..), StepReport (..), TransactionView (..), advance, startTransaction)
import Lockstep.Application.Execution (Admission (..), admitBug, enableExecution)
import Lockstep.Application.ProjectChecks (ExpectedChecks (..))
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks (NewTask (..), TaskDecision (..), TaskView (..), createTask, decideTask)
import Lockstep.Effects.Process (newCancel)
import Lockstep.Effects.Roles (Adapter, directRunner, scriptedAdapter)
import Lockstep.Foundation.SystemConfig (DatabaseConfig)
import Lockstep.Kernel.Conversation (RequestInput (..))
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Roles (Role (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (databaseConfigFor, requireAdmin, withFreshDatabase, withRuntime)

tests :: TestTree
tests =
  testGroup
    "S2 reproduction may be omitted, RED may not; no ineffective retry (real Git, processes, PostgreSQL)"
    [ testCase "1 a supplied command that fails with its signature reproduces, and the tests follow" supplied
    , testCase "2-3 no command: recorded as not run, never as reproduced, and on to the candidate tests without a person" omitted
    , testCase "4 omitted, then a candidate whose RED fails for its reason reaches the challenge" omittedThenRed
    , testCase "5-6 omitted: RED for the wrong reason and GREEN alone never qualify; the budget then halts" omittedNoRed
    , testCase "7-9 a command that does not reproduce: no retry offered; replan runs the Planner again, across a restart" replan
    , testCase "8 every other halt's question names what a retry runs" retryNamed
    ]

-- Fixtures ----------------------------------------------------------------------------

data Scenario
  = Scenario
  { scRuntime :: DatabaseRuntime
  , scConfig :: DatabaseConfig
  , scTmp :: FilePath
  }

withScenario :: (Scenario -> IO a) -> IO a
withScenario action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-stab-s2" $ \tmp -> do
      config <- databaseConfigFor admin db
      withRuntime config $ \runtime -> do
        migrated <- runMigrations migrations runtime
        assertBool "migrations failed" (either (const False) (const True) migrated)
        createDirectory (tmp <> "/projects")
        createDirectory (tmp <> "/work")
        action (Scenario runtime config tmp)

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
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-stab-s2-key-" <> text))

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

calcSource :: String
calcSource =
  "def add(a, b):\n    return a - b\n\n\ndef mul(a, b):\n    return a * b\n"

mulTest :: T.Text
mulTest =
  "import unittest\nimport calc\n\n\nclass TestMul(unittest.TestCase):\n    def test_mul(self):\n        self.assertEqual(calc.mul(3, 4), 12)\n"

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
  writeFile (folder <> "/calc.py") calcSource
  _ <- gitIn folder ["add", "calc.py"]
  _ <- gitIn folder ["commit", "-q", "-m", "calc"]
  ek <- key ("enable-" <> name)
  _ <- accepted (ready (enableExecution (scRuntime sc) (folders sc) ek (projectId view) ExpectNothing))
  tk <- key ("task-" <> name)
  t <- accepted (ready (createTask (scRuntime sc) (NewTask tk (projectId view) "add subtracts" "add(2, 2) is 4 and add(1, 2) is 3" Normal [])))
  readied <- accepted (ready (decideTask (scRuntime sc) "test-session" (taskId t) (taskTicketRevision t) MarkReady))
  ak <- key ("admit-" <> name)
  admission <- accepted (ready (admitBug (scRuntime sc) (folders sc) ak (taskId readied) (taskTicketRevision readied)))
  pure (Bug folder (admissionWorkOrder admission))

-- Scripts --------------------------------------------------------------------------------

result :: T.Text -> T.Text
result answer =
  "{\"result\":" <> answer <> "}"

-- | A discovery with the given reproduction member (with its trailing comma), or none.
discoveryWith :: T.Text -> T.Text
discoveryWith reproduction =
  result
    ( "{\"kind\":\"discovery\",\"summary\":\"add subtracts\",\"hypothesis\":\"calc.add uses minus\","
        <> "\"citations\":[{\"path\":\"calc.py\",\"first\":1,\"last\":2}],"
        <> reproduction
        <> "\"allowed_paths\":[\"calc.py\"]}"
    )

failingCheck :: T.Text
failingCheck =
  "\"reproduction\":{\"argv\":[\"python3\",\"-c\",\"import calc; assert calc.add(2, 2) == 4, 'add is wrong'\"],\"signature\":\"add is wrong\"},"

passingCheck :: T.Text
passingCheck =
  "\"reproduction\":{\"argv\":[\"python3\",\"-c\",\"print(1)\"],\"signature\":\"add is wrong\"},"

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

redTestSource :: T.Text
redTestSource =
  "import unittest\nimport calc\n\n\nclass TestAdd(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(calc.add(2, 2), 4, 'add is wrong')\n"

testEntry :: T.Text -> T.Text -> T.Text -> [T.Text] -> Maybe T.Text -> T.Text
testEntry path content expect argv signature =
  "{\"path\":"
    <> jsonString path
    <> ",\"content\":"
    <> jsonString content
    <> ",\"expect\":"
    <> jsonString expect
    <> ",\"argv\":["
    <> T.intercalate "," (fmap jsonString argv)
    <> "]"
    <> maybe "" (\s -> ",\"signature\":" <> jsonString s) signature
    <> "}"

candidateWith :: [T.Text] -> T.Text
candidateWith entries =
  result
    ( "{\"kind\":\"candidate\",\"criteria\":[{\"id\":\"add-adds\",\"text\":\"add returns the sum\",\"ticket_quote\":\"add(2, 2) is 4\","
        <> "\"citations\":[{\"path\":\"calc.py\",\"first\":1,\"last\":2}]}],\"allowed_paths\":[\"calc.py\"],"
        <> "\"verification\":[[\"python3\",\"-m\",\"unittest\",\"test_calc\"]],\"tests\":["
        <> T.intercalate "," entries
        <> "]}"
    )

redTest :: T.Text
redTest =
  testEntry "test_calc.py" redTestSource "red" ["python3", "-m", "unittest", "test_calc"] (Just "add is wrong")

wrongReason :: T.Text
wrongReason =
  candidateWith [testEntry "test_calc.py" "import nothing_here\n" "red" ["python3", "-m", "unittest", "test_calc"] (Just "add is wrong")]

-- | Only a GREEN test that passes at the basis: it shows nothing about the bug.
greenOnly :: T.Text
greenOnly =
  candidateWith [testEntry "test_mul.py" mulTest "green" ["python3", "-m", "unittest", "test_mul"] Nothing]

script :: T.Text -> BS.ByteString
script answer =
  TE.encodeUtf8 ("{\"steps\":[" <> answer <> "]}")

-- | An engine whose Planner gives the n-th script on its n-th run in this transaction.
engineWith :: Scenario -> [T.Text] -> IO Engine
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

begin :: Scenario -> Bug -> IO TransactionView
begin sc bug =
  accepted (ready (startTransaction (scRuntime sc) (bugWorkOrder bug)))

stepWith :: DatabaseRuntime -> Engine -> TransactionView -> IO StepReport
stepWith runtime engine view =
  accepted (ready (advance runtime engine (viewId view)))

stepTimes :: Scenario -> Engine -> TransactionView -> Int -> IO StepReport
stepTimes sc engine view n =
  if n <= 1
    then stepWith (scRuntime sc) engine view
    else stepWith (scRuntime sc) engine view >> stepTimes sc engine view (n - 1)

recordsOf :: T.Text -> TransactionView -> [T.Text]
recordsOf kind view =
  [recordBody r | r <- viewRecords view, recordKind r == kind]

requestsFor :: Scenario -> Bug -> IO [StoredRequest]
requestsFor sc bug =
  L.filter ((== bugWorkOrder bug) . storedWorkOrder) <$> ready (openRequests (scRuntime sc))

-- Cases ---------------------------------------------------------------------------------------

supplied :: Assertion
supplied =
  withScenario $ \sc -> do
    bug <- admittedBug sc "supplied"
    engine <- engineWith sc [discoveryWith failingCheck]
    view <- begin sc bug
    report <- stepTimes sc engine view 3
    (inputOf report, viewState (viewAfter report), viewStage (viewAfter report)) @?= ("reproduced", "running", "candidate")
    assertBool "recorded as reproduced" (L.any ("\"reproduced\":true" `T.isInfixOf`) (recordsOf "reproduction" (viewAfter report)))
    L.length [i | i <- viewInvocations (viewAfter report), invocationWhat i == "reproduction"] @?= 1

omitted :: Assertion
omitted =
  withScenario $ \sc -> do
    bug <- admittedBug sc "omitted"
    engine <- engineWith sc [discoveryWith ""]
    view <- begin sc bug
    report <- stepTimes sc engine view 3
    (inputOf report, viewState (viewAfter report), viewStage (viewAfter report), viewHalt (viewAfter report))
      @?= ("reproduction-omitted", "running", "candidate", Nothing)
    case recordsOf "reproduction" (viewAfter report) of
      [body] -> do
        assertBool ("never a reproduction: " <> T.unpack body) ("\"reproduced\":false" `T.isInfixOf` body)
        assertBool ("no command: " <> T.unpack body) ("\"command\":null" `T.isInfixOf` body)
      other -> assertFailure ("reproduction records: " <> show other)
    [i | i <- viewInvocations (viewAfter report), invocationWhat i == "reproduction"] @?= []
    requests <- requestsFor sc bug
    requests @?= []

omittedThenRed :: Assertion
omittedThenRed =
  withScenario $ \sc -> do
    bug <- admittedBug sc "omitted-red"
    engine <- engineWith sc [discoveryWith "", candidateWith [redTest]]
    view <- begin sc bug
    report <- stepTimes sc engine view 4
    (inputOf report, viewStage (viewAfter report)) @?= ("candidate-classified", "challenge-pre")
    case recordsOf "baseline" (viewAfter report) of
      [b] -> assertBool ("red-confirmed: " <> T.unpack b) ("\"class\":\"red-confirmed\"" `T.isInfixOf` b)
      other -> assertFailure ("baseline records: " <> show other)

omittedNoRed :: Assertion
omittedNoRed =
  withScenario $ \sc -> do
    bug <- admittedBug sc "omitted-no-red"
    engine <- engineWith sc [discoveryWith "", wrongReason, greenOnly, wrongReason]
    view <- begin sc bug
    first <- stepTimes sc engine view 4
    (viewStage (viewAfter first), viewCandidates (viewAfter first)) @?= ("candidate", 1)
    assertBool "wrong reason" (L.any ("red-wrong-reason" `T.isInfixOf`) (recordsOf "baseline" (viewAfter first)))
    second <- stepWith (scRuntime sc) engine view
    (viewStage (viewAfter second), viewCandidates (viewAfter second)) @?= ("candidate", 2)
    assertBool "GREEN alone is classified, and does not qualify" (L.any ("green-confirmed" `T.isInfixOf`) (recordsOf "baseline" (viewAfter second)))
    third <- stepWith (scRuntime sc) engine view
    (viewState (viewAfter third), viewHalt (viewAfter third)) @?= ("halted", Just "candidates-exhausted")
    [i | i <- viewInvocations (viewAfter third), invocationWhat i == "freeze"] @?= []

replan :: Assertion
replan =
  withScenario $ \sc -> do
    bug <- admittedBug sc "replan"
    engine <- engineWith sc [discoveryWith passingCheck, discoveryWith ""]
    view <- begin sc bug
    report <- stepTimes sc engine view 3
    (inputOf report, viewHalt (viewAfter report)) @?= ("not-reproduced", Just "reproduction-missing")
    request <-
      requestsFor sc bug >>= \rs -> case rs of
        [r] -> pure r
        other -> assertFailure ("requests: " <> show other)
    storedChoices request @?= ["accept-non-reproduction", "replan", "stop"]
    -- The same command at the same basis is not offered again: an answer of "retry" is refused.
    rk <- key "retry"
    refused <- ready (postMessage (scRuntime sc) rk (storedRequestId request) (SenderHuman ApplicationChannel) (HumanDecides (storedRevision request) "retry" "again"))
    either (@?= "unknown-choice") (const (assertFailure "retry was accepted")) refused
    pk <- key "replan"
    _ <- accepted (ready (postMessage (scRuntime sc) pk (storedRequestId request) (SenderHuman ApplicationChannel) (HumanDecides (storedRevision request) "replan" "look again")))
    -- A restart: a new runtime over the same database, and a new engine whose Planner continues its scripts.
    engine2 <- engineWith sc [discoveryWith passingCheck, discoveryWith ""]
    withRuntime (scConfig sc) $ \runtime2 -> do
      resumed <- stepWith runtime2 engine2 view
      (inputOf resumed, viewState (viewAfter resumed), viewStage (viewAfter resumed)) @?= ("human-replan", "running", "discovery")
      again <- stepWith runtime2 engine2 view
      inputOf again @?= "discovery-answered"
      L.length [i | i <- viewInvocations (viewAfter again), invocationWhat i == "planner", invocationStage i == "discovery"] @?= 2
      onward <- stepWith runtime2 engine2 view
      (inputOf onward, viewStage (viewAfter onward)) @?= ("reproduction-omitted", "candidate")

retryNamed :: Assertion
retryNamed =
  withScenario $ \sc -> do
    bug <- admittedBug sc "named"
    writeFile (bugFolder bug <> "/notes.txt") "uncommitted\n"
    engine <- engineWith sc []
    view <- begin sc bug
    _ <- stepWith (scRuntime sc) engine view
    requests <- requestsFor sc bug
    case requests of
      [r] -> do
        storedChoices r @?= ["retry", "stop"]
        assertBool ("the question names what a retry runs: " <> T.unpack (storedQuestion r)) ("Retry checks the project's folder and its Git state again" `T.isInfixOf` storedQuestion r)
      other -> assertFailure ("requests: " <> show other)
    bug2 <- admittedBug sc "named-two"
    crash <- engineWith sc ["{\"exit\":3}"]
    view2 <- begin sc bug2
    _ <- stepTimes sc crash view2 2
    requests2 <- requestsFor sc bug2
    case requests2 of
      [r] -> assertBool ("the Planner is named: " <> T.unpack (storedQuestion r)) ("Retry runs the Planner's search for the cause again" `T.isInfixOf` storedQuestion r)
      other -> assertFailure ("requests: " <> show other)
