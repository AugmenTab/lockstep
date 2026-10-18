module Main
  ( main
  ) where

import Flipstone.Prelude
import Test.Tasty (defaultMain, testGroup)

import Lockstep.BrowserFormTest qualified as BrowserFormTest
import Lockstep.CommandCenterTest qualified as CommandCenterTest
import Lockstep.DispatcherTest qualified as DispatcherTest
import Lockstep.FaultPlanTest qualified as FaultPlanTest
import Lockstep.MigrationDbTest qualified as MigrationDbTest
import Lockstep.OperatorCommandTest qualified as OperatorCommandTest
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
      , OperatorCommandTest.tests
      , DispatcherTest.tests
      , CommandCenterTest.tests
      , FaultPlanTest.tests
      , BrowserFormTest.tests
      ]
