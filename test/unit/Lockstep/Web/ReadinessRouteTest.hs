{-# LANGUAGE OverloadedStrings #-}

module Lockstep.Web.ReadinessRouteTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTP
import Network.Wai qualified as Wai
import Network.Wai.Test qualified as WaiTest
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Lockstep.Foundation.Config (defaultServeConfig)
import Lockstep.Web.Application (application)

tests :: TestTree
tests =
  testGroup
    "Readiness route (no database configured)"
    [ testCase "GET /api/readiness answers 503 database_not_configured" $ do
        res <- get "/api/readiness"
        WaiTest.simpleStatus res @?= HTTP.status503
        WaiTest.simpleBody res @?= "not_ready database_not_configured"
    , testCase "GET /api/health_check still answers 204" $ do
        res <- get "/api/health_check"
        WaiTest.simpleStatus res @?= HTTP.status204
    ]

get :: BS.ByteString -> IO WaiTest.SResponse
get path =
  WaiTest.runSession
    (WaiTest.request (WaiTest.setPath Wai.defaultRequest path))
    (application defaultServeConfig (\_ -> pure ()))
