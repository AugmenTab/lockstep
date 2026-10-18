{-# LANGUAGE OverloadedStrings #-}

module Lockstep.CommandCenterTest
  ( tests
  ) where

import Control.Concurrent (threadDelay)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTP
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Database (runMigrations)
import Lockstep.Foundation.OperatorToken (csrfFor, decodeToken)
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Http (HttpResponse (..), httpRequest, responseHeader, responseHeaders)
import Lockstep.Support.Postgres
  ( AdminSettings (..)
  , adminExecute
  , databaseConfigFor
  , queryInts
  , requireAdmin
  , withFreshDatabase
  , withRuntime
  , writeConfigFile
  )
import Lockstep.Support.Process (freePort, runLockstep, withService)

tests :: TestTree
tests =
  testGroup
    "command center (PostgreSQL + real binary)"
    [ testCase "the page projects canonical rows truthfully; tampered or missing evidence is never PASSED" $
        withMigrated $ \fx dir -> do
          (c1, _, _) <- runLockstep (fxEnv fx) ["workspace", "rename", "--expected-revision", "0", "--idempotency-key", key 1, "One"]
          c1 @?= ExitSuccess
          (c2, _, _) <- runLockstep (fxEnv fx) ["workspace", "rename", "--expected-revision", "0", "--idempotency-key", key 2, "Two"]
          c2 @?= ExitFailure 65
          queue fx 3 ["--steps", "2", "--step-ms", "50"]
          queue fx 4 ["--steps", "1", "--step-ms", "50"]
          queue fx 5 ["--steps", "3", "--step-ms", "50", "--fail-at-step", "2"]
          port <- freePort
          (_, serverLog) <-
            withService (fxEnv fx) port (dir <> "/serve.log") $ do
              settled <- pollUntil 15000 ((== [3]) <$> sql fx "SELECT count(*)::integer AS v FROM lockstep_jobs WHERE state IN ('succeeded', 'failed')")
              assertBool "the first three jobs did not settle" settled
              queue fx 6 ["--steps", "20", "--step-ms", "5000"]
              queue fx 7 ["--steps", "1", "--step-ms", "50"]
              running <- pollUntil 10000 ((== [1]) <$> sql fx "SELECT count(*)::integer AS v FROM lockstep_jobs WHERE id = 4 AND state = 'running'")
              assertBool "job 4 did not start" running
              cookie <- signIn fx port
              page <- center port cookie
              responseStatus page @?= 200
              responseHeader "Cache-Control" page @?= Just "no-store"
              let
                body = responseBody page
              traverse_
                (\(status, n) -> assertContains ("data-status=\"" <> status <> "\" data-count=\"" <> BS8.pack (show n) <> "\"") body)
                [ ("jobs:queued", 1 :: Int)
                , ("jobs:running", 1)
                , ("jobs:succeeded", 2)
                , ("jobs:failed", 1)
                , ("receipts:applied", 1)
                , ("receipts:queued", 5)
                , ("receipts:refused_stale", 1)
                ]
              sqlCounts <-
                traverse
                  (sql fx)
                  [ "SELECT count(*)::integer AS v FROM lockstep_jobs WHERE state = 'queued'"
                  , "SELECT count(*)::integer AS v FROM lockstep_jobs WHERE state = 'running'"
                  , "SELECT count(*)::integer AS v FROM lockstep_command_receipts WHERE outcome = 'refused_stale'"
                  ]
              sqlCounts @?= [[1], [1], [1]]
              traverse_
                (\(job, label) -> assertContains ("data-criterion=\"AC-JOB-" <> job <> "@v1\" data-disposition=\"" <> label <> "\"") body)
                [ ("1", "PASSED")
                , ("2", "PASSED")
                , ("3", "FAILED")
                , ("4", "NOT_RUN (in progress)")
                , ("5", "NOT_RUN (queued)")
                ]
              assertContains "data-aggregate=\"FAILED\"" body
              assertContains "refused_stale" body
              assertContains "/operator/receipts/2" body
              adminExecute (fxAdmin fx) (T.unpack (fxDb fx)) "UPDATE lockstep_jobs SET steps_done = 1 WHERE id = 1"
              adminExecute (fxAdmin fx) (T.unpack (fxDb fx)) "UPDATE lockstep_jobs SET outcome_digest = NULL WHERE id = 2"
              after <- center port cookie
              assertContains "data-criterion=\"AC-JOB-1@v1\" data-disposition=\"INCONCLUSIVE (evidence changed)\"" (responseBody after)
              assertContains "data-criterion=\"AC-JOB-2@v1\" data-disposition=\"INCONCLUSIVE (incomplete evidence)\"" (responseBody after)
              assertLacks "data-disposition=\"PASSED\"" (responseBody after)
              assertContains "data-aggregate=\"FAILED\"" (responseBody after)
          noSecret fx [serverLog]
    , testCase "an operator action visibly changes the page" $
        withMigrated $ \fx dir -> do
          port <- freePort
          _ <-
            withService (fxEnv fx) port (dir <> "/serve.log") $ do
              cookie <- signIn fx port
              before <- center port cookie
              assertContains "data-status=\"receipts:queued\" data-count=\"0\"" (responseBody before)
              assertContains "/operator/jobs/new" (responseBody before)
              csrf <- csrfOf cookie
              posted <-
                httpRequest
                  port
                  "POST"
                  "/operator/commands/queue-noop"
                  [formType, cookieHeader cookie, origin port]
                  ("steps=20&step_ms=5000&fail_at_step=&expected_revision=0&idempotency_key=" <> BS8.pack (key 9) <> "&csrf=" <> csrf)
              responseStatus posted @?= 303
              location <- maybe (assertFailure "no Location") pure (responseHeader HTTP.hLocation posted)
              after <- center port cookie
              assertContains "data-status=\"receipts:queued\" data-count=\"1\"" (responseBody after)
              assertContains location (responseBody after)
              assertContains "data-criterion=\"AC-JOB-1@v1\"" (responseBody after)
          pure ()
    , testCase "no session is 401; a database that stops being ready shows a notice and no evidence" $
        withMigrated $ \fx dir -> do
          port <- freePort
          _ <-
            withService (fxEnv fx) port (dir <> "/serve.log") $ do
              anonymous <- httpRequest port "GET" "/operator/center" [] ""
              responseStatus anonymous @?= 401
              queue fx 3 ["--steps", "1", "--step-ms", "0"]
              done <- pollUntil 10000 ((== [1]) <$> sql fx "SELECT count(*)::integer AS v FROM lockstep_jobs WHERE state = 'succeeded'")
              assertBool "the job did not succeed" done
              cookie <- signIn fx port
              adminExecute
                (fxAdmin fx)
                (T.unpack (fxDb fx))
                "INSERT INTO lockstep_schema_migrations (id, description, checksum) VALUES (99, 'forged', 'forged')"
              page <- center port cookie
              responseStatus page @?= 200
              assertContains "unavailable" (BS8.map Char.toLower (responseBody page))
              assertLacks "data-criterion=" (responseBody page)
              assertLacks "PASSED" (responseBody page)
          pure ()
    , testCase "db migrate from revision 4 needs a backup decision for migration 0005" $ do
        admin <- requireAdmin
        withFreshDatabase admin $ \db ->
          withSystemTempDirectory "lockstep-config" $ \dir -> do
            config <- databaseConfigFor admin db
            first <- withRuntime config (runMigrations (L.take 4 migrations))
            fmap L.length first @?= Right 4
            path <- writeConfigFile dir admin db (adminPassword admin)
            let
              env = [("LOCKSTEP_CONFIG", path)]
            (code, _, _) <- runLockstep env ["db", "migrate"]
            code @?= ExitFailure 75
            (code2, out2, _) <- runLockstep env ["db", "migrate", "--no-backup"]
            code2 @?= ExitSuccess
            assertBool ("unexpected: " <> out2) ("applied migrations: 5" `L.isInfixOf` out2)
    ]

data Fixture
  = Fixture
  { fxAdmin :: AdminSettings
  , fxDb :: T.Text
  , fxEnv :: [(String, String)]
  }

key :: Int -> String
key n =
  "center-key-" <> L.replicate (8 - L.length (show n)) '0' <> show n

withMigrated :: (Fixture -> String -> IO a) -> IO a
withMigrated action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-center" $ \dir -> do
      path <- writeConfigFile dir admin db (adminPassword admin)
      let
        fx = Fixture admin db [("LOCKSTEP_CONFIG", path)]
      (code, _, err) <- runLockstep (fxEnv fx) ["db", "migrate"]
      assertBool ("db migrate failed: " <> err) (code == ExitSuccess)
      action fx dir

queue :: Fixture -> Int -> [String] -> Assertion
queue fx n extra = do
  (_, shown, _) <- runLockstep (fxEnv fx) ["workspace", "show"]
  revision <-
    maybe (assertFailure ("no revision in: " <> shown)) pure (L.stripPrefix "revision: " =<< L.find ("revision: " `L.isPrefixOf`) (L.lines shown))
  (code, out, err) <- runLockstep (fxEnv fx) (["job", "queue", "--expected-revision", revision, "--idempotency-key", key n] <> extra)
  assertBool ("job queue failed: " <> out <> err) (code == ExitSuccess)

sql :: Fixture -> String -> IO [Int]
sql fx =
  queryInts (fxAdmin fx) (fxDb fx)

pollUntil :: Int -> IO Bool -> IO Bool
pollUntil remainingMillis check = do
  ok <- check
  if ok || remainingMillis <= 0
    then pure ok
    else threadDelay 200000 >> pollUntil (remainingMillis - 200) check

signIn :: Fixture -> Int -> IO BS.ByteString
signIn fx port = do
  (code, out, _) <- runLockstep (fxEnv fx) ["operator", "sign-in", "--port", show port]
  code @?= ExitSuccess
  token <-
    maybe (assertFailure "no token") pure $
      L.stripPrefix ("http://127.0.0.1:" <> show port <> "/operator/sign-in?token=") (L.filter (/= '\n') out)
  response <- httpRequest port "POST" "/operator/sign-in" [formType, origin port] ("token=" <> BS8.pack token)
  responseStatus response @?= 303
  case responseHeaders "Set-Cookie" response of
    [value] | Just rest <- BS.stripPrefix "lockstep_session=" value -> pure (BS8.takeWhile (/= ';') rest)
    other -> assertFailure ("unexpected Set-Cookie: " <> show other)

csrfOf :: BS.ByteString -> IO BS.ByteString
csrfOf cookie =
  maybe (assertFailure "cookie is not a token") (pure . TE.encodeUtf8 . csrfFor) (decodeToken (TE.decodeLatin1 cookie))

center :: Int -> BS.ByteString -> IO HttpResponse
center port cookie =
  httpRequest port "GET" "/operator/center" [cookieHeader cookie] ""

origin :: Int -> HTTP.Header
origin port =
  ("Origin", "http://127.0.0.1:" <> BS8.pack (show port))

formType :: HTTP.Header
formType =
  (HTTP.hContentType, "application/x-www-form-urlencoded")

cookieHeader :: BS.ByteString -> HTTP.Header
cookieHeader value =
  (HTTP.hCookie, "lockstep_session=" <> value)

assertContains :: BS.ByteString -> BS.ByteString -> Assertion
assertContains needle haystack =
  assertBool ("expected the page to contain " <> BS8.unpack needle) (needle `BS.isInfixOf` haystack)

assertLacks :: BS.ByteString -> BS.ByteString -> Assertion
assertLacks needle haystack =
  assertBool ("expected the page not to contain " <> BS8.unpack needle) (not (needle `BS.isInfixOf` haystack))

noSecret :: Fixture -> [String] -> Assertion
noSecret fx outputs =
  assertBool "the database password appeared in output" (not (any (adminPassword (fxAdmin fx) `L.isInfixOf`) outputs))
