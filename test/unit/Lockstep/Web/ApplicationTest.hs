{-# LANGUAGE OverloadedStrings #-}

module Lockstep.Web.ApplicationTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.Char qualified as Char
import Data.List qualified as L
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTP
import Network.Wai qualified as Wai
import Network.Wai.Test qualified as WaiTest
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, testCase, (@?=))

import Lockstep.Foundation.Config (BindHost (Loopback), ServeConfig (..), defaultPort)
import Lockstep.Web.Application (application)

tests :: TestTree
tests =
  testGroup
    "Application"
    [ testGroup
        "health"
        [ testCase "GET /api/health_check answers 204 with an empty body" $ do
            res <- get "/api/health_check"
            WaiTest.simpleStatus res @?= HTTP.status204
            WaiTest.simpleBody res @?= LBS.empty
        , testCase "POST /api/health_check is not a route" $ do
            res <- send "POST" "/api/health_check"
            WaiTest.simpleStatus res @?= HTTP.status404
        ]
    , testGroup
        "liveness"
        [ testCase "GET / renders an HTML liveness page" $ do
            res <- get "/"
            WaiTest.simpleStatus res @?= HTTP.status200
            assertContentType "text/html" res
        , testCase "the page states liveness only and that database readiness is not checked" $ do
            body <- pageBody
            assertContains "liveness" body
            assertContains "database readiness" body
            assertContains "not checked" body
        , testCase "the page links the Lockstep stylesheet" $ do
            body <- pageBody
            assertContains "/static/lockstep.css" body
        , testCase "the page carries no Pico, hyperscript or Rollbar reference" $ do
            body <- pageBody
            assertLacks "pico" body
            assertLacks "hyperscript" body
            assertLacks "rollbar" body
        ]
    , testGroup "removed template routes" (fmap removedRoute removedRoutes)
    , testGroup
        "static assets"
        [ testCase "/static/lockstep.css is served as CSS" $ do
            res <- get "/static/lockstep.css"
            WaiTest.simpleStatus res @?= HTTP.status200
            assertContentType "text/css" res
        , testCase "the Pico stylesheet is not shipped" $
            assertNotFound "/static/css/pico.min.css"
        , testCase "the hyperscript bundle is not shipped" $
            assertNotFound "/static/js/_hyperscript.min.js"
        , testCase "a path outside the asset allowlist is not served" $
            assertNotFound "/static/../package.yaml"
        , testCase "an unlisted asset name is not served" $
            assertNotFound "/static/package.yaml"
        ]
    ]

removedRoutes :: [BS.ByteString]
removedRoutes =
  [ "/app"
  , "/app/login"
  , "/app/logout"
  , "/app/signup"
  , "/app/admin/users"
  , "/app/account/profile"
  , "/api/docs"
  , "/api/test_authentication"
  , "/mobile"
  ]

removedRoute :: BS.ByteString -> TestTree
removedRoute path =
  testCase (BS8.unpack path <> " is not a route") $
    assertNotFound path

testConfig :: ServeConfig
testConfig =
  ServeConfig Loopback defaultPort

send :: HTTP.Method -> BS.ByteString -> IO WaiTest.SResponse
send method path =
  WaiTest.runSession
    (WaiTest.request (WaiTest.setPath Wai.defaultRequest {Wai.requestMethod = method} path))
    (application testConfig (\_ -> pure ()))

get :: BS.ByteString -> IO WaiTest.SResponse
get =
  send HTTP.methodGet

pageBody :: IO BS.ByteString
pageBody =
  fmap (BS8.map Char.toLower . LBS.toStrict . WaiTest.simpleBody) (get "/")

assertNotFound :: BS.ByteString -> Assertion
assertNotFound path = do
  res <- get path
  WaiTest.simpleStatus res @?= HTTP.status404

assertContentType :: BS.ByteString -> WaiTest.SResponse -> Assertion
assertContentType expected res =
  case L.lookup HTTP.hContentType (WaiTest.simpleHeaders res) of
    Nothing ->
      assertBool "missing Content-Type header" False
    Just value ->
      assertBool
        ("Content-Type " <> BS8.unpack value <> " does not start with " <> BS8.unpack expected)
        (expected `BS.isPrefixOf` value)

assertContains :: BS.ByteString -> BS.ByteString -> Assertion
assertContains needle haystack =
  assertBool
    ("expected the page to contain " <> BS8.unpack needle)
    (needle `BS.isInfixOf` haystack)

assertLacks :: BS.ByteString -> BS.ByteString -> Assertion
assertLacks needle haystack =
  assertBool
    ("expected the page not to contain " <> BS8.unpack needle)
    (not (needle `BS.isInfixOf` haystack))
