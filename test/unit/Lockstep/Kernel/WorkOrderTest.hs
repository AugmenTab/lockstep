{-# LANGUAGE OverloadedStrings #-}

module Lockstep.Kernel.WorkOrderTest
  ( tests
  ) where

import Data.List qualified as L
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Lockstep.Kernel.Identity (WorkOrderId (..), uuidFromWords)
import Lockstep.Kernel.LifecycleFixtures
  ( Expect (..)
  , Fixtures (..)
  , claimA
  , claimB
  , engineerA
  , exhaustive
  , row
  , rows
  , withFixtures
  )
import Lockstep.Kernel.Transition (Command (..), Principal (..), transitionRefusalCode)
import Lockstep.Kernel.WorkOrder
  ( Claim (..)
  , WorkOrder (..)
  , WorkOrderInput (..)
  , WorkOrderKind (..)
  , WorkOrderState (..)
  , mayCompleteWithWorkUnits
  , newWorkOrder
  , stepWorkOrder
  , workOrderStateName
  )

tests :: TestTree
tests =
  testGroup
    "Kernel Work Order lifecycle (C-P2.2 §3.2)"
    [ testCase "exhaustive: every state × input × principal matches the table (Engineering)" $
        withFixtures $ \fx -> do
          let
            states =
              fmap
                (fmap (WorkOrder orderId Engineering))
                [ ("pending", Pending)
                , ("eligible", Eligible)
                , ("claimed", Claimed claimA)
                , ("active", Active claimA)
                , ("waiting", Waiting claimA "awaiting a reservation")
                , ("halted", Halted "operator halt")
                , ("completed", Completed claimA [fxAcceptedA fx])
                , ("superseded", Superseded otherId)
                , ("canceled", Canceled)
                ]
            inputs =
              [ ("mark-eligible", WoMarkEligible)
              , ("mark-ineligible", WoMarkIneligible)
              , ("claim", WoClaim claimA)
              , ("release-a", WoRelease claimA)
              , ("release-b", WoRelease claimB)
              , ("start-a", WoStart claimA)
              , ("start-b", WoStart claimB)
              , ("wait-a", WoWait claimA "reservation")
              , ("resume-a", WoResume claimA)
              , ("complete-with", WoComplete claimA [fxAcceptedA fx])
              , ("complete-empty", WoComplete claimA [])
              , ("halt", WoHalt "halt")
              , ("requeue", WoRequeue)
              , ("supersede", WoSupersede otherId)
              , ("cancel", WoCancel)
              ]
            table =
              [ row "pending" "mark-eligible" [Scheduler] (To "eligible")
              , row "eligible" "mark-ineligible" [Scheduler] (To "pending")
              , row "eligible" "claim" [Scheduler] (To "claimed")
              , row "claimed" "release-a" [Scheduler] (To "eligible")
              , row "claimed" "release-b" [Scheduler] (Refuse "claim-mismatch")
              , row "claimed" "start-a" [Supervisor] (To "active")
              , row "claimed" "start-b" [Supervisor] (Refuse "claim-mismatch")
              , row "active" "wait-a" [Supervisor] (To "waiting")
              , row "waiting" "resume-a" [Supervisor] (To "active")
              , row "active" "complete-with" [Supervisor] (To "completed")
              , row "active" "complete-empty" [Supervisor] (Refuse "kind-forbids")
              , row "halted" "requeue" [Human] (To "pending")
              ]
                <> rows ["claimed", "active", "waiting"] "halt" [Human, Supervisor] (To "halted")
                <> rows ["pending", "eligible", "halted"] "supersede" [Human] (To "superseded")
                <> rows ["pending", "eligible", "halted"] "cancel" [Human] (To "canceled")
          exhaustive stepWorkOrder (workOrderStateName . workOrderState) states inputs ["completed", "superseded", "canceled"] table
    , testCase "only Engineering and PR rework may complete with Work Units" $
        fmap mayCompleteWithWorkUnits [minBound .. maxBound]
          @?= [True, False, True, False, False, False, False]
    , testCase "non-code kinds must complete with no Work Units" $
        withFixtures $ \fx ->
          traverse_
            ( \kind -> do
                let
                  active = WorkOrder orderId kind (Active claimA)
                fmap (workOrderStateName . workOrderState) (stepWorkOrder active (Command Supervisor (WoComplete claimA [])))
                  @?= Right "completed"
                either transitionRefusalCode (workOrderStateName . workOrderState) (stepWorkOrder active (Command Supervisor (WoComplete claimA [fxAcceptedA fx])))
                  @?= "kind-forbids"
            )
            (L.filter (not . mayCompleteWithWorkUnits) [minBound .. maxBound])
    , testCase "a claim must match exactly: engineer and generation" $ do
        let
          active = WorkOrder orderId Engineering (Active claimA)
          code input = either transitionRefusalCode (workOrderStateName . workOrderState) (stepWorkOrder active (Command Supervisor input))
        code (WoWait (Claim engineerA 2) "x") @?= "claim-mismatch"
        code (WoWait claimB "x") @?= "claim-mismatch"
        code (WoComplete (Claim engineerA 2) []) @?= "claim-mismatch"
        either transitionRefusalCode (workOrderStateName . workOrderState) (stepWorkOrder (WorkOrder orderId Engineering (Waiting claimA "x")) (Command Supervisor (WoResume claimB)))
          @?= "claim-mismatch"
    , testCase "an active or claimed order cannot be canceled before it is halted" $ do
        either transitionRefusalCode (workOrderStateName . workOrderState) (stepWorkOrder (WorkOrder orderId Engineering (Active claimA)) (Command Human WoCancel))
          @?= "illegal-transition"
        either transitionRefusalCode (workOrderStateName . workOrderState) (stepWorkOrder (WorkOrder orderId Engineering (Claimed claimA)) (Command Human WoCancel))
          @?= "illegal-transition"
    , testCase "a new Work Order is pending and keeps its identity and kind through transitions" $ do
        let
          order = newWorkOrder orderId Investigate
        workOrderState order @?= Pending
        fmap (\o -> (workOrderId o, workOrderKind o)) (stepWorkOrder order (Command Scheduler WoMarkEligible))
          @?= Right (orderId, Investigate)
    ]

orderId :: WorkOrderId
orderId =
  WorkOrderId (uuidFromWords 5 1)

otherId :: WorkOrderId
otherId =
  WorkOrderId (uuidFromWords 5 2)
