{-# LANGUAGE OverloadedStrings #-}

{- | The Projects pages of the application over real HTTP (contract C-P3.5 J7,
J9, J10): the real service with a migrated real PostgreSQL database and
@LOCKSTEP_PROJECT_FOLDERS@ naming temporary folders; the session comes from the
real CLI as in C-P3.4.
-}
module Lockstep.ProjectsPageTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Maybe (fromMaybe, isJust)
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTPTypes
import System.Directory (createDirectory)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath)
import System.IO.Temp (withSystemTempDirectory)
import System.Process qualified as Process
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Support.Http (HttpResponse (..), httpRequest, responseHeader)
import Lockstep.Support.Postgres (AdminSettings (..), requireAdmin, withFreshDatabase, writeConfigFile)
import Lockstep.Support.Process (freePort, runLockstep, withService)

data Svc
  = Svc
  { svcPort :: Int
  , svcEnv :: [(String, String)]
  , svcRoot :: FilePath
  , svcScratch :: FilePath
  }

-- | A migrated database, a projects folder, a scratch folder, and the service seeing only the projects folder.
withProjects :: (Svc -> IO a) -> IO a
withProjects action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-p35-page" $ \dir -> do
      path <- writeConfigFile dir admin db (adminPassword admin)
      createDirectory (dir <> "/projects")
      createDirectory (dir <> "/scratch")
      let
        env = [("LOCKSTEP_CONFIG", path), ("LOCKSTEP_PROJECT_FOLDERS", dir <> "/projects")]
      (code, _, err) <- runLockstep env ["db", "migrate"]
      assertBool ("db migrate failed: " <> err) (code == ExitSuccess)
      port <- freePort
      (result, _) <- withService env port (dir <> "/serve.log") (action (Svc port env (dir <> "/projects") (dir <> "/scratch")))
      pure result

origin :: Svc -> BS.ByteString
origin svc =
  "http://127.0.0.1:" <> BS8.pack (show (svcPort svc))

signIn :: Svc -> IO BS.ByteString
signIn svc = do
  (code, out, err) <- runLockstep (svcEnv svc) ["operator", "sign-in", "--port", show (svcPort svc)]
  code @?= ExitSuccess
  token <-
    case L.stripPrefix "=" (L.dropWhile (/= '=') (L.filter (/= '\n') out)) of
      Just t | L.length t == 43 -> pure (BS8.pack t)
      _ -> assertFailure ("unexpected sign-in output: " <> out <> err)
  resp <- httpRequest (svcPort svc) "POST" "/app/api/session" [("Origin", origin svc)] token
  responseStatus resp @?= 200
  pure (BS.take 43 (BS.drop 11 (snd (BS.breakSubstring "\"session\":\"" (responseBody resp)))))

fragment :: Svc -> BS.ByteString -> String -> IO HttpResponse
fragment svc session path =
  httpRequest (svcPort svc) "GET" ("/app/fragments/" <> path) [("X-Lockstep-Session", session)] ""

post :: Svc -> [HTTPTypes.Header] -> String -> [(BS.ByteString, BS.ByteString)] -> IO HttpResponse
post svc headers path fields =
  httpRequest (svcPort svc) "POST" path (("Content-Type", "application/x-www-form-urlencoded") : headers) (HTTPTypes.renderSimpleQuery False fields)

asOperator :: Svc -> BS.ByteString -> [HTTPTypes.Header]
asOperator svc session =
  [("Origin", origin svc), ("X-Lockstep-Session", session)]

contains :: BS.ByteString -> BS.ByteString -> Bool
contains needle haystack =
  not (BS.null (snd (BS.breakSubstring needle haystack)))

-- | The value of the first @name="NAME" value="…"@ input in a page.
inputValue :: BS.ByteString -> BS.ByteString -> Maybe BS.ByteString
inputValue name page =
  let
    after = snd (BS.breakSubstring ("name=\"" <> name <> "\" value=\"") page)
  in
    if BS.null after
      then Nothing
      else Just (BS.takeWhile (/= 0x22) (BS.drop (BS.length name + 15) after))

-- | Creates a project from the new-project page; returns the answer and its project path.
createVia :: Svc -> BS.ByteString -> [(BS.ByteString, BS.ByteString)] -> IO (HttpResponse, BS.ByteString)
createVia svc session fields = do
  form <- fragment svc session "project-new"
  responseStatus form @?= 200
  formKey <- maybe (assertFailure ("no key in the form: " <> show (responseBody form))) pure (inputValue "key" (responseBody form))
  resp <- post svc (asOperator svc session) "/app/api/projects" (("key", formKey) : fields)
  responseStatus resp @?= 200
  pure (resp, fromMaybe "" (responseHeader "X-Lockstep-Path" resp))

git :: FilePath -> [String] -> Assertion
git dir args = do
  base <- getEnvironment
  let
    identity = ["-c", "user.name=Lockstep Test", "-c", "user.email=test@example.invalid", "-c", "init.defaultBranch=main"]
  (code, out, err) <- Process.readCreateProcessWithExitCode ((Process.proc "git" (identity <> args)) {Process.cwd = Just dir, Process.env = Just base}) ""
  assertBool ("git " <> show args <> " failed: " <> out <> err) (code == ExitSuccess)

newRepo :: FilePath -> String -> IO FilePath
newRepo dir name = do
  git dir ["init", "-q", name]
  git (dir <> "/" <> name) ["commit", "-q", "--allow-empty", "-m", "first"]
  pure (dir <> "/" <> name)

tests :: TestTree
tests =
  testGroup
    "Projects pages over HTTP (C-P3.5)"
    [ testCase "the new-project page asks for a name, an outcome and a folder, with a new folder as the default" $
        withProjects $ \svc -> do
          session <- signIn svc
          page <- fragment svc session "project-new"
          responseStatus page @?= 200
          let
            body = responseBody page
          traverse_
            (\needle -> assertBool ("missing " <> show needle <> ": " <> show body) (contains needle body))
            [ "<form"
            , "action=\"/app/api/projects\""
            , "name=\"name\""
            , "name=\"outcome\""
            , "name=\"folder\" value=\"new\" checked"
            , "name=\"folder\" value=\"existing\""
            , "name=\"folder\" value=\"later\""
            , "<label"
            ]
          assertBool "no key" (isJust (inputValue "key" body))
          assertBool "a Git word on the ordinary path" (not (contains "Git" body) && not (contains "repositor" body))
    , testCase "creating needs the session and this origin; the answer is the project page with its status" $
        withProjects $ \svc -> do
          session <- signIn svc
          form <- fragment svc session "project-new"
          formKey <- maybe (assertFailure "no key") pure (inputValue "key" (responseBody form))
          let
            fields = [("key", formKey), ("name", "My Site"), ("outcome", "Put my recipes online."), ("folder", "new")]
          none <- post svc [("Origin", origin svc)] "/app/api/projects" fields
          responseStatus none @?= 401
          elsewhere <- post svc [("Origin", "http://127.0.0.1:1"), ("X-Lockstep-Session", session)] "/app/api/projects" fields
          responseStatus elsewhere @?= 403
          noOrigin <- post svc [("X-Lockstep-Session", session)] "/app/api/projects" fields
          responseStatus noOrigin @?= 403
          resp <- post svc (asOperator svc session) "/app/api/projects" fields
          responseStatus resp @?= 200
          let
            body = responseBody resp
            path = fromMaybe "" (responseHeader "X-Lockstep-Path" resp)
          assertBool ("no project path: " <> show path) ("/app/projects/" `BS.isPrefixOf` path && BS.length path == 14 + 36)
          assertBool ("no name: " <> show body) (contains "My Site" body)
          assertBool ("no outcome: " <> show body) (contains "Put my recipes online." body)
          assertBool ("no plain status: " <> show body) (contains "Lockstep can see this folder" body)
          assertBool "it claims it can run code" (contains "cannot change it or run anything in it yet" body)
          shell <- httpRequest (svcPort svc) "GET" (BS8.unpack path) [] ""
          responseStatus shell @?= 200
          again <- fragment svc session (L.drop 5 (BS8.unpack path))
          responseStatus again @?= 404
          shown <- fragment svc session ("project/" <> BS8.unpack (BS.drop 14 path))
          responseStatus shown @?= 200
          assertBool "the project page lacks the name" (contains "My Site" (responseBody shown))
    , testCase "the overview lists projects as links, with no form or button" $
        withProjects $ \svc -> do
          session <- signIn svc
          (_, path) <- createVia svc session [("name", "Garden"), ("outcome", ""), ("folder", "later")]
          overview <- fragment svc session "projects"
          responseStatus overview @?= 200
          let
            body = responseBody overview
          assertBool "no link to the new-project page" (contains "href=\"/app/projects/new\"" body)
          assertBool ("no link to the project: " <> show body) (contains ("href=\"" <> path <> "\"") body)
          assertBool "no name" (contains "Garden" body)
          assertBool "a form on the overview" (not (contains "<form" body))
          assertBool "a button on the overview" (not (contains "<button" body))
          new <- httpRequest (svcPort svc) "GET" "/app/projects/new" [] ""
          responseStatus new @?= 200
    , testCase "only offered folders are listed, and a forged path is refused in plain words" $
        withProjects $ \svc -> do
          alpha <- newRepo (svcRoot svc) "alpha"
          outside <- newRepo (svcScratch svc) "outside"
          session <- signIn svc
          form <- fragment svc session "project-new"
          assertBool "the offered folder is missing" (contains (BS8.pack alpha) (responseBody form))
          assertBool "a folder Lockstep may not see is offered" (not (contains (BS8.pack outside) (responseBody form)))
          (resp, path) <- createVia svc session [("name", "Forged"), ("outcome", ""), ("folder", "existing"), ("path", BS8.pack outside)]
          assertBool ("no project was kept: " <> show path) ("/app/projects/" `BS.isPrefixOf` path)
          assertBool ("not plain: " <> show (responseBody resp)) (contains "not one of the folders Lockstep can see" (responseBody resp))
          assertBool "no Try again" (contains "Try again" (responseBody resp))
          (ok, _) <- createVia svc session [("name", "Alpha"), ("outcome", ""), ("folder", "existing"), ("path", BS8.pack alpha)]
          assertBool ("not connected: " <> show (responseBody ok)) (contains "Lockstep can see this folder" (responseBody ok))
    , testCase "a taken name is explained on the form, which keeps what was typed" $
        withProjects $ \svc -> do
          session <- signIn svc
          _ <- createVia svc session [("name", "Taken"), ("outcome", ""), ("folder", "later")]
          (resp, path) <- createVia svc session [("name", "taken"), ("outcome", "Kept text"), ("folder", "later")]
          path @?= ""
          assertBool ("not explained: " <> show (responseBody resp)) (contains "already has a project with this name" (responseBody resp))
          assertBool "the outcome was lost" (contains "Kept text" (responseBody resp))
    , testCase "Try again with an old revision says the project changed and changes nothing" $
        withProjects $ \svc -> do
          session <- signIn svc
          (_, path) <- createVia svc session [("name", "Later"), ("outcome", ""), ("folder", "later")]
          let
            connectPath = BS8.unpack path <> "/connect"
            apiPath = "/app/api/projects/" <> L.drop 14 connectPath
          stale <- post svc (asOperator svc session) apiPath [("revision", "0"), ("folder", "new")]
          responseStatus stale @?= 200
          assertBool ("not explained: " <> show (responseBody stale)) (contains "changed since this page was shown" (responseBody stale))
          fresh <- post svc (asOperator svc session) apiPath [("revision", "1"), ("folder", "new")]
          responseStatus fresh @?= 200
          assertBool ("not connected: " <> show (responseBody fresh)) (contains "Lockstep can see this folder" (responseBody fresh))
    , testCase "text people typed is escaped" $
        withProjects $ \svc -> do
          session <- signIn svc
          (resp, _) <- createVia svc session [("name", "<script>alert(1)</script>"), ("outcome", "<img src=x onerror=alert(2)>"), ("folder", "later")]
          let
            body = responseBody resp
          assertBool "markup was not escaped" (not (contains "<script>alert(1)" body) && not (contains "<img src=x" body))
          assertBool ("the name is missing: " <> show body) (contains "&lt;script&gt;alert(1)&lt;/script&gt;" body)
          overview <- fragment svc session "projects"
          assertBool "the overview did not escape" (not (contains "<script>alert(1)" (responseBody overview)))
    , testCase "unknown projects and other addresses are 404; bodies over 16 KiB are refused" $
        withProjects $ \svc -> do
          session <- signIn svc
          missing <- fragment svc session "project/00000000-0000-4000-8000-000000000000"
          responseStatus missing @?= 404
          malformed <- fragment svc session "project/not-a-uuid"
          responseStatus malformed @?= 404
          traverse_
            ( \p -> do
                resp <- httpRequest (svcPort svc) "GET" p [] ""
                assertBool (p <> " gave " <> show (responseStatus resp)) (responseStatus resp == 404)
            )
            ["/app/projects/not-a-uuid", "/app/projects/new/x", "/app/fragments/project-new/x"]
          big <- post svc (asOperator svc session) "/app/api/projects" [("name", "Big"), ("outcome", BS.replicate 17000 0x61), ("folder", "later")]
          responseStatus big @?= 413
    ]
