{-# LANGUAGE OverloadedStrings #-}

module Lockstep.Kernel.DeliveryTest
  ( tests
  ) where

import Data.List.NonEmpty (NonEmpty ((:|)))
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

import Lockstep.Kernel.Delivery
  ( Delivery (..)
  , DeliveryInput (..)
  , DeliveryMode (..)
  , DeliveryState (..)
  , deliveryStateName
  , integratedCommit
  , integratedWorkUnits
  , integrationEvidence
  , mkPullRequestRef
  , newDelivery
  , stepDelivery
  )
import Lockstep.Kernel.LifecycleFixtures
  ( Expect (..)
  , Fixtures (..)
  , exhaustive
  , row
  , rows
  , withFixtures
  )
import Lockstep.Kernel.Transition (Command (..), Principal (..), transitionRefusalCode)
import Lockstep.Kernel.WorkUnitLifecycle (acceptedWorkUnitId)

tests :: TestTree
tests =
  testGroup
    "Kernel Delivery lifecycle (C-P2.2 §3.4)"
    [ testCase "exhaustive: every state × input × principal matches the table (both modes)" $
        withFixtures $ \fx -> do
          pr <- maybe (assertFailure "pull request ref") pure (mkPullRequestRef "owner/repo#12")
          let
            ws = fxAcceptedA fx :| []
            a = fxCommitA fx
            b = fxCommitB fx
            inPr = Delivery PullRequest
            states =
              [ ("locally-accepted", inPr (LocallyAccepted ws))
              , ("published", inPr (Published ws pr a))
              , ("approved", inPr (Approved ws pr a))
              , ("changes-requested", inPr (ChangesRequested ws pr))
              , ("stale-approval", inPr (StaleApproval ws pr b))
              , ("integrated", inPr (Integrated ws a))
              , ("closed-without-merge", inPr (ClosedWithoutMerge ws pr))
              , ("needs-reconciliation", inPr (NeedsReconciliation (Published ws pr a) "publish timed out"))
              , ("local-accepted", Delivery LocalOnly (LocallyAccepted ws))
              ]
            inputs =
              [ ("publish", DelPublish pr a)
              , ("approve-a", DelApprove a)
              , ("approve-b", DelApprove b)
              , ("request-changes", DelRequestChanges)
              , ("push-a", DelPush a)
              , ("push-b", DelPush b)
              , ("integrate-a", DelIntegrate a)
              , ("integrate-b", DelIntegrate b)
              , ("close", DelClose)
              , ("outcome-unknown", DelOutcomeUnknown "no response")
              , ("reconciled", DelReconciled)
              ]
            table =
              [ row "locally-accepted" "publish" [DeliveryAdapter] (To "published")
              , row "published" "approve-a" [DeliveryAdapter] (To "approved")
              , row "published" "approve-b" [DeliveryAdapter] (Refuse "basis-mismatch")
              , row "stale-approval" "approve-b" [DeliveryAdapter] (To "approved")
              , row "stale-approval" "approve-a" [DeliveryAdapter] (Refuse "basis-mismatch")
              , row "changes-requested" "push-a" [DeliveryAdapter] (To "published")
              , row "changes-requested" "push-b" [DeliveryAdapter] (To "published")
              , row "approved" "push-b" [DeliveryAdapter] (To "stale-approval")
              , row "approved" "push-a" [DeliveryAdapter] (Refuse "basis-mismatch")
              , row "approved" "integrate-a" [DeliveryAdapter] (To "integrated")
              , row "approved" "integrate-b" [DeliveryAdapter] (Refuse "basis-mismatch")
              , row "needs-reconciliation" "reconciled" [Supervisor] (To "published")
              , row "local-accepted" "publish" [DeliveryAdapter] (Refuse "kind-forbids")
              , row "local-accepted" "integrate-a" [Supervisor] (To "integrated")
              , row "local-accepted" "integrate-b" [Supervisor] (To "integrated")
              ]
                <> rows ["published", "approved", "stale-approval"] "request-changes" [DeliveryAdapter] (To "changes-requested")
                <> rows ["published", "approved", "changes-requested", "stale-approval"] "close" [DeliveryAdapter] (To "closed-without-merge")
                <> rows
                  ["locally-accepted", "published", "approved", "changes-requested", "stale-approval", "local-accepted"]
                  "outcome-unknown"
                  [DeliveryAdapter, Supervisor]
                  (To "needs-reconciliation")
          exhaustive stepDelivery (deliveryStateName . deliveryState) states inputs ["integrated", "closed-without-merge"] table
    , testCase "integration evidence exists only for an Integrated delivery and names its Work Units and commit" $
        withFixtures $ \fx -> do
          let
            ws = fxAcceptedA fx :| [fxAcceptedB fx]
            a = fxCommitA fx
          integrated <-
            either (const (assertFailure "local integration refused")) pure $
              stepDelivery (newDelivery LocalOnly ws) (Command Supervisor (DelIntegrate a))
          fmap integratedCommit (integrationEvidence integrated) @?= Just a
          fmap integratedWorkUnits (integrationEvidence integrated) @?= Just (fmap acceptedWorkUnitId ws)
          fmap integratedCommit (integrationEvidence (newDelivery LocalOnly ws)) @?= Nothing
          fmap integratedCommit (integrationEvidence (newDelivery PullRequest ws)) @?= Nothing
    , testCase "PullRequest mode: integrating without approval is illegal; a push after approval makes it stale" $
        withFixtures $ \fx -> do
          pr <- maybe (assertFailure "pull request ref") pure (mkPullRequestRef "owner/repo#12")
          let
            ws = fxAcceptedA fx :| []
            a = fxCommitA fx
            b = fxCommitB fx
            code d c = either transitionRefusalCode (deliveryStateName . deliveryState) (stepDelivery d c)
          code (newDelivery PullRequest ws) (Command DeliveryAdapter (DelIntegrate a)) @?= "illegal-transition"
          code (newDelivery PullRequest ws) (Command Supervisor (DelIntegrate a)) @?= "illegal-transition"
          code (Delivery PullRequest (Published ws pr a)) (Command DeliveryAdapter (DelIntegrate a)) @?= "illegal-transition"
          code (Delivery PullRequest (StaleApproval ws pr b)) (Command DeliveryAdapter (DelIntegrate b)) @?= "illegal-transition"
    , testCase "reconciliation returns to the exact prior state" $
        withFixtures $ \fx -> do
          pr <- maybe (assertFailure "pull request ref") pure (mkPullRequestRef "owner/repo#12")
          let
            prior = Approved (fxAcceptedA fx :| []) pr (fxCommitA fx)
          fmap deliveryState (stepDelivery (Delivery PullRequest (NeedsReconciliation prior "timeout")) (Command Supervisor DelReconciled))
            @?= Right prior
    , testCase "pull request references are non-empty" $ do
        fmap (const ()) (mkPullRequestRef "") @?= Nothing
        fmap (const ()) (mkPullRequestRef "#1") @?= Just ()
    ]
