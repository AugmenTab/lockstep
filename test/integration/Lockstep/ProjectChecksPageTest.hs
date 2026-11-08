{-# LANGUAGE OverloadedStrings #-}

{- | The page for how a project's work is checked, over real HTTP (contract
C-P3.7 L1, L5–L8): the real service with a migrated real PostgreSQL database and
@LOCKSTEP_PROJECT_FOLDERS@ naming a temporary folder; the session comes from the
real CLI as in C-P3.4. Work orders are made in this process through C-P2.5 only
to fill the queue.
-}
module Lockstep.ProjectChecksPageTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTPTypes
import System.Directory (createDirectory)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath, writeFile)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Database (DatabaseRuntime)
import Lockstep.Application.Ledger (NewWorkOrder (..), createWorkOrder)
import Lockstep.Application.Projects (ProjectView (..), findProject)
import Lockstep.Kernel.Identity (TicketId (..), WorkOrderId, parseUuid)
import Lockstep.Kernel.WorkOrder (WorkOrderKind (..))
import Lockstep.Support.Http (HttpResponse (..), httpRequest, responseHeader)
import Lockstep.Support.Postgres (AdminSettings (..), databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime, writeConfigFile)
import Lockstep.Support.Process (freePort, runLockstep, withService)

data Svc
  = Svc
  { svcPort :: Int
  , svcSession :: BS.ByteString
  , svcEnv :: [(String, String)]
  , svcDir :: FilePath
  , svcRuntime :: DatabaseRuntime
  , svcCount :: String -> IO Int
  }

-- | A migrated database, a projects folder, the service, a signed-in session and an in-process runtime.
withChecks :: (Svc -> IO a) -> IO a
withChecks action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-p37-page" $ \dir -> do
      path <- writeConfigFile dir admin db (adminPassword admin)
      createDirectory (dir <> "/projects")
      let
        env = [("LOCKSTEP_CONFIG", path), ("LOCKSTEP_PROJECT_FOLDERS", dir <> "/projects")]
        counter table = do
          rows <- queryInts admin db ("SELECT count(*)::integer AS v FROM " <> table)
          case rows of
            [n] -> pure n
            _ -> assertFailure ("count " <> table)
      (code, _, err) <- runLockstep env ["db", "migrate"]
      assertBool ("db migrate failed: " <> err) (code == ExitSuccess)
      config <- databaseConfigFor admin db
      withRuntime config $ \runtime -> do
        port <- freePort
        (result, _) <-
          withService env port (dir <> "/serve.log") $ do
            session <- signIn port env
            action (Svc port session env dir runtime counter)
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

has :: BS.ByteString -> [BS.ByteString] -> IO ()
has body =
  traverse_ (\needle -> assertBool ("missing " <> show needle <> ": " <> show body) (contains needle body))

inputValue :: BS.ByteString -> BS.ByteString -> Maybe BS.ByteString
inputValue name page =
  let
    after = snd (BS.breakSubstring ("name=\"" <> name <> "\" value=\"") page)
  in
    if BS.null after
      then Nothing
      else Just (BS.takeWhile (/= 0x22) (BS.drop (BS.length name + 15) after))

-- | A project through the C-P3.5 form ("new" makes a folder, "later" has none); returns its id.
newProject :: Svc -> BS.ByteString -> BS.ByteString -> IO String
newProject svc name folder = do
  form <- fragment svc "project-new"
  k <- maybe (assertFailure "no project key") pure (inputValue "key" (responseBody form))
  resp <- post svc (asOperator svc) "/app/api/projects" [("key", k), ("name", name), ("outcome", ""), ("folder", folder)]
  responseStatus resp @?= 200
  case BS.stripPrefix "/app/projects/" (fromMaybe "" (responseHeader "X-Lockstep-Path" resp)) of
    Just pid -> pure (BS8.unpack pid)
    Nothing -> assertFailure ("no project address: " <> show (responseBody resp))

-- | A task through the C-P3.6 form, marked ready; returns its id.
readyTask :: Svc -> String -> BS.ByteString -> BS.ByteString -> IO String
readyTask svc pid title priority = do
  form <- fragment svc ("task-new/" <> pid)
  k <- maybe (assertFailure "no task key") pure (inputValue "key" (responseBody form))
  resp <- post svc (asOperator svc) ("/app/api/projects/" <> pid <> "/tasks") [("key", k), ("title", title), ("acceptance", ""), ("priority", priority)]
  tid <- maybe (assertFailure "no task address") (pure . BS8.unpack) (BS.stripPrefix "/app/tasks/" (fromMaybe "" (responseHeader "X-Lockstep-Path" resp)))
  r <- maybe (assertFailure "no ticket revision") pure (inputValue "ticket_revision" (responseBody resp))
  marked <- post svc (asOperator svc) ("/app/api/tasks/" <> tid <> "/decide") [("ticket_revision", r), ("action", "ready")]
  assertBool "not marked ready" (contains "Ready to work on." (responseBody marked))
  pure tid

workOrder :: Svc -> String -> String -> Int -> [WorkOrderId] -> IO WorkOrderId
workOrder svc pid tid priority dependencies = do
  found <- findProject (svcRuntime svc) (T.pack pid)
  engineer <-
    case found of
      Right (Just view) -> maybe (assertFailure "no Engineer") pure (projectEngineer view)
      _ -> assertFailure "no project"
  ticket <- either (const (assertFailure "task id")) (pure . TicketId) (parseUuid (T.pack tid))
  created <- createWorkOrder (svcRuntime svc) (NewWorkOrder ticket engineer Engineering priority dependencies [] ["source"] Nothing)
  either (\f -> assertFailure ("work order refused: " <> show f)) pure created

choose :: Svc -> String -> [(BS.ByteString, BS.ByteString)] -> IO HttpResponse
choose svc pid fields = do
  resp <- post svc (asOperator svc) ("/app/api/projects/" <> pid <> "/checks") fields
  responseStatus resp @?= 200
  pure resp

-- | The ordinary text of a page: everything before its technical details.
ordinary :: BS.ByteString -> BS.ByteString
ordinary =
  BS8.map Char.toLower . fst . BS.breakSubstring "<details"

tests :: TestTree
tests =
  testGroup
    "how work is checked over HTTP (C-P3.7)"
    [ testCase "the project page links its checks; the checks page lists the always-on rules and the choices" $
        withChecks $ \svc -> do
          pid <- newProject svc "Website" "new"
          project <- fragment svc ("project/" <> pid)
          has (responseBody project) ["How work is checked", "id=\"project-checks\"", "href=\"/app/projects/" <> BS8.pack pid <> "/checks\""]
          page <- fragment svc ("project-checks/" <> pid)
          responseStatus page @?= 200
          has
            (responseBody page)
            [ "How work is checked"
            , "No choice on this page can turn them off"
            , "Only one worker changes a piece of work at a time."
            , "No checks are chosen for this project yet."
            , "<form"
            , "action=\"/app/api/projects/" <> BS8.pack pid <> "/checks\""
            , "name=\"expected\" value=\"none\""
            , "id=\"choice-lockstep-basic\""
            , "Always-on rules only"
            , "id=\"confirm-fewer\""
            , "id=\"save-checks\""
            , "Lockstep does not start work by itself yet"
            ]
          shell <- httpRequest (svcPort svc) "GET" ("/app/projects/" <> pid <> "/checks") [] ""
          responseStatus shell @?= 200
    , testCase "a project without a folder is explained and has no form" $
        withChecks $ \svc -> do
          pid <- newProject svc "Kitchen" "later"
          page <- fragment svc ("project-checks/" <> pid)
          responseStatus page @?= 200
          has (responseBody page) ["has no folder yet", "No choice on this page can turn them off"]
          assertBool "a form without a folder" (not (contains "<form" (responseBody page)))
    , testCase "choosing needs the session and this origin; the answer is the checks page, saved" $
        withChecks $ \svc -> do
          pid <- newProject svc "Website" "new"
          let
            fields = [("expected", "none"), ("choice", "lockstep-basic")]
            path = "/app/api/projects/" <> pid <> "/checks"
          none <- post svc [("Origin", origin (svcPort svc))] path fields
          responseStatus none @?= 401
          elsewhere <- post svc [("Origin", "http://127.0.0.1:1"), ("X-Lockstep-Session", svcSession svc)] path fields
          responseStatus elsewhere @?= 403
          svcCount svc "lockstep_repository_profiles" >>= (@?= 0)
          resp <- choose svc pid fields
          has (responseBody resp) ["Saved.", "name=\"expected\" value=\"lockstep-basic\"", "Always-on rules only"]
          responseHeader "X-Lockstep-Path" resp @?= Just (BS8.pack ("/app/projects/" <> pid <> "/checks"))
          project <- fragment svc ("project/" <> pid)
          has (responseBody project) ["Always-on rules only"]
          svcCount svc "lockstep_repository_profiles" >>= (@?= 1)
    , testCase "a stale page and a choice with fewer checks are explained in words and change nothing" $
        withChecks $ \svc -> do
          pid <- newProject svc "Website" "new"
          _ <- choose svc pid [("expected", "none"), ("choice", "lockstep-basic")]
          writeFile (svcDir svc <> "/team.json") "{\"id\":\"team-checks\",\"version\":1,\"gates\":[{\"id\":\"impact\",\"stage\":\"before-acceptance\",\"artifacts\":[\"impact-assessment\"],\"verifiers\":[\"human-inspection\"],\"approval\":\"human\"}]}"
          (code, _, err) <- runLockstep (svcEnv svc) ["profile", "add", svcDir svc <> "/team.json"]
          assertBool ("profile add failed: " <> err) (code == ExitSuccess)
          stricter <- choose svc pid [("expected", "lockstep-basic"), ("choice", "team-checks")]
          has (responseBody stricter) ["Saved.", "name=\"expected\" value=\"team-checks\"", "impact", "A person must approve it"]
          stale <- choose svc pid [("expected", "none"), ("choice", "lockstep-basic")]
          has (responseBody stale) ["since this page was shown", "name=\"expected\" value=\"team-checks\""]
          unconfirmed <- choose svc pid [("expected", "team-checks"), ("choice", "lockstep-basic")]
          has (responseBody unconfirmed) ["would stop requiring some checks", "the check impact", "name=\"expected\" value=\"team-checks\""]
          assertBool "a refusal said Saved" (not (contains "Saved." (responseBody unconfirmed)))
          svcCount svc "lockstep_repository_profiles" >>= (@?= 2)
          confirmed <- choose svc pid [("expected", "team-checks"), ("choice", "lockstep-basic"), ("confirm_fewer", "yes")]
          has (responseBody confirmed) ["Saved.", "name=\"expected\" value=\"lockstep-basic\""]
          svcCount svc "lockstep_repository_profiles" >>= (@?= 3)
    , testCase "work waiting to start: a high-priority piece that cannot start says why, and nothing is scheduled" $
        withChecks $ \svc -> do
          pid <- newProject svc "Website" "new"
          _ <- choose svc pid [("expected", "none"), ("choice", "lockstep-basic")]
          paper <- readyTask svc pid "Buy paper" "low"
          menu <- readyTask svc pid "Print the menu" "high"
          low <- workOrder svc pid paper 200 []
          _ <- workOrder svc pid menu 900 [low]
          page <- fragment svc ("project-checks/" <> pid)
          let
            body = responseBody page
            entry title = fst (BS.breakSubstring "</li>" (snd (BS.breakSubstring title body)))
          has body ["Work waiting to start", "Lockstep does not start work by itself yet"]
          has (entry "Buy paper") ["First in line"]
          has (entry "Print the menu") ["Cannot start yet", "It needs other work to finish first.", "High"]
          assertBool "the blocked piece looks able to start" (not (contains "in line" (entry "Print the menu")))
          assertBool "not first in line first" (BS.length (fst (BS.breakSubstring "Buy paper" body)) < BS.length (fst (BS.breakSubstring "Print the menu" body)))
          project <- fragment svc ("project/" <> pid)
          has (responseBody project) ["Work waiting to start", "Cannot start yet"]
          svcCount svc "lockstep_schedule_decisions" >>= (@?= 0)
          svcCount svc "lockstep_subjects WHERE kind = 'work-order' AND state <> 'pending'" >>= (@?= 0)
    , testCase "typed text is escaped, and the ordinary text has no internal words" $
        withChecks $ \svc -> do
          pid <- newProject svc "Website" "new"
          _ <- choose svc pid [("expected", "none"), ("choice", "lockstep-basic")]
          tid <- readyTask svc pid "<script>alert(1)</script>" "normal"
          _ <- workOrder svc pid tid 500 []
          page <- fragment svc ("project-checks/" <> pid)
          let
            body = responseBody page
          assertBool "markup was not escaped" (not (contains "<script>alert(1)" body))
          has body ["&lt;script&gt;alert(1)&lt;/script&gt;", "<details"]
          traverse_
            (\word -> assertBool ("internal word " <> show word <> " before the technical details") (not (contains word (ordinary body))))
            ["profile", "gate", "invariant", "work order", "ticket", "engineer", "scheduler", "digest"]
          project <- fragment svc ("project/" <> pid)
          traverse_
            (\word -> assertBool ("internal word " <> show word <> " on the project page") (not (contains word (ordinary (responseBody project)))))
            ["profile", "gate", "invariant", "work order", "scheduler", "digest"]
    , testCase "unknown projects and other addresses are 404; bodies over 16 KiB are refused" $
        withChecks $ \svc -> do
          pid <- newProject svc "Website" "new"
          missing <- fragment svc "project-checks/00000000-0000-4000-8000-000000000000"
          responseStatus missing @?= 404
          traverse_
            ( \p -> do
                resp <- httpRequest (svcPort svc) "GET" p [] ""
                assertBool (p <> " gave " <> show (responseStatus resp)) (responseStatus resp == 404)
            )
            ["/app/projects/not-a-uuid/checks", "/app/projects/" <> pid <> "/checks/more", "/app/fragments/project-checks/not-a-uuid"]
          big <- post svc (asOperator svc) ("/app/api/projects/" <> pid <> "/checks") [("expected", BS.replicate 17000 0x61), ("choice", "lockstep-basic")]
          responseStatus big @?= 413
    ]
