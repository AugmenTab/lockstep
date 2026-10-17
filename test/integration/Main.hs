module Main
  ( main
  ) where

import Flipstone.Prelude
import Test.Tasty (defaultMain, testGroup)

import Lockstep.MigrationDbTest qualified as MigrationDbTest
import Lockstep.OperatorTrustTest qualified as OperatorTrustTest
import Lockstep.ProcessTest qualified as ProcessTest
import Lockstep.ServiceDbTest qualified as ServiceDbTest

main :: IO ()
main =
  defaultMain $
    testGroup
      "lockstep-integration"
      [ ProcessTest.tests
      , MigrationDbTest.tests
      , ServiceDbTest.tests
      , OperatorTrustTest.tests
      ]
