{-# LANGUAGE OverloadedStrings #-}

{- | Stop, start and restart from the control pane in a real browser (contract
C-P3.2 §4): headless Chromium (@test/browser/control_driver.py@), the real pane
and the real helper with stateful @docker@ and @curl@ stubs. Buttons are
pressed with real mouse events, except the deliberate double press, which is
two @click()@ calls in one script turn to prove the second is ignored.
-}
module Lockstep.LifecycleBrowserTest
  ( tests
  ) where

import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import System.IO (readFile)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Support.Control (issueSignIn, withPaneOn)
import Lockstep.Support.Lifecycle (lHelper, lPane, readStub, stubLog, withLifecycleEnv, withLifecycleHelper)

tests :: TestTree
tests =
  testGroup
    "control pane lifecycle in a real browser (C-P3.2)"
    [ testCase "the system view shows the state in words; Stop, Start and Restart change it; a double press is one operation" $
        withLifecycleEnv Nothing $ \env -> withLifecycleHelper env [] $ withPaneOn (lPane env) [] $ \port -> do
          token <- issueSignIn (lPane env) 300
          let
            base = "http://127.0.0.1:" <> show port
          observed <- runDriver (scenario (base <> "/sign-in#" <> T.unpack token))
          let
            value key = fromMaybe "<missing>" (L.lookup key observed)
            check ok message = [message | not ok]
            expect key expected = check (value key == expected) (key <> ": expected " <> show expected <> ", got " <> show (value key))
            has key needle = check (needle `L.isInfixOf` value key) (key <> " lacks " <> show needle <> ": " <> show (L.take 500 (value key)))
            failures =
              L.concat
                [ expect "done" "ok"
                , expect "running.found" "yes"
                , has "running.text" "Docker"
                , expect "stopped.found" "yes"
                , has "stopped.text" "Not running"
                , expect "started.found" "yes"
                , expect "afterstart.found" "yes"
                , expect "busy.value" "true"
                , expect "restarted.found" "yes"
                ]
          assertBool ("browser expectations failed:\n" <> L.unlines failures) (L.null failures)
          readStub env "svc" >>= (@?= "running")
          journal <- fmap (L.drop 1 . L.words) . L.lines <$> readFile (lHelper env <> "/journal")
          let
            started op = L.length [() | e <- journal, L.take 1 e == ["start"], L.drop 2 e == [op]]
          (started "service-stop", started "service-start", started "service-restart") @?= (1, 1, 1)
          stops <- L.length . L.filter ("docker stop" `L.isInfixOf`) <$> stubLog env
          stops @?= 2
    ]

scenario :: String -> String
scenario link =
  jsonList
    [ obj [("op", str "open"), ("label", str "landing"), ("url", str link)]
    , obj [("op", str "wait_text"), ("label", str "running"), ("text", str "Running"), ("timeout", "30")]
    , obj [("op", str "click"), ("label", str "stop"), ("selector", str "#service-stop")]
    , obj [("op", str "wait_text"), ("label", str "stopped"), ("text", str "Done: the service was stopped."), ("timeout", "60")]
    , obj [("op", str "click"), ("label", str "start"), ("selector", str "#service-start")]
    , obj [("op", str "wait_text"), ("label", str "started"), ("text", str "Done: the service was started."), ("timeout", "60")]
    , obj [("op", str "wait_text"), ("label", str "afterstart"), ("text", str "Running"), ("timeout", "30")]
    , obj
        [ ("op", str "eval")
        , ("label", str "busy")
        , ("expression", str "(function(){var b=document.getElementById('service-restart');b.click();var d=b.disabled;b.click();return d;})()")
        ]
    , obj [("op", str "wait_text"), ("label", str "restarted"), ("text", str "Done: the service was restarted."), ("timeout", "60")]
    , obj [("op", str "sleep"), ("seconds", "2")]
    ]

runDriver :: String -> IO [(String, String)]
runDriver input = do
  result <-
    timeout 300000000 $
      Process.readCreateProcessWithExitCode (Process.proc "python3" ["test/browser/control_driver.py"]) input
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

jsonList :: [String] -> String
jsonList items =
  "[" <> L.intercalate "," items <> "]"

obj :: [(String, String)] -> String
obj fields =
  "{" <> L.intercalate "," [str k <> ":" <> v | (k, v) <- fields] <> "}"

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
