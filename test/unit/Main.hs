module Main
  ( main
  ) where

import Flipstone.Prelude
import Test.Tasty (defaultMain, testGroup)

import Lockstep.Foundation.CliTest qualified as CliTest
import Lockstep.Web.ApplicationTest qualified as ApplicationTest
import Lockstep.Web.ServerTest qualified as ServerTest

main :: IO ()
main =
  defaultMain $
    testGroup
      "lockstep-unit"
      [ CliTest.tests
      , ServerTest.tests
      , ApplicationTest.tests
      ]
