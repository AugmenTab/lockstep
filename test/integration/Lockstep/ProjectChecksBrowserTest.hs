{-# LANGUAGE OverloadedStrings #-}

{- | Choosing how a project's work is checked in a real browser (contract
C-P3.7 L7): headless Chromium through the frozen @test/browser/app_driver.py@,
the real service against a migrated real PostgreSQL database with
@LOCKSTEP_PROJECT_FOLDERS@ naming a temporary folder, sign-in tokens from the
real CLI. The form is used with the keyboard only.
-}
module Lockstep.ProjectChecksBrowserTest
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
    "how work is checked in a real browser (C-P3.7)"
    [ testCase "a project in a new folder → How work is checked → Always-on rules only → Save with the keyboard → kept after a reload" $ do
        admin <- requireAdmin
        withFreshDatabase admin $ \db ->
          withSystemTempDirectory "lockstep-p37-browser" $ \dir -> do
            config <- writeConfigFile dir admin db (adminPassword admin)
            createDirectory (dir <> "/projects")
            let
              env = [("LOCKSTEP_CONFIG", config), ("LOCKSTEP_PROJECT_FOLDERS", dir <> "/projects")]
              app port = "http://127.0.0.1:" <> show port
            (code, _, err) <- runLockstep env ["db", "migrate"]
            assertBool ("db migrate failed: " <> err) (code == ExitSuccess)
            port <- freePort
            (observed, _) <-
              withService env port (dir <> "/serve.log") $ do
                token <- signInToken env port
                runDriver (journey (app port) token)
            let
              value key = fromMaybe "<missing>" (L.lookup key observed)
              failures =
                [ key <> ": expected " <> show expected <> ", got " <> show (value key)
                | (key, expected) <-
                    [ ("done", "ok")
                    , ("home.found", "yes")
                    , ("projectform.found", "yes")
                    , ("project.found", "yes")
                    , ("checks.found", "yes")
                    , ("checkspath.value", "true")
                    , ("saved.found", "yes")
                    , ("reloaded.found", "yes")
                    , ("fresh.value", "true")
                    , ("kept.value", "\"lockstep-basic\"")
                    , ("checked.value", "true")
                    ]
                , value key /= expected
                ]
            assertBool ("the journey:\n" <> L.unlines failures) (L.null failures)
            counts <- traverse (\t -> queryInts admin db ("SELECT count(*)::integer AS v FROM " <> t)) ["lockstep_repository_profiles", "lockstep_work_orders", "lockstep_schedule_decisions"]
            counts @?= [[1], [0], [0]]
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

sleep' :: Int -> String
sleep' seconds =
  step [("op", str "sleep"), ("seconds", show seconds)]

journey :: String -> String -> String
journey app token =
  "["
    <> L.intercalate
      ","
      [ open' "landing" (app <> "/app/sign-in#" <> token)
      , wait' "home" "What needs your attention"
      , open' "projectpage" (app <> "/app/projects/new")
      , wait' "projectform" "What should it achieve"
      , type' "#project-name" "Website"
      , click' "newfolder" "#folder-new"
      , click' "createproject" "#create-project"
      , wait' "project" "How work is checked"
      , click' "openchecks" "#project-checks"
      , wait' "checks" "No choice on this page can turn them off"
      , eval' "checkspath" "/^\\/app\\/projects\\/[0-9a-f-]{36}\\/checks$/.test(location.pathname)"
      , eval' "focuschoice" "(function(){document.querySelector('#choice-lockstep-basic').focus();return true;})()"
      , key' "Space"
      , eval' "focussave" "(function(){document.querySelector('#save-checks').focus();return true;})()"
      , key' "Enter"
      , wait' "saved" "Saved."
      , eval' "mark" "(function(){window.lockstepBeforeReload = true;return true;})()"
      , eval' "reload" "(function(){location.reload();return true;})()"
      , sleep' 2
      , wait' "reloaded" "No choice on this page can turn them off"
      , eval' "fresh" "window.lockstepBeforeReload === undefined"
      , eval' "kept" "document.querySelector('input[name=\"expected\"]').value"
      , eval' "checked" "document.querySelector('#choice-lockstep-basic').checked"
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
