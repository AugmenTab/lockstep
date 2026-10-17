{-# LANGUAGE OverloadedStrings #-}

module Lockstep.Web.ServerTest
  ( tests
  ) where

import Flipstone.Prelude
import Network.Wai.Handler.Warp qualified as Warp
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

import Lockstep.Foundation.Config (BindHost (Loopback), ServeConfig (..), defaultPort, mkPort)
import Lockstep.Web.Server (serverSettings)

tests :: TestTree
tests =
  testGroup
    "Server"
    [ testCase "the default configuration binds 127.0.0.1 only" $ do
        let
          settings = serverSettings (ServeConfig Loopback defaultPort)
        Warp.getHost settings @?= "127.0.0.1"
        Warp.getPort settings @?= 8000
    , testCase "a configured port keeps the loopback host" $ do
        port <-
          maybe (assertFailure "mkPort rejected 9123") pure (mkPort 9123)
        let
          settings = serverSettings (ServeConfig Loopback port)
        Warp.getHost settings @?= "127.0.0.1"
        Warp.getPort settings @?= 9123
    ]
