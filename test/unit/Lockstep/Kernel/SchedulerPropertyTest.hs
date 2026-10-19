{-# LANGUAGE OverloadedStrings #-}

{- | C-P2.4 §6 properties: seeded (reproducible), 1000 cases each, over
generated worlds of up to six orders with random states, priorities,
admission times, dependencies, repositories, owners, defaults, resources,
revisions, bindings and gate evidence.
-}
module Lockstep.Kernel.SchedulerPropertyTest
  ( tests
  ) where

import Data.List qualified as L
import Data.Maybe (catMaybes, isJust, mapMaybe)
import Data.Ord (Down (..), comparing)
import Flipstone.Prelude
import Test.QuickCheck (Gen, Property, choose, conjoin, counterexample, elements, forAll, frequency, property, shuffle, sublistOf, (===))
import Test.Tasty (TestTree, localOption, testGroup)
import Test.Tasty.QuickCheck (QuickCheckReplay (QuickCheckReplayLegacy), QuickCheckTests (QuickCheckTests), testProperty)
import Text.Show (show)

import Lockstep.Kernel.Identity (WorkOrderId)
import Lockstep.Kernel.Profile (GateEvidence, bindingExceptions, bindingWorkOrder)
import Lockstep.Kernel.Scheduler
  ( Availability (..)
  , ScheduleDecision
  , ScheduledOrder (..)
  , SchedulerInput (..)
  , SourceBasis (..)
  , decisionEligible
  , decisionIneligible
  , decisionSelected
  , renderScheduleDecision
  , scheduleDigest
  , scheduleOrders
  , schedulingCommands
  )
import Lockstep.Kernel.SchedulerFixtures (SchedulerFixtures (..), at, claim, engineer, h, inState, orderIn, repo, schedulerFixtures, ticket, wo)
import Lockstep.Kernel.WorkOrder (WorkOrder (..), WorkOrderState (..), stepWorkOrder)

tests :: TestTree
tests =
  localOption (QuickCheckReplayLegacy 20261019) . localOption (QuickCheckTests 1000) $
    testGroup
      "Work Order scheduler properties (C-P2.4 §6; seed 20261019, 1000 cases)"
      [ testProperty "replay: deciding twice gives the same rendering and digest" $
          withWorld $ \_ input ->
            decide input $ \d ->
              decide input $ \d' ->
                conjoin
                  [ renderScheduleDecision d === renderScheduleDecision d'
                  , scheduleDigest h d === scheduleDigest h d'
                  ]
      , testProperty "permutation: shuffling every input list gives the same rendering" $
          withWorld $ \_ input ->
            forAll (shuffled input) $ \input' ->
              decide input $ \d ->
                decide input' $ \d' ->
                  renderScheduleDecision d === renderScheduleDecision d'
      , testProperty "soundness: candidates are eligible xor reasoned; ranking sorted; selection is the head" $
          withWorld $ \_ input ->
            decide input $ \d ->
              let
                candidates = L.sort (fmap orderId (L.filter isCandidate (inputOrders input)))
                eligible = decisionEligible d
                ineligible = decisionIneligible d
                byId i = L.find ((== i) . orderId) (inputOrders input)
                rankKey o = (Down (orderPriority o), orderAdmittedAt o, orderId o)
                ranked = fmap orderId (L.sortBy (comparing rankKey) (mapMaybe byId eligible))
                ownerOf i = byId i >>= \o -> L.lookup (orderRepository o) (inputOwners input)
              in
                conjoin
                  [ counterexample "eligible and ineligible overlap" (L.null (eligible `L.intersect` fmap fst ineligible))
                  , L.sort (eligible <> fmap fst ineligible) === candidates
                  , counterexample "an ineligible order without reasons" (not (L.any (L.null . snd) ineligible))
                  , eligible === ranked
                  , decisionSelected d === (headOf eligible >>= \i -> fmap (\e -> (i, e)) (ownerOf i))
                  ]
      , testProperty "oracle: eligible exactly when an independent predicate says so" $
          withWorld $ \fx input ->
            decide input $ \d ->
              conjoin
                [ counterexample (show (orderId o, decisionIneligible d)) ((orderId o `L.elem` decisionEligible d) === oracle fx input o)
                | o <- inputOrders input
                , isCandidate o
                ]
      , testProperty "commands: each is accepted and leaves exactly the eligible candidates eligible" $
          withWorld $ \_ input ->
            decide input $ \d ->
              let
                commands = schedulingCommands input d
                after o =
                  case L.lookup (orderId o) commands of
                    Nothing -> Right (orderWorkOrder o)
                    Just command -> stepWorkOrder (orderWorkOrder o) command
              in
                conjoin
                  [ case after o of
                      Left refusal -> counterexample ("command refused: " <> show refusal) (property False)
                      Right next -> isEligibleState (workOrderState next) === (orderId o `L.elem` decisionEligible d)
                  | o <- inputOrders input
                  , isCandidate o
                  ]
      ]

-- Helpers --------------------------------------------------------------------

withWorld :: (SchedulerFixtures -> SchedulerInput -> Property) -> Property
withWorld check =
  case schedulerFixtures of
    Nothing -> counterexample "fixtures could not be built" (property False)
    Just fx -> forAll (world fx) (check fx)

decide :: SchedulerInput -> (ScheduleDecision -> Property) -> Property
decide input check =
  either (\refusal -> counterexample ("refused: " <> show refusal) (property False)) check (scheduleOrders input)

orderId :: ScheduledOrder -> WorkOrderId
orderId =
  workOrderId . orderWorkOrder

isCandidate :: ScheduledOrder -> Bool
isCandidate o =
  case workOrderState (orderWorkOrder o) of
    Pending -> True
    Eligible -> True
    _ -> False

isEligibleState :: WorkOrderState -> Bool
isEligibleState state =
  case state of
    Eligible -> True
    _ -> False

reserves :: WorkOrderState -> Bool
reserves state =
  case state of
    Claimed _ -> True
    Active _ -> True
    Waiting _ _ -> True
    _ -> False

isCompleted :: WorkOrderState -> Bool
isCompleted state =
  case state of
    Completed _ _ -> True
    _ -> False

headOf :: [a] -> Maybe a
headOf xs =
  case xs of
    [] -> Nothing
    x : _ -> Just x

-- | The S3 conditions, restated independently over the generated world.
oracle :: SchedulerFixtures -> SchedulerInput -> ScheduledOrder -> Bool
oracle fx input o =
  let
    others = L.filter ((/= orderId o) . orderId) (inputOrders input)
    binding = orderBinding o
    evidence = orderEvidence o
    stateOf i = workOrderState . orderWorkOrder <$> L.find ((== i) . orderId) (inputOrders input)
  in
    L.and
      [ bindingWorkOrder binding == orderId o
      , L.lookup (orderRepository o) (inputDefaults input) == Just (fxRefV1 fx)
      , not (L.null (bindingExceptions binding)) || (not (L.null evidence) && L.all (== fxImpactEvidence fx) evidence)
      , L.all (maybe False isCompleted . stateOf) (orderDependencies o)
      , isJust (L.lookup (orderRepository o) (inputOwners input))
      , not (L.any (\x -> orderRepository x == orderRepository o && reserves (workOrderState (orderWorkOrder x))) others)
      , L.all (\r -> L.lookup r (inputResources input) == Just ResourceAvailable) (orderResources o)
      , L.lookup (sourceTicket (orderSource o)) (inputRevisions input) == Just (sourceRevision (orderSource o))
      ]

-- Generators -----------------------------------------------------------------

world :: SchedulerFixtures -> Gen SchedulerInput
world fx = do
  count <- choose (1, 6)
  orders <- fmap catMaybes (traverse (genOrder fx count) [1 .. count])
  owners <- sublistOf [(repo n, engineer n) | n <- [1, 2, 3]]
  defaults <- fmap catMaybes (traverse (\n -> elements [Nothing, Just (repo n, fxRefV1 fx), Just (repo n, fxRefV1 fx), Just (repo n, fxRefV2 fx)]) [1, 2, 3])
  resources <- fmap catMaybes (traverse (\r -> elements [Nothing, Just (r, ResourceAvailable), Just (r, ResourceAvailable), Just (r, ResourceUnavailable), Just (r, ResourceUnknown)]) [fxCpu fx, fxGpu fx])
  revisions <- fmap catMaybes (traverse (\n -> frequency [(1, pure Nothing), (4, pure (Just (ticket n, 1))), (1, pure (Just (ticket n, 2)))]) [1 .. 6])
  pure
    SchedulerInput
      { inputOrders = orders
      , inputOwners = owners
      , inputDefaults = defaults
      , inputCatalog = [fxRefV1 fx, fxRefV2 fx]
      , inputResources = resources
      , inputRevisions = revisions
      }

genOrder :: SchedulerFixtures -> Word64 -> Word64 -> Gen (Maybe ScheduledOrder)
genOrder fx count n = do
  state <-
    frequency
      [ (4, pure Pending)
      , (2, pure Eligible)
      , (1, elements [Claimed (claim 1), Active (claim 1), Waiting (claim 1) "w"])
      , (1, elements [Halted "h", Superseded (wo 9), Canceled])
      , (2, pure (Completed (claim 1) []))
      ]
  repository <- elements [repo 1, repo 2, repo 3]
  priority <- elements (fxPriorities fx)
  admitted <- choose (0, 3)
  dependencies <- frequency [(2, pure []), (1, sublistOf (fmap wo [1 .. count + 1]))]
  bindingFor <- frequency [(6, pure (fxBinding fx)), (2, pure (fxExceptedBinding fx)), (1, pure (\_ -> fxBinding fx (wo (n `mod` 6 + 1))))]
  evidence <- frequency [(5, pure [fxImpactEvidence fx]), (1, pure []), (1, pure [fxImpactEvidence fx, fxImpactEvidenceOther fx]), (1, pure [fxImpactUnapproved fx])]
  resources <- frequency [(3, pure []), (1, sublistOf [fxCpu fx, fxGpu fx])]
  pure $ do
    base <- orderIn fx n
    binding <- bindingFor (wo n)
    pure
      (inState state base)
        { orderRepository = repository
        , orderPriority = priority
        , orderAdmittedAt = at admitted
        , orderDependencies = dependencies
        , orderBinding = binding
        , orderEvidence = evidence :: [GateEvidence]
        , orderResources = resources
        }

shuffled :: SchedulerInput -> Gen SchedulerInput
shuffled input = do
  orders <- shuffle (inputOrders input)
  owners <- shuffle (inputOwners input)
  defaults <- shuffle (inputDefaults input)
  catalog <- shuffle (inputCatalog input)
  resources <- shuffle (inputResources input)
  revisions <- shuffle (inputRevisions input)
  pure (SchedulerInput orders owners defaults catalog resources revisions)
