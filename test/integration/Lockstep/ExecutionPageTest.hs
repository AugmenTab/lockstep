{-# LANGUAGE OverloadedStrings #-}

{- | Letting Lockstep work in a project and handing it a bug, over real HTTP
(contract C-P4.1 X10, X11): the real service with a migrated real PostgreSQL
database and @LOCKSTEP_PROJECT_FOLDERS@ naming a temporary projects folder and
one Git folder added from elsewhere; the session comes from the real CLI as in
C-P3.4.
-}
module Lockstep.ExecutionPageTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTPTypes
import System.Directory (createDirectory)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath)
import System.IO.Temp (withSystemTempDirectory)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Support.Http (HttpResponse (..), httpRequest, responseHeader)
import Lockstep.Support.Postgres (AdminSettings (..), queryInts, requireAdmin, withFreshDatabase, writeConfigFile)
import Lockstep.Support.Process (freePort, runLockstep, withService)

data Svc
  = Svc
  { svcPort :: Int
  , svcSession :: BS.ByteString
  , svcCount :: String -> IO Int
  , svcElsewhere :: FilePath
  }

gitInit :: FilePath -> String -> IO ()
gitInit dir name = do
  base <- getEnvironment
  let
    env = ("GIT_CONFIG_NOSYSTEM", "1") : L.filter ((/= "GIT_CONFIG_NOSYSTEM") . fst) base
  result <-
    timeout 30000000 $
      Process.readCreateProcessWithExitCode ((Process.proc "git" ["-c", "init.defaultBranch=main", "init", "-q", name]) {Process.cwd = Just dir, Process.env = Just env}) ""
  case result of
    Just (ExitSuccess, _, _) -> pure ()
    other -> assertFailure ("git init failed: " <> show other)

-- | A migrated database, a projects folder and one Git folder added from elsewhere, the service and a signed-in session.
withExecution :: (Svc -> IO a) -> IO a
withExecution action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-p41-page" $ \dir -> do
      path <- writeConfigFile dir admin db (adminPassword admin)
      createDirectory (dir <> "/projects")
      createDirectory (dir <> "/elsewhere")
      gitInit (dir <> "/elsewhere") "site"
      let
        env = [("LOCKSTEP_CONFIG", path), ("LOCKSTEP_PROJECT_FOLDERS", dir <> "/projects:" <> dir <> "/elsewhere/site")]
        counter table = do
          rows <- queryInts admin db ("SELECT count(*)::integer AS v FROM " <> table)
          case rows of
            [n] -> pure n
            _ -> assertFailure ("count " <> table)
      (code, _, err) <- runLockstep env ["db", "migrate"]
      assertBool ("db migrate failed: " <> err) (code == ExitSuccess)
      port <- freePort
      (result, _) <-
        withService env port (dir <> "/serve.log") $ do
          session <- signIn port env
          action (Svc port session counter (dir <> "/elsewhere/site"))
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

lacks :: BS.ByteString -> [BS.ByteString] -> IO ()
lacks body =
  traverse_ (\needle -> assertBool ("unexpected " <> show needle <> ": " <> show body) (not (contains needle body)))

inputValue :: BS.ByteString -> BS.ByteString -> Maybe BS.ByteString
inputValue name page =
  let
    after = snd (BS.breakSubstring ("name=\"" <> name <> "\" value=\"") page)
  in
    if BS.null after
      then Nothing
      else Just (BS.takeWhile (/= 0x22) (BS.drop (BS.length name + 15) after))

-- | The named form's fields (hidden inputs) as the page rendered them.
formFields :: BS.ByteString -> BS.ByteString -> [BS.ByteString] -> IO [(BS.ByteString, BS.ByteString)]
formFields formId page names = do
  let
    form = fst (BS.breakSubstring "</form>" (snd (BS.breakSubstring ("id=\"" <> formId <> "\"") page)))
  assertBool ("no form " <> show formId <> ": " <> show page) (not (BS.null form))
  traverse (\n -> maybe (assertFailure ("no field " <> show n <> " in " <> show form)) (\v -> pure (n, v)) (inputValue n form)) names

-- | A project through the C-P3.5 form; returns its id.
newProject :: Svc -> BS.ByteString -> [(BS.ByteString, BS.ByteString)] -> IO String
newProject svc name folder = do
  form <- fragment svc "project-new"
  k <- maybe (assertFailure "no project key") pure (inputValue "key" (responseBody form))
  resp <- post svc (asOperator svc) "/app/api/projects" ([("key", k), ("name", name), ("outcome", "")] <> folder)
  responseStatus resp @?= 200
  case BS.stripPrefix "/app/projects/" (fromMaybe "" (responseHeader "X-Lockstep-Path" resp)) of
    Just pid -> pure (BS8.unpack pid)
    Nothing -> assertFailure ("no project address: " <> show (responseBody resp))

inNewFolder :: [(BS.ByteString, BS.ByteString)]
inNewFolder =
  [("folder", "new")]

-- | A task through the C-P3.6 form, optionally marked ready; returns its id.
newTask :: Svc -> String -> BS.ByteString -> Bool -> IO String
newTask svc pid title markReady = do
  form <- fragment svc ("task-new/" <> pid)
  k <- maybe (assertFailure "no task key") pure (inputValue "key" (responseBody form))
  resp <- post svc (asOperator svc) ("/app/api/projects/" <> pid <> "/tasks") [("key", k), ("title", title), ("acceptance", "The link opens the menu."), ("priority", "normal")]
  tid <- maybe (assertFailure "no task address") (pure . BS8.unpack) (BS.stripPrefix "/app/tasks/" (fromMaybe "" (responseHeader "X-Lockstep-Path" resp)))
  when markReady $ do
    r <- maybe (assertFailure "no ticket revision") pure (inputValue "ticket_revision" (responseBody resp))
    marked <- post svc (asOperator svc) ("/app/api/tasks/" <> tid <> "/decide") [("ticket_revision", r), ("action", "ready")]
    assertBool "not marked ready" (contains "Ready to work on." (responseBody marked))
  pure tid

-- | Lets Lockstep work in the project through its page's form; returns the answer.
allow :: Svc -> String -> IO HttpResponse
allow svc pid = do
  page <- fragment svc ("project/" <> pid)
  fields <- formFields "enable-form" (responseBody page) ["key", "expected", "expected_set"]
  resp <- post svc (asOperator svc) ("/app/api/projects/" <> pid <> "/execution") fields
  responseStatus resp @?= 200
  pure resp

-- | The section of a page from the element with this id to the next second-level heading.
sectionOf :: BS.ByteString -> BS.ByteString -> BS.ByteString
sectionOf sectionId body =
  let
    start = snd (BS.breakSubstring ("id=\"" <> sectionId <> "\"") body)
    rest = BS.drop 1 start
  in
    BS.take 1 start <> fst (BS.breakSubstring "<h2" rest)

-- | Lower-case text before any technical details.
ordinary :: BS.ByteString -> BS.ByteString
ordinary =
  BS8.map Char.toLower . fst . BS.breakSubstring "<details"

internalWords :: [BS.ByteString]
internalWords =
  ["profile", "gate", "invariant", "work order", "ticket", "engineer", "scheduler", "digest", "supervisor", "repositor", "phase", "work unit", "contract"]

tests :: TestTree
tests =
  testGroup
    "letting Lockstep work in a project and handing it a bug over HTTP (C-P4.1)"
    [ testCase "the project page's Fixing bugs section says what is possible in each state" $
        withExecution $ \svc -> do
          later <- newProject svc "Kitchen" [("folder", "later")]
          noFolder <- responseBody <$> fragment svc ("project/" <> later)
          has (sectionOf "execution" noFolder) ["Fixing bugs", "Connect a folder"]
          lacks noFolder ["id=\"enable-form\""]
          site <- newProject svc "Site" [("folder", "existing"), ("path", BS8.pack (svcElsewhere svc))]
          readOnly <- responseBody <$> fragment svc ("project/" <> site)
          has (sectionOf "execution" readOnly) ["Fixing bugs", "only reads it"]
          lacks readOnly ["id=\"enable-form\""]
          website <- newProject svc "Website" inNewFolder
          page <- responseBody <$> fragment svc ("project/" <> website)
          has
            (sectionOf "execution" page)
            [ "Fixing bugs"
            , "id=\"enable-form\""
            , "action=\"/app/api/projects/" <> BS8.pack website <> "/execution\""
            , "name=\"key\""
            , "name=\"expected\" value=\"none\""
            , "name=\"expected_set\" value=\"no\""
            , "id=\"enable-execution\""
            , "Let Lockstep fix bugs here"
            , "reproduce"
            ]
          has page ["cannot change it or run anything in it yet"]
    , testCase "allowing needs the session and this origin; the answer is the project page, and a repeated form changes nothing" $
        withExecution $ \svc -> do
          pid <- newProject svc "Website" inNewFolder
          page <- fragment svc ("project/" <> pid)
          fields <- formFields "enable-form" (responseBody page) ["key", "expected", "expected_set"]
          let
            path = "/app/api/projects/" <> pid <> "/execution"
          none <- post svc [("Origin", origin (svcPort svc))] path fields
          responseStatus none @?= 401
          elsewhere <- post svc [("Origin", "http://127.0.0.1:1"), ("X-Lockstep-Session", svcSession svc)] path fields
          responseStatus elsewhere @?= 403
          svcCount svc "lockstep_execution_enablements" >>= (@?= 0)
          resp <- post svc (asOperator svc) path fields
          responseStatus resp @?= 200
          responseHeader "X-Lockstep-Path" resp @?= Just (BS8.pack ("/app/projects/" <> pid))
          has (sectionOf "execution" (responseBody resp)) ["Lockstep may work on bugs in this project.", "Nothing has run yet"]
          lacks (responseBody resp) ["id=\"enable-form\""]
          again <- post svc (asOperator svc) path fields
          responseStatus again @?= 200
          has (sectionOf "execution" (responseBody again)) ["Lockstep may work on bugs in this project."]
          svcCount svc "lockstep_execution_enablements" >>= (@?= 1)
    , testCase "a form shown before the checks changed is explained in words and changes nothing" $
        withExecution $ \svc -> do
          pid <- newProject svc "Website" inNewFolder
          page <- fragment svc ("project/" <> pid)
          fields <- formFields "enable-form" (responseBody page) ["key", "expected", "expected_set"]
          chosen <- post svc (asOperator svc) ("/app/api/projects/" <> pid <> "/checks") [("expected", "none"), ("choice", "lockstep-basic")]
          has (responseBody chosen) ["Saved."]
          resp <- post svc (asOperator svc) ("/app/api/projects/" <> pid <> "/execution") fields
          responseStatus resp @?= 200
          has (responseBody resp) ["changed since this page was shown"]
          svcCount svc "lockstep_execution_enablements" >>= (@?= 0)
    , testCase "the task page offers handing a bug over only when allowed and ready; afterwards the bug is in line" $
        withExecution $ \svc -> do
          pid <- newProject svc "Website" inNewFolder
          tid <- newTask svc pid "The menu link is broken" True
          before <- responseBody <$> fragment svc ("task/" <> tid)
          lacks before ["id=\"admit-form\""]
          _ <- allow svc pid
          proposed <- newTask svc pid "Not looked at yet" False
          notReady <- responseBody <$> fragment svc ("task/" <> proposed)
          lacks notReady ["id=\"admit-form\""]
          page <- responseBody <$> fragment svc ("task/" <> tid)
          has
            (sectionOf "fixing" page)
            [ "id=\"admit-form\""
            , "action=\"/app/api/tasks/" <> BS8.pack tid <> "/bug\""
            , "name=\"key\""
            , "name=\"ticket_revision\""
            , "id=\"admit-bug\""
            , "Ask Lockstep to fix this bug"
            ]
          fields <- formFields "admit-form" page ["key", "ticket_revision"]
          resp <- post svc (asOperator svc) ("/app/api/tasks/" <> tid <> "/bug") fields
          responseStatus resp @?= 200
          responseHeader "X-Lockstep-Path" resp @?= Just (BS8.pack ("/app/tasks/" <> tid))
          has (sectionOf "fixing" (responseBody resp)) ["Lockstep has this bug in line to fix.", "first in line"]
          has (responseBody resp) ["Nothing runs it yet"]
          lacks (responseBody resp) ["id=\"admit-form\""]
          again <- post svc (asOperator svc) ("/app/api/tasks/" <> tid <> "/bug") fields
          has (sectionOf "fixing" (responseBody again)) ["Lockstep has this bug in line to fix."]
          svcCount svc "lockstep_bug_admissions" >>= (@?= 1)
          svcCount svc "lockstep_work_orders" >>= (@?= 1)
          svcCount svc "lockstep_schedule_decisions" >>= (@?= 0)
    , testCase "handing over needs the session and this origin; a task page shown at an old revision is explained" $
        withExecution $ \svc -> do
          pid <- newProject svc "Website" inNewFolder
          _ <- allow svc pid
          tid <- newTask svc pid "The menu link is broken" True
          page <- responseBody <$> fragment svc ("task/" <> tid)
          fields <- formFields "admit-form" page ["key", "ticket_revision"]
          let
            path = "/app/api/tasks/" <> tid <> "/bug"
          none <- post svc [("Origin", origin (svcPort svc))] path fields
          responseStatus none @?= 401
          elsewhere <- post svc [("Origin", "http://127.0.0.1:1"), ("X-Lockstep-Session", svcSession svc)] path fields
          responseStatus elsewhere @?= 403
          revision <- maybe (assertFailure "no revision") pure (L.lookup "ticket_revision" fields)
          blocked <- post svc (asOperator svc) ("/app/api/tasks/" <> tid <> "/decide") [("ticket_revision", revision), ("action", "block"), ("reason", "waiting for the designer")]
          has (responseBody blocked) ["Blocked: waiting for the designer"]
          stale <- post svc (asOperator svc) path fields
          responseStatus stale @?= 200
          has (responseBody stale) ["changed since this page was shown"]
          svcCount svc "lockstep_bug_admissions" >>= (@?= 0)
          svcCount svc "lockstep_work_orders" >>= (@?= 0)
    , testCase "typed text is escaped, and the new sections have no internal words outside Technical details" $
        withExecution $ \svc -> do
          pid <- newProject svc "Website" inNewFolder
          project <- responseBody <$> fragment svc ("project/" <> pid)
          traverse_
            (\word -> assertBool ("internal word " <> show word <> " before allowing") (not (contains word (ordinary (sectionOf "execution" project)))))
            internalWords
          allowed <- responseBody <$> allow svc pid
          traverse_
            (\word -> assertBool ("internal word " <> show word <> " once allowed") (not (contains word (ordinary (sectionOf "execution" allowed)))))
            internalWords
          tid <- newTask svc pid "<script>alert(1)</script>" True
          page <- responseBody <$> fragment svc ("task/" <> tid)
          lacks page ["<script>alert(1)"]
          has page ["&lt;script&gt;alert(1)&lt;/script&gt;"]
          fields <- formFields "admit-form" page ["key", "ticket_revision"]
          resp <- responseBody <$> post svc (asOperator svc) ("/app/api/tasks/" <> tid <> "/bug") fields
          lacks resp ["<script>alert(1)"]
          has resp ["<details"]
          traverse_
            (\word -> assertBool ("internal word " <> show word <> " in the task's section") (not (contains word (ordinary (sectionOf "fixing" resp)))))
            internalWords
    , testCase "unknown projects and tasks and other addresses are 404; bodies over 16 KiB are refused" $
        withExecution $ \svc -> do
          pid <- newProject svc "Website" inNewFolder
          tid <- newTask svc pid "The menu link is broken" True
          unknownProject <- post svc (asOperator svc) "/app/api/projects/00000000-0000-4000-8000-000000000000/execution" [("key", "aaaaaaaaaaaaaaaaaaaaaa"), ("expected", "none"), ("expected_set", "no")]
          responseStatus unknownProject @?= 404
          unknownTask <- post svc (asOperator svc) "/app/api/tasks/00000000-0000-4000-8000-000000000000/bug" [("key", "aaaaaaaaaaaaaaaaaaaaaa"), ("ticket_revision", "2")]
          responseStatus unknownTask @?= 404
          traverse_
            ( \p -> do
                resp <- post svc (asOperator svc) p [("key", "aaaaaaaaaaaaaaaaaaaaaa")]
                assertBool (p <> " gave " <> show (responseStatus resp)) (responseStatus resp == 404)
            )
            ["/app/api/projects/not-a-uuid/execution", "/app/api/tasks/not-a-uuid/bug", "/app/api/projects/" <> pid <> "/execution/more"]
          big <- post svc (asOperator svc) ("/app/api/projects/" <> pid <> "/execution") [("key", BS.replicate 17000 0x61)]
          responseStatus big @?= 413
          bigger <- post svc (asOperator svc) ("/app/api/tasks/" <> tid <> "/bug") [("key", BS.replicate 17000 0x61)]
          responseStatus bigger @?= 413
          svcCount svc "lockstep_execution_enablements" >>= (@?= 0)
    ]
