{-# LANGUAGE OverloadedStrings #-}

{- | The Human Inbox and bounded Planner clarification against real
PostgreSQL, Git and processes, with scripted roles (contract C-P6.3 I1–I9 and
the handoff §7 list): a person's question gets one read-only Planner answer
that decides nothing; attempts are bounded, idempotent and never replayed
after a restart; the inbox lists every open request with the consequence of
each choice; unrelated work continues.
-}
module Lockstep.InboxTest
  ( tests
  ) where

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

import Lockstep.Application.Clarification (ClarificationOutcome (..), ClarificationReport (..), answerClarifications)
import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Conversation (Channel (..), Conversation (..), Sender (..), StoredMessage (..), StoredRequest (..), conversation, openRequests, postMessage)
import Lockstep.Application.Database (DatabaseRuntime, runMigrations)
import Lockstep.Application.Engine (Engine (..), StepReport (..), TransactionView (..), advance, startTransaction)
import Lockstep.Application.Execution (Admission (..), admitBug, enableExecution)
import Lockstep.Application.Inbox (InboxChoice (..), InboxEntry (..), askQuestion, inboxEntries)
import Lockstep.Application.ProjectChecks (ExpectedChecks (..))
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks (NewTask (..), TaskDecision (..), TaskView (..), createTask, decideTask)
import Lockstep.Effects.Process (newCancel)
import Lockstep.Effects.Roles (Adapter, directRunner, scriptedAdapter)
import Lockstep.Kernel.Conversation (RequestInput (..))
import Lockstep.Kernel.Inbox (choiceConsequence)
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Roles (Role (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Kernel.Transaction (Stage (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (AdminSettings, adminExecute, databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime)

tests :: TestTree
tests =
  testGroup
    "C-P6.3 the Human Inbox and bounded Planner clarification (real Git, processes, PostgreSQL; scripted roles)"
    [ testCase "a person's question gets one read-only Planner answer, which decides and resumes nothing (I3, I4, I5)" questionAnswered
    , testCase "a second pass or a second worker runs nothing more: one attempt, one answer (I6)" idempotent
    , testCase "at most 3 answers per request; a fourth question is left for the person (I6)" bounded
    , testCase "without a coding helper nothing is invented, and the attempt is not run again (I6)" noHelper
    , testCase "an attempt left unfinished by a stopped worker is never run again and posts nothing (I7)" restart
    , testCase "a failed or wrong-kind Planner run posts nothing (I6)" failedRun
    , testCase "only a person decides: a Planner, a Supervisor or an agent cannot; a stale or replayed message changes nothing; a closed request takes nothing (handoff §7)" authority
    , testCase "two requests stay distinct, and a question on one fix holds no other fix (I8)" distinct
    , testCase "the inbox lists every open request with its project, task, step and each choice's consequence, and drops it once decided (I1, I2, I9)" inbox
    ]

-- Fixtures (as C-P4.15) -------------------------------------------------------------------

data Scenario
  = Scenario
  { scAdmin :: AdminSettings
  , scDb :: T.Text
  , scRuntime :: DatabaseRuntime
  , scTmp :: FilePath
  }

withScenario :: (Scenario -> IO a) -> IO a
withScenario action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-p63" $ \tmp -> do
      config <- databaseConfigFor admin db
      withRuntime config $ \runtime -> do
        migrated <- runMigrations migrations runtime
        assertBool "migrations failed" (either (const False) (const True) migrated)
        createDirectory (tmp <> "/projects")
        createDirectory (tmp <> "/work")
        action (Scenario admin db runtime tmp)

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
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-inbox-key-" <> text))

gitIn :: FilePath -> [String] -> IO ()
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
    Just (code, out, err) -> assertBool ("git " <> show args <> " failed: " <> out <> err) (code == ExitSuccess)

data Bug
  = Bug
  { bugProject :: ProjectView
  , bugTask :: TaskView
  , bugFolder :: FilePath
  , bugWorkOrder :: T.Text
  }

-- | A handed-over bug in its own project; @dirty@ leaves an uncommitted file, so its fix stops at the basis.
admittedBug :: Scenario -> T.Text -> Bool -> IO Bug
admittedBug sc name dirty = do
  pk <- key ("project-" <> name)
  view <- accepted (ready (createProject (scRuntime sc) (folders sc) (NewProject pk name "" NewFolder)))
  folder <- maybe (assertFailure "no folder") (pure . T.unpack) (projectFolder view)
  writeFile (folder <> "/calc.py") "def add(a, b):\n    return a - b\n"
  gitIn folder ["add", "calc.py"]
  gitIn folder ["commit", "-q", "-m", "calc"]
  ek <- key ("enable-" <> name)
  _ <- accepted (ready (enableExecution (scRuntime sc) (folders sc) ek (projectId view) ExpectNothing))
  tk <- key ("task-" <> name)
  t <- accepted (ready (createTask (scRuntime sc) (NewTask tk (projectId view) ("add subtracts in " <> name) "add(2, 2) is 4" Normal [])))
  readied <- accepted (ready (decideTask (scRuntime sc) "test-session" (taskId t) (taskTicketRevision t) MarkReady))
  ak <- key ("admit-" <> name)
  admission <- accepted (ready (admitBug (scRuntime sc) (folders sc) ak (taskId readied) (taskTicketRevision readied)))
  when dirty (writeFile (folder <> "/notes.txt") "uncommitted\n")
  pure (Bug view readied folder (admissionWorkOrder admission))

clarification :: T.Text -> T.Text
clarification text =
  "{\"result\":{\"kind\":\"clarification\",\"text\":\"" <> text <> "\"}}"

-- | An engine whose Planner answers, at its n-th invocation, the n-th script (none: no helper).
engineWith :: Scenario -> [T.Text] -> IO Engine
engineWith sc plannerAnswers = do
  cancel <- newCancel
  runner <- directRunner cancel (scTmp sc <> "/work")
  let
    pick n = scriptedAdapter "scripts/runner/scripted-role" . script <$> L.lookup n (L.zip [0 ..] plannerAnswers)
    adapter :: Role -> Int -> Maybe Adapter
    adapter role n =
      case role of
        Planner -> pick n
        _ -> Nothing
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

-- | Starts the bug's fix and takes it to its halt and open request (two steps).
halted :: Scenario -> Engine -> Bug -> IO (TransactionView, StoredRequest)
halted sc engine bug = do
  view <- accepted (ready (startTransaction (scRuntime sc) (bugWorkOrder bug)))
  first <- accepted (ready (advance (scRuntime sc) engine (viewId view)))
  viewHalt (viewAfter first) @?= Just "repository-dirty"
  second <- accepted (ready (advance (scRuntime sc) engine (viewId view)))
  inputOf second @?= "idle halted"
  request <- openRequestFor sc bug
  pure (view, request)

openRequestFor :: Scenario -> Bug -> IO StoredRequest
openRequestFor sc bug = do
  open <- L.filter ((== bugWorkOrder bug) . storedWorkOrder) <$> ready (openRequests (scRuntime sc))
  case open of
    [r] -> pure r
    other -> assertFailure ("open requests: " <> show (L.length other))

ask :: Scenario -> T.Text -> StoredRequest -> T.Text -> IO StoredMessage
ask sc k request text = do
  ik <- key k
  accepted (ready (askQuestion (scRuntime sc) ik (storedRequestId request) (storedRevision request) text))

messagesOf :: Scenario -> StoredRequest -> IO [StoredMessage]
messagesOf sc request =
  ready (conversation (scRuntime sc) (storedRequestId request)) >>= maybe (assertFailure "no conversation") (pure . conversationMessages)

kinds :: [StoredMessage] -> [T.Text]
kinds =
  fmap messageKind

kindsOf :: Scenario -> StoredRequest -> IO [T.Text]
kindsOf sc request =
  kinds <$> messagesOf sc request

pass :: Scenario -> Engine -> IO [ClarificationReport]
pass sc engine =
  ready (answerClarifications (scRuntime sc) engine)

count :: Scenario -> String -> IO Int
count sc query = do
  rows <- queryInts (scAdmin sc) (scDb sc) ("SELECT count(*)::integer AS v FROM " <> query)
  case rows of
    [n] -> pure n
    _ -> assertFailure ("count " <> query)

-- Cases --------------------------------------------------------------------------------------------

questionAnswered :: Assertion
questionAnswered =
  withScenario $ \sc -> do
    bug <- admittedBug sc "asked" True
    engine <- engineWith sc [clarification "Retry checks the folder again. I approve retry."]
    (view, request) <- halted sc engine bug
    asked <- ask sc "q1" request "What happens if I retry?"
    (messageKind asked, messagePrincipal asked, messageBody asked) @?= ("human", "human", "What happens if I retry?")
    reports <- pass sc engine
    reports @?= [ClarificationReport (storedRequestId request) (messageSequence asked) ClarifiedAnswered]
    messages <- messagesOf sc request
    kinds messages @?= ["opened", "human", "planner"]
    case L.reverse messages of
      answer : _ -> do
        (messagePrincipal answer, messageBody answer, messageChoice answer) @?= ("supervisor", "Retry checks the folder again. I approve retry.", Nothing)
        assertBool "the answer does not name its Planner invocation" ("planner-invocation " `T.isPrefixOf` messageEvidence answer)
      [] -> assertFailure "no messages"
    still <- openRequestFor sc bug
    (storedState still, storedRevision still, storedAnswer still) @?= ("open", storedRevision request, Nothing)
    -- The fix does not move: only a person's decision resumes it.
    waiting <- accepted (ready (advance (scRuntime sc) engine (viewId view)))
    (inputOf waiting, viewState (viewAfter waiting)) @?= ("idle halted", "halted")
    count sc "lockstep_clarifications WHERE outcome = 'answered' AND answer_digest IS NOT NULL" >>= (@?= 1)
    count sc "lockstep_transaction_records WHERE kind = 'resume'" >>= (@?= 0)

idempotent :: Assertion
idempotent =
  withScenario $ \sc -> do
    bug <- admittedBug sc "twice" True
    engine <- engineWith sc [clarification "First answer.", clarification "Second answer."]
    (_, request) <- halted sc engine bug
    _ <- ask sc "q1" request "Why did it stop?"
    first <- pass sc engine
    L.length first @?= 1
    second <- pass sc engine
    second @?= []
    -- The same question replayed by its key is the same message, and asks nothing new.
    _ <- ask sc "q1" request "Why did it stop?"
    third <- pass sc engine
    third @?= []
    count sc "lockstep_clarifications" >>= (@?= 1)
    kindsOf sc request >>= (@?= ["opened", "human", "planner"])

bounded :: Assertion
bounded =
  withScenario $ \sc -> do
    bug <- admittedBug sc "bounded" True
    engine <- engineWith sc (fmap (\n -> clarification ("Answer " <> T.pack (show n) <> ".")) [1 .. 5 :: Int])
    (_, request) <- halted sc engine bug
    let
      round' n = do
        q <- ask sc ("q" <> T.pack (show n)) request ("Question " <> T.pack (show n) <> "?")
        reports <- pass sc engine
        pure (q, reports)
    outcomes <- traverse (fmap (fmap reportOutcome . snd) . round') [1 .. 3 :: Int]
    outcomes @?= [[ClarifiedAnswered], [ClarifiedAnswered], [ClarifiedAnswered]]
    (fourth, reports) <- round' (4 :: Int)
    reports @?= [ClarificationReport (storedRequestId request) (messageSequence fourth) ClarifiedLimit]
    count sc "lockstep_clarifications" >>= (@?= 3)
    count sc "lockstep_conversation_messages WHERE kind = 'planner'" >>= (@?= 3)
    again <- pass sc engine
    again @?= [ClarificationReport (storedRequestId request) (messageSequence fourth) ClarifiedLimit]
    count sc "lockstep_clarifications" >>= (@?= 3)

noHelper :: Assertion
noHelper =
  withScenario $ \sc -> do
    bug <- admittedBug sc "nohelper" True
    engine <- engineWith sc []
    (_, request) <- halted sc engine bug
    asked <- ask sc "q1" request "Is anyone there?"
    pass sc engine >>= (@?= [ClarificationReport (storedRequestId request) (messageSequence asked) ClarifiedNoHelper])
    pass sc engine >>= (@?= [])
    kindsOf sc request >>= (@?= ["opened", "human"])
    count sc "lockstep_clarifications WHERE outcome = 'no-helper' AND answer_digest IS NULL" >>= (@?= 1)

restart :: Assertion
restart =
  withScenario $ \sc -> do
    bug <- admittedBug sc "restart" True
    engine <- engineWith sc [clarification "Too late."]
    (_, request) <- halted sc engine bug
    asked <- ask sc "q1" request "Are you still there?"
    -- A worker that stopped while running the attempt left it started and unfinished.
    adminExecute
      (scAdmin sc)
      (T.unpack (scDb sc))
      ( "INSERT INTO lockstep_clarifications (id, request_id, message_sequence, request_revision) VALUES ('00000000-0000-4000-8000-0000000000aa', '"
          <> T.unpack (storedRequestId request)
          <> "', "
          <> show (messageSequence asked)
          <> ", "
          <> show (storedRevision request)
          <> ")"
      )
    pass sc engine >>= (@?= [ClarificationReport (storedRequestId request) (messageSequence asked) ClarifiedUncertain])
    pass sc engine >>= (@?= [])
    kindsOf sc request >>= (@?= ["opened", "human"])
    count sc "lockstep_clarifications WHERE outcome = 'uncertain' AND finished_at IS NOT NULL" >>= (@?= 1)

failedRun :: Assertion
failedRun =
  withScenario $ \sc -> do
    bug <- admittedBug sc "failed" True
    let
      wrongKind = "{\"result\":{\"kind\":\"review\",\"verdict\":\"approve\",\"reasons\":[\"yes\"]}}"
      empty' = "{\"result\":{\"kind\":\"clarification\",\"text\":\"   \"}}"
    engine <- engineWith sc [wrongKind, empty']
    (_, request) <- halted sc engine bug
    q1 <- ask sc "q1" request "First?"
    reports1 <- pass sc engine
    fmap reportSequence reports1 @?= [messageSequence q1]
    assertBool ("not a failure: " <> show reports1) (L.all (\r -> case reportOutcome r of ClarifiedFailed _ -> True; _ -> False) reports1)
    q2 <- ask sc "q2" request "Second?"
    reports2 <- pass sc engine
    fmap reportSequence reports2 @?= [messageSequence q2]
    assertBool ("not a failure: " <> show reports2) (L.all (\r -> case reportOutcome r of ClarifiedFailed _ -> True; _ -> False) reports2)
    kindsOf sc request >>= (@?= ["opened", "human", "human"])
    count sc "lockstep_clarifications WHERE outcome = 'failed' AND code IS NOT NULL" >>= (@?= 2)

authority :: Assertion
authority =
  withScenario $ \sc -> do
    bug <- admittedBug sc "authority" True
    engine <- engineWith sc [clarification "Choose retry."]
    (view, request) <- halted sc engine bug
    let
      post k sender input = do
        ik <- key k
        ready (postMessage (scRuntime sc) ik (storedRequestId request) sender input)
      rev = storedRevision request
    -- Nobody but a person decides.
    post "planner-decides" (SenderPlanner "x") (HumanDecides rev "retry" "I decide") >>= (@?= Left "not-authorized")
    post "supervisor-decides" SenderSupervisor (HumanDecides rev "retry" "I decide") >>= (@?= Left "not-authorized")
    post "agent-says" (SenderAgent "rogue") (HumanSays rev "approve") >>= (@?= Left "agent-assertion")
    -- A stale page refuses; a question at an old revision too.
    ik <- key "stale-question"
    ready (askQuestion (scRuntime sc) ik (storedRequestId request) (rev + 1) "stale?") >>= (@?= Left "stale-revision")
    -- A choice that is not offered is refused.
    post "launch" (SenderHuman ApplicationChannel) (HumanDecides rev "launch" "go") >>= (@?= Left "unknown-choice")
    -- The Planner's text does not decide.
    _ <- ask sc "q1" request "Should I retry?"
    _ <- pass sc engine
    stillOpen <- openRequestFor sc bug
    storedState stillOpen @?= "open"
    -- The person decides once; a replay by the same key is the same message; the decision resumes the fix once.
    removeFile (bugFolder bug <> "/notes.txt")
    decided <- post "decide" (SenderHuman ApplicationChannel) (HumanDecides rev "retry" "retry it")
    replayed <- post "decide" (SenderHuman ApplicationChannel) (HumanDecides rev "retry" "retry it")
    replayed @?= decided
    resumed <- accepted (ready (advance (scRuntime sc) engine (viewId view)))
    inputOf resumed @?= "human-retry"
    count sc "lockstep_transaction_records WHERE kind = 'resume'" >>= (@?= 1)
    -- A closed request takes no late question and no late decision; the clarification pass leaves it alone.
    late <- key "late"
    ready (askQuestion (scRuntime sc) late (storedRequestId request) rev "too late?") >>= (@?= Left "request-closed")
    post "late-decide" (SenderHuman ApplicationChannel) (HumanDecides rev "stop" "stop it") >>= (@?= Left "request-closed")
    pass sc engine >>= (@?= [])

distinct :: Assertion
distinct =
  withScenario $ \sc -> do
    stuck <- admittedBug sc "stuck" True
    other <- admittedBug sc "other" True
    engine <- engineWith sc [clarification "About the stuck one."]
    (_, stuckRequest) <- halted sc engine stuck
    (otherView, otherRequest) <- halted sc engine other
    assertBool "the two requests are one" (storedRequestId stuckRequest /= storedRequestId otherRequest)
    _ <- ask sc "q-stuck" stuckRequest "Why?"
    reports <- pass sc engine
    fmap reportRequest reports @?= [storedRequestId stuckRequest]
    kindsOf sc otherRequest >>= (@?= ["opened"])
    -- The other fix is decided and moves on while the first question's request stays open.
    removeFile (bugFolder other <> "/notes.txt")
    ik <- key "other-retry"
    _ <- accepted (ready (postMessage (scRuntime sc) ik (storedRequestId otherRequest) (SenderHuman ApplicationChannel) (HumanDecides (storedRevision otherRequest) "retry" "go")))
    resumed <- accepted (ready (advance (scRuntime sc) engine (viewId otherView)))
    inputOf resumed @?= "human-retry"
    next <- accepted (ready (advance (scRuntime sc) engine (viewId otherView)))
    inputOf next @?= "basis-ready"
    stillOpen <- openRequestFor sc stuck
    storedState stillOpen @?= "open"

inbox :: Assertion
inbox =
  withScenario $ \sc -> do
    bug <- admittedBug sc "inbox" True
    engine <- engineWith sc [clarification "It checks the folder again."]
    (_, request) <- halted sc engine bug
    _ <- ask sc "q1" request "What does retry do?"
    _ <- pass sc engine
    entries <- ready (inboxEntries (scRuntime sc))
    case entries of
      [entry] -> do
        (entryRequest entry, entryRevision entry) @?= (storedRequestId request, storedRevision request)
        (entryProject entry, entryProjectName entry) @?= (projectKey (bugProject bug), projectName (bugProject bug))
        (entryTask entry, entryTaskTitle entry) @?= (taskKey (bugTask bug), taskTitle (bugTask bug))
        entryQuestion entry @?= storedQuestion request
        entryStep entry @?= Just StageBasis
        entryChoices entry @?= [InboxChoice c (choiceConsequence StageBasis c) | c <- storedChoices request]
        kinds (entryMessages entry) @?= ["opened", "human", "planner"]
        entryAnswersLeft entry @?= 2
      other -> assertFailure ("inbox entries: " <> show (L.length other))
    removeFile (bugFolder bug <> "/notes.txt")
    ik <- key "decide"
    _ <- accepted (ready (postMessage (scRuntime sc) ik (storedRequestId request) (SenderHuman ApplicationChannel) (HumanDecides (storedRevision request) "stop" "stop it")))
    ready (inboxEntries (scRuntime sc)) >>= (@?= [])
