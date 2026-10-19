module Main
  ( main
  ) where

import Flipstone.Prelude
import Test.Tasty (defaultMain, testGroup)

import Lockstep.Application.CommandTest qualified as CommandTest
import Lockstep.Application.NoopCommandTest qualified as NoopCommandTest
import Lockstep.Application.ProfileDocumentTest qualified as ProfileDocumentTest
import Lockstep.Application.ReadinessTest qualified as ReadinessTest
import Lockstep.Effects.ExecutorTest qualified as ExecutorTest
import Lockstep.Foundation.CliDbTest qualified as CliDbTest
import Lockstep.Foundation.CliJobTest qualified as CliJobTest
import Lockstep.Foundation.CliOperatorTest qualified as CliOperatorTest
import Lockstep.Foundation.CliProfileTest qualified as CliProfileTest
import Lockstep.Foundation.CliRepositoryTest qualified as CliRepositoryTest
import Lockstep.Foundation.CliTest qualified as CliTest
import Lockstep.Foundation.CliWorkspaceTest qualified as CliWorkspaceTest
import Lockstep.Foundation.EvidenceModelTest qualified as EvidenceModelTest
import Lockstep.Foundation.OperatorTokenTest qualified as OperatorTokenTest
import Lockstep.Foundation.SystemConfigTest qualified as SystemConfigTest
import Lockstep.Kernel.DeliveryTest qualified as DeliveryTest
import Lockstep.Kernel.EffectTest qualified as EffectTest
import Lockstep.Kernel.EventCodecTest qualified as EventCodecTest
import Lockstep.Kernel.IdentityTest qualified as IdentityTest
import Lockstep.Kernel.LifecyclePropertyTest qualified as LifecyclePropertyTest
import Lockstep.Kernel.ProfileTest qualified as ProfileTest
import Lockstep.Kernel.RecoveryTest qualified as RecoveryTest
import Lockstep.Kernel.RemoteTest qualified as RemoteTest
import Lockstep.Kernel.RepositoryTest qualified as RepositoryTest
import Lockstep.Kernel.SchedulerPropertyTest qualified as SchedulerPropertyTest
import Lockstep.Kernel.SchedulerTest qualified as SchedulerTest
import Lockstep.Kernel.TicketTest qualified as TicketTest
import Lockstep.Kernel.TransitionTest qualified as TransitionTest
import Lockstep.Kernel.WorkOrderTest qualified as WorkOrderTest
import Lockstep.Kernel.WorkUnitLifecycleTest qualified as WorkUnitLifecycleTest
import Lockstep.Kernel.WorkUnitTest qualified as WorkUnitTest
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
      , IdentityTest.tests
      , RemoteTest.tests
      , RepositoryTest.tests
      , WorkUnitTest.tests
      , CliRepositoryTest.tests
      , TransitionTest.tests
      , TicketTest.tests
      , WorkOrderTest.tests
      , WorkUnitLifecycleTest.tests
      , DeliveryTest.tests
      , LifecyclePropertyTest.tests
      , ProfileTest.tests
      , ProfileDocumentTest.tests
      , CliProfileTest.tests
      , SchedulerTest.tests
      , SchedulerPropertyTest.tests
      , EffectTest.tests
      , EventCodecTest.tests
      , RecoveryTest.tests
      , ExecutorTest.tests
      ]
