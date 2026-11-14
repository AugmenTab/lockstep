{-# LANGUAGE OverloadedStrings #-}

{- | Review remediation of C-P6.3 (R-P6.3-1 to R-P6.3-6), against real
PostgreSQL, Git and processes with scripted roles: the Planner reads the
request's evidence; an answer posted before a crash is recorded as answered;
a stop requested before the phase runs nothing; attempts that ran no helper do
not use up the bound; the task page says when no answer came or the limit is
reached.
-}
module Lockstep.InboxReviewTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
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
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Clarification (ClarificationOutcome (..), ClarificationReport (..), answerClarifications, answerClarificationsUntil, clarificationContext)
import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Conversation (Sender (..), StoredMessage (..), StoredRequest (..), openRequests, postMessage)
import Lockstep.Application.Database (DatabaseRuntime)
import Lockstep.Application.Engine (Engine (..), StepReport (..), TransactionView (..), advance, startTransaction)
import Lockstep.Application.Execution (Admission (..), admitBug, enableExecution)
import Lockstep.Application.Inbox (InboxEntry (..), askQuestion, inboxEntries)
import Lockstep.Application.ProjectChecks (ExpectedChecks (..))
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks (NewTask (..), TaskDecision (..), TaskView (..), createTask, decideTask)
import Lockstep.Effects.Process (newCancel)
import Lockstep.Effects.Roles (Adapter, directRunner, scriptedAdapter)
import Lockstep.Kernel.Conversation (RequestInput (..))
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Roles (Role (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Kernel.Transaction (Stage (..), retryOperation)
import Lockstep.Support.Http (HttpResponse (..), httpRequest)
import Lockstep.Support.Postgres (AdminSettings (..), adminExecute, databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime, writeConfigFile)
import Lockstep.Support.Process (freePort, runLockstep, withService)

data Env
  = Env
  { envAdmin :: AdminSettings
  , envDb :: T.Text
  , envRuntime :: DatabaseRuntime
  , envCli :: [(String, String)]
  , envPort :: Int
  , envDir :: FilePath
  }

withEnv :: (Env -> IO a) -> IO a
withEnv action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-p63r" $ \dir -> do
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
        (result, _) <- withService cli port (dir <> "/serve.log") (action (Env admin db runtime cli port dir))
        pure result

accepted :: Show e => IO (Either e a) -> IO a
accepted act =
  act >>= either (\e -> assertFailure ("refused: " <> show e)) pure

ready :: Show e => IO (Either e a) -> IO a
ready act =
  act >>= either (\e -> assertFailure ("not ready: " <> show e)) pure

key :: T.Text -> IO IdempotencyKey
key text =
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-inbox-review-" <> text))

gitIn :: FilePath -> [String] -> IO ()
gitIn dir args = do
  base <- getEnvironment
  let
    identity = ["-c", "user.name=Person", "-c", "user.email=person@example.invalid", "-c", "init.defaultBranch=main"]
    env = ("GIT_CONFIG_NOSYSTEM", "1") : L.filter ((/= "GIT_CONFIG_NOSYSTEM") . fst) base
  finished <- timeout 30000000 (Process.readCreateProcessWithExitCode ((Process.proc "git" (identity <> args)) {Process.cwd = Just dir, Process.env = Just env}) "")
  case finished of
    Just (ExitSuccess, _, _) -> pure ()
    other -> assertFailure ("git " <> show args <> ": " <> show (fmap (\(c, o, e) -> (show c, o, e)) other))

-- | An engine whose Planner gives these scripted answers in turn (none: no helper).
engineWith :: Env -> [T.Text] -> IO Engine
engineWith env answers = do
  cancel <- newCancel
  runner <- directRunner cancel (envDir env <> "/work")
  let
    pick n = scriptedAdapter "scripts/runner/scripted-role" . (\a -> TE.encodeUtf8 ("{\"steps\":[" <> a <> "]}")) <$> L.lookup n (L.zip [0 ..] answers)
    adapter :: Role -> Int -> Maybe Adapter
    adapter role n = if role == Planner then pick n else Nothing
  pure (Engine runner adapter)

-- | A bug whose fix the real engine halted at the basis; its task and open request.
haltedBug :: Env -> Engine -> IO (TaskView, StoredRequest)
haltedBug env engine = do
  let
    folders = ProjectFolders (Just (envDir env <> "/projects")) []
  pk <- key "project"
  view <- accepted (ready (createProject (envRuntime env) folders (NewProject pk "Caesura" "" NewFolder)))
  folder <- maybe (assertFailure "no folder") (pure . T.unpack) (projectFolder view)
  writeFile (folder <> "/calc.py") "def add(a, b):\n    return a - b\n"
  gitIn folder ["add", "calc.py"]
  gitIn folder ["commit", "-q", "-m", "calc"]
  ek <- key "enable"
  _ <- accepted (ready (enableExecution (envRuntime env) folders ek (projectId view) ExpectNothing))
  tk <- key "task"
  t <- accepted (ready (createTask (envRuntime env) (NewTask tk (projectId view) "The timer adds wrong" "add(2, 2) is 4" Normal [])))
  readied <- accepted (ready (decideTask (envRuntime env) "test-session" (taskId t) (taskTicketRevision t) MarkReady))
  ak <- key "admit"
  admission <- accepted (ready (admitBug (envRuntime env) folders ak (taskId readied) (taskTicketRevision readied)))
  writeFile (folder <> "/notes.txt") "uncommitted\n"
  tx <- accepted (ready (startTransaction (envRuntime env) (admissionWorkOrder admission)))
  _ <- accepted (ready (advance (envRuntime env) engine (viewId tx)))
  second <- accepted (ready (advance (envRuntime env) engine (viewId tx)))
  case second of
    Idle "halted" _ -> pure ()
    _ -> assertFailure "the fix did not halt"
  open <- ready (openRequests (envRuntime env))
  case open of
    [request] -> pure (readied, request)
    other -> assertFailure ("open requests: " <> show (L.length other))

ask :: Env -> T.Text -> StoredRequest -> T.Text -> IO StoredMessage
ask env k request text = do
  ik <- key k
  accepted (ready (askQuestion (envRuntime env) ik (storedRequestId request) (storedRevision request) text))

count :: Env -> String -> IO Int
count env query = do
  rows <- queryInts (envAdmin env) (envDb env) ("SELECT count(*)::integer AS v FROM " <> query)
  case rows of
    [n] -> pure n
    _ -> assertFailure ("count " <> query)

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

taskPage :: Env -> TaskView -> IO BS.ByteString
taskPage env task = do
  s <- session env
  resp <- httpRequest (envPort env) "GET" ("/app/fragments/task/" <> T.unpack (taskId task)) [("X-Lockstep-Session", s)] ""
  responseStatus resp @?= 200
  pure (responseBody resp)

contains :: BS.ByteString -> BS.ByteString -> Bool
contains needle haystack =
  not (BS.null (snd (BS.breakSubstring needle haystack)))

clarification :: T.Text -> T.Text
clarification text =
  "{\"result\":{\"kind\":\"clarification\",\"text\":\"" <> text <> "\"}}"

tests :: TestTree
tests =
  testGroup
    "C-P6.3 review remediation R-P6.3-1 to R-P6.3-6 (real Git, processes, PostgreSQL, service)"
    [ testCase "the Planner reads the request's evidence and why the fix stopped (R-P6.3-1)" $
        withEnv $ \env -> do
          engine <- engineWith env []
          (_, request) <- haltedBug env engine
          entries <- ready (inboxEntries (envRuntime env))
          case entries of
            [entry] -> do
              let
                context = clarificationContext entry
              assertBool ("no evidence in " <> show context) (storedEvidence request `T.isInfixOf` context)
              assertBool ("no reason in " <> show context) ("repository-dirty" `T.isInfixOf` context)
              assertBool ("no consequence in " <> show context) (retryOperation StageBasis `T.isInfixOf` context)
            other -> assertFailure ("entries: " <> show (L.length other))
    , testCase "an answer posted just before a crash is recorded as answered, once (R-P6.3-2)" $
        withEnv $ \env -> do
          engine <- engineWith env [clarification "Never asked."]
          (_, request) <- haltedBug env engine
          asked <- ask env "q1" request "Still there?"
          let
            attempt = "00000000-0000-4000-8000-0000000000bb" :: T.Text
          adminExecute
            (envAdmin env)
            (T.unpack (envDb env))
            ( "INSERT INTO lockstep_clarifications (id, request_id, message_sequence, request_revision) VALUES ('"
                <> T.unpack attempt
                <> "', '"
                <> T.unpack (storedRequestId request)
                <> "', "
                <> show (messageSequence asked)
                <> ", "
                <> show (storedRevision request)
                <> ")"
            )
          k <- either (const (assertFailure "key")) pure (mkIdempotencyKey ("clarification-" <> attempt))
          _ <- accepted (ready (postMessage (envRuntime env) k (storedRequestId request) (SenderPlanner attempt) (PlannerSays (storedRevision request) "Posted before the crash.")))
          reports <- ready (answerClarifications (envRuntime env) engine)
          reports @?= [ClarificationReport (storedRequestId request) (messageSequence asked) ClarifiedAnswered]
          count env "lockstep_clarifications WHERE outcome = 'answered' AND answer_digest IS NOT NULL" >>= (@?= 1)
          count env "lockstep_conversation_messages WHERE kind = 'planner'" >>= (@?= 1)
    , testCase "a stop requested before the phase runs no Planner and starts no attempt (R-P6.3-4)" $
        withEnv $ \env -> do
          engine <- engineWith env [clarification "Should not run."]
          (_, request) <- haltedBug env engine
          _ <- ask env "q1" request "Anyone?"
          ready (answerClarificationsUntil (envRuntime env) engine (pure True)) >>= (@?= [])
          count env "lockstep_clarifications" >>= (@?= 0)
    , testCase "attempts that ran no helper do not use up the bound; the task page says no answer came (R-P6.3-5, R-P6.3-6)" $
        withEnv $ \env -> do
          engine <- engineWith env []
          (task, request) <- haltedBug env engine
          outcomes <-
            traverse
              ( \n -> do
                  _ <- ask env ("q" <> T.pack (show n)) request ("Question " <> T.pack (show n) <> "?")
                  fmap reportOutcome <$> ready (answerClarifications (envRuntime env) engine)
              )
              [1 .. 4 :: Int]
          outcomes @?= L.replicate 4 [ClarifiedNoHelper]
          entries <- ready (inboxEntries (envRuntime env))
          fmap entryAnswersLeft entries @?= [3]
          page <- taskPage env task
          assertBool "the page does not say no answer came" (contains "could not answer" page)
          assertBool "the ask form is gone" (contains "/questions" page)
    , testCase "once three answers were tried, the task page says so and offers no more asking (R-P6.3-6)" $
        withEnv $ \env -> do
          engine <- engineWith env [clarification "One.", clarification "Two.", clarification "Three."]
          (task, request) <- haltedBug env engine
          traverse_
            ( \n -> do
                _ <- ask env ("q" <> T.pack (show n)) request ("Question " <> T.pack (show n) <> "?")
                ready (answerClarifications (envRuntime env) engine)
            )
            [1 .. 3 :: Int]
          page <- taskPage env task
          assertBool "the limit is not said" (contains "as many of your questions" page)
          assertBool "the ask form is still offered" (not (contains (TE.encodeUtf8 ("/app/api/requests/" <> storedRequestId request <> "/questions")) page))
    ]
