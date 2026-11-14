{-# LANGUAGE OverloadedStrings #-}

{- | A project's Progress page through the real service (contract C-P6.2 C1,
C3, C4, C6, C7): real PostgreSQL, the real CLI (sign-in, and the C-P6.1
backlog import), real HTTP, and one journey in headless Chromium through the
frozen @test/browser/app_driver.py@. Tasks are made through the application's
own operations on the same database; the page is only read.
-}
module Lockstep.ProgressPageTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Maybe (fromMaybe, isJust)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath, writeFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Database (DatabaseRuntime)
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks (NewTask (..), TaskDecision (..), TaskView (..), createTask, decideTask)
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Support.Http (HttpResponse (..), httpRequest, responseHeader)
import Lockstep.Support.Postgres (AdminSettings (..), databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime, writeConfigFile)
import Lockstep.Support.Process (freePort, runLockstep, withService)

data Env
  = Env
  { envAdmin :: AdminSettings
  , envDb :: T.Text
  , envRuntime :: DatabaseRuntime
  , envCli :: [(String, String)]
  , envPort :: Int
  , envDir :: FilePath
  }

-- | A migrated database, the service on it, and a runtime for the application's own operations.
withEnv :: (Env -> IO a) -> IO a
withEnv action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-p62" $ \dir -> do
      path <- writeConfigFile dir admin db (adminPassword admin)
      let
        cli = [("LOCKSTEP_CONFIG", path)]
      (code, _, err) <- runLockstep cli ["db", "migrate"]
      assertBool ("db migrate failed: " <> err) (code == ExitSuccess)
      config <- databaseConfigFor admin db
      withRuntime config $ \runtime -> do
        port <- freePort
        (result, _) <- withService cli port (dir <> "/serve.log") (action (Env admin db runtime cli port dir))
        pure result

ready :: Show e => IO (Either e a) -> IO a
ready act =
  act >>= either (\e -> assertFailure ("not ready: " <> show e)) pure

key :: T.Text -> IO IdempotencyKey
key text =
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-progress-key-" <> text))

project :: Env -> T.Text -> IO ProjectView
project env name = do
  k <- key ("project-" <> name)
  made <- ready (createProject (envRuntime env) (ProjectFolders Nothing []) (NewProject k name "" DecideLater))
  either (\c -> assertFailure ("refused: " <> T.unpack c)) pure made

task :: Env -> ProjectView -> T.Text -> Priority -> [TaskView] -> IO TaskView
task env view title priority deps = do
  k <- key ("task-" <> T.filter (/= ' ') title)
  made <- ready (createTask (envRuntime env) (NewTask k (projectId view) title "It works." priority (fmap taskId deps)))
  either (\c -> assertFailure ("task refused: " <> T.unpack c)) pure made

decide :: Env -> TaskView -> TaskDecision -> IO TaskView
decide env t decision =
  ready (decideTask (envRuntime env) "test-session" (taskId t) (taskTicketRevision t) decision) >>= either (\c -> assertFailure ("decision refused: " <> T.unpack c)) pure

signInToken :: Env -> IO String
signInToken env = do
  (code, out, err) <- runLockstep (envCli env) ["operator", "sign-in", "--port", show (envPort env)]
  code @?= ExitSuccess
  case L.stripPrefix "=" (L.dropWhile (/= '=') (L.filter (/= '\n') out)) of
    Just t | L.length t == 43 -> pure t
    _ -> assertFailure ("unexpected sign-in output: " <> out <> err)

origin :: Env -> BS.ByteString
origin env =
  "http://127.0.0.1:" <> BS8.pack (show (envPort env))

session :: Env -> IO BS.ByteString
session env = do
  token <- signInToken env
  resp <- httpRequest (envPort env) "POST" "/app/api/session" [("Origin", origin env)] (BS8.pack token)
  responseStatus resp @?= 200
  pure (BS.take 43 (BS.drop 11 (snd (BS.breakSubstring "\"session\":\"" (responseBody resp)))))

progressFragment :: Env -> BS.ByteString -> T.Text -> IO HttpResponse
progressFragment env s pid =
  httpRequest (envPort env) "GET" ("/app/fragments/project-progress/" <> T.unpack pid) [("X-Lockstep-Session", s)] ""

contains :: BS.ByteString -> BS.ByteString -> Bool
contains needle haystack =
  not (BS.null (snd (BS.breakSubstring needle haystack)))

-- | The table row whose standing is this code and which names this title.
rowWith :: BS.ByteString -> BS.ByteString -> BS.ByteString -> Maybe BS.ByteString
rowWith page code title =
  L.find (contains title) [fst (BS.breakSubstring "</tr>" r) | r <- L.drop 1 (splitOn ("data-standing=\"" <> code <> "\"") page)]
 where
  splitOn sep bytes =
    case BS.breakSubstring sep bytes of
      (before, rest)
        | BS.null rest -> [before]
        | otherwise -> before : splitOn sep (BS.drop (BS.length sep) rest)

hasRow :: BS.ByteString -> BS.ByteString -> BS.ByteString -> Assertion
hasRow page code title =
  assertBool ("no " <> show code <> " row for " <> show title) (isJust (rowWith page code title))

backlogDocument :: String
backlogDocument =
  "{\"format\":\"lockstep-backlog\",\"version\":1,\"source\":{\"provider\":\"canonical\",\"locator\":\"caesura-notes\"},\"revision\":1,"
    <> "\"items\":[{\"key\":\"CAE-1\",\"revision\":1,\"title\":\"Imported sleep timer\",\"acceptance\":[{\"text\":\"It stops\"}]}]}"

tests :: TestTree
tests =
  testGroup
    "a project's Progress page (C-P6.2; real service, PostgreSQL, CLI, HTTP, browser)"
    [ testCase "standings, reasons, the next task to hand over, an imported task's source; priority never disguises a waiting task" $
        withEnv $ \env -> do
          view <- project env "Caesura"
          base <- task env view "Base player" Low [] >>= \t -> decide env t MarkReady
          top <- task env view "Top feature" High [base] >>= \t -> decide env t MarkReady
          _ <- task env view "Side fix" Normal [] >>= \t -> decide env t MarkReady
          _ <- task env view "Stuck idea" High [] >>= \t -> decide env t (BlockTask "waiting for a design")
          _ <- task env view "Rough idea" High []
          let
            file = envDir env <> "/backlog.json"
          writeFile file backlogDocument
          (code, out, err) <- runLockstep (envCli env) ["backlog", "import", "--project", T.unpack (projectId view), file]
          assertBool ("backlog import failed: " <> out <> err) (code == ExitSuccess)
          assertBool ("import output: " <> out) ("item CAE-1 created" `L.isInfixOf` out)
          s <- session env
          resp <- progressFragment env s (projectId view)
          responseStatus resp @?= 200
          responseHeader "X-Lockstep-Path" resp @?= Just (TE.encodeUtf8 ("/app/projects/" <> projectId view <> "/progress"))
          let
            page = responseBody resp
          hasRow page "waiting" "Top feature"
          assertBool "the waiting row does not name what it waits for" (maybe False (contains "Base player") (rowWith page "waiting" "Top feature"))
          hasRow page "ready" "Base player"
          hasRow page "ready" "Side fix"
          hasRow page "blocked" "Stuck idea"
          assertBool "the blocked row lacks its reason" (maybe False (contains "waiting for a design") (rowWith page "blocked" "Stuck idea"))
          hasRow page "proposed" "Rough idea"
          hasRow page "proposed" "Imported sleep timer"
          assertBool "the imported row lacks its source" (maybe False (contains "canonical caesura-notes CAE-1 @ 1") (rowWith page "proposed" "Imported sleep timer"))
          let
            next = fst (BS.breakSubstring "</p>" (snd (BS.breakSubstring "Next to hand over" page)))
          assertBool ("the next task is not Side fix: " <> show next) (contains "Side fix" next && not (contains "Top feature" next))
          assertBool "no approved plan was claimed absent" (contains "No approved plan" page)
          assertBool ("a task links to a page that is not its own: " <> show (taskId top)) (contains (TE.encodeUtf8 ("/app/tasks/" <> taskId top)) page)
          assertBool "the page is not read only" (not (contains "<form" page))
    , testCase "truthful failures: no session is 401, an unknown project 404; the shell serves the page's address; a POST to it changes nothing" $
        withEnv $ \env -> do
          view <- project env "Caesura"
          _ <- task env view "Base player" Normal []
          s <- session env
          none <- httpRequest (envPort env) "GET" ("/app/fragments/project-progress/" <> T.unpack (projectId view)) [] ""
          responseStatus none @?= 401
          unknown <- progressFragment env s "00000000-0000-4000-8000-000000000000"
          responseStatus unknown @?= 404
          shellPage <- httpRequest (envPort env) "GET" ("/app/projects/" <> T.unpack (projectId view) <> "/progress") [] ""
          responseStatus shellPage @?= 200
          assertBool "the shell is not served" (contains "/static/app.js" (responseBody shellPage))
          before <- queryInts (envAdmin env) (envDb env) "SELECT count(*)::integer + coalesce(sum(revision), 0)::integer AS v FROM lockstep_project_tasks"
          posted <- httpRequest (envPort env) "POST" ("/app/projects/" <> T.unpack (projectId view) <> "/progress") [("Origin", origin env), ("X-Lockstep-Session", s)] ""
          assertBool ("a POST to the page was accepted: " <> show (responseStatus posted)) (responseStatus posted `L.elem` [404, 405])
          after <- queryInts (envAdmin env) (envDb env) "SELECT count(*)::integer + coalesce(sum(revision), 0)::integer AS v FROM lockstep_project_tasks"
          after @?= before
    , testCase "in a real browser: from the project page to Progress by keyboard; the sign-in ends; the next sign-in returns to Progress" $
        withEnv $ \env -> do
          view <- project env "Caesura"
          _ <- task env view "Base player" Normal [] >>= \t -> decide env t MarkReady
          first <- signInToken env
          second <- signInToken env
          let
            app = "http://127.0.0.1:" <> show (envPort env)
            progressPath = "/app/projects/" <> T.unpack (projectId view) <> "/progress"
          observed <- runDriver (journey app (T.unpack (projectId view)) first second)
          let
            value k = fromMaybe "<missing>" (L.lookup k observed)
            failures =
              [ k <> ": expected " <> show expected <> ", got " <> show (value k)
              | (k, expected) <- [("done", "ok"), ("project.found", "yes"), ("progress.found", "yes"), ("ended.found", "yes"), ("back.found", "yes")]
              , value k /= expected
              ]
          assertBool ("the journey:\n" <> L.unlines failures) (L.null failures)
          value "progresspath.value" @?= show progressPath
          value "backpath.value" @?= show progressPath
    ]

journey :: String -> String -> String -> String -> String
journey app pid first second =
  "["
    <> L.intercalate
      ","
      [ open' "landing" (app <> "/app/sign-in#" <> first)
      , wait' "home" "What needs your attention"
      , open' "projectpage" (app <> "/app/projects/" <> pid)
      , wait' "project" "Progress: where all of this project"
      , -- Keyboard only: focus the link, then Enter.
        eval' "focus" "(function(){document.querySelector('#project-progress').focus();return document.activeElement.id;})()"
      , key' "Enter"
      , wait' "progress" "Next to hand over"
      , eval' "progresspath" "location.pathname"
      , -- The service no longer accepts this browser's session (as when it expires), then the page is opened again.
        eval' "spoil" "(function(){localStorage.setItem('lockstep.app.session','A'.repeat(43));return true;})()"
      , eval' "reload" "(function(){location.reload();return true;})()"
      , wait' "ended" "Your sign-in has ended."
      , open' "again" (app <> "/app/sign-in#" <> second)
      , wait' "back" "Next to hand over"
      , eval' "backpath" "location.pathname"
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

key' :: String -> String
key' k =
  step [("op", str "key"), ("key", str k)]

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
