{-# LANGUAGE OverloadedStrings #-}

{- | Attribute escaping in a real browser (contract C-C.R1 R8): headless
Chromium through the frozen @test/browser/app_driver.py@, the real service on a
'Lockstep.Support.Ledger.withLedger' database, a task made in this process with
a title written to look like markup.
-}
module Lockstep.GateCRemediationBrowserTest
  ( tests
  ) where

import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import System.Exit (ExitCode (ExitSuccess))
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Command (mkIdempotencyKey)
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks (NewTask (..), TaskView (..), createTask)
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Support.Ledger (Ledger (..), withLedger)
import Lockstep.Support.Process (freePort, runLockstep, withService)

hostile :: T.Text
hostile =
  "\" autofocus onfocus=alert(1) x=\""

tests :: TestTree
tests =
  testGroup
    "attribute escaping in a real browser (C-C.R1 R8)"
    [ testCase "a task titled like markup: no injected attribute, and the title field holds the exact text" $
        withLedger $ \lg -> do
          pk <- either (const (assertFailure "key")) pure (mkIdempotencyKey "test-remedy-browser-project")
          tk <- either (const (assertFailure "key")) pure (mkIdempotencyKey "test-remedy-browser-task-1")
          madeProject <- createProject (lgRuntime lg) (ProjectFolders Nothing []) (NewProject pk "Kitchen" "" DecideLater)
          p <- either (\e -> assertFailure ("project: " <> show e)) (either (assertFailure . T.unpack) pure) madeProject
          madeTask <- createTask (lgRuntime lg) (NewTask tk (projectId p) hostile "" Normal [])
          t <- either (\e -> assertFailure ("task: " <> show e)) (either (assertFailure . T.unpack) pure) madeTask
          port <- freePort
          (observed, _) <-
            withService (lgEnv lg) port (lgDir lg <> "/serve.log") $ do
              token <- signInToken (lgEnv lg) port
              runDriver (journey ("http://127.0.0.1:" <> show port) token (T.unpack (taskId t)))
          let
            value key = fromMaybe "<missing>" (L.lookup key observed)
            failures =
              [ key <> ": expected " <> show expected <> ", got " <> show (value key)
              | (key, expected) <- [("done", "ok"), ("home.found", "yes"), ("task.found", "yes"), ("injected.value", "0"), ("exact.value", "true"), ("focused.value", "false")]
              , value key /= expected
              ]
          assertBool ("in the browser:\n" <> L.unlines failures) (L.null failures)
    ]

signInToken :: [(String, String)] -> Int -> IO String
signInToken env port = do
  (code, out, err) <- runLockstep env ["operator", "sign-in", "--port", show port]
  code @?= ExitSuccess
  case L.stripPrefix "=" (L.dropWhile (/= '=') (L.filter (/= '\n') out)) of
    Just t | L.length t == 43 -> pure t
    _ -> assertFailure ("unexpected sign-in output: " <> out <> err)

journey :: String -> String -> String -> String
journey app token tid =
  "["
    <> L.intercalate
      ","
      [ step [("op", str "open"), ("label", str "landing"), ("url", str (app <> "/app/sign-in#" <> token))]
      , step [("op", str "wait_text"), ("label", str "home"), ("text", str "What needs your attention"), ("timeout", "60")]
      , step [("op", str "open"), ("label", str "taskpage"), ("url", str (app <> "/app/tasks/" <> tid))]
      , step [("op", str "wait_text"), ("label", str "task"), ("text", str "Change it"), ("timeout", "60")]
      , step [("op", str "eval"), ("label", str "injected"), ("expression", str "document.querySelectorAll('[onfocus],[autofocus]').length")]
      , step [("op", str "eval"), ("label", str "exact"), ("expression", str ("document.querySelector('#task-title').value === " <> jsString (T.unpack hostile)))]
      , step [("op", str "eval"), ("label", str "focused"), ("expression", str "document.activeElement !== null && document.activeElement.id === 'task-title'")]
      ]
    <> "]"

step :: [(String, String)] -> String
step fields =
  "{" <> L.intercalate "," [str k <> ":" <> v | (k, v) <- fields] <> "}"

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

-- | A JavaScript string literal in single quotes.
jsString :: String -> String
jsString s =
  "'" <> L.concatMap escape s <> "'"
 where
  escape c =
    case c of
      '\'' -> "\\'"
      '\\' -> "\\\\"
      _ -> [c]

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
