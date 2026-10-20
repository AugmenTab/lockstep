module Main
  ( main
  ) where

import Flipstone.Prelude
import Test.Tasty (defaultMain, testGroup)

import Lockstep.BrowserFormTest qualified as BrowserFormTest
import Lockstep.CommandCenterTest qualified as CommandCenterTest
import Lockstep.DispatcherTest qualified as DispatcherTest
import Lockstep.ExecutorTest qualified as ExecutorTest
import Lockstep.FaultPlanTest qualified as FaultPlanTest
import Lockstep.LedgerTest qualified as LedgerTest
import Lockstep.LedgerTraceTest qualified as LedgerTraceTest
import Lockstep.MigrationDbTest qualified as MigrationDbTest
import Lockstep.OperatorCommandTest qualified as OperatorCommandTest
import Lockstep.OperatorLedgerTest qualified as OperatorLedgerTest
import Lockstep.OperatorTrustTest qualified as OperatorTrustTest
import Lockstep.ProcessTest qualified as ProcessTest
import Lockstep.ProfileRegistryTest qualified as ProfileRegistryTest
import Lockstep.ReconciliationTest qualified as ReconciliationTest
import Lockstep.RemediationFinalReviewTest qualified as RemediationFinalReviewTest
import Lockstep.RemediationReviewTest qualified as RemediationReviewTest
import Lockstep.RemediationTest qualified as RemediationTest
import Lockstep.RemediationThirdReviewTest qualified as RemediationThirdReviewTest
import Lockstep.RepositoryOwnershipTest qualified as RepositoryOwnershipTest
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
      ]
