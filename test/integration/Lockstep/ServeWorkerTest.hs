{-# LANGUAGE OverloadedStrings #-}

{- | The engine in the installed service (contract C-P4.17 Q5): the real
@lockstep serve@ binary starts the engine worker itself when the host
helper's runner channel is there (@LOCKSTEP_RUNNER_DIR@, as
@scripts/service@ passes it) — the real @scripts/control-helper@ with
@--runner@ here, with a @docker@ stand-in. A handed-over bug is started, its
basis taken and its work branch made by the service; with no coding helper
built in, it stops for a person at its first role step and says so on the task
page; the person's Stop, from the page, is acted on by the service. Without a
runner channel the service runs no engine and starts nothing.
-}
module Lockstep.ServeWorkerTest
  ( tests
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket)
import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTPTypes
import System.Directory (copyFile, createDirectory, createDirectoryIfMissing, doesFileExist)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath, writeFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (setFileMode)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Database (DatabaseRuntime)
import Lockstep.Application.Execution (Admission (..), admitBug, enableExecution)
import Lockstep.Application.ProjectChecks (ExpectedChecks (..))
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks (NewTask (..), TaskDecision (..), TaskView (..), createTask, decideTask)
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Support.Http (HttpResponse (..), httpRequest)
import Lockstep.Support.Postgres (AdminSettings (..), databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime, writeConfigFile)
import Lockstep.Support.Process (freePort, runLockstep, withService)

tests :: TestTree
tests =
  testGroup
    "C-P4.17 the engine in the installed service: lockstep serve runs the worker with the host helper's runner"
    [ testCase "with the helper's runner channel the service starts a handed-over bug, stops it for a person (no coding helper built in) and acts on their Stop" withChannel
    , testCase "without a runner channel the service runs no engine and starts nothing" withoutChannel
    ]

-- The helper ---------------------------------------------------------------------------------------

dockerStub :: String
dockerStub =
  L.unlines
    [ "#!/bin/sh"
    , "# docker stand-in (C-P4.17): the helper only needs its image and container listings here"
    , "case \"$1\" in"
    , "  image) echo sha256:stub; exit 0 ;;"
    , "  ps|rm|kill) exit 0 ;;"
    , "esac"
    , "exit 2"
    ]

-- | The real helper with --runner on a throwaway state directory; its runner directory.
withHelper :: FilePath -> (FilePath -> IO a) -> IO a
withHelper tmp body = do
  let
    state = tmp <> "/state"
    stub = tmp <> "/stub"
  createDirectoryIfMissing True (tmp <> "/scripts")
  copyFile "scripts/control-helper" (tmp <> "/scripts/control-helper")
  setFileMode (tmp <> "/scripts/control-helper") 0o755
  traverse_ (\d -> createDirectory d >> setFileMode d 0o700) [state, state <> "/helper", state <> "/pane"]
  writeFile (state <> "/helper/channel.key") (L.replicate 64 'e')
  createDirectoryIfMissing True (stub <> "/bin")
  writeFile (stub <> "/bin/docker") dockerStub
  setFileMode (stub <> "/bin/docker") 0o755
  base <- getEnvironment
  let
    path = stub <> "/bin:" <> fromMaybe "/usr/bin:/bin" (L.lookup "PATH" base)
    env = ("PATH", path) : L.filter ((/= "PATH") . fst) base
    start =
      Process.createProcess
        (Process.proc (tmp <> "/scripts/control-helper") ["--state", state, "--instance", "p417w", "--runner"])
          { Process.env = Just env
          , Process.std_in = Process.NoStream
          , Process.std_out = Process.NoStream
          , Process.std_err = Process.NoStream
          }
    stop (_, _, _, handle) = Process.terminateProcess handle >> void (Process.waitForProcess handle)
  bracket start stop $ \_ -> do
    up <- waitFor 100 (doesFileExist (state <> "/runner/channel.key"))
    unless up (assertFailure "the helper did not make the runner key")
    body (state <> "/runner")

waitFor :: Int -> IO Bool -> IO Bool
waitFor ticks check = do
  ok <- check
  if ok || ticks <= 0 then pure ok else threadDelay 100000 >> waitFor (ticks - 1) check

-- Fixture ----------------------------------------------------------------------------------------

data Fx
  = Fx
  { fxRuntime :: DatabaseRuntime
  , fxTmp :: FilePath
  , fxPort :: Int
  , fxEnv :: [(String, String)]
  , fxCount :: String -> IO Int
  }

-- | A migrated database and the service over it, with these extra variables; the service's log.
withFx :: FilePath -> [(String, String)] -> (Fx -> IO a) -> IO (a, String)
withFx tmp extra action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db -> do
    path <- writeConfigFile tmp admin db (adminPassword admin)
    createDirectory (tmp <> "/projects")
    let
      env = [("LOCKSTEP_CONFIG", path), ("LOCKSTEP_PROJECT_FOLDERS", tmp <> "/projects")] <> extra
      counter query = do
        rows <- queryInts admin db query
        case rows of
          [n] -> pure n
          _ -> assertFailure ("count " <> query)
    (code, _, err) <- runLockstep env ["db", "migrate"]
    assertBool ("db migrate failed: " <> err) (code == ExitSuccess)
    config <- databaseConfigFor admin db
    port <- freePort
    withService env port (tmp <> "/serve.log") $
      withRuntime config $
        \runtime -> action (Fx runtime tmp port env counter)

key :: T.Text -> IO IdempotencyKey
key text =
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-serve-worker-" <> text))

accepted :: Show e => IO (Either e a) -> IO a
accepted action =
  action >>= either (\e -> assertFailure ("refused: " <> show e)) pure

ready :: Show e => IO (Either e a) -> IO a
ready action =
  action >>= either (\e -> assertFailure ("not ready: " <> show e)) pure

gitOut :: FilePath -> [String] -> IO String
gitOut dir args = do
  base <- getEnvironment
  let
    identity = ["-c", "user.name=Person", "-c", "user.email=person@example.invalid", "-c", "init.defaultBranch=main"]
    env = ("GIT_CONFIG_NOSYSTEM", "1") : L.filter ((/= "GIT_CONFIG_NOSYSTEM") . fst) base
  finished <-
    timeout 30000000 $
      Process.readCreateProcessWithExitCode ((Process.proc "git" (identity <> args)) {Process.cwd = Just dir, Process.env = Just env}) ""
  case finished of
    Just (ExitSuccess, out, _) -> pure out
    other -> assertFailure ("git " <> show args <> ": " <> show other)

-- | A project with a buggy calc.py, allowed, a ready task handed over as a bug: the folder and task.
handedOver :: Fx -> T.Text -> IO (FilePath, T.Text, T.Text)
handedOver fx name = do
  let
    folders = ProjectFolders (Just (fxTmp fx <> "/projects")) []
  pk <- key ("project-" <> name)
  view <- accepted (ready (createProject (fxRuntime fx) folders (NewProject pk name "" NewFolder)))
  folder <- maybe (assertFailure "no folder") (pure . T.unpack) (projectFolder view)
  writeFile (folder <> "/calc.py") "def add(a, b):\n    return a - b\n"
  _ <- gitOut folder ["add", "calc.py"]
  _ <- gitOut folder ["commit", "-q", "-m", "calc"]
  ek <- key ("enable-" <> name)
  _ <- accepted (ready (enableExecution (fxRuntime fx) folders ek (projectId view) ExpectNothing))
  tk <- key ("task-" <> name)
  t <- accepted (ready (createTask (fxRuntime fx) (NewTask tk (projectId view) "add subtracts" "add(2, 2) is 4" Normal [])))
  readied <- accepted (ready (decideTask (fxRuntime fx) "test-session" (taskId t) (taskTicketRevision t) MarkReady))
  ak <- key ("admit-" <> name)
  admission <- accepted (ready (admitBug (fxRuntime fx) folders ak (taskId readied) (taskTicketRevision readied)))
  pure (folder, taskId readied, admissionWorkOrder admission)

origin :: Int -> BS.ByteString
origin port =
  "http://127.0.0.1:" <> BS8.pack (show port)

signIn :: Fx -> IO BS.ByteString
signIn fx = do
  (code, out, err) <- runLockstep (fxEnv fx) ["operator", "sign-in", "--port", show (fxPort fx)]
  code @?= ExitSuccess
  token <-
    case L.stripPrefix "=" (L.dropWhile (/= '=') (L.filter (/= '\n') out)) of
      Just t | L.length t == 43 -> pure (BS8.pack t)
      _ -> assertFailure ("unexpected sign-in output: " <> out <> err)
  resp <- httpRequest (fxPort fx) "POST" "/app/api/session" [("Origin", origin (fxPort fx))] token
  responseStatus resp @?= 200
  pure (BS.take 43 (BS.drop 11 (snd (BS.breakSubstring "\"session\":\"" (responseBody resp)))))

contains :: BS.ByteString -> BS.ByteString -> Bool
contains needle haystack =
  not (BS.null (snd (BS.breakSubstring needle haystack)))

-- | The value of a named input of a form on the page.
fieldOf :: BS.ByteString -> BS.ByteString -> IO BS.ByteString
fieldOf name page =
  let
    after = snd (BS.breakSubstring ("name=\"" <> name <> "\" value=\"") page)
  in
    if BS.null after
      then assertFailure ("no field " <> show name)
      else pure (BS.takeWhile (/= 0x22) (BS.drop (BS.length name + 15) after))

-- Cases ---------------------------------------------------------------------------------------------

withChannel :: Assertion
withChannel =
  withSystemTempDirectory "lockstep-p417-serve" $ \tmp ->
    withHelper tmp $ \runnerDir -> do
      (_, serveLog) <-
        withFx tmp [("LOCKSTEP_RUNNER_DIR", runnerDir)] $ \fx -> do
          (folder, task, workOrder) <- handedOver fx "served"
          stopped <-
            waitFor 300 $
              (== 1) <$> fxCount fx "SELECT count(*)::integer AS v FROM lockstep_transactions WHERE state = 'halted' AND halt_code = 'role-failed no-coding-agent'"
          assertBool "the service did not start the bug and stop it for a person" stopped
          fxCount fx "SELECT count(*)::integer AS v FROM lockstep_transactions WHERE basis_commit IS NOT NULL" >>= (@?= 1)
          branch <- gitOut folder ["rev-parse", "--verify", "refs/heads/lockstep/" <> T.unpack workOrder]
          main' <- gitOut folder ["rev-parse", "refs/heads/main"]
          branch @?= main'
          session <- signIn fx
          page <- responseBody <$> httpRequest (fxPort fx) "GET" ("/app/fragments/task/" <> T.unpack task) [("X-Lockstep-Session", session)] ""
          assertBool ("the page says why it stopped: " <> show page) (contains "No coding helper is set up for Lockstep." page)
          assertBool "the page asks the person" (contains "id=\"halt-form\"" page)
          -- The person stops it from the page; the service's worker acts on it.
          let
            form = fst (BS.breakSubstring "</form>" (snd (BS.breakSubstring "id=\"halt-form\"" page)))
            action = BS.takeWhile (/= 0x22) (BS.drop 8 (snd (BS.breakSubstring "action=\"" form)))
          fields <- traverse (\n -> (,) n <$> fieldOf n form) ["key", "request", "revision"]
          resp <-
            httpRequest
              (fxPort fx)
              "POST"
              (BS8.unpack action)
              [("Content-Type", "application/x-www-form-urlencoded"), ("Origin", origin (fxPort fx)), ("X-Lockstep-Session", session)]
              (HTTPTypes.renderSimpleQuery False (fields <> [("choice", "stop")]))
          responseStatus resp @?= 200
          done <- waitFor 300 ((== 1) <$> fxCount fx "SELECT count(*)::integer AS v FROM lockstep_transactions WHERE state = 'stopped'")
          assertBool "the service did not act on the person's Stop" done
          fxCount fx "SELECT count(*)::integer AS v FROM lockstep_transaction_records WHERE kind = 'resume' AND principal = 'human'" >>= (@?= 1)
          fxCount fx "SELECT count(*)::integer AS v FROM lockstep_invocations" >>= (@?= 0)
      assertBool ("the log says the engine runs: " <> serveLog) ("Engine worker: on" `L.isInfixOf` serveLog)

withoutChannel :: Assertion
withoutChannel =
  withSystemTempDirectory "lockstep-p417-serve-off" $ \tmp -> do
    (_, serveLog) <-
      withFx tmp [] $ \fx -> do
        _ <- handedOver fx "unserved"
        threadDelay 6000000
        fxCount fx "SELECT count(*)::integer AS v FROM lockstep_transactions" >>= (@?= 0)
    assertBool ("the log says the engine is off: " <> serveLog) ("Engine worker: off" `L.isInfixOf` serveLog)
