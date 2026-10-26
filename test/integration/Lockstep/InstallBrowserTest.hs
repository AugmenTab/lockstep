{-# LANGUAGE OverloadedStrings #-}

{- | Upgrade and recovery from the control pane in a real browser (contract
C-P3.3 §1, §3): headless Chromium, the real pane, the real helper with the
install stubs. Every change needs two presses: review, then confirm.
-}
module Lockstep.InstallBrowserTest
  ( tests
  ) where

import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Support.Control (issueSignIn, withPaneOn)
import Lockstep.Support.Install (iInstall, iPane, iStub, readFileTrim, setFile, withInstallEnv, withInstallHelper)

tests :: TestTree
tests =
  testGroup
    "control pane install and upgrade in a real browser (C-P3.3)"
    [ testCase "prepare, review and upgrade; the page shows each step's outcome" $
        withInstallEnv Nothing (Just 5) 5 $ \env -> withInstallHelper env [] $ withPaneOn (iPane env) [] $ \port -> do
          token <- issueSignIn (iPane env) 300
          observed <- runDriver (upgrade ("http://127.0.0.1:" <> show port <> "/sign-in#" <> T.unpack token))
          expectAll observed [("done", "ok"), ("ready.found", "yes"), ("candidate.found", "yes"), ("review.found", "yes"), ("upgraded.found", "yes")]
          has observed "candidate.text" "1 database upgrade"
          has observed "review.text" "back up the database"
          readFileTrim (iStub env <> "/applied") >>= (@?= "6")
          bin <- readFileTrim (iInstall env <> "/bin/lockstep")
          assertBool "the new version is not active" ("# rev 6" `L.isInfixOf` bin)
    , testCase "a failed upgrade is explained, and recovery from the page restores the previous version" $
        withInstallEnv Nothing (Just 5) 5 $ \env -> withInstallHelper env [] $ withPaneOn (iPane env) [] $ \port -> do
          setFile env "flags" "migrate-fail"
          token <- issueSignIn (iPane env) 300
          first <- runDriver (failing ("http://127.0.0.1:" <> show port <> "/sign-in#" <> T.unpack token))
          expectAll first [("done", "ok"), ("attention.found", "yes")]
          setFile env "flags" ""
          token2 <- issueSignIn (iPane env) 300
          second <- runDriver (recover ("http://127.0.0.1:" <> show port <> "/sign-in#" <> T.unpack token2))
          expectAll second [("done", "ok"), ("needs.found", "yes"), ("restorereview.found", "yes"), ("restored.found", "yes")]
          has second "restorereview.text" "restore the database backup"
          readFileTrim (iStub env <> "/applied") >>= (@?= "5")
          bin <- readFileTrim (iInstall env <> "/bin/lockstep")
          assertBool "the previous version is not active" ("# rev 5" `L.isInfixOf` bin)
    ]
 where
  expectAll observed pairs =
    let
      failures = [k <> ": expected " <> show v <> ", got " <> show (fromMaybe "<missing>" (L.lookup k observed)) | (k, v) <- pairs, L.lookup k observed /= Just v]
    in
      assertBool ("browser expectations failed:\n" <> L.unlines failures) (L.null failures)
  has observed key needle =
    assertBool (key <> " lacks " <> show needle <> ": " <> show (L.take 600 (fromMaybe "" (L.lookup key observed)))) (needle `L.isInfixOf` fromMaybe "" (L.lookup key observed))

step :: [(String, String)] -> String
step fields =
  "{" <> L.intercalate "," [str k <> ":" <> v | (k, v) <- fields] <> "}"

open', wait', click' :: String -> String -> String
open' label url = step [("op", str "open"), ("label", str label), ("url", str url)]
wait' label text = step [("op", str "wait_text"), ("label", str label), ("text", str text), ("timeout", "60")]
click' label selector = step [("op", str "click"), ("label", str label), ("selector", str selector)]

upgrade :: String -> String
upgrade link =
  "["
    <> L.intercalate
      ","
      [ open' "landing" link
      , wait' "ready" "Installed"
      , click' "prepare" "#prepare-candidate"
      , wait' "candidate" "A new version is ready to install"
      , click' "reviewbutton" "#apply-review"
      , wait' "review" "Lockstep will"
      , click' "apply" "#apply-candidate"
      , wait' "upgraded" "Done: Lockstep was upgraded."
      ]
    <> "]"

failing :: String -> String
failing link =
  "["
    <> L.intercalate
      ","
      [ open' "landing" link
      , wait' "ready" "Installed"
      , click' "prepare" "#prepare-candidate"
      , wait' "candidate" "A new version is ready to install"
      , click' "reviewbutton" "#apply-review"
      , click' "apply" "#apply-candidate"
      , wait' "attention" "The upgrade needs your attention"
      ]
    <> "]"

-- | A fresh browser: the failed upgrade is still shown, and recovered from the page.
recover :: String -> String
recover link =
  "["
    <> L.intercalate
      ","
      [ open' "landing" link
      , wait' "needs" "The upgrade needs your attention"
      , click' "restorereviewbutton" "#restore-review"
      , wait' "restorereview" "Lockstep will"
      , click' "restore" "#restore-previous"
      , wait' "restored" "Done: the previous version is back."
      ]
    <> "]"

runDriver :: String -> IO [(String, String)]
runDriver input = do
  result <-
    timeout 400000000 $
      Process.readCreateProcessWithExitCode (Process.proc "python3" ["test/browser/control_driver.py"]) input
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
