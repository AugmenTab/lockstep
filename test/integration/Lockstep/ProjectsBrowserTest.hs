{-# LANGUAGE OverloadedStrings #-}

{- | Guided project setup in a real browser (contract C-P3.5): headless Chromium
through the frozen @test/browser/app_driver.py@; the real pane, the real helper
and @scripts/service@ with the folder list, the real service (started by the
@docker@ stub as the container would be) against a migrated real database.
-}
module Lockstep.ProjectsBrowserTest
  ( tests
  ) where

import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import System.Directory (canonicalizePath, doesDirectoryExist)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase)
import Text.Show (show)

import Lockstep.Support.Control (issueSignIn, withPaneOn)
import Lockstep.Support.Folders (FEnv (..), runServiceScript, withFolderEnv, withFolderHelper)

tests :: TestTree
tests =
  testGroup
    "guided project setup in a real browser (C-P3.5)"
    [ testCase "pane: add a folder → Open Lockstep → Projects → a project in a new folder, then one in the added folder" $
        withFolderEnv True $ \env -> withFolderHelper env Nothing $ do
          (code, _, err) <- runServiceScript env [("LOCKSTEP_SERVICE_FOLDERS", fState env <> "/helper/folders")] ["start", "--port", show (fServicePort env)]
          assertBool ("the service did not start: " <> err) (code == ExitSuccess)
          withPaneOn (fState env <> "/pane") [] $ \port -> do
            token <- issueSignIn (fState env <> "/pane") 300
            site <- canonicalizePath (fHome env <> "/code/site")
            gitInit site
            let
              app = "http://127.0.0.1:" <> show (fServicePort env)
            observed <- runDriver (journey ("http://127.0.0.1:" <> show port <> "/sign-in#" <> T.unpack token) app site)
            let
              value key = fromMaybe "<missing>" (L.lookup key observed)
              failures =
                [ key <> ": expected " <> show expected <> ", got " <> show (value key)
                | (key, expected) <-
                    [ ("done", "ok")
                    , ("pane.found", "yes")
                    , ("review.found", "yes")
                    , ("added.found", "yes")
                    , ("running.found", "yes")
                    , ("home.found", "yes")
                    , ("projects.found", "yes")
                    , ("newform.found", "yes")
                    , ("created.found", "yes")
                    , ("createdurl.value", "true")
                    , ("again.found", "yes")
                    , ("offered.value", "true")
                    , ("second.found", "yes")
                    , ("secondfolder.value", "true")
                    , ("overview.found", "yes")
                    , ("listed.value", "2")
                    ]
                , value key /= expected
                ]
            assertBool ("browser expectations failed:\n" <> L.unlines failures) (L.null failures)
            made <- doesDirectoryExist (fProjects env <> "/family-recipes/.git")
            assertBool "the new project's folder was not made" made
    ]

gitInit :: FilePath -> IO ()
gitInit dir = do
  (code, out, err) <-
    Process.readCreateProcessWithExitCode
      (Process.proc "git" ["-c", "user.name=Lockstep Test", "-c", "user.email=test@example.invalid", "-c", "init.defaultBranch=main", "init", "-q", dir])
      ""
  assertBool ("git init failed: " <> out <> err) (code == ExitSuccess)

journey :: String -> String -> FilePath -> String
journey paneLink app site =
  let
    step fields = "{" <> L.intercalate "," [str k <> ":" <> v | (k, v) <- fields] <> "}"
    open' label url = step [("op", str "open"), ("label", str label), ("url", str url)]
    wait' label text = step [("op", str "wait_text"), ("label", str label), ("text", str text), ("timeout", "90")]
    eval' label expression = step [("op", str "eval"), ("label", str label), ("expression", str expression)]
    click' label selector = step [("op", str "click"), ("label", str label), ("selector", str selector)]
    type' selector text = step [("op", str "type"), ("selector", str selector), ("text", str text)]
    setValue selector value = step [("op", str "set_dom_value"), ("selector", str selector), ("value", str value)]
    key' k = step [("op", str "key"), ("key", str k)]
  in
    "["
      <> L.intercalate
        ","
        [ open' "landing" paneLink
        , wait' "pane" "Project folders"
        , type' "#folder-path" site
        , click' "reviewbutton" "#folder-review"
        , wait' "review" "Lockstep will be able to see this folder"
        , click' "addbutton" "#add-folder"
        , wait' "added" "Lockstep can now see"
        , wait' "running" "Running"
        , click' "open" "#open-application"
        , wait' "home" "What needs your attention"
        , eval' "focusprep" "(function(){document.querySelector('nav a').focus();return true;})()"
        , key' "Tab"
        , key' "Enter"
        , wait' "projects" "New project"
        , click' "new" "#new-project"
        , wait' "newform" "What should it achieve"
        , type' "#project-name" "Family recipes"
        , type' "#project-outcome" "Share them with my sister."
        , click' "create" "#create-project"
        , wait' "created" "Lockstep can see this folder"
        , eval' "createdurl" "/^\\/app\\/projects\\/[0-9a-f-]{36}$/.test(location.pathname)"
        , open' "againpage" (app <> "/app/projects/new")
        , wait' "again" "What should it achieve"
        , eval' "offered" ("Array.from(document.querySelectorAll('#folder-choice option')).some(function(o){return o.value === " <> jsString site <> ";})")
        , type' "#project-name" "My site"
        , click' "existing" "#folder-existing"
        , setValue "#folder-choice" site
        , click' "create2" "#create-project"
        , wait' "second" "Lockstep can see this folder"
        , eval' "secondfolder" ("document.body.textContent.indexOf(" <> jsString site <> ") >= 0")
        , open' "overviewpage" (app <> "/app/projects")
        , wait' "overview" "Family recipes"
        , eval' "listed" "document.querySelectorAll('#content a[href^=\"/app/projects/\"]:not([href=\"/app/projects/new\"])').length"
        ]
      <> "]"

jsString :: String -> String
jsString s =
  "'" <> L.concatMap (\c -> if c == '\'' || c == '\\' then ['\\', c] else [c]) s <> "'"

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
