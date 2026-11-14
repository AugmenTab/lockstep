{-# LANGUAGE OverloadedStrings #-}

{- | The Human Inbox over the real service (contract C-P6.3 I1, I3): the
Decisions section lists an open request with its consequences and no form; the
task page shows the request's conversation, labels the Planner's answer as
information, and takes a person's question only with the session and this
origin. The fix is halted by the real engine (scripted roles) in this process,
on the same database.
-}
module Lockstep.InboxPageTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTPTypes
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

import Lockstep.Application.Clarification (answerClarifications)
import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Conversation (StoredRequest (..), openRequests)
import Lockstep.Application.Database (DatabaseRuntime)
import Lockstep.Application.Engine (Engine (..), StepReport (..), TransactionView (..), advance, startTransaction)
import Lockstep.Application.Execution (Admission (..), admitBug, enableExecution)
import Lockstep.Application.Inbox (askQuestion)
import Lockstep.Application.ProjectChecks (ExpectedChecks (..))
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks (NewTask (..), TaskDecision (..), TaskView (..), createTask, decideTask)
import Lockstep.Effects.Process (newCancel)
import Lockstep.Effects.Roles (Adapter, directRunner, scriptedAdapter)
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Roles (Role (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Kernel.Transaction (Stage (..), retryOperation)
import Lockstep.Support.Http (HttpResponse (..), httpRequest, responseHeader)
import Lockstep.Support.Postgres (AdminSettings (..), databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime, writeConfigFile)
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
    withSystemTempDirectory "lockstep-p63-page" $ \dir -> do
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
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-inbox-page-" <> text))

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

-- | A bug whose fix the real engine halted at the basis, with its open request; the Planner's one answer is scripted.
haltedBug :: Env -> IO (TaskView, StoredRequest, Engine)
haltedBug env = do
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
  cancel <- newCancel
  runner <- directRunner cancel (envDir env <> "/work")
  let
    answer = TE.encodeUtf8 "{\"steps\":[{\"result\":{\"kind\":\"clarification\",\"text\":\"Retry looks at the folder again; it cannot fix the folder for you.\"}}]}"
    adapter :: Role -> Int -> Maybe Adapter
    adapter role n = if role == Planner && n == 0 then Just (scriptedAdapter "scripts/runner/scripted-role" answer) else Nothing
    engine = Engine runner adapter
  tx <- accepted (ready (startTransaction (envRuntime env) (admissionWorkOrder admission)))
  _ <- accepted (ready (advance (envRuntime env) engine (viewId tx)))
  second <- accepted (ready (advance (envRuntime env) engine (viewId tx)))
  case second of
    Idle "halted" _ -> pure ()
    _ -> assertFailure "the fix did not halt"
  open <- ready (openRequests (envRuntime env))
  case open of
    [request] -> pure (readied, request, engine)
    other -> assertFailure ("open requests: " <> show (L.length other))

origin :: Env -> BS.ByteString
origin env =
  "http://127.0.0.1:" <> BS8.pack (show (envPort env))

session :: Env -> IO BS.ByteString
session env = do
  (code, out, err) <- runLockstep (envCli env) ["operator", "sign-in", "--port", show (envPort env)]
  code @?= ExitSuccess
  token <-
    case L.stripPrefix "=" (L.dropWhile (/= '=') (L.filter (/= '\n') out)) of
      Just t | L.length t == 43 -> pure t
      _ -> assertFailure ("unexpected sign-in output: " <> out <> err)
  resp <- httpRequest (envPort env) "POST" "/app/api/session" [("Origin", origin env)] (BS8.pack token)
  responseStatus resp @?= 200
  pure (BS.take 43 (BS.drop 11 (snd (BS.breakSubstring "\"session\":\"" (responseBody resp)))))

fragment :: Env -> BS.ByteString -> String -> IO HttpResponse
fragment env s path =
  httpRequest (envPort env) "GET" ("/app/fragments/" <> path) [("X-Lockstep-Session", s)] ""

contains :: BS.ByteString -> BS.ByteString -> Bool
contains needle haystack =
  not (BS.null (snd (BS.breakSubstring needle haystack)))

has :: BS.ByteString -> T.Text -> Assertion
has page needle =
  assertBool ("the page lacks " <> show needle) (contains (TE.encodeUtf8 needle) page)

questionPath :: StoredRequest -> String
questionPath request =
  "/app/api/requests/" <> T.unpack (storedRequestId request) <> "/questions"

postQuestion :: Env -> [HTTPTypes.Header] -> StoredRequest -> Int -> T.Text -> T.Text -> IO HttpResponse
postQuestion env headers request revision k text =
  httpRequest
    (envPort env)
    "POST"
    (questionPath request)
    (("Content-Type", "application/x-www-form-urlencoded") : headers)
    (HTTPTypes.renderSimpleQuery False [("key", TE.encodeUtf8 k), ("revision", BS8.pack (show revision)), ("question", TE.encodeUtf8 text)])

humanMessages :: Env -> IO Int
humanMessages env = do
  rows <- queryInts (envAdmin env) (envDb env) "SELECT count(*)::integer AS v FROM lockstep_conversation_messages WHERE kind = 'human'"
  case rows of
    [n] -> pure n
    _ -> assertFailure "count"

tests :: TestTree
tests =
  testGroup
    "C-P6.3 the Human Inbox over the real service (HTTP, PostgreSQL; the engine with scripted roles in this process)"
    [ testCase "the Decisions section lists the open request: project, task, question, each choice's consequence; no form (I1, I2)" $
        withEnv $ \env -> do
          (task, request, _) <- haltedBug env
          s <- session env
          resp <- fragment env s "decisions"
          responseStatus resp @?= 200
          let
            page = responseBody resp
          traverse_ (has page) ["Caesura", "The timer adds wrong", storedQuestion request, retryOperation StageBasis, "Stop ends this fix", "/app/tasks/" <> taskId task]
          assertBool "a form on the Decisions section" (not (contains "<form" page))
    , testCase "the task page shows the conversation, the Planner's answer as information only, and a form to ask (I3, I4, I5)" $
        withEnv $ \env -> do
          (task, request, engine) <- haltedBug env
          k <- key "q1"
          _ <- accepted (ready (askQuestion (envRuntime env) k (storedRequestId request) (storedRevision request) "What does retry do?"))
          _ <- ready (answerClarifications (envRuntime env) engine)
          s <- session env
          resp <- fragment env s ("task/" <> T.unpack (taskId task))
          responseStatus resp @?= 200
          let
            page = responseBody resp
          traverse_ (has page) ["What does retry do?", "Retry looks at the folder again; it cannot fix the folder for you.", "information only", T.pack (questionPath request)]
    , testCase "asking needs the session and this origin; it records one question and decides nothing; a stale page is explained (I3)" $
        withEnv $ \env -> do
          (task, request, _) <- haltedBug env
          s <- session env
          before <- humanMessages env
          noSession <- postQuestion env [("Origin", origin env)] request (storedRevision request) "test-inbox-page-k1" "Why?"
          responseStatus noSession @?= 401
          foreign' <- postQuestion env [("Origin", "http://127.0.0.1:1"), ("X-Lockstep-Session", s)] request (storedRevision request) "test-inbox-page-k2" "Why?"
          responseStatus foreign' @?= 403
          humanMessages env >>= (@?= before)
          asked <- postQuestion env [("Origin", origin env), ("X-Lockstep-Session", s)] request (storedRevision request) "test-inbox-page-k3" "Why did it stop?"
          responseStatus asked @?= 200
          responseHeader "X-Lockstep-Path" asked @?= Just (TE.encodeUtf8 ("/app/tasks/" <> taskId task))
          assertBool "the task page does not show the question" (contains "Why did it stop?" (responseBody asked))
          humanMessages env >>= (@?= before + 1)
          open <- ready (openRequests (envRuntime env))
          fmap storedState open @?= ["open"]
          stale <- postQuestion env [("Origin", origin env), ("X-Lockstep-Session", s)] request (storedRevision request + 1) "test-inbox-page-k4" "Stale?"
          responseStatus stale @?= 200
          assertBool ("a stale question was not explained: " <> show (responseBody stale)) (contains "changed since this page was shown" (responseBody stale))
          humanMessages env >>= (@?= before + 1)
    ]
