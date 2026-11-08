{-# LANGUAGE OverloadedStrings #-}

{- | The task pages of the application over real HTTP (contract C-P3.6 K6, K7):
the real service with a migrated real PostgreSQL database; the session comes
from the real CLI as in C-P3.4.
-}
module Lockstep.TasksPageTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTPTypes
import System.Exit (ExitCode (ExitSuccess))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Support.Http (HttpResponse (..), httpRequest, responseHeader)
import Lockstep.Support.Postgres (AdminSettings (..), requireAdmin, withFreshDatabase, writeConfigFile)
import Lockstep.Support.Process (freePort, runLockstep, withService)

data Svc
  = Svc
  { svcPort :: Int
  , svcSession :: BS.ByteString
  }

-- | A migrated database, the service, and a signed-in application session.
withTasks :: (Svc -> IO a) -> IO a
withTasks action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-p36-page" $ \dir -> do
      path <- writeConfigFile dir admin db (adminPassword admin)
      let
        env = [("LOCKSTEP_CONFIG", path)]
      (code, _, err) <- runLockstep env ["db", "migrate"]
      assertBool ("db migrate failed: " <> err) (code == ExitSuccess)
      port <- freePort
      (result, _) <-
        withService env port (dir <> "/serve.log") $ do
          session <- signIn port env
          action (Svc port session)
      pure result

origin :: Int -> BS.ByteString
origin port =
  "http://127.0.0.1:" <> BS8.pack (show port)

signIn :: Int -> [(String, String)] -> IO BS.ByteString
signIn port env = do
  (code, out, err) <- runLockstep env ["operator", "sign-in", "--port", show port]
  code @?= ExitSuccess
  token <-
    case L.stripPrefix "=" (L.dropWhile (/= '=') (L.filter (/= '\n') out)) of
      Just t | L.length t == 43 -> pure (BS8.pack t)
      _ -> assertFailure ("unexpected sign-in output: " <> out <> err)
  resp <- httpRequest port "POST" "/app/api/session" [("Origin", origin port)] token
  responseStatus resp @?= 200
  pure (BS.take 43 (BS.drop 11 (snd (BS.breakSubstring "\"session\":\"" (responseBody resp)))))

fragment :: Svc -> String -> IO HttpResponse
fragment svc path =
  httpRequest (svcPort svc) "GET" ("/app/fragments/" <> path) [("X-Lockstep-Session", svcSession svc)] ""

post :: Svc -> [HTTPTypes.Header] -> String -> [(BS.ByteString, BS.ByteString)] -> IO HttpResponse
post svc headers path fields =
  httpRequest (svcPort svc) "POST" path (("Content-Type", "application/x-www-form-urlencoded") : headers) (HTTPTypes.renderSimpleQuery False fields)

asOperator :: Svc -> [HTTPTypes.Header]
asOperator svc =
  [("Origin", origin (svcPort svc)), ("X-Lockstep-Session", svcSession svc)]

contains :: BS.ByteString -> BS.ByteString -> Bool
contains needle haystack =
  not (BS.null (snd (BS.breakSubstring needle haystack)))

inputValue :: BS.ByteString -> BS.ByteString -> Maybe BS.ByteString
inputValue name page =
  let
    after = snd (BS.breakSubstring ("name=\"" <> name <> "\" value=\"") page)
  in
    if BS.null after
      then Nothing
      else Just (BS.takeWhile (/= 0x22) (BS.drop (BS.length name + 15) after))

-- | A project with no folder, through the C-P3.5 form; returns its id.
newProject :: Svc -> BS.ByteString -> IO String
newProject svc name = do
  form <- fragment svc "project-new"
  k <- maybe (assertFailure "no project key") pure (inputValue "key" (responseBody form))
  resp <- post svc (asOperator svc) "/app/api/projects" [("key", k), ("name", name), ("outcome", ""), ("folder", "later")]
  responseStatus resp @?= 200
  case BS.stripPrefix "/app/projects/" (fromMaybe "" (responseHeader "X-Lockstep-Path" resp)) of
    Just pid -> pure (BS8.unpack pid)
    Nothing -> assertFailure "no project address"

-- | A task through the new-task form; returns the answer and the task's id.
newTask :: Svc -> String -> [(BS.ByteString, BS.ByteString)] -> IO (HttpResponse, String)
newTask svc pid fields = do
  form <- fragment svc ("task-new/" <> pid)
  responseStatus form @?= 200
  k <- maybe (assertFailure ("no task key: " <> show (responseBody form))) pure (inputValue "key" (responseBody form))
  resp <- post svc (asOperator svc) ("/app/api/projects/" <> pid <> "/tasks") (("key", k) : fields)
  responseStatus resp @?= 200
  pure (resp, maybe "" BS8.unpack (BS.stripPrefix "/app/tasks/" (fromMaybe "" (responseHeader "X-Lockstep-Path" resp))))

-- | The task page's current values of a hidden field.
hidden :: Svc -> String -> BS.ByteString -> IO BS.ByteString
hidden svc tid name = do
  page <- fragment svc ("task/" <> tid)
  maybe (assertFailure ("no " <> show name <> " in: " <> show (responseBody page))) pure (inputValue name (responseBody page))

tests :: TestTree
tests =
  testGroup
    "task pages over HTTP (C-P3.6)"
    [ testCase "the new-task form asks what needs doing, what done looks like, priority and what comes first" $
        withTasks $ \svc -> do
          pid <- newProject svc "Kitchen"
          form <- fragment svc ("task-new/" <> pid)
          responseStatus form @?= 200
          traverse_
            (\needle -> assertBool ("missing " <> show needle <> ": " <> show (responseBody form)) (contains needle (responseBody form)))
            [ "<form"
            , "action=\"/app/api/projects/" <> BS8.pack pid <> "/tasks\""
            , "name=\"title\""
            , "name=\"acceptance\""
            , "name=\"priority\" value=\"high\""
            , "name=\"priority\" value=\"normal\" checked"
            , "name=\"priority\" value=\"low\""
            , "<label"
            ]
          traverse_
            (\word -> assertBool ("internal word " <> show word) (not (contains word (responseBody form))))
            ["Ticket", "ticket", "Work Order", "work order", "Engineer", "schedul"]
          shell <- httpRequest (svcPort svc) "GET" ("/app/projects/" <> pid <> "/tasks/new") [] ""
          responseStatus shell @?= 200
    , testCase "creating needs the session and this origin; the answer is the task page, and nothing runs it" $
        withTasks $ \svc -> do
          pid <- newProject svc "Kitchen"
          form <- fragment svc ("task-new/" <> pid)
          k <- maybe (assertFailure "no key") pure (inputValue "key" (responseBody form))
          let
            fields = [("key", k), ("title", "Write the menu"), ("acceptance", "Printed and on the wall."), ("priority", "high")]
            path = "/app/api/projects/" <> pid <> "/tasks"
          none <- post svc [("Origin", origin (svcPort svc))] path fields
          responseStatus none @?= 401
          elsewhere <- post svc [("Origin", "http://127.0.0.1:1"), ("X-Lockstep-Session", svcSession svc)] path fields
          responseStatus elsewhere @?= 403
          resp <- post svc (asOperator svc) path fields
          responseStatus resp @?= 200
          let
            body = responseBody resp
            address = fromMaybe "" (responseHeader "X-Lockstep-Path" resp)
          assertBool ("no task address: " <> show address) ("/app/tasks/" `BS.isPrefixOf` address && BS.length address == 11 + 36)
          traverse_
            (\needle -> assertBool ("missing " <> show needle <> ": " <> show body) (contains needle body))
            ["Write the menu", "Printed and on the wall.", "Not yet ready to work on.", "Mark as ready to work on", "Nothing runs it yet", "High"]
          assertBool "an Unblock on a task that is not blocked" (not (contains "Unblock" body))
          shell <- httpRequest (svcPort svc) "GET" (BS8.unpack address) [] ""
          responseStatus shell @?= 200
    , testCase "the project page lists its tasks, most important first, and names the most important ready one" $
        withTasks $ \svc -> do
          pid <- newProject svc "Kitchen"
          empty <- fragment svc ("project/" <> pid)
          assertBool "no New task link" (contains ("href=\"/app/projects/" <> BS8.pack pid <> "/tasks/new\"") (responseBody empty))
          (_, low) <- newTask svc pid [("title", "Buy paper"), ("acceptance", ""), ("priority", "low")]
          (_, high) <- newTask svc pid [("title", "Fix the oven"), ("acceptance", ""), ("priority", "high")]
          traverse_
            ( \tid -> do
                r <- hidden svc tid "ticket_revision"
                resp <- post svc (asOperator svc) ("/app/api/tasks/" <> tid <> "/decide") [("ticket_revision", r), ("action", "ready")]
                responseStatus resp @?= 200
            )
            [low, high]
          r <- hidden svc high "ticket_revision"
          _ <- post svc (asOperator svc) ("/app/api/tasks/" <> high <> "/decide") [("ticket_revision", r), ("action", "block"), ("reason", "waiting for a part")]
          page <- fragment svc ("project/" <> pid)
          let
            body = responseBody page
            at needle = BS.length (fst (BS.breakSubstring needle body))
          assertBool "a task is missing" (contains "Fix the oven" body && contains "Buy paper" body)
          assertBool "not most important first" (at "Fix the oven" < at "Buy paper")
          assertBool ("blocked not shown: " <> show body) (contains "Blocked: waiting for a part" body)
          assertBool ("no most important ready task: " <> show body) (contains "Most important task ready to work on: Buy paper" body)
          assertBool "no link to a task" (contains ("href=\"/app/tasks/" <> BS8.pack low <> "\"") body)
    , testCase "an edit with an old revision is explained and changes nothing" $
        withTasks $ \svc -> do
          pid <- newProject svc "Kitchen"
          (_, tid) <- newTask svc pid [("title", "Write the menu"), ("acceptance", ""), ("priority", "normal")]
          stale <- post svc (asOperator svc) ("/app/api/tasks/" <> tid <> "/edit") [("revision", "0"), ("title", "Overwritten"), ("acceptance", ""), ("priority", "low")]
          responseStatus stale @?= 200
          assertBool ("not explained: " <> show (responseBody stale)) (contains "changed since this page was shown" (responseBody stale))
          page <- fragment svc ("task/" <> tid)
          assertBool "the stale edit changed the task" (contains "Write the menu" (responseBody page) && not (contains "Overwritten" (responseBody page)))
          rev <- hidden svc tid "revision"
          fresh <- post svc (asOperator svc) ("/app/api/tasks/" <> tid <> "/edit") [("revision", rev), ("title", "Write the winter menu"), ("acceptance", "On the wall."), ("priority", "low")]
          assertBool ("not edited: " <> show (responseBody fresh)) (contains "Write the winter menu" (responseBody fresh) && contains "On the wall." (responseBody fresh))
    , testCase "the actions follow the task's state" $
        withTasks $ \svc -> do
          pid <- newProject svc "Kitchen"
          (_, tid) <- newTask svc pid [("title", "Write the menu"), ("acceptance", ""), ("priority", "normal")]
          let
            decide fields = do
              r <- hidden svc tid "ticket_revision"
              resp <- post svc (asOperator svc) ("/app/api/tasks/" <> tid <> "/decide") (("ticket_revision", r) : fields)
              responseStatus resp @?= 200
              pure (responseBody resp)
          readyPage <- decide [("action", "ready")]
          assertBool ("not ready: " <> show readyPage) (contains "Ready to work on." readyPage && not (contains "Mark as ready to work on" readyPage))
          assertBool "no Block" (contains "Block" readyPage)
          blockedPage <- decide [("action", "block"), ("reason", "the printer is broken")]
          assertBool ("not blocked: " <> show blockedPage) (contains "Blocked: the printer is broken" blockedPage && contains "Unblock" blockedPage)
          noReason <- decide [("action", "unblock")]
          assertBool "not unblocked" (contains "Ready to work on." noReason)
          emptyReason <- decide [("action", "block"), ("reason", "   ")]
          assertBool ("no reason asked for: " <> show emptyReason) (contains "Say why it is blocked" emptyReason)
          canceled <- decide [("action", "cancel")]
          assertBool ("not canceled: " <> show canceled) (contains "Canceled." canceled && not (contains "Mark as ready" canceled))
    , testCase "text people typed is escaped on the task and project pages" $
        withTasks $ \svc -> do
          pid <- newProject svc "Kitchen"
          (resp, _) <- newTask svc pid [("title", "<script>alert(1)</script>"), ("acceptance", "<img src=x onerror=alert(2)>"), ("priority", "normal")]
          let
            body = responseBody resp
          assertBool "markup was not escaped" (not (contains "<script>alert(1)" body) && not (contains "<img src=x" body))
          assertBool ("the title is missing: " <> show body) (contains "&lt;script&gt;alert(1)&lt;/script&gt;" body)
          page <- fragment svc ("project/" <> pid)
          assertBool "the project page did not escape" (not (contains "<script>alert(1)" (responseBody page)))
    , testCase "the Tasks section lists tasks as links, with no form or button" $
        withTasks $ \svc -> do
          pid <- newProject svc "Kitchen"
          (_, tid) <- newTask svc pid [("title", "Write the menu"), ("acceptance", ""), ("priority", "normal")]
          overview <- fragment svc "tasks"
          responseStatus overview @?= 200
          let
            body = responseBody overview
          assertBool ("no link to the task: " <> show body) (contains ("href=\"/app/tasks/" <> BS8.pack tid <> "\"") body)
          assertBool "no project name" (contains "Kitchen" body)
          assertBool "a form on the overview" (not (contains "<form" body))
          assertBool "a button on the overview" (not (contains "<button" body))
          assertBool "the overview does not say what is coming" (contains "later update" body)
    , testCase "unknown tasks and other addresses are 404; bodies over 16 KiB are refused" $
        withTasks $ \svc -> do
          pid <- newProject svc "Kitchen"
          missing <- fragment svc "task/00000000-0000-4000-8000-000000000000"
          responseStatus missing @?= 404
          noProject <- fragment svc "task-new/00000000-0000-4000-8000-000000000000"
          responseStatus noProject @?= 404
          traverse_
            ( \p -> do
                resp <- httpRequest (svcPort svc) "GET" p [] ""
                assertBool (p <> " gave " <> show (responseStatus resp)) (responseStatus resp == 404)
            )
            ["/app/tasks/not-a-uuid", "/app/tasks/new", "/app/projects/" <> pid <> "/tasks", "/app/fragments/task/not-a-uuid"]
          big <- post svc (asOperator svc) ("/app/api/projects/" <> pid <> "/tasks") [("title", "Big"), ("acceptance", BS.replicate 17000 0x61), ("priority", "normal")]
          responseStatus big @?= 413
    ]
