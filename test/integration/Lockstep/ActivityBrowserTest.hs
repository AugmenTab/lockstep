{-# LANGUAGE OverloadedStrings #-}

{- | The Activity view in a real browser (contract C-P3.9 N4): headless Chromium
through the frozen @test/browser/app_driver.py@, the real service on a
'Lockstep.Support.Ledger.withLedger' database, a step with no answer made in
this process through the C-P2.5 ledger, sign-in tokens from the real CLI.
-}
module Lockstep.ActivityBrowserTest
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

import Lockstep.Kernel.Effect (OperationId (..))
import Lockstep.Kernel.Identity (uuidText)
import Lockstep.Support.Decisions (stepWithUnknownOutcome)
import Lockstep.Support.Ledger (Ledger (..), withLedger)
import Lockstep.Support.Process (freePort, runLockstep, withService)

tests :: TestTree
tests =
  testGroup
    "activity in a real browser (C-P3.9)"
    [ testCase "Home → Activity → the step that needs a person → its decision" $
        withLedger $ \lg -> do
          (_, OperationId u) <- stepWithUnknownOutcome lg "Send the invoice"
          let
            op = T.unpack (uuidText u)
          port <- freePort
          (observed, _) <-
            withService (lgEnv lg) port (lgDir lg <> "/serve.log") $ do
              token <- signInToken (lgEnv lg) port
              runDriver (journey ("http://127.0.0.1:" <> show port) token op)
          let
            value key = fromMaybe "<missing>" (L.lookup key observed)
            failures =
              [ key <> ": expected " <> show expected <> ", got " <> show (value key)
              | (key, expected) <-
                  [ ("done", "ok")
                  , ("home.found", "yes")
                  , ("activity.found", "yes")
                  , ("label.value", "true")
                  , ("decision.found", "yes")
                  , ("decisionpath.value", "true")
                  ]
              , value key /= expected
              ]
          assertBool ("the journey:\n" <> L.unlines failures) (L.null failures)
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

journey :: String -> String -> String -> String
journey app token op =
  "["
    <> L.intercalate
      ","
      [ open' "landing" (app <> "/app/sign-in#" <> token)
      , wait' "home" "What needs your attention"
      , click' "nav" "nav a[href=\"/app/activity\"]"
      , wait' "activity" "Needs attention"
      , eval' "label" "document.querySelector('.ls-effect-unknown') !== null && document.querySelector('.ls-effect-passed') === null"
      , click' "open" ("a[href=\"/app/decisions/" <> op <> "\"]")
      , wait' "decision" "It happened"
      , eval' "decisionpath" ("location.pathname === '/app/decisions/" <> op <> "'")
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
