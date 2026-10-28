module Main
  ( main
  ) where

import Flipstone.Prelude
import Test.Tasty (defaultMain, testGroup)

import Lockstep.ActivityBrowserTest qualified as ActivityBrowserTest
import Lockstep.ActivityPageTest qualified as ActivityPageTest
import Lockstep.AppShellTest qualified as AppShellTest
import Lockstep.BrowserFormTest qualified as BrowserFormTest
import Lockstep.CommandCenterTest qualified as CommandCenterTest
import Lockstep.ControlBrowserTest qualified as ControlBrowserTest
import Lockstep.ControlHelperTest qualified as ControlHelperTest
import Lockstep.ControlPaneTest qualified as ControlPaneTest
import Lockstep.DecisionsBrowserTest qualified as DecisionsBrowserTest
import Lockstep.DecisionsPageTest qualified as DecisionsPageTest
import Lockstep.DecisionsTest qualified as DecisionsTest
import Lockstep.DispatcherTest qualified as DispatcherTest
import Lockstep.ExecutorTest qualified as ExecutorTest
import Lockstep.FaultPlanTest qualified as FaultPlanTest
import Lockstep.FirstUseJourneyTest qualified as FirstUseJourneyTest
import Lockstep.FolderHelperTest qualified as FolderHelperTest
import Lockstep.GateCRemediationAddendumTest qualified as GateCRemediationAddendumTest
import Lockstep.GateCRemediationBrowserTest qualified as GateCRemediationBrowserTest
import Lockstep.GateCRemediationFolderRaceTest qualified as GateCRemediationFolderRaceTest
import Lockstep.GateCRemediationFolderTest qualified as GateCRemediationFolderTest
import Lockstep.GateCRemediationPageTest qualified as GateCRemediationPageTest
import Lockstep.GateCRemediationTest qualified as GateCRemediationTest
import Lockstep.HandoverTest qualified as HandoverTest
import Lockstep.InstallBrowserTest qualified as InstallBrowserTest
import Lockstep.InstallHelperTest qualified as InstallHelperTest
import Lockstep.InstallPaneTest qualified as InstallPaneTest
import Lockstep.LauncherTest qualified as LauncherTest
import Lockstep.LedgerTest qualified as LedgerTest
import Lockstep.LedgerTraceTest qualified as LedgerTraceTest
import Lockstep.LifecycleBrowserTest qualified as LifecycleBrowserTest
import Lockstep.LifecycleHelperTest qualified as LifecycleHelperTest
import Lockstep.LifecyclePaneTest qualified as LifecyclePaneTest
import Lockstep.MigrationDbTest qualified as MigrationDbTest
import Lockstep.OperatorCommandTest qualified as OperatorCommandTest
import Lockstep.OperatorLedgerTest qualified as OperatorLedgerTest
import Lockstep.OperatorTrustTest qualified as OperatorTrustTest
import Lockstep.ProcessTest qualified as ProcessTest
import Lockstep.ProfileRegistryTest qualified as ProfileRegistryTest
import Lockstep.ProjectChecksBrowserTest qualified as ProjectChecksBrowserTest
import Lockstep.ProjectChecksPageTest qualified as ProjectChecksPageTest
import Lockstep.ProjectChecksTest qualified as ProjectChecksTest
import Lockstep.ProjectsBrowserTest qualified as ProjectsBrowserTest
import Lockstep.ProjectsPageTest qualified as ProjectsPageTest
import Lockstep.ProjectsTest qualified as ProjectsTest
import Lockstep.ReconciliationTest qualified as ReconciliationTest
import Lockstep.RemediationFinalReviewTest qualified as RemediationFinalReviewTest
import Lockstep.RemediationReviewTest qualified as RemediationReviewTest
import Lockstep.RemediationTest qualified as RemediationTest
import Lockstep.RemediationThirdReviewTest qualified as RemediationThirdReviewTest
import Lockstep.RepositoryOwnershipTest qualified as RepositoryOwnershipTest
import Lockstep.ServiceDbTest qualified as ServiceDbTest
import Lockstep.TasksBrowserTest qualified as TasksBrowserTest
import Lockstep.TasksPageTest qualified as TasksPageTest
import Lockstep.TasksTest qualified as TasksTest

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
      , RepositoryOwnershipTest.tests
      , ProfileRegistryTest.tests
      , LedgerTest.tests
      , ExecutorTest.tests
      , ReconciliationTest.tests
      , OperatorLedgerTest.tests
      , LedgerTraceTest.tests
      , RemediationTest.tests
      , RemediationReviewTest.tests
      , RemediationThirdReviewTest.tests
      , RemediationFinalReviewTest.tests
      , ControlPaneTest.tests
      , ControlHelperTest.tests
      , ControlBrowserTest.tests
      , LauncherTest.tests
      , LifecycleHelperTest.tests
      , LifecyclePaneTest.tests
      , LifecycleBrowserTest.tests
      , InstallHelperTest.tests
      , InstallPaneTest.tests
      , InstallBrowserTest.tests
      , AppShellTest.tests
      , HandoverTest.tests
      , ProjectsTest.tests
      , ProjectsPageTest.tests
      , FolderHelperTest.tests
      , ProjectsBrowserTest.tests
      , TasksTest.tests
      , TasksPageTest.tests
      , TasksBrowserTest.tests
      , ProjectChecksTest.tests
      , ProjectChecksPageTest.tests
      , ProjectChecksBrowserTest.tests
      , DecisionsTest.tests
      , DecisionsPageTest.tests
      , DecisionsBrowserTest.tests
      , ActivityPageTest.tests
      , ActivityBrowserTest.tests
      , FirstUseJourneyTest.tests
      , GateCRemediationTest.tests
      , GateCRemediationPageTest.tests
      , GateCRemediationFolderTest.tests
      , GateCRemediationBrowserTest.tests
      , GateCRemediationAddendumTest.tests
      , GateCRemediationFolderRaceTest.tests
      ]
