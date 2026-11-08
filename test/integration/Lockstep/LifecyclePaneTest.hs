{-# LANGUAGE OverloadedStrings #-}

{- | The pane's lifecycle endpoint (contract C-P3.2 M6): the real pane binary,
no helper. The test reads the request files the pane writes and plays the
helper where a result is needed.
-}
module Lockstep.LifecyclePaneTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTPTypes
import System.Directory (listDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Foundation.ControlProtocol (ControlResult (..), Outcome (OutcomeOk), encodeResult, requestIdText)
import Lockstep.Foundation.LifecycleProtocol (LifecycleExpect (..), LifecycleOp (..), LifecycleRequest (..), decodeLifecycleRequest)
import Lockstep.Support.Control (Env (..), currentSeconds, issueSignIn, paneDir, withEnv, withPaneOn)
import Lockstep.Support.Http (HttpResponse (..), httpRequest)

origin :: Int -> BS.ByteString
origin port =
  "http://127.0.0.1:" <> BS8.pack (show port)

signIn :: Env -> Int -> IO BS.ByteString
signIn env port = do
  token <- issueSignIn (paneDir env) 300
  resp <- httpRequest port "POST" "/api/session" [("Origin", origin port)] (TE.encodeUtf8 token)
  responseStatus resp @?= 200
  pure (BS.take 43 (BS.drop 11 (snd (BS.breakSubstring "\"session\":\"" (responseBody resp)))))

headers :: Int -> BS.ByteString -> [HTTPTypes.Header]
headers port session =
  [("Origin", origin port), ("X-Lockstep-Session", session)]

lifecycleFiles :: Env -> IO [String]
lifecycleFiles env =
  L.filter (".lreq" `L.isSuffixOf`) <$> listDirectory (paneDir env <> "/requests")

theLifecycleRequest :: Env -> IO LifecycleRequest
theLifecycleRequest env = do
  names <- lifecycleFiles env
  case names of
    [name] -> do
      bytes <- BS.readFile (paneDir env <> "/requests/" <> name)
      either (\e -> assertFailure ("the pane's lifecycle request does not verify: " <> show e)) pure (decodeLifecycleRequest (envKey env) bytes)
    other -> assertFailure ("expected one lifecycle request, found " <> show other)

contains :: BS.ByteString -> BS.ByteString -> Bool
contains needle haystack =
  not (BS.null (snd (BS.breakSubstring needle haystack)))

tests :: TestTree
tests =
  testGroup
    "pane lifecycle endpoint (C-P3.2 M6)"
    [ testCase "a lifecycle request needs a session and this pane's origin" $
        withEnv $ \env -> withPaneOn (paneDir env) [] $ \port -> do
          session <- signIn env port
          none <- httpRequest port "POST" "/api/lifecycle" [("Origin", origin port)] "service-stop running"
          responseStatus none @?= 401
          elsewhere <- httpRequest port "POST" "/api/lifecycle" [("Origin", "http://127.0.0.1:1"), ("X-Lockstep-Session", session)] "service-stop running"
          responseStatus elsewhere @?= 403
          host <- httpRequest port "POST" "/api/lifecycle" [("Host", "localhost:" <> BS8.pack (show port)), ("Origin", origin port), ("X-Lockstep-Session", session)] "service-stop running"
          responseStatus host @?= 403
          lifecycleFiles env >>= (@?= [])
    , testCase "an allowlisted operation with its expectation becomes one signed lifecycle request" $
        withEnv $ \env -> withPaneOn (paneDir env) [] $ \port -> do
          session <- signIn env port
          resp <- httpRequest port "POST" "/api/lifecycle" (headers port session) "service-stop running"
          responseStatus resp @?= 202
          r <- theLifecycleRequest env
          lifecycleOp r @?= ServiceStop
          lifecycleExpect r @?= ExpectRunning
          now <- currentSeconds
          assertBool "issued is not now" (abs (now - lifecycleIssued r) <= 5)
          assertBool "the response lacks the id" (contains (TE.encodeUtf8 (requestIdText (lifecycleId r))) (responseBody resp))
    , testCase "unknown operations, wrong expectations and extra words are 400 and write nothing" $
        withEnv $ \env -> withPaneOn (paneDir env) [] $ \port -> do
          session <- signIn env port
          traverse_
            ( \b -> do
                resp <- httpRequest port "POST" "/api/lifecycle" (headers port session) b
                assertBool (show b <> " gave " <> show (responseStatus resp)) (responseStatus resp == 400)
            )
            ["reboot running", "service-stop", "service-stop not-running", "service-stop running now", "status any", "service-stop  running", ""]
          lifecycleFiles env >>= (@?= [])
    , testCase "a second lifecycle request while one is pending is 409, and allowed once its result exists" $
        withEnv $ \env -> withPaneOn (paneDir env) [] $ \port -> do
          session <- signIn env port
          first <- httpRequest port "POST" "/api/lifecycle" (headers port session) "service-stop running"
          responseStatus first @?= 202
          second <- httpRequest port "POST" "/api/lifecycle" (headers port session) "service-restart running"
          responseStatus second @?= 409
          r <- theLifecycleRequest env
          let
            rid = requestIdText (lifecycleId r)
            result = ControlResult rid "service-stop" OutcomeOk Nothing (lifecycleIssued r) (lifecycleIssued r) [] ""
          BS.writeFile (paneDir env <> "/results/" <> T.unpack rid <> ".res") (encodeResult (envKey env) result)
          done <- httpRequest port "GET" ("/api/requests/" <> T.unpack rid) [("X-Lockstep-Session", session)] ""
          assertBool ("result not shown: " <> show (responseBody done)) (contains "\"state\":\"done\"" (responseBody done))
          third <- httpRequest port "POST" "/api/lifecycle" (headers port session) "service-start not-running"
          responseStatus third @?= 202
    , testCase "the status channel still refuses lifecycle names" $
        withEnv $ \env -> withPaneOn (paneDir env) [] $ \port -> do
          session <- signIn env port
          resp <- httpRequest port "POST" "/api/requests" (headers port session) "service-stop"
          responseStatus resp @?= 400
    , testCase "a body over 4 KiB is refused" $
        withEnv $ \env -> withPaneOn (paneDir env) [] $ \port -> do
          session <- signIn env port
          resp <- httpRequest port "POST" "/api/lifecycle" (headers port session) (BS.replicate 5000 0x61)
          responseStatus resp @?= 413
    ]
