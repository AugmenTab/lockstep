{-# LANGUAGE OverloadedStrings #-}

{- | The task page tells attempts apart (contract C-P4.R1 R-A1), over HTTP
from the real service while the test moves the transaction with the engine
in-process (scripted roles, real Git and processes, PostgreSQL): during a
second attempt the page shows that attempt's checks and review only and names
the earlier one; a passing check is "on the latest change" until the commit is
accepted, and "on the committed change" only after.
-}
module Lockstep.EngineAttemptPageTest
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
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Database (DatabaseRuntime)
import Lockstep.Application.Engine (Engine (..), StepReport (..), TransactionView (..), advance, startTransaction)
import Lockstep.Application.Execution (Admission (..), admitBug, enableExecution)
import Lockstep.Application.ProjectChecks (ExpectedChecks (..))
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks (NewTask (..), TaskDecision (..), TaskView (..), createTask, decideTask)
import Lockstep.Effects.Process (newCancel)
import Lockstep.Effects.Roles (Adapter, directRunner, scriptedAdapter)
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Roles (Role (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Support.Http (HttpResponse (..), httpRequest)
import Lockstep.Support.Postgres (AdminSettings (..), databaseConfigFor, requireAdmin, withFreshDatabase, withRuntime, writeConfigFile)
import Lockstep.Support.Process (freePort, runLockstep, withService)

tests :: TestTree
tests =
  testGroup
    "C-P4.R1 the task page tells attempts apart and claims no commit before acceptance (real service, Git, processes, PostgreSQL)"
    [ testCase "R-A1 after a failed check, the second attempt shows its own checks only; passing is on the latest change until it is committed" failedThenFixed
    , testCase "R-A1 after a rejecting review, the second attempt is not reviewed yet and the earlier attempt is named" rejectedThenApproved
    ]

-- Fixture (as C-P4.16) -------------------------------------------------------------------------

data Fx
  = Fx
  { fxRuntime :: DatabaseRuntime
  , fxTmp :: FilePath
  , fxPort :: Int
  , fxSession :: BS.ByteString
  }

withFx :: (Fx -> IO a) -> IO a
withFx action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-p4r1-page" $ \tmp -> do
      path <- writeConfigFile tmp admin db (adminPassword admin)
      createDirectory (tmp <> "/projects")
      createDirectory (tmp <> "/work")
      let
        env = [("LOCKSTEP_CONFIG", path), ("LOCKSTEP_PROJECT_FOLDERS", tmp <> "/projects")]
      (code, _, err) <- runLockstep env ["db", "migrate"]
      assertBool ("db migrate failed: " <> err) (code == ExitSuccess)
      config <- databaseConfigFor admin db
      port <- freePort
      (outcome, _) <-
        withService env port (tmp <> "/serve.log") $ do
          session <- signIn port env
          withRuntime config $ \runtime -> action (Fx runtime tmp port session)
      pure outcome

origin :: Int -> BS.ByteString
origin port =
  "http://127.0.0.1:" <> BS8.pack (show port)

signIn :: Int -> [(String, String)] -> IO BS.ByteString
signIn port env = do
  (code, out, err) <- runLockstep env ["operator", "sign-in", "--port", show port]
  code @?= ExitSuccess
  token <-
    case L.stripPrefix "=" (L.dropWhile (/= '=') (L.filter (/= '\n') out)) of
      Just t | L.length t == 43 -> pure (BS8.pack t)
      _ -> assertFailure ("unexpected sign-in output: " <> out <> err)
  resp <- httpRequest port "POST" "/app/api/session" [("Origin", origin port)] token
  responseStatus resp @?= 200
  pure (BS.take 43 (BS.drop 11 (snd (BS.breakSubstring "\"session\":\"" (responseBody resp)))))

-- | The Fixing it section of the task page.
fixing :: Fx -> T.Text -> IO BS.ByteString
fixing fx tid = do
  resp <- httpRequest (fxPort fx) "GET" ("/app/fragments/task/" <> T.unpack tid) [("X-Lockstep-Session", fxSession fx)] ""
  responseStatus resp @?= 200
  let
    start = snd (BS.breakSubstring "id=\"fixing\"" (responseBody resp))
  pure (BS.take 1 start <> fst (BS.breakSubstring "<h2" (BS.drop 1 start)))

contains :: BS.ByteString -> BS.ByteString -> Bool
contains needle haystack =
  not (BS.null (snd (BS.breakSubstring needle haystack)))

has :: BS.ByteString -> [BS.ByteString] -> IO ()
has body =
  traverse_ (\needle -> assertBool ("missing " <> show needle <> ": " <> show body) (contains needle body))

lacks :: BS.ByteString -> [BS.ByteString] -> IO ()
lacks body =
  traverse_ (\needle -> assertBool ("unexpected " <> show needle <> ": " <> show body) (not (contains needle body)))

key :: T.Text -> IO IdempotencyKey
key text =
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-attempt-key-" <> text))

accepted :: Show e => IO (Either e a) -> IO a
accepted action =
  action >>= either (\e -> assertFailure ("refused: " <> show e)) pure

ready :: Show e => IO (Either e a) -> IO a
ready action =
  action >>= either (\e -> assertFailure ("not ready: " <> show e)) pure

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
    Just (ExitSuccess, _, _) -> pure ()
    other -> assertFailure ("git " <> show args <> ": " <> show other)

-- | A project with a buggy calc.py, allowed; a ready task handed over as a bug: its task and transaction.
begin :: Fx -> T.Text -> IO (T.Text, TransactionView)
begin fx name = do
  let
    folders = ProjectFolders (Just (fxTmp fx <> "/projects")) []
  pk <- key ("project-" <> name)
  view <- accepted (ready (createProject (fxRuntime fx) folders (NewProject pk name "" NewFolder)))
  folder <- maybe (assertFailure "no folder") (pure . T.unpack) (projectFolder view)
  writeFile (folder <> "/calc.py") "def add(a, b):\n    return a - b\n"
  gitIn folder ["add", "calc.py"]
  gitIn folder ["commit", "-q", "-m", "calc"]
  ek <- key ("enable-" <> name)
  _ <- accepted (ready (enableExecution (fxRuntime fx) folders ek (projectId view) ExpectNothing))
  tk <- key ("task-" <> name)
  t <- accepted (ready (createTask (fxRuntime fx) (NewTask tk (projectId view) "add subtracts" "add(2, 2) is 4" Normal [])))
  readied <- accepted (ready (decideTask (fxRuntime fx) "test-session" (taskId t) (taskTicketRevision t) MarkReady))
  ak <- key ("admit-" <> name)
  admission <- accepted (ready (admitBug (fxRuntime fx) folders ak (taskId readied) (taskTicketRevision readied)))
  tx <- accepted (ready (startTransaction (fxRuntime fx) (admissionWorkOrder admission)))
  pure (taskId readied, tx)

-- Scripted roles -------------------------------------------------------------------------------

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

implementing :: T.Text -> T.Text
implementing code =
  "{\"write\":{\"path\":\"calc.py\",\"content\":" <> jsonString code <> "}}," <> result "{\"kind\":\"implementation\",\"summary\":\"changed add\"}"

fixes :: T.Text
fixes =
  implementing "def add(a, b):\n    return a + b\n"

wrong :: T.Text
wrong =
  implementing "def add(a, b):\n    return a - b + 1\n"

review :: T.Text -> T.Text
review verdict =
  result ("{\"kind\":\"review\",\"verdict\":" <> jsonString verdict <> ",\"reasons\":[\"read the change and the checks\"]}")

engineWith :: Fx -> [T.Text] -> [T.Text] -> IO Engine
engineWith fx implementer reviewer = do
  cancel <- newCancel
  runner <- directRunner cancel (fxTmp fx <> "/work")
  let
    pick answers n = scriptedAdapter "scripts/runner/scripted-role" . script <$> L.lookup n (L.zip [0 ..] answers)
    adapter :: Role -> Int -> Maybe Adapter
    adapter role =
      case role of
        Planner -> pick [discovery, candidate]
        Challenger -> pick [noFindings, noFindings, noFindings]
        Implementer -> pick implementer
        Reviewer -> pick reviewer
  pure (Engine runner adapter)

script :: T.Text -> BS.ByteString
script actions =
  TE.encodeUtf8 ("{\"steps\":[" <> actions <> "]}")

-- | Advances n times; the last step's input.
steps :: Fx -> Engine -> TransactionView -> Int -> IO T.Text
steps fx engine view n = do
  reports <- traverse (const (accepted (ready (advance (fxRuntime fx) engine (viewId view))))) [1 .. n]
  pure $ case L.reverse reports of
    Stepped i _ : _ -> i
    Idle why _ : _ -> "idle " <> why
    [] -> "none"

-- Cases ---------------------------------------------------------------------------------------------

failedThenFixed :: Assertion
failedThenFixed =
  withFx $ \fx -> do
    (task, tx) <- begin fx "failed-then-fixed"
    engine <- engineWith fx [wrong, fixes] [review "approve"]
    steps fx engine tx 8 >>= (@?= "verification-failed")
    first <- fixing fx task
    has first ["Not every check passed on the latest change."]
    steps fx engine tx 1 >>= (@?= "implemented")
    second <- fixing fx task
    has second ["id=\"fix-earlier\"", "The checks have not run on the latest change yet."]
    lacks second ["Not every check passed", "Every check passed"]
    steps fx engine tx 1 >>= (@?= "verification-passed")
    passed <- fixing fx task
    has passed ["Every check passed on the latest change.", "id=\"fix-earlier\""]
    lacks passed ["committed change", "committed it"]
    steps fx engine tx 3 >>= (@?= "commit-accepted")
    committed <- fixing fx task
    has committed ["Every check passed on the committed change."]

rejectedThenApproved :: Assertion
rejectedThenApproved =
  withFx $ \fx -> do
    (task, tx) <- begin fx "rejected-then-approved"
    engine <- engineWith fx [fixes, fixes] [review "reject", review "approve"]
    steps fx engine tx 10 >>= (@?= "review-rejected")
    first <- fixing fx task
    has first ["The reviewer rejected the change."]
    steps fx engine tx 1 >>= (@?= "implemented")
    second <- fixing fx task
    has second ["id=\"fix-earlier\"", "Not reviewed yet.", "The checks have not run on the latest change yet."]
    lacks second ["The reviewer rejected the change.", "Every check passed"]
    steps fx engine tx 4 >>= (@?= "commit-accepted")
    final <- fixing fx task
    has final ["The reviewer approved the change.", "Every check passed on the committed change."]
    lacks final ["The reviewer rejected the change."]
