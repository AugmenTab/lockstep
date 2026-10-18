{-# LANGUAGE OverloadedStrings #-}

module Lockstep.DispatcherTest
  ( tests
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket, try)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Maybe (isNothing)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Flipstone.Prelude
import Network.HTTP.Client qualified as HTTPClient
import Network.HTTP.Types qualified as HTTP
import Network.Socket qualified as Socket
import Network.Socket.ByteString qualified as SocketBS
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.IO (IOMode (WriteMode), openFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Signals (Signal, sigKILL, sigTERM, signalProcess)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Database (runMigrations)
import Lockstep.Foundation.OperatorToken (csrfFor, decodeToken)
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Http (HttpResponse (..), httpRequest, responseHeader, responseHeaders)
import Lockstep.Support.Postgres
  ( AdminSettings (..)
  , databaseConfigFor
  , queryBool
  , queryInts
  , requireAdmin
  , withFreshDatabase
  , withRuntime
  , writeConfigFile
  )
import Lockstep.Support.Process (freePort, httpGet, runLockstep)

tests :: TestTree
tests =
  testGroup
    "background dispatcher (PostgreSQL + real binary)"
    [ testCase "the CLI only queues; a running service executes the job" $
        withMigrated $ \fx dir -> do
          (code, out, err) <- queueJob fx 0 (Just keyA) ["--steps", "3", "--step-ms", "50"]
          code @?= ExitSuccess
          err @?= ""
          out @?= "receipt 1 queued revision 0 key " <> keyA <> " job 1\n"
          threadDelay 1000000
          jobState fx 1 >>= (@?= "queued")
          stepsDone fx 1 >>= (@?= [0])
          withServe fx dir "a" $ \_ -> do
            done <- pollUntil 10000 (isState fx 1 "succeeded")
            assertBool "the job did not succeed" done
          (_, shown, _) <- runLockstep (fxEnv fx) ["job", "show", "1"]
          shown @?= "job 1 succeeded steps 3/3 attempts 1\n"
          (_, ws, _) <- runLockstep (fxEnv fx) ["workspace", "show"]
          ws @?= "name: Lockstep\nrevision: 0\n"
          (c2, _, _) <- runLockstep (fxEnv fx) ["job", "show", "99"]
          c2 @?= ExitFailure 65
    , testCase "HTTP admission returns before the work and the job still completes" $
        withMigrated $ \fx dir ->
          withServe fx dir "a" $ \port -> do
            (cookie, csrf) <- signIn fx port
            before <- getCurrentTime
            response <- queuePost port cookie csrf (BS8.pack keyA) "0" "10" "300" ""
            after <- getCurrentTime
            responseStatus response @?= 303
            assertBool "admission waited for the job" (diffUTCTime after before < 1)
            location <- maybe (assertFailure "no Location") pure (responseHeader HTTP.hLocation response)
            assertBool ("unexpected Location " <> show location) ("/operator/receipts/" `BS.isPrefixOf` location)
            unfinished <- queryBool (fxAdmin fx) (fxDb fx) "SELECT state IN ('queued', 'running') AS v FROM lockstep_jobs WHERE id = 1"
            assertBool "the job finished before admission returned" unfinished
            receipt <- httpRequest port "GET" (BS8.unpack location) [cookieHeader cookie] ""
            responseStatus receipt @?= 200
            contains' "queued" (responseBody receipt)
            done <- pollUntil 15000 (isState fx 1 "succeeded")
            assertBool "the job did not succeed" done
            receipt2 <- httpRequest port "GET" (BS8.unpack location) [cookieHeader cookie] ""
            contains' "succeeded" (responseBody receipt2)
    , testCase "a client that disconnects right after queueing does not lose the job" $
        withMigrated $ \fx dir ->
          withServe fx dir "a" $ \port -> do
            (cookie, csrf) <- signIn fx port
            rawPostAndClose port cookie (queueForm csrf (BS8.pack keyA) "0" "2" "50" "")
            done <- pollUntil 10000 (isState fx 1 "succeeded")
            assertBool "the job did not succeed" done
    , testCase "duplicate admission (CLI, then HTTP with the same key) creates one job" $
        withMigrated $ \fx dir ->
          withServe fx dir "a" $ \port -> do
            (_, out, _) <- queueJob fx 0 (Just keyA) ["--steps", "2", "--step-ms", "50"]
            out @?= "receipt 1 queued revision 0 key " <> keyA <> " job 1\n"
            (cookie, csrf) <- signIn fx port
            again <- queuePost port cookie csrf (BS8.pack keyA) "0" "2" "50" ""
            responseStatus again @?= 303
            responseHeader HTTP.hLocation again @?= Just "/operator/receipts/1"
            (_, out2, _) <- queueJob fx 0 (Just keyA) ["--steps", "2", "--step-ms", "50"]
            out2 @?= "receipt 1 queued revision 0 key " <> keyA <> " job 1 (replayed)\n"
            count fx "lockstep_jobs" >>= (@?= [1])
            count fx "lockstep_command_receipts" >>= (@?= [1])
    , testCase "a deterministic failure stops the job at its step and is not retried" $
        withMigrated $ \fx dir ->
          withServe fx dir "a" $ \_ -> do
            _ <- queueJob fx 0 (Just keyA) ["--steps", "3", "--step-ms", "50", "--fail-at-step", "2"]
            failed <- pollUntil 10000 (isState fx 1 "failed")
            assertBool "the job did not fail" failed
            threadDelay 1000000
            (_, shown, _) <- runLockstep (fxEnv fx) ["job", "show", "1"]
            shown @?= "job 1 failed steps 1/3 attempts 1\nerror: deterministic failure injected at step 2\n"
    , testCase "SIGTERM mid-job returns it to the queue; a restart resumes it from its last step" $
        withMigrated $ \fx dir -> do
          _ <- queueJob fx 0 (Just keyA) ["--steps", "10", "--step-ms", "300"]
          withServeStoppedBy sigTERM fx dir "a" $ \_ -> do
            progressed <- pollUntil 10000 ((\n -> n >= [2]) <$> stepsDone fx 1)
            assertBool "the job made no progress" progressed
          jobState fx 1 >>= (@?= "queued")
          interrupted <- stepsDone fx 1
          assertBool ("unexpected progress " <> show interrupted) (interrupted >= [2] && interrupted < [10])
          withServe fx dir "b" $ \_ -> do
            resumedEarly <- pollUntil 3000 ((> interrupted) <$> stepsDone fx 1)
            assertBool "the restarted service did not resume" resumedEarly
            done <- pollUntil 15000 (isState fx 1 "succeeded")
            assertBool "the job did not succeed" done
          (_, shown, _) <- runLockstep (fxEnv fx) ["job", "show", "1"]
          shown @?= "job 1 succeeded steps 10/10 attempts 2\n"
    , testCase "after SIGKILL the job stays running until its lease expires, then is reclaimed" $
        withMigrated $ \fx dir -> do
          _ <- queueJob fx 0 (Just keyA) ["--steps", "10", "--step-ms", "300"]
          withServeStoppedBy sigKILL fx dir "a" $ \_ -> do
            progressed <- pollUntil 10000 ((\n -> n >= [2]) <$> stepsDone fx 1)
            assertBool "the job made no progress" progressed
          jobState fx 1 >>= (@?= "running")
          withServe fx dir "b" $ \_ -> do
            done <- pollUntil 25000 (isState fx 1 "succeeded")
            assertBool "the job was not reclaimed and finished" done
          queryInts (fxAdmin fx) (fxDb fx) "SELECT recovered_count AS v FROM lockstep_jobs WHERE id = 1" >>= (@?= [1])
          queryInts (fxAdmin fx) (fxDb fx) "SELECT attempts AS v FROM lockstep_jobs WHERE id = 1" >>= (@?= [2])
          stepsDone fx 1 >>= (@?= [10])
    , testCase "two services on one database run every job exactly once" $
        withMigrated $ \fx dir -> do
          traverse_ (\k -> queueJob fx 0 (Just k) ["--steps", "3", "--step-ms", "100"]) [keyA, keyB, keyC]
          withServe fx dir "a" $ \_ ->
            withServe fx dir "b" $ \_ -> do
              done <- pollUntil 15000 ((== [3]) <$> queryInts (fxAdmin fx) (fxDb fx) "SELECT count(*)::integer AS v FROM lockstep_jobs WHERE state = 'succeeded'")
              assertBool "not every job succeeded" done
          queryInts (fxAdmin fx) (fxDb fx) "SELECT count(*)::integer AS v FROM lockstep_jobs WHERE attempts <> 1 OR steps_done <> 3" >>= (@?= [0])
    , testCase "db migrate from revision 3 needs a backup decision for migration 0004" $ do
        admin <- requireAdmin
        withFreshDatabase admin $ \db ->
          withSystemTempDirectory "lockstep-config" $ \dir -> do
            config <- databaseConfigFor admin db
            first <- withRuntime config (runMigrations (L.take 3 migrations))
            fmap L.length first @?= Right 3
            path <- writeConfigFile dir admin db (adminPassword admin)
            let
              env = [("LOCKSTEP_CONFIG", path)]
            (code, _, _) <- runLockstep env ["db", "migrate"]
            code @?= ExitFailure 75
            (code2, out2, _) <- runLockstep env ["db", "migrate", "--no-backup"]
            code2 @?= ExitSuccess
            contains "applied migrations: 4" out2
    ]

data Fixture
  = Fixture
  { fxAdmin :: AdminSettings
  , fxDb :: T.Text
  , fxEnv :: [(String, String)]
  }

keyA :: String
keyA =
  "job-key-aaaaaaaaaaaa"

keyB :: String
keyB =
  "job-key-bbbbbbbbbbbb"

keyC :: String
keyC =
  "job-key-cccccccccccc"

withMigrated :: (Fixture -> String -> IO a) -> IO a
withMigrated action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-dispatch" $ \dir -> do
      path <- writeConfigFile dir admin db (adminPassword admin)
      let
        fx = Fixture admin db [("LOCKSTEP_CONFIG", path)]
      (code, _, err) <- runLockstep (fxEnv fx) ["db", "migrate"]
      assertBool ("db migrate failed: " <> err) (code == ExitSuccess)
      action fx dir

queueJob :: Fixture -> Integer -> Maybe String -> [String] -> IO (ExitCode, String, String)
queueJob fx expected key extra =
  runLockstep
    (fxEnv fx)
    (["job", "queue", "--expected-revision", show expected] <> maybe [] (\k -> ["--idempotency-key", k]) key <> extra)

-- | Runs @lockstep serve@ on a free port; stops it with SIGTERM afterwards.
withServe :: Fixture -> String -> String -> (Int -> IO a) -> IO a
withServe =
  withServeStoppedBy sigTERM

{- | Runs @lockstep serve@ on a free port until the action returns, then sends
the signal and waits (at most 10 s) for the process to exit. The server log
must never contain the database password.
-}
withServeStoppedBy :: Signal -> Fixture -> String -> String -> (Int -> IO a) -> IO a
withServeStoppedBy signal fx dir name action = do
  port <- freePort
  base <- getEnvironment
  let
    env = fxEnv fx <> L.filter (\(k, _) -> k `L.notElem` fmap fst (fxEnv fx)) base
    logPath = dir <> "/serve-" <> name <> ".log"
  bracket
    ( do
        logHandle <- openFile logPath WriteMode
        (_, _, _, handle) <-
          Process.createProcess
            (Process.proc "lockstep" ["serve", "--port", show port])
              { Process.env = Just env
              , Process.std_out = Process.UseHandle logHandle
              , Process.std_err = Process.UseHandle logHandle
              }
        pure handle
    )
    ( \handle -> do
        mbPid <- Process.getPid handle
        traverse_ (signalProcess signal) mbPid
        exited <- timeout 10000000 (Process.waitForProcess handle)
        when (isNothing exited) (Process.terminateProcess handle)
    )
    ( \handle -> do
        ready <- pollUntil 10000 (healthy port)
        exited <- Process.getProcessExitCode handle
        assertBool ("serve did not become ready (exit " <> show exited <> ")") (ready && isNothing exited)
        action port
    )

healthy :: Int -> IO Bool
healthy port = do
  result <- try (timeout 1000000 (httpGet port "/api/health_check"))
  pure $
    case result of
      Right reply -> fmap fst reply == Just 204
      Left (_ :: HTTPClient.HttpException) -> False

pollUntil :: Int -> IO Bool -> IO Bool
pollUntil remainingMillis check = do
  ok <- check
  if ok || remainingMillis <= 0
    then pure ok
    else threadDelay 100000 >> pollUntil (remainingMillis - 100) check

isState :: Fixture -> Int -> String -> IO Bool
isState fx job state =
  (== state) <$> jobState fx job

jobState :: Fixture -> Int -> IO String
jobState fx job = do
  codes <-
    queryInts
      (fxAdmin fx)
      (fxDb fx)
      ("SELECT CASE state WHEN 'queued' THEN 1 WHEN 'running' THEN 2 WHEN 'succeeded' THEN 3 ELSE 4 END AS v FROM lockstep_jobs WHERE id = " <> show job)
  pure $
    case codes of
      [1] -> "queued"
      [2] -> "running"
      [3] -> "succeeded"
      [4] -> "failed"
      _ -> "missing"

stepsDone :: Fixture -> Int -> IO [Int]
stepsDone fx job =
  queryInts (fxAdmin fx) (fxDb fx) ("SELECT steps_done AS v FROM lockstep_jobs WHERE id = " <> show job)

count :: Fixture -> String -> IO [Int]
count fx table =
  queryInts (fxAdmin fx) (fxDb fx) ("SELECT count(*)::integer AS v FROM " <> table)

signIn :: Fixture -> Int -> IO (BS.ByteString, BS.ByteString)
signIn fx port = do
  (code, out, _) <- runLockstep (fxEnv fx) ["operator", "sign-in", "--port", show port]
  code @?= ExitSuccess
  token <-
    maybe (assertFailure "no token") pure $
      L.stripPrefix ("http://127.0.0.1:" <> show port <> "/operator/sign-in?token=") (L.filter (/= '\n') out)
  response <- httpRequest port "POST" "/operator/sign-in" [formType, exactOrigin port] ("token=" <> BS8.pack token)
  responseStatus response @?= 303
  cookie <-
    case responseHeaders "Set-Cookie" response of
      [value] | Just rest <- BS.stripPrefix "lockstep_session=" value -> pure (BS8.takeWhile (/= ';') rest)
      other -> assertFailure ("unexpected Set-Cookie: " <> show other)
  session <- maybe (assertFailure "cookie is not a token") pure (decodeToken (TE.decodeLatin1 cookie))
  pure (cookie, TE.encodeUtf8 (csrfFor session))

queueForm :: BS.ByteString -> BS.ByteString -> BS.ByteString -> BS.ByteString -> BS.ByteString -> BS.ByteString -> BS.ByteString
queueForm csrf key expected steps millis failAt =
  BS.intercalate
    "&"
    ["steps=" <> steps, "step_ms=" <> millis, "fail_at_step=" <> failAt, "expected_revision=" <> expected, "idempotency_key=" <> key, "csrf=" <> csrf]

queuePost :: Int -> BS.ByteString -> BS.ByteString -> BS.ByteString -> BS.ByteString -> BS.ByteString -> BS.ByteString -> BS.ByteString -> IO HttpResponse
queuePost port cookie csrf key expected steps millis failAt =
  httpRequest
    port
    "POST"
    "/operator/commands/queue-noop"
    [formType, cookieHeader cookie, exactOrigin port]
    (queueForm csrf key expected steps millis failAt)

rawPostAndClose :: Int -> BS.ByteString -> BS.ByteString -> Assertion
rawPostAndClose port cookie body =
  let
    raw =
      BS.concat
        [ "POST /operator/commands/queue-noop HTTP/1.1\r\n"
        , "Host: 127.0.0.1:" <> BS8.pack (show port) <> "\r\n"
        , "Origin: http://127.0.0.1:" <> BS8.pack (show port) <> "\r\n"
        , "Cookie: lockstep_session=" <> cookie <> "\r\n"
        , "Content-Type: application/x-www-form-urlencoded\r\n"
        , "Content-Length: " <> BS8.pack (show (BS.length body)) <> "\r\n"
        , "Connection: close\r\n\r\n"
        , body
        ]
  in
    bracket
      (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol)
      Socket.close
      ( \sock -> do
          Socket.connect sock (Socket.SockAddrInet (fromIntegral port) (Socket.tupleToHostAddress (127, 0, 0, 1)))
          SocketBS.sendAll sock raw
      )

exactOrigin :: Int -> HTTP.Header
exactOrigin port =
  ("Origin", "http://127.0.0.1:" <> BS8.pack (show port))

formType :: HTTP.Header
formType =
  (HTTP.hContentType, "application/x-www-form-urlencoded")

cookieHeader :: BS.ByteString -> HTTP.Header
cookieHeader value =
  (HTTP.hCookie, "lockstep_session=" <> value)

contains :: String -> String -> Assertion
contains needle haystack =
  assertBool ("expected output to contain " <> needle <> " in:\n" <> haystack) (needle `L.isInfixOf` haystack)

contains' :: BS.ByteString -> BS.ByteString -> Assertion
contains' needle haystack =
  assertBool ("expected the page to contain " <> BS8.unpack needle) (needle `BS.isInfixOf` haystack)
