{-# LANGUAGE OverloadedStrings #-}

module Lockstep.Web.CommandRoutesTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTP
import Network.Wai qualified as Wai
import Network.Wai.Test qualified as WaiTest
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Lockstep.Foundation.Config (BindHost (Loopback), ServeConfig (..), defaultPort)
import Lockstep.Web.Application (application)

tests :: TestTree
tests =
  testGroup
    "Command routes (no database)"
    [ testCase "POST /operator/commands/rename-workspace without a session answers 401" $ do
        res <- run (request "POST" "/operator/commands/rename-workspace" [exactHost, exactOrigin, form] renameBody)
        WaiTest.simpleStatus res @?= HTTP.status401
        L.lookup "Cache-Control" (WaiTest.simpleHeaders res) @?= Just "no-store"
    , testCase "POST /operator/commands/rename-workspace with a missing Origin answers 403" $ do
        res <- run (request "POST" "/operator/commands/rename-workspace" [exactHost, form] renameBody)
        WaiTest.simpleStatus res @?= HTTP.status403
    , testCase "POST /operator/commands/rename-workspace with a foreign Host answers 403" $ do
        res <- run (request "POST" "/operator/commands/rename-workspace" [("Host", "attacker.example:8000"), exactOrigin, form] renameBody)
        WaiTest.simpleStatus res @?= HTTP.status403
    , testCase "GET /operator/receipts/1 without a session answers 401" $ do
        res <- run (request "GET" "/operator/receipts/1" [exactHost] "")
        WaiTest.simpleStatus res @?= HTTP.status401
    , testCase "GET /operator/commands/rename-workspace is not a route" $ do
        res <- run (request "GET" "/operator/commands/rename-workspace" [exactHost] "")
        WaiTest.simpleStatus res @?= HTTP.status404
    , testCase "POST /operator/receipts/1 is not a route" $ do
        res <- run (request "POST" "/operator/receipts/1" [exactHost, exactOrigin] "")
        WaiTest.simpleStatus res @?= HTTP.status404
    ]

renameBody :: LBS.ByteString
renameBody =
  "name=X&expected_revision=0&idempotency_key=abcdefghijklmnop&csrf=x"

exactHost :: HTTP.Header
exactHost =
  ("Host", "127.0.0.1:8000")

exactOrigin :: HTTP.Header
exactOrigin =
  ("Origin", "http://127.0.0.1:8000")

form :: HTTP.Header
form =
  (HTTP.hContentType, "application/x-www-form-urlencoded")

run :: WaiTest.SRequest -> IO WaiTest.SResponse
run r =
  WaiTest.runSession (WaiTest.srequest r) (application (ServeConfig Loopback defaultPort) (\_ -> pure ()))

request :: HTTP.Method -> BS.ByteString -> [HTTP.Header] -> LBS.ByteString -> WaiTest.SRequest
request method path headers body =
  let
    base = WaiTest.setPath Wai.defaultRequest {Wai.requestMethod = method} path
  in
    WaiTest.SRequest base {Wai.requestHeaders = headers, Wai.requestHeaderHost = L.lookup "Host" headers} body
