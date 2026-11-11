{-# LANGUAGE OverloadedStrings #-}

{- | P5.11: the full transaction end to end with real capsule execution
(contract C-P5.11; Phase 5 update 1 §5). The journey of Gate C-EXEC
(@test/integration/Lockstep/EndToEndTest.hs@, unchanged in what the person does
and sees): in a real browser, against the real service and a migrated real
PostgreSQL, a person makes a project, lets Lockstep fix bugs, writes a bug,
hands it over, deals with the stop on an uncommitted change, and marks the
committed fix done. The difference: the engine's runner is the host helper's
runner channel (@LOCKSTEP_RUNNER_DIR@), served by the real helper on the Mac in
capsule mode (given to this test as @LOCKSTEP_E2E_RUNNER_DIR@, so the service it
starts runs no second worker), so every role (scripted, model-free), every proof step and every
verification runs in real Lima VMs: the Engineer's capsule and the separate,
snapshot-restored verification capsule. Run by @scripts/lib/check-capsule-e2e@,
which starts that helper and checks its side of the record.
-}
module Main
  ( main
  ) where

import Data.ByteString qualified as BS
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import System.Directory (createDirectory, listDirectory, removeFile)
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath, writeFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Engine (Engine (..))
import Lockstep.Application.EngineWorker (startEngineWorker, stopEngineWorker)
import Lockstep.Effects.HelperRunner (openRunnerChannel)
import Lockstep.Effects.Roles (Adapter, helperRunner, scriptedAdapter)
import Lockstep.Kernel.Roles (Role (..))
import Lockstep.Support.Postgres (AdminSettings (..), databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime, writeConfigFile)
import Lockstep.Support.Process (freePort, runLockstep, withService)

main :: IO ()
main =
  defaultMain tests

tests :: TestTree
tests =
  testGroup
    "C-P5.11 the full transaction through the real service, with every run in real Dev Capsules (scripted roles, no provider)"
    [ testCase "make a project, allow, write and hand over a bug; stop on an uncommitted change; retry; committed after checks, challenge and review run in the capsules; Done" endToEnd
    ]

endToEnd :: IO ()
endToEnd = do
  -- Its own variable, not LOCKSTEP_RUNNER_DIR: the service this test starts must not run a second engine
  -- worker on the same channel (it would take steps with no roles configured).
  runnerDir <- lookupEnv "LOCKSTEP_E2E_RUNNER_DIR" >>= maybe (assertFailure "NOT_RUN: no LOCKSTEP_E2E_RUNNER_DIR (run scripts/lib/check-capsule-e2e)") pure
  channel <- openRunnerChannel runnerDir >>= either (\code -> assertFailure ("the runner channel: " <> T.unpack code)) pure
  capsuleOn <- BS.readFile (runnerDir <> "/capsule")
  assertBool "the helper is in capsule mode" ("lockstep-capsule 1 " `BS.isPrefixOf` capsuleOn)
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-p511" $ \dir -> do
      config <- writeConfigFile dir admin db (adminPassword admin)
      createDirectory (dir <> "/projects")
      let
        env = [("LOCKSTEP_CONFIG", config), ("LOCKSTEP_PROJECT_FOLDERS", dir <> "/projects")]
        app port = "http://127.0.0.1:" <> show port
        count = queryInts admin db
      (code, _, err) <- runLockstep env ["db", "migrate"]
      assertBool ("db migrate failed: " <> err) (code == ExitSuccess)
      dbConfig <- databaseConfigFor admin db
      port <- freePort
      _ <-
        withService env port (dir <> "/serve.log") $ do
          token1 <- signInToken env port
          first <- runDriver (setUp (app port) token1)
          expect first [("done", "ok"), ("allowed.found", "yes"), ("readytask.found", "yes")]
          taskPath <- maybe (assertFailure ("no task address: " <> show first)) (pure . L.filter (/= '"')) (L.lookup "taskpath.value" first)
          folders <- listDirectory (dir <> "/projects")
          folder <-
            case folders of
              [f] -> pure (dir <> "/projects/" <> f)
              other -> assertFailure ("project folders: " <> show other)
          writeFile (folder <> "/calc.py") "def add(a, b):\n    return a - b\n"
          gitIn folder ["add", "calc.py"]
          gitIn folder ["commit", "-q", "-m", "calc"]
          mainBefore <- gitOut folder ["rev-parse", "refs/heads/main"]
          writeFile (folder <> "/notes.txt") "my own notes, not committed\n"
          withRuntime dbConfig $ \runtime -> do
            -- The engine: the helper's runner channel (capsule mode) and the scripted, model-free roles.
            worker <- startEngineWorker runtime (Engine (helperRunner channel) scriptedRoles) 500 (const (pure ()))
            token2 <- signInToken env port
            second <- runDriver (handOver (app port) token2 taskPath)
            expect second [("done", "ok"), ("handed.found", "yes")]
            asked <- pollTask env port taskPath 24 "asked" "needs your decision" [wait' "words" "has changes that are not committed"]
            expect asked [("done", "ok"), ("asked.found", "yes"), ("words.found", "yes")]
            removeFile (folder <> "/notes.txt")
            token3 <- signInToken env port
            third <- runDriver (finish (app port) token3 taskPath)
            expect third [("done", "ok"), ("recorded.found", "yes")]
            fourth <- pollTask env port taskPath 120 "committed" "Only you decide whether this bug is fixed." decide
            stopEngineWorker worker
            expect
              fourth
              [ ("done", "ok")
              , ("committed.found", "yes")
              , ("checks.found", "yes")
              , ("review.found", "yes")
              , ("marked.found", "yes")
              , ("reloaded.found", "yes")
              ]
          count "SELECT count(*)::integer AS v FROM lockstep_transactions WHERE state = 'done'" >>= (@?= [1])
          count "SELECT count(*)::integer AS v FROM lockstep_transaction_records WHERE kind = 'completion' AND principal = 'human'" >>= (@?= [1])
          count "SELECT count(*)::integer AS v FROM lockstep_invocations WHERE outcome IS NULL" >>= (@?= [0])
          mainAfter <- gitOut folder ["rev-parse", "refs/heads/main"]
          mainAfter @?= mainBefore
          branches <- gitOut folder ["for-each-ref", "--format=%(refname)", "refs/heads/lockstep/"]
          case L.lines branches of
            [branch] -> do
              fixedCalc <- gitOut folder ["show", branch <> ":calc.py"]
              fixedCalc @?= "def add(a, b):\n    return a + b\n"
              testFile <- gitOut folder ["show", branch <> ":test_calc.py"]
              assertBool "the frozen test is on the branch" ("add is wrong" `L.isInfixOf` testFile)
              author <- gitOut folder ["log", "-1", "--format=%an", branch]
              assertBool ("committed by Lockstep: " <> author) ("Lockstep" `L.isInfixOf` author)
            other -> assertFailure ("work branches: " <> show other)
          remotes <- gitOut folder ["remote"]
          remotes @?= ""
          workTree <- gitOut folder ["status", "--porcelain"]
          workTree @?= ""
      pure ()

expect :: [(String, String)] -> [(String, String)] -> IO ()
expect observed expected =
  let
    value key = fromMaybe "<missing>" (L.lookup key observed)
    failures = [key <> ": expected " <> show want <> ", got " <> show (value key) | (key, want) <- expected, value key /= want]
  in
    assertBool ("the journey:\n" <> L.unlines failures <> "\nall: " <> show observed) (L.null failures)

-- The scripted roles (as Gate C-EXEC's), run by the helper in the capsules ---------------------

scriptedRoles :: Role -> Int -> Maybe Adapter
scriptedRoles role =
  case role of
    Planner -> pick [discovery, candidate]
    Challenger -> pick [noFindings, noFindings]
    Implementer -> pick [fixes]
    Reviewer -> pick [approve]
 where
  pick answers n =
    scriptedAdapter "scripts/runner/scripted-role" . script <$> L.lookup n (L.zip [0 ..] answers)

script :: T.Text -> BS.ByteString
script steps =
  TE.encodeUtf8 ("{\"steps\":[" <> steps <> "]}")

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
    ( "{\"kind\":\"candidate\",\"criteria\":[{\"id\":\"add-adds\",\"text\":\"add returns the sum of its two numbers\",\"ticket_quote\":\"add(2, 2) is 4\","
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
  "{\"write\":{\"path\":\"calc.py\",\"content\":" <> jsonString "def add(a, b):\n    return a + b\n" <> "}}," <> result "{\"kind\":\"implementation\",\"summary\":\"add now adds\"}"

approve :: T.Text
approve =
  result "{\"kind\":\"review\",\"verdict\":\"approve\",\"reasons\":[\"the one-line change makes add add\"]}"

-- Git --------------------------------------------------------------------------------------

gitOut :: FilePath -> [String] -> IO String
gitOut folder args = do
  base <- getEnvironment
  let
    identity = ["-c", "user.name=Person", "-c", "user.email=person@example.invalid", "-c", "init.defaultBranch=main"]
    env = ("GIT_CONFIG_NOSYSTEM", "1") : L.filter ((/= "GIT_CONFIG_NOSYSTEM") . fst) base
  finished <-
    timeout 30000000 $
      Process.readCreateProcessWithExitCode ((Process.proc "git" (identity <> args)) {Process.cwd = Just folder, Process.env = Just env}) ""
  case finished of
    Just (ExitSuccess, out, _) -> pure out
    other -> assertFailure ("git " <> show args <> ": " <> show other)

gitIn :: FilePath -> [String] -> IO ()
gitIn folder args =
  void (gitOut folder args)

-- The browser (the frozen driver), with waits that fit runs in VMs -----------------------------

signInToken :: [(String, String)] -> Int -> IO String
signInToken env port = do
  (code, out, err) <- runLockstep env ["operator", "sign-in", "--port", show port]
  code @?= ExitSuccess
  case L.stripPrefix "=" (L.dropWhile (/= '=') (L.filter (/= '\n') out)) of
    Just t | L.length t == 43 -> pure t
    _ -> assertFailure ("unexpected sign-in output: " <> out <> err)

step :: [(String, String)] -> String
step fields =
  "{" <> L.intercalate "," [str k <> ":" <> v | (k, v) <- fields] <> "}"

open' :: String -> String -> String
open' label url =
  step [("op", str "open"), ("label", str label), ("url", str url)]

wait' :: String -> String -> String
wait' label text =
  step [("op", str "wait_text"), ("label", str label), ("text", str text), ("timeout", "60")]

eval' :: String -> String -> String
eval' label expression =
  step [("op", str "eval"), ("label", str label), ("expression", str expression)]

click' :: String -> String -> String
click' label selector =
  step [("op", str "click"), ("label", str label), ("selector", str selector)]

type' :: String -> String -> String
type' selector text =
  step [("op", str "type"), ("selector", str selector), ("text", str text)]

sleep' :: Int -> String
sleep' seconds =
  step [("op", str "sleep"), ("seconds", show seconds)]

{- | Opens the task page afresh until TEXT shows: up to TRIES tries, each waiting
about 10 s (a VM-backed transaction takes minutes). It stops at the first try
that finds it (a fixed list of reloads always ran to its end), then runs REST in
a new browser on the task page. A try that never finds it returns that try's
observations, so the caller's check names what was missing.
-}
pollTask :: [(String, String)] -> Int -> String -> Int -> String -> String -> [String] -> IO [(String, String)]
pollTask env port taskPath tries label text rest =
  go 1
 where
  app = "http://127.0.0.1:" <> show port
  onTask token =
    [ open' "landing" (app <> "/app/sign-in#" <> token)
    , wait' "home" "What needs your attention"
    , open' "task" (app <> taskPath)
    , step [("op", str "wait_text"), ("label", str label), ("text", str text), ("timeout", "10")]
    ]
  go :: Int -> IO [(String, String)]
  go n = do
    token <- signInToken env port
    observed <- runDriver (journey (onTask token))
    if L.lookup (label <> ".found") observed == Just "yes"
      then do
        token' <- signInToken env port
        runDriver (journey (onTask token' <> rest))
      else
        if n >= tries
          then pure observed
          else go (n + 1)

journey :: [String] -> String
journey steps =
  "[" <> L.intercalate "," steps <> "]"

setUp :: String -> String -> String
setUp app token =
  journey
    [ open' "landing" (app <> "/app/sign-in#" <> token)
    , wait' "home" "What needs your attention"
    , open' "newproject" (app <> "/app/projects/new")
    , wait' "projectform" "What should it achieve"
    , type' "#project-name" "Calculator"
    , click' "newfolder" "#folder-new"
    , click' "createproject" "#create-project"
    , wait' "project" "Let Lockstep fix bugs here"
    , click' "allow" "#enable-execution"
    , wait' "allowed" "Lockstep may work on bugs in this project."
    , click' "newtask" "#new-task"
    , wait' "taskform" "What needs doing"
    , type' "#task-title" "add subtracts instead of adding"
    , type' "#task-acceptance" "add(2, 2) is 4"
    , click' "createtask" "#create-task"
    , wait' "task" "Mark as ready to work on"
    , click' "markready" "#task-ready"
    , wait' "readytask" "Ask Lockstep to fix this bug"
    , eval' "taskpath" "location.pathname"
    ]

handOver :: String -> String -> String -> String
handOver app token taskPath =
  journey
    [ open' "landing" (app <> "/app/sign-in#" <> token)
    , wait' "home" "What needs your attention"
    , open' "task" (app <> taskPath)
    , wait' "readytask" "Ask Lockstep to fix this bug"
    , click' "admit" "#admit-bug"
    , wait' "handed" "Fixing it"
    ]

finish :: String -> String -> String -> String
finish app token taskPath =
  journey
    [ open' "landing" (app <> "/app/sign-in#" <> token)
    , wait' "home" "What needs your attention"
    , open' "task" (app <> taskPath)
    , wait' "halted" "needs your decision"
    , click' "retry" "#halt-retry"
    , click' "answer" "#answer-halt"
    , wait' "recorded" "Fixing it"
    ]

-- | On the committed bug's page: the checks and the review shown, and the person marks it fixed.
decide :: [String]
decide =
  [ wait' "checks" "Every check passed on the committed change."
  , wait' "review" "The reviewer approved the change."
  , click' "yes" "#completion-done"
  , click' "decide" "#decide-completion"
  , wait' "marked" "You marked this bug fixed."
  , eval' "reload" "(function(){location.reload();return true;})()"
  , sleep' 2
  , wait' "reloaded" "You marked this bug fixed."
  ]

runDriver :: String -> IO [(String, String)]
runDriver input = do
  outcome <-
    timeout 2400000000 $
      Process.readCreateProcessWithExitCode (Process.proc "python3" ["test/browser/app_driver.py"]) input
  case outcome of
    Nothing -> assertFailure "the browser driver did not finish within 40 minutes"
    Just (_, out, err) -> do
      let
        pairs =
          [ (k, L.drop 1 v)
          | line <- L.lines out
          , let
              (k, v) = L.break (== '\t') line
          ]
      case L.lookup "error" pairs of
        Just message -> assertFailure ("browser driver error: " <> message <> "\n" <> err <> "\n" <> out)
        Nothing -> pure pairs

str :: String -> String
str s =
  "\"" <> L.concatMap escape s <> "\""
 where
  escape c =
    case c of
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\n' -> "\\n"
      _ -> [c]
