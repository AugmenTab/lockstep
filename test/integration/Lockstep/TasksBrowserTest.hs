{-# LANGUAGE OverloadedStrings #-}

{- | Tasks in a real browser across a service restart (contract C-P3.6):
headless Chromium through the frozen @test/browser/app_driver.py@, the real
service against a migrated real PostgreSQL database, sign-in tokens from the
real CLI. The service is stopped and started again between the two halves.
-}
module Lockstep.TasksBrowserTest
  ( tests
  ) where

import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Flipstone.Prelude
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath)
import System.IO.Temp (withSystemTempDirectory)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Support.Postgres (AdminSettings (..), queryInts, requireAdmin, withFreshDatabase, writeConfigFile)
import Lockstep.Support.Process (freePort, runLockstep, withService)

tests :: TestTree
tests =
  testGroup
    "tasks in a real browser across a restart (C-P3.6)"
    [ testCase "a project, two tasks, a dependency, ready, a blocked high-priority task, a restart, the same words; a keyboard-only form" $ do
        admin <- requireAdmin
        withFreshDatabase admin $ \db ->
          withSystemTempDirectory "lockstep-p36-browser" $ \dir -> do
            config <- writeConfigFile dir admin db (adminPassword admin)
            let
              env = [("LOCKSTEP_CONFIG", config)]
              app port = "http://127.0.0.1:" <> show port
            (code, _, err) <- runLockstep env ["db", "migrate"]
            assertBool ("db migrate failed: " <> err) (code == ExitSuccess)
            port <- freePort
            (first, _) <-
              withService env port (dir <> "/serve-1.log") $ do
                token <- signInToken env port
                runDriver (firstHalf (app port) token)
            let
              value observed key = fromMaybe "<missing>" (L.lookup key observed)
              check observed expectations =
                [ key <> ": expected " <> show expected <> ", got " <> show (value observed key)
                | (key, expected) <- expectations
                , value observed key /= expected
                ]
              firstFailures =
                check
                  first
                  [ ("done", "ok")
                  , ("home.found", "yes")
                  , ("projectform.found", "yes")
                  , ("project.found", "yes")
                  , ("taskform.found", "yes")
                  , ("created.found", "yes")
                  , ("marked.found", "yes")
                  , ("taskform2.found", "yes")
                  , ("created2.found", "yes")
                  , ("waiting.found", "yes")
                  , ("blocked.found", "yes")
                  , ("summary.found", "yes")
                  ]
            assertBool ("before the restart:\n" <> L.unlines firstFailures) (L.null firstFailures)
            projectUrl <-
              case L.stripPrefix "\"" (value first "projecturl.value") of
                Just rest -> pure (L.takeWhile (/= '"') rest)
                Nothing -> assertFailure ("no project address: " <> value first "projecturl.value")
            (second, _) <-
              withService env port (dir <> "/serve-2.log") $ do
                token <- signInToken env port
                runDriver (secondHalf (app port) token projectUrl)
            let
              secondFailures =
                check
                  second
                  [ ("done", "ok")
                  , ("home.found", "yes")
                  , ("after.found", "yes")
                  , ("stillblocked.found", "yes")
                  , ("stillwaiting.value", "true")
                  , ("taskform.found", "yes")
                  , ("bykeyboard.found", "yes")
                  ]
            assertBool ("after the restart:\n" <> L.unlines secondFailures) (L.null secondFailures)
            counts <- traverse (\t -> queryInts admin db ("SELECT count(*)::integer AS v FROM " <> t)) ["lockstep_tickets", "lockstep_work_orders", "lockstep_schedule_decisions"]
            counts @?= [[3], [0], [0]]
    ]

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

key' :: String -> String
key' k =
  step [("op", str "key"), ("key", str k)]

firstHalf :: String -> String -> String
firstHalf app token =
  "["
    <> L.intercalate
      ","
      [ open' "landing" (app <> "/app/sign-in#" <> token)
      , wait' "home" "What needs your attention"
      , open' "projectpage" (app <> "/app/projects/new")
      , wait' "projectform" "What should it achieve"
      , type' "#project-name" "Kitchen"
      , click' "later" "#folder-later"
      , click' "createproject" "#create-project"
      , wait' "project" "New task"
      , eval' "projecturl" "location.pathname"
      , click' "newtask" "#new-task"
      , wait' "taskform" "What needs doing"
      , type' "#task-title" "Buy paper"
      , click' "low" "#priority-low"
      , click' "createtask" "#create-task"
      , wait' "created" "Not yet ready to work on."
      , click' "markready" "#task-ready"
      , wait' "marked" "Ready to work on."
      , click' "back" "#back-to-project"
      , wait' "projectagain" "New task"
      , click' "newtask2" "#new-task"
      , wait' "taskform2" "What needs doing"
      , type' "#task-title" "Print the menu"
      , click' "high" "#priority-high"
      , click' "depends" "input[name=\"depends_on\"]"
      , click' "createtask2" "#create-task"
      , wait' "created2" "Not yet ready to work on."
      , click' "markready2" "#task-ready"
      , wait' "waiting" "Waiting for: Buy paper"
      , type' "#block-reason" "the printer is out of ink"
      , click' "block" "#task-block"
      , wait' "blocked" "Blocked: the printer is out of ink"
      , click' "back2" "#back-to-project"
      , wait' "summary" "Most important task ready to work on: Buy paper"
      ]
    <> "]"

secondHalf :: String -> String -> FilePath -> String
secondHalf app token projectPath =
  "["
    <> L.intercalate
      ","
      [ open' "landing" (app <> "/app/sign-in#" <> token)
      , wait' "home" "What needs your attention"
      , open' "projectpage" (app <> projectPath)
      , wait' "after" "Most important task ready to work on: Buy paper"
      , wait' "stillblocked" "Blocked: the printer is out of ink"
      , eval' "stillwaiting" "document.body.textContent.indexOf('Print the menu') >= 0"
      , click' "newtask" "#new-task"
      , wait' "taskform" "What needs doing"
      , eval' "focus" "(function(){document.querySelector('#task-title').focus();return true;})()"
      , type' "#task-title" "Wash up"
      , key' "Enter"
      , wait' "bykeyboard" "Wash up"
      ]
    <> "]"

runDriver :: String -> IO [(String, String)]
runDriver input = do
  result <-
    timeout 300000000 $
      Process.readCreateProcessWithExitCode (Process.proc "python3" ["test/browser/app_driver.py"]) input
  case result of
    Nothing -> assertFailure "the browser driver did not finish within 300 s"
    Just (_, out, err) -> do
      let
        pairs =
          [ (k, L.drop 1 v)
          | line <- L.lines out
          , let
              (k, v) = L.break (== '\t') line
          ]
      case L.lookup "error" pairs of
        Just message -> assertFailure ("browser driver error: " <> message <> "\n" <> err)
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
