module Main
  ( main
  ) where

import Flipstone.Prelude
import Test.Tasty (defaultMain, testGroup)

import Lockstep.Application.CommandTest qualified as CommandTest
import Lockstep.Application.NoopCommandTest qualified as NoopCommandTest
import Lockstep.Application.ReadinessTest qualified as ReadinessTest
import Lockstep.Foundation.CliDbTest qualified as CliDbTest
import Lockstep.Foundation.CliJobTest qualified as CliJobTest
import Lockstep.Foundation.CliOperatorTest qualified as CliOperatorTest
import Lockstep.Foundation.CliTest qualified as CliTest
import Lockstep.Foundation.CliWorkspaceTest qualified as CliWorkspaceTest
import Lockstep.Foundation.EvidenceModelTest qualified as EvidenceModelTest
import Lockstep.Foundation.OperatorTokenTest qualified as OperatorTokenTest
import Lockstep.Foundation.SystemConfigTest qualified as SystemConfigTest
import Lockstep.Persistence.MigrationTest qualified as MigrationTest
import Lockstep.Web.ApplicationTest qualified as ApplicationTest
import Lockstep.Web.CommandCenterViewTest qualified as CommandCenterViewTest
import Lockstep.Web.CommandRoutesTest qualified as CommandRoutesTest
import Lockstep.Web.LivenessPageTest qualified as LivenessPageTest
import Lockstep.Web.OperatorRoutesTest qualified as OperatorRoutesTest
import Lockstep.Web.ReadinessRouteTest qualified as ReadinessRouteTest
import Lockstep.Web.RequestGuardTest qualified as RequestGuardTest
import Lockstep.Web.ServerTest qualified as ServerTest

main :: IO ()
main =
  defaultMain $
    testGroup
      "lockstep-unit"
      [ CliTest.tests
      , ServerTest.tests
      , ApplicationTest.tests
      , SystemConfigTest.tests
      , CliDbTest.tests
      , MigrationTest.tests
      , ReadinessTest.tests
      , LivenessPageTest.tests
      , ReadinessRouteTest.tests
      , OperatorTokenTest.tests
      , RequestGuardTest.tests
      , CliOperatorTest.tests
      , OperatorRoutesTest.tests
      , CommandTest.tests
      , CliWorkspaceTest.tests
      , CommandRoutesTest.tests
      , NoopCommandTest.tests
      , CliJobTest.tests
      , EvidenceModelTest.tests
      , CommandCenterViewTest.tests
      ]
