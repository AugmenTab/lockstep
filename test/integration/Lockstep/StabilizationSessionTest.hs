{-# LANGUAGE OverloadedStrings #-}

{- | Stabilization S4 (post-Phase-5 handoff §5): when the application's sign-in
ends, the page says nothing was decided or lost and remembers where the
operator was; the next sign-in in that browser returns there, once, and only
to an address the application itself routes. Headless Chromium through the
frozen @test/browser/app_driver.py@, the real service against a migrated real
PostgreSQL database, sign-in tokens from the real CLI. The ending is the
service refusing the browser's session (401), as for an expired one.
-}
module Lockstep.StabilizationSessionTest
  ( tests
  ) where

import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Flipstone.Prelude
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
    "S4 an ended sign-in loses nothing and the next one returns to the same page (real browser, service, PostgreSQL)"
    [ testCase "the project page, the sign-in refused, a new sign-in: back on the same project; a foreign address is never followed" $ do
        admin <- requireAdmin
        withFreshDatabase admin $ \db ->
          withSystemTempDirectory "lockstep-stab-s4" $ \dir -> do
            config <- writeConfigFile dir admin db (adminPassword admin)
            let
              env = [("LOCKSTEP_CONFIG", config)]
              app port = "http://127.0.0.1:" <> show port
            (code, _, err) <- runLockstep env ["db", "migrate"]
            assertBool ("db migrate failed: " <> err) (code == ExitSuccess)
            port <- freePort
            (observed, _) <-
              withService env port (dir <> "/serve.log") $ do
                first <- signInToken env port
                second <- signInToken env port
                third <- signInToken env port
                runDriver (journey (app port) first second third)
            let
              value key = fromMaybe "<missing>" (L.lookup key observed)
              failures =
                [ key <> ": expected " <> show expected <> ", got " <> show (value key)
                | (key, expected) <- [("done", "ok"), ("home.found", "yes"), ("project.found", "yes"), ("ended.found", "yes"), ("nothinglost.found", "yes"), ("back.found", "yes"), ("forgotten.value", "null"), ("foreign.found", "yes")]
                , value key /= expected
                ]
            assertBool ("the journey:\n" <> L.unlines failures) (L.null failures)
            value "backpath.value" @?= value "projecturl.value"
            value "foreignpath.value" @?= "\"/app/home\""
            -- The project made before the sign-in ended is still there, once.
            projects <- queryInts admin db "SELECT count(*)::integer AS v FROM lockstep_projects"
            projects @?= [1]
    ]

signInToken :: [(String, String)] -> Int -> IO String
signInToken env port = do
  (code, out, err) <- runLockstep env ["operator", "sign-in", "--port", show port]
  code @?= ExitSuccess
  case L.stripPrefix "=" (L.dropWhile (/= '=') (L.filter (/= '\n') out)) of
    Just t | L.length t == 43 -> pure t
    _ -> assertFailure ("unexpected sign-in output: " <> out <> err)

journey :: String -> String -> String -> String -> String
journey app first second third =
  "["
    <> L.intercalate
      ","
      [ open' "landing" (app <> "/app/sign-in#" <> first)
      , wait' "home" "What needs your attention"
      , open' "projectpage" (app <> "/app/projects/new")
      , wait' "projectform" "What should it achieve"
      , type' "#project-name" "Kitchen"
      , click' "later" "#folder-later"
      , click' "createproject" "#create-project"
      , wait' "project" "New task"
      , eval' "projecturl" "location.pathname"
      , -- The service no longer accepts this browser's session (as when it expires), then the page is opened again.
        eval' "spoil" "(function(){localStorage.setItem('lockstep.app.session','A'.repeat(43));return true;})()"
      , eval' "reload" "(function(){location.reload();return true;})()"
      , wait' "ended" "Your sign-in has ended."
      , wait' "nothinglost" "every decision waiting for you is still waiting"
      , open' "again" (app <> "/app/sign-in#" <> second)
      , wait' "back" "New task"
      , eval' "backpath" "location.pathname"
      , eval' "forgotten" "localStorage.getItem('lockstep.app.return')"
      , -- An address this application does not route is never followed.
        eval' "foreignset" "(function(){localStorage.setItem('lockstep.app.return','//evil.example/app/home');return true;})()"
      , open' "third" (app <> "/app/sign-in#" <> third)
      , wait' "foreign" "What needs your attention"
      , eval' "foreignpath" "location.pathname"
      ]
    <> "]"

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
