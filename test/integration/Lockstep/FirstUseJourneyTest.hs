{-# LANGUAGE OverloadedStrings #-}

{- | A first-time person's whole journey in a real browser (contract C-P3.10
O1–O4): headless Chromium through the frozen @test/browser/app_driver.py@, the
real service against a migrated real PostgreSQL database with
@LOCKSTEP_PROJECT_FOLDERS@ naming a temporary folder, a sign-in token from the
real CLI. Only clicks, typing and keys; on every page an accessibility sweep;
then every page again at phone width.
-}
module Lockstep.FirstUseJourneyTest
  ( tests
  ) where

import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Flipstone.Prelude
import System.Directory (createDirectory)
import System.Exit (ExitCode (ExitSuccess))
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
    "a first-use journey through every section (C-P3.10)"
    [ testCase "keyboard and mouse through projects, a task, checks, decisions and activity; labels and one heading everywhere; nothing scrolls sideways on a phone" $ do
        admin <- requireAdmin
        withFreshDatabase admin $ \db ->
          withSystemTempDirectory "lockstep-p310" $ \dir -> do
            config <- writeConfigFile dir admin db (adminPassword admin)
            createDirectory (dir <> "/projects")
            let
              env = [("LOCKSTEP_CONFIG", config), ("LOCKSTEP_PROJECT_FOLDERS", dir <> "/projects")]
            (code, _, err) <- runLockstep env ["db", "migrate"]
            assertBool ("db migrate failed: " <> err) (code == ExitSuccess)
            port <- freePort
            (observed, _) <-
              withService env port (dir <> "/serve.log") $ do
                token <- signInToken env port
                runDriver (journey ("http://127.0.0.1:" <> show port) token)
            let
              value key = fromMaybe "<missing>" (L.lookup key observed)
              expectations =
                [("done", "ok")]
                  <> [(w <> ".found", "yes") | w <- waits]
                  <> [(c <> ".value", "true") | c <- sweeps <> narrows]
              failures =
                [ key <> ": expected " <> show expected <> ", got " <> show (value key)
                | (key, expected) <- expectations
                , value key /= expected
                ]
            assertBool ("the journey:\n" <> L.unlines failures) (L.null failures)
            counts <- traverse (\t -> queryInts admin db ("SELECT count(*)::integer AS v FROM " <> t)) ["lockstep_projects", "lockstep_tickets", "lockstep_work_orders", "lockstep_schedule_decisions"]
            counts @?= [[2], [1], [0], [0]]
    ]

-- | The pages waited for, the accessibility sweeps and the phone-width checks, by label.
waits :: [String]
waits =
  ["home", "projects", "projectform", "project", "taskform", "task", "ready", "projectagain", "checks", "saved", "decisions", "activity", "projects2", "projectform2", "later", "narrowhome", "narrowprojects", "narrowproject", "narrowchecks", "narrowtasks", "narrowtask", "narrowdecisions", "narrowactivity", "narrowsettings", "narrowadvanced"]

sweeps :: [String]
sweeps =
  ["a11yhome", "a11yprojects", "truewords", "a11yprojectform", "a11yproject", "a11ytaskform", "a11ytask", "a11ychecks", "a11ydecisions", "a11yactivity", "a11ylater"]

narrows :: [String]
narrows =
  ["widehome", "wideprojects", "wideproject", "widechecks", "widetasks", "widetask", "widedecisions", "wideactivity", "widesettings", "wideadvanced"]

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

focus' :: String -> String -> String
focus' label selector =
  eval' label ("(function(){document.querySelector('" <> selector <> "').focus();return true;})()")

-- | Every visible control in the section has a label, and the section has one main heading.
sweep :: String -> String
sweep label =
  eval'
    label
    "(function(){var bad=0;document.querySelectorAll('#content input, #content select, #content textarea').forEach(function(el){if(el.type==='hidden'){return;}var named=el.getAttribute('aria-label')||(el.id&&document.querySelector('label[for=\"'+el.id+'\"]'));if(!named){bad+=1;}});return bad===0&&document.querySelectorAll('#content h1').length===1;})()"

wide :: String -> String
wide label =
  eval' label "document.documentElement.scrollWidth <= window.innerWidth"

nav :: String -> String -> String
nav label section =
  click' label ("nav a[href=\"/app/" <> section <> "\"]")

journey :: String -> String -> String
journey app token =
  "["
    <> L.intercalate
      ","
      [ open' "landing" (app <> "/app/sign-in#" <> token)
      , wait' "home" "What needs your attention"
      , sweep "a11yhome"
      , focus' "focusnav" "nav a"
      , key' "Tab"
      , key' "Enter"
      , wait' "projects" "A project is something you want to achieve"
      , sweep "a11yprojects"
      , eval' "truewords" "document.querySelector('#content').textContent.indexOf('Tasks inside a project arrive') < 0 && document.querySelector('#content').textContent.indexOf('later update') >= 0"
      , click' "newproject" "#new-project"
      , wait' "projectform" "What should it achieve"
      , sweep "a11yprojectform"
      , type' "#project-name" "My first project"
      , type' "#project-outcome" "Try Lockstep out"
      , focus' "focuscreate" "#create-project"
      , key' "Enter"
      , wait' "project" "New task"
      , sweep "a11yproject"
      , click' "newtask" "#new-task"
      , wait' "taskform" "What needs doing"
      , sweep "a11ytaskform"
      , type' "#task-title" "Write the welcome page"
      , focus' "focusaddtask" "#create-task"
      , key' "Enter"
      , wait' "task" "Not yet ready to work on."
      , sweep "a11ytask"
      , click' "markready" "#task-ready"
      , wait' "ready" "Ready to work on."
      , click' "back" "#back-to-project"
      , wait' "projectagain" "See or change how work is checked"
      , click' "openchecks" "#project-checks"
      , wait' "checks" "No choice on this page can turn them off"
      , sweep "a11ychecks"
      , focus' "focussave" "#save-checks"
      , key' "Enter"
      , wait' "saved" "Saved."
      , nav "navdecisions" "decisions"
      , wait' "decisions" "Nothing needs your decision right now."
      , sweep "a11ydecisions"
      , nav "navactivity" "activity"
      , wait' "activity" "Nothing has happened yet."
      , sweep "a11yactivity"
      , nav "navprojects" "projects"
      , wait' "projects2" "A project is something you want to achieve"
      , click' "newproject2" "#new-project"
      , wait' "projectform2" "What should it achieve"
      , type' "#project-name" "Later project"
      , click' "decidelater" "#folder-later"
      , click' "createlater" "#create-project"
      , wait' "later" "Connect a folder"
      , sweep "a11ylater"
      , step [("op", str "viewport"), ("width", "390"), ("height", "800")]
      , step [("op", str "sleep"), ("seconds", "1")]
      , nav "phonehome" "home"
      , wait' "narrowhome" "What needs your attention"
      , wide "widehome"
      , nav "phoneprojects" "projects"
      , wait' "narrowprojects" "A project is something you want to achieve"
      , wide "wideprojects"
      , click' "phoneproject" ".ls-projects a"
      , wait' "narrowproject" "How work is checked"
      , wide "wideproject"
      , click' "phonechecks" "#project-checks"
      , wait' "narrowchecks" "No choice on this page can turn them off"
      , wide "widechecks"
      , nav "phonetasks" "tasks"
      , wait' "narrowtasks" "Write the welcome page"
      , wide "widetasks"
      , click' "phonetask" ".ls-projects a[href^=\"/app/tasks/\"]"
      , wait' "narrowtask" "What done looks like"
      , wide "widetask"
      , nav "phonedecisions" "decisions"
      , wait' "narrowdecisions" "Nothing needs your decision right now."
      , wide "widedecisions"
      , nav "phoneactivity" "activity"
      , wait' "narrowactivity" "Nothing has happened yet."
      , wide "wideactivity"
      , nav "phonesettings" "settings"
      , wait' "narrowsettings" "How work is checked"
      , wide "widesettings"
      , nav "phoneadvanced" "advanced"
      , wait' "narrowadvanced" "Schema revision"
      , wide "wideadvanced"
      ]
    <> "]"

runDriver :: String -> IO [(String, String)]
runDriver input = do
  result <-
    timeout 400000000 $
      Process.readCreateProcessWithExitCode (Process.proc "python3" ["test/browser/app_driver.py"]) input
  case result of
    Nothing -> assertFailure "the browser driver did not finish within 400 s"
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
