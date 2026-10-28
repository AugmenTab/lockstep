{-# LANGUAGE OverloadedStrings #-}

{- | A person's decisions in the coding transaction, against real PostgreSQL,
Git and processes (contract C-P4.15): a halt waits for a person's binding
answer to its own decision request (C-P4.3); that answer, and only that
answer, resumes or stops it; the Done decision after acceptance is a
person's alone; a restart changes nothing; the engine worker keeps
transactions moving by itself.
-}
module Lockstep.EngineHumanTest
  ( tests
  ) where

import Control.Concurrent (threadDelay)
import Data.ByteString qualified as BS
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import System.Directory (createDirectory, removeFile)
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
import Lockstep.Application.Conversation (Channel (..), Sender (..), StoredMessage (..), StoredRequest (..), openRequests, postMessage)
import Lockstep.Application.Database (DatabaseRuntime, runMigrations)
import Lockstep.Application.Engine
  ( Engine (..)
  , InvocationView (..)
  , RecordView (..)
  , StepReport (..)
  , TransactionView (..)
  , advance
  , decideCompletion
  , startTransaction
  , transactionForWorkOrder
  )
import Lockstep.Application.EngineWorker (startEngineWorker, stopEngineWorker)
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
    "C-P4.15 a person's decisions in the coding transaction (real Git, processes, PostgreSQL)"
    [ testCase "a person's retry on a halt's request resumes its stage; nothing resumes without an answer" retry
    , testCase "accepting non-reproduction is honored only where reproduction is missing; stop stops" nonReproduction
    , testCase "a replayed or older answer never resumes a later halt" staleAnswers
    , testCase "an agent never answers or decides; a Supervisor or Planner never decides for a person" principals
    , testCase "Done only after acceptance, only by a person, once; not done stops it" completion
    , testCase "halted across a restart: still halted, nothing run again; a person's retry runs the stage once more" restart
    , testCase "the engine worker starts handed-over bugs and takes them to acceptance by itself, then stops cleanly" worker
    ]

-- Fixtures (as C-P4.10-14) ------------------------------------------------------------

data Scenario
  = Scenario
  { scConfig :: DatabaseConfig
  , scRuntime :: DatabaseRuntime
  , scTmp :: FilePath
  }

withScenario :: (Scenario -> IO a) -> IO a
withScenario action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-p415" $ \tmp -> do
      config <- databaseConfigFor admin db
      withRuntime config $ \runtime -> do
        migrated <- runMigrations migrations runtime
        assertBool "migrations failed" (either (const False) (const True) migrated)
        createDirectory (tmp <> "/projects")
        createDirectory (tmp <> "/work")
        action (Scenario config runtime tmp)

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
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-human-key-" <> text))

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

admittedBug :: Scenario -> T.Text -> IO Bug
admittedBug sc name = do
  pk <- key ("project-" <> name)
  view <- accepted (ready (createProject (scRuntime sc) (folders sc) (NewProject pk name "" NewFolder)))
  folder <- maybe (assertFailure "no folder") (pure . T.unpack) (projectFolder view)
  writeFile (folder <> "/calc.py") (T.unpack buggy)
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

-- Scripts -----------------------------------------------------------------------------------

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

discoveryWith :: T.Text -> T.Text
discoveryWith reproduction =
  result
    ( "{\"kind\":\"discovery\",\"summary\":\"add subtracts\",\"hypothesis\":\"calc.add uses minus\","
        <> "\"citations\":[{\"path\":\"calc.py\",\"first\":1,\"last\":2}],"
        <> reproduction
        <> "\"allowed_paths\":[\"calc.py\"]}"
    )

discovery :: T.Text
discovery =
  discoveryWith "\"reproduction\":{\"argv\":[\"python3\",\"-c\",\"import calc; assert calc.add(2, 2) == 4, 'add is wrong'\"],\"signature\":\"add is wrong\"},"

candidate :: T.Text
candidate =
  result
    ( "{\"kind\":\"candidate\",\"criteria\":[{\"id\":\"add-adds\",\"text\":\"add returns the sum\",\"ticket_quote\":\"add(2, 2) is 4\","
        <> "\"citations\":[{\"path\":\"calc.py\",\"first\":1,\"last\":2}]}],\"allowed_paths\":[\"calc.py\"],"
        <> "\"verification\":[[\"python3\",\"-m\",\"unittest\",\"test_calc\"]],\"tests\":[{\"path\":\"test_calc.py\",\"content\":"
        <> jsonString "import unittest\nimport calc\n\n\nclass TestAdd(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(calc.add(2, 2), 4, 'add is wrong')\n"
        <> ",\"expect\":\"red\",\"argv\":[\"python3\",\"-m\",\"unittest\",\"test_calc\"],\"signature\":\"add is wrong\"}]}"
    )

noFindings :: T.Text
noFindings =
  result "{\"kind\":\"challenge\",\"findings\":[]}"

fixes :: T.Text
fixes =
  "{\"write\":{\"path\":\"calc.py\",\"content\":" <> jsonString fixed <> "}}," <> result "{\"kind\":\"implementation\",\"summary\":\"add now adds\"}"

approve :: T.Text
approve =
  result "{\"kind\":\"review\",\"verdict\":\"approve\",\"reasons\":[\"read it\"]}"

data Scripts
  = Scripts
  { planner :: [T.Text]
  , challenger :: [T.Text]
  , implementer :: [T.Text]
  , reviewer :: [T.Text]
  }

happy :: Scripts
happy =
  Scripts [discovery, candidate] [noFindings, noFindings] [fixes] [approve]

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

script :: T.Text -> BS.ByteString
script steps' =
  TE.encodeUtf8 ("{\"steps\":[" <> steps' <> "]}")

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

stepOnce :: Scenario -> Engine -> TransactionView -> IO StepReport
stepOnce sc engine view =
  accepted (ready (advance (scRuntime sc) engine (viewId view)))

stepTimes :: Scenario -> Engine -> TransactionView -> Int -> IO StepReport
stepTimes sc engine view n =
  case n of
    1 -> stepOnce sc engine view
    _ -> stepOnce sc engine view >> stepTimes sc engine view (n - 1)

-- | The open request about this bug's Work Order (there is at most one at a time).
openRequestFor :: Scenario -> Bug -> IO StoredRequest
openRequestFor sc bug = do
  open <- L.filter ((== bugWorkOrder bug) . storedWorkOrder) <$> ready (openRequests (scRuntime sc))
  case open of
    [r] -> pure r
    other -> assertFailure ("open requests: " <> show (fmap storedChoices other))

-- | A person's binding answer through the application channel.
answer :: Scenario -> T.Text -> StoredRequest -> T.Text -> IO StoredMessage
answer sc k request choice = do
  ik <- key k
  accepted (ready (postMessage (scRuntime sc) ik (storedRequestId request) (SenderHuman ApplicationChannel) (HumanDecides (storedRevision request) choice "my decision")))

recordKinds :: TransactionView -> [T.Text]
recordKinds =
  fmap recordKind . viewRecords

-- Cases -----------------------------------------------------------------------------------------

retry :: Assertion
retry =
  withScenario $ \sc -> do
    bug <- admittedBug sc "retry"
    writeFile (bugFolder bug <> "/notes.txt") "uncommitted\n"
    engine <- engineWith sc happy
    view <- begin sc bug
    halted <- stepOnce sc engine view
    viewHalt (viewAfter halted) @?= Just "repository-dirty"
    waiting <- stepOnce sc engine view
    inputOf waiting @?= "idle halted"
    request <- openRequestFor sc bug
    removeFile (bugFolder bug <> "/notes.txt")
    _ <- answer sc "retry-1" request "retry"
    resumed <- stepOnce sc engine view
    (inputOf resumed, viewState (viewAfter resumed), viewStage (viewAfter resumed)) @?= ("human-retry", "running", "basis")
    assertBool "the resume names the request and the choice" (L.any (\r -> recordKind r == "resume" && storedRequestId request `T.isInfixOf` recordBody r && "retry" `T.isInfixOf` recordBody r) (viewRecords (viewAfter resumed)))
    assertBool "a person gave it" (L.any (\r -> recordKind r == "resume" && recordPrincipal r == "human") (viewRecords (viewAfter resumed)))
    next <- stepOnce sc engine view
    inputOf next @?= "basis-ready"

nonReproduction :: Assertion
nonReproduction =
  withScenario $ \sc -> do
    bug <- admittedBug sc "non-reproduction"
    engine <- engineWith sc happy {planner = [discoveryWith "", candidate]}
    view <- begin sc bug
    report <- stepTimes sc engine view 3
    viewHalt (viewAfter report) @?= Just "reproduction-missing"
    request <- openRequestFor sc bug
    storedChoices request @?= ["accept-non-reproduction", "retry", "stop"]
    _ <- answer sc "accept-1" request "accept-non-reproduction"
    resumed <- stepOnce sc engine view
    (inputOf resumed, viewStage (viewAfter resumed)) @?= ("human-accept-non-reproduction", "candidate")
    bug2 <- admittedBug sc "stopped"
    writeFile (bugFolder bug2 <> "/notes.txt") "uncommitted\n"
    view2 <- begin sc bug2
    _ <- stepOnce sc engine view2
    request2 <- openRequestFor sc bug2
    _ <- answer sc "stop-2" request2 "stop"
    stopped <- stepOnce sc engine view2
    (inputOf stopped, viewState (viewAfter stopped), viewHalt (viewAfter stopped)) @?= ("human-stop", "stopped", Just "repository-dirty")
    after <- stepOnce sc engine view2
    inputOf after @?= "idle stopped"

staleAnswers :: Assertion
staleAnswers =
  withScenario $ \sc -> do
    bug <- admittedBug sc "stale"
    writeFile (bugFolder bug <> "/notes.txt") "uncommitted\n"
    engine <- engineWith sc happy
    view <- begin sc bug
    _ <- stepOnce sc engine view
    first <- openRequestFor sc bug
    _ <- answer sc "stale-1" first "retry"
    _ <- stepOnce sc engine view
    -- still dirty: the retried basis halts again, with a new request
    halted <- stepOnce sc engine view
    viewHalt (viewAfter halted) @?= Just "repository-dirty"
    second <- openRequestFor sc bug
    assertBool "a new request for the new halt" (storedRequestId second /= storedRequestId first)
    -- the first answer replayed changes nothing
    replayed <- answer sc "stale-1" first "retry"
    messageChoice replayed @?= Just "retry"
    still <- stepOnce sc engine view
    (inputOf still, viewState (viewAfter still)) @?= ("idle halted", "halted")
    L.length (L.filter (== "resume") (recordKinds (viewAfter still))) @?= 1

principals :: Assertion
principals =
  withScenario $ \sc -> do
    bug <- admittedBug sc "principals"
    writeFile (bugFolder bug <> "/notes.txt") "uncommitted\n"
    engine <- engineWith sc happy
    view <- begin sc bug
    _ <- stepOnce sc engine view
    request <- openRequestFor sc bug
    ak <- key "agent-answer"
    agent <- ready (postMessage (scRuntime sc) ak (storedRequestId request) (SenderAgent "implementer") (HumanDecides (storedRevision request) "retry" "I decide"))
    fromLeft "accepted" agent @?= "agent-assertion"
    sk <- key "supervisor-answer"
    supervisor <- ready (postMessage (scRuntime sc) sk (storedRequestId request) SenderSupervisor (HumanDecides (storedRevision request) "retry" "for them"))
    fromLeft "accepted" supervisor @?= "not-authorized"
    pk <- key "planner-answer"
    planned <- ready (postMessage (scRuntime sc) pk (storedRequestId request) (SenderPlanner "planner-1") (HumanDecides (storedRevision request) "retry" "for them"))
    fromLeft "accepted" planned @?= "not-authorized"
    still <- stepOnce sc engine view
    inputOf still @?= "idle halted"
    agentDone <- ready (decideCompletion (scRuntime sc) (viewId view) (SenderAgent "reviewer") "done")
    fromLeft "accepted" agentDone @?= "agent-assertion"
    supervisorDone <- ready (decideCompletion (scRuntime sc) (viewId view) SenderSupervisor "done")
    fromLeft "accepted" supervisorDone @?= "not-authorized"

completion :: Assertion
completion =
  withScenario $ \sc -> do
    bug <- admittedBug sc "done"
    engine <- engineWith sc happy
    view <- begin sc bug
    early <- ready (decideCompletion (scRuntime sc) (viewId view) (SenderHuman ApplicationChannel) "done")
    fromLeft "accepted" early @?= "illegal-input"
    report <- stepTimes sc engine view 11
    viewState (viewAfter report) @?= "accepted"
    unknown <- ready (decideCompletion (scRuntime sc) (viewId view) (SenderHuman ApplicationChannel) "finished")
    fromLeft "accepted" unknown @?= "unknown-choice"
    done <- accepted (ready (decideCompletion (scRuntime sc) (viewId view) (SenderHuman ApplicationChannel) "done"))
    viewState done @?= "done"
    assertBool "a person's completion is recorded" (L.any (\r -> recordKind r == "completion" && recordPrincipal r == "human") (viewRecords done))
    again <- ready (decideCompletion (scRuntime sc) (viewId view) (SenderHuman ApplicationChannel) "done")
    fromLeft "accepted" again @?= "closed"
    bug2 <- admittedBug sc "not-done"
    view2 <- begin sc bug2
    _ <- stepTimes sc engine view2 11
    notDone <- accepted (ready (decideCompletion (scRuntime sc) (viewId view2) (SenderHuman CliChannel) "not-done"))
    (viewState notDone, viewHalt notDone) @?= ("stopped", Just "not accepted by a person")

restart :: Assertion
restart =
  withScenario $ \sc -> do
    bug <- admittedBug sc "restart"
    engine <- engineWith sc happy {planner = ["{\"exit\":3}", discovery, candidate]}
    view <- begin sc bug
    halted <- stepTimes sc engine view 2
    viewHalt (viewAfter halted) @?= Just "role-failed role-crashed"
    withRuntime (scConfig sc) $ \runtime2 -> do
      idle <- accepted (ready (advance runtime2 engine (viewId view)))
      inputOf idle @?= "idle halted"
      fmap invocationWhat (viewInvocations (viewAfter idle)) @?= ["planner"]
      request <- openRequestFor sc bug
      ik <- key "restart-retry"
      _ <- accepted (ready (postMessage runtime2 ik (storedRequestId request) (SenderHuman ApplicationChannel) (HumanDecides (storedRevision request) "retry" "try again")))
      resumed <- accepted (ready (advance runtime2 engine (viewId view)))
      inputOf resumed @?= "human-retry"
      again <- accepted (ready (advance runtime2 engine (viewId view)))
      inputOf again @?= "discovery-answered"
      fmap invocationWhat (viewInvocations (viewAfter again)) @?= ["planner", "planner"]

-- Two bugs handed over in two projects of two Engineers; the worker starts and finishes both by itself.
worker :: Assertion
worker =
  withScenario $ \sc -> do
    first <- admittedBug sc "worker-one"
    second <- admittedBug sc "worker-two"
    engine <- engineWith sc happy
    running <- startEngineWorker (scRuntime sc) engine 100 (const (pure ()))
    let
      stateOf bug = fmap (fmap viewState) (ready (transactionForWorkOrder (scRuntime sc) (bugWorkOrder bug)))
      wait :: Int -> IO (Maybe T.Text, Maybe T.Text)
      wait n = do
        a <- stateOf first
        b <- stateOf second
        if (a == Just "accepted" && b == Just "accepted") || n <= 0
          then pure (a, b)
          else threadDelay 200000 >> wait (n - 1)
    final <- wait 450
    stopEngineWorker running
    final @?= (Just "accepted", Just "accepted")
    after <- stateOf first
    after @?= Just "accepted"
