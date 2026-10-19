{-# LANGUAGE OverloadedStrings #-}

-- | C-P2.4 §6 unit cases: the deterministic Work Order scheduler.
module Lockstep.Kernel.SchedulerTest
  ( tests
  ) where

import Data.List qualified as L
import Data.Maybe (isJust)
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Kernel.Identity (WorkOrderId, uuidText)
import Lockstep.Kernel.Identity qualified as Id
import Lockstep.Kernel.Profile
  ( Approval (..)
  , ArtifactKind (..)
  , GateBlock (..)
  , GateEvidence (..)
  , Hasher (..)
  , VerifierKind (..)
  , acceptanceGateIds
  , contentDigestText
  , mkProfileConfirmation
  , mkProfileId
  )
import Lockstep.Kernel.Scheduler
  ( Availability (..)
  , Ineligibility (..)
  , ScheduleDecision
  , ScheduledOrder (..)
  , SchedulerInput (..)
  , SchedulerRefusal (..)
  , SourceBasis (..)
  , decisionEligible
  , decisionIneligible
  , decisionSelected
  , ineligibilityCode
  , mkPriority
  , mkResourceName
  , priorityValue
  , renderScheduleDecision
  , resourceNameText
  , scheduleDigest
  , scheduleOrders
  , schedulerRefusalCode
  , schedulingCommands
  )
import Lockstep.Kernel.SchedulerFixtures (SchedulerFixtures (..), at, claim, engineer, h, inState, orderIn, repo, schedulerFixtures, t0, ticket, wo, worldOf)
import Lockstep.Kernel.Transition (Command (..), Principal (..))
import Lockstep.Kernel.WorkOrder (WorkOrder (..), WorkOrderInput (..), WorkOrderState (..), stepWorkOrder, workOrderStateName)

tests :: TestTree
tests =
  testGroup
    "Work Order scheduler (C-P2.4)"
    [ fixtureTests
    , nameTests
    , selectionTests
    , reasonTests
    , clarificationTests
    , contextTests
    , integrityTests
    , commandTests
    , renderingTests
    ]

-- Helpers --------------------------------------------------------------------

withFx :: (SchedulerFixtures -> Assertion) -> Assertion
withFx check =
  maybe (assertFailure "the scheduler fixtures were refused") check schedulerFixtures

order :: SchedulerFixtures -> Word64 -> IO ScheduledOrder
order fx n =
  maybe (assertFailure ("fixture order refused: " <> show n)) pure (orderIn fx n)

decided :: SchedulerInput -> IO ScheduleDecision
decided input =
  either (\refusal -> assertFailure ("decision refused: " <> show refusal)) pure (scheduleOrders input)

-- | The reasons reported for order @n@; empty when it is not reported ineligible.
reasons :: ScheduleDecision -> Word64 -> [Ineligibility]
reasons decision n =
  maybe [] snd (L.find ((== wo n) . fst) (decisionIneligible decision))

-- | Decides a world of one otherwise eligible order 1 changed by @f@, and returns its reasons.
reasonsFor :: SchedulerFixtures -> (ScheduledOrder -> ScheduledOrder) -> (SchedulerInput -> SchedulerInput) -> IO [Ineligibility]
reasonsFor fx f g = do
  o <- order fx 1
  d <- decided (g (worldOf fx [f o]))
  pure (reasons d 1)

refusedWith :: T.Text -> Either SchedulerRefusal a -> Assertion
refusedWith code result =
  case result of
    Left refusal -> schedulerRefusalCode refusal @?= code
    Right _ -> assertFailure ("expected refusal " <> T.unpack code)

idText :: WorkOrderId -> T.Text
idText (Id.WorkOrderId u) =
  uuidText u

-- Fixtures -------------------------------------------------------------------

fixtureTests :: TestTree
fixtureTests =
  testGroup
    "fixtures (exercised on their own before the freeze)"
    [ testCase "the fixture world builds" $
        withFx $ \fx -> do
          traverse_ (order fx) [1 .. 9]
          traverse_ (\n -> assertBool ("excepted binding " <> show n) (isJust (fxExceptedBinding fx (wo n)))) [1 .. 9]
          fmap priorityValue (fxPriorities fx) @?= [0, 1, 2, 3]
          fmap priorityValue [fxLow fx, fxMid fx, fxHigh fx] @?= [1, 5, 9]
          fmap resourceNameText [fxCpu fx, fxGpu fx] @?= ["cpu", "gpu"]
          assertBool "versions differ" (fxRefV1 fx /= fxRefV2 fx)
          w <- fmap (worldOf fx) (traverse (order fx) [1, 2])
          fmap fst (inputOwners w) @?= [repo 1, repo 2, repo 3]
          L.length (inputRevisions w) @?= 9
    ]

-- Names ----------------------------------------------------------------------

nameTests :: TestTree
nameTests =
  testGroup
    "priority and resource names (S2, S6)"
    [ testCase "a human sets 0 to 999" $ do
        fmap priorityValue (mkPriority Human 0) @?= Right 0
        fmap priorityValue (mkPriority Human 999) @?= Right 999
    , testCase "only a human sets a priority" $
        traverse_
          (\p -> mkPriority p 5 @?= Left (PriorityNotHuman p))
          [Agent, Scheduler, Supervisor, DeliveryAdapter]
    , testCase "out-of-range priorities are invalid-priority" $ do
        refusedWith "invalid-priority" (mkPriority Human (-1))
        refusedWith "invalid-priority" (mkPriority Human 1000)
        refusedWith "priority-not-human" (mkPriority Agent 5)
    , testCase "resource names" $ do
        fmap resourceNameText (mkResourceName "cpu-2") @?= Right "cpu-2"
        fmap resourceNameText (mkResourceName (T.cons 'a' (T.replicate 63 "b"))) @?= Right (T.cons 'a' (T.replicate 63 "b"))
        traverse_
          (refusedWith "invalid-resource" . mkResourceName)
          ["", "Cpu", "1cpu", "cpu_2", "cpu 2", T.cons 'a' (T.replicate 64 "b")]
    ]

-- Selection ------------------------------------------------------------------

selectionTests :: TestTree
selectionTests =
  testGroup
    "selection and ordering (S7, D-5.8)"
    [ testCase "one eligible order is selected with its repository's owner" $
        withFx $ \fx -> do
          o <- order fx 1
          d <- decided (worldOf fx [o {orderRepository = repo 2}])
          decisionSelected d @?= Just (wo 1, engineer 2)
          decisionEligible d @?= [wo 1]
          decisionIneligible d @?= []
    , testCase "no candidates selects none" $
        withFx $ \fx -> do
          o <- order fx 1
          d <- decided (worldOf fx [inState (Completed (claim 1) []) o])
          decisionSelected d @?= Nothing
          renderScheduleDecision d @?= "lockstep-schedule 1\nselected none\n"
    , testCase "a blocked highest-priority order is excluded; the eligible lower one is selected" $
        withFx $ \fx -> do
          high <- order fx 1
          low <- order fx 2
          d <-
            decided
              ( worldOf
                  fx
                  [ high {orderPriority = fxHigh fx, orderEvidence = []}
                  , low {orderPriority = fxLow fx, orderRepository = repo 2}
                  ]
              )
          decisionSelected d @?= Just (wo 2, engineer 2)
          decisionEligible d @?= [wo 2]
          reasons d 1 @?= [PrerequisiteBlocked (fxImpact fx) (MissingArtifact ImpactAssessment)]
    , testCase "higher priority first" $
        withFx $ \fx -> do
          a <- order fx 1
          b <- order fx 2
          d <- decided (worldOf fx [a {orderPriority = fxLow fx}, b {orderPriority = fxHigh fx, orderRepository = repo 2}])
          decisionEligible d @?= [wo 2, wo 1]
          decisionSelected d @?= Just (wo 2, engineer 2)
    , testCase "equal priority: the oldest admission first" $
        withFx $ \fx -> do
          a <- order fx 1
          b <- order fx 2
          d <- decided (worldOf fx [a {orderAdmittedAt = at 30}, b {orderAdmittedAt = at 10, orderRepository = repo 2}])
          decisionEligible d @?= [wo 2, wo 1]
    , testCase "equal priority and admission: the smallest Work Order id first" $
        withFx $ \fx -> do
          a <- order fx 7
          b <- order fx 3
          d <- decided (worldOf fx [a {orderAdmittedAt = t0}, b {orderAdmittedAt = t0, orderRepository = repo 2}])
          decisionEligible d @?= [wo 3, wo 7]
          decisionSelected d @?= Just (wo 3, engineer 2)
    , testCase "the decision is the same for every permutation of every input list" $
        withFx $ \fx -> do
          o1 <- order fx 1
          o2 <- order fx 2
          o3 <- order fx 3
          o4 <- order fx 4
          let
            mixed =
              [ o1 {orderPriority = fxHigh fx, orderEvidence = []}
              , o2 {orderRepository = repo 2, orderAdmittedAt = t0}
              , o3 {orderRepository = repo 3, orderAdmittedAt = t0, orderResources = [fxGpu fx, fxCpu fx]}
              , inState (Claimed (claim 1)) o4
              ]
            base = worldOf fx mixed
            withResources w = w {inputResources = [(fxCpu fx, ResourceAvailable), (fxGpu fx, ResourceAvailable)]}
          reference <- decided (withResources base)
          traverse_
            ( \perm -> do
                d <-
                  decided
                    ( withResources
                        base
                          { inputOrders = perm
                          , inputOwners = L.reverse (inputOwners base)
                          , inputDefaults = L.reverse (inputDefaults base)
                          , inputRevisions = L.reverse (inputRevisions base)
                          }
                    )
                renderScheduleDecision d @?= renderScheduleDecision reference
            )
            (L.permutations mixed)
          let
            reversedResources = base {inputResources = L.reverse (inputResources (withResources base))}
          d <- decided reversedResources
          renderScheduleDecision d @?= renderScheduleDecision reference
    ]

-- Reasons --------------------------------------------------------------------

reasonTests :: TestTree
reasonTests =
  testGroup
    "eligibility reasons (S3, D-5.7)"
    [ testCase "an otherwise eligible order has no reasons" $
        withFx $ \fx -> do
          rs <- reasonsFor fx id id
          rs @?= []
    , testCase "binding-mismatch reports no Profile reasons" $
        withFx $ \fx -> do
          other <- maybe (assertFailure "binding") pure (fxBinding fx (wo 2))
          rs <- reasonsFor fx (\o -> o {orderBinding = other, orderEvidence = []}) (\w -> w {inputDefaults = []})
          rs @?= [BindingMismatch]
    , testCase "profile-default-unset" $
        withFx $ \fx -> do
          rs <- reasonsFor fx id (\w -> w {inputDefaults = L.filter ((/= repo 1) . fst) (inputDefaults w)})
          rs @?= [ProfileDefaultUnset]
    , testCase "profile-changed names the changed Profile; a human confirmation makes it eligible" $
        withFx $ \fx -> do
          sched <- maybe (assertFailure "profile id") pure (mkProfileId "sched")
          let
            newDefault w = w {inputDefaults = [(repo 1, fxRefV2 fx)], inputCatalog = [fxRefV1 fx, fxRefV2 fx]}
          rs <- reasonsFor fx id newDefault
          rs @?= [ProfileChangedSince [sched]]
          binding <- maybe (assertFailure "binding") pure (fxBinding fx (wo 1))
          confirmation <- either (assertFailure . show) pure (mkProfileConfirmation Human binding [fxRefV2 fx] "alice")
          confirmed <- reasonsFor fx (\o -> o {orderConfirmations = [confirmation]}) newDefault
          confirmed @?= []
          wrong <- either (assertFailure . show) pure (mkProfileConfirmation Human binding [fxRefV1 fx] "alice")
          stillChanged <- reasonsFor fx (\o -> o {orderConfirmations = [wrong]}) newDefault
          stillChanged @?= [ProfileChangedSince [sched]]
    , testCase "prerequisite-blocked: missing, ambiguous, unverified and under-approved evidence" $
        withFx $ \fx -> do
          let
            blockedBy evidence = reasonsFor fx (\o -> o {orderEvidence = evidence}) id
            impact = fxImpact fx
          missing <- blockedBy []
          missing @?= [PrerequisiteBlocked impact (MissingArtifact ImpactAssessment)]
          ambiguous <- blockedBy [fxImpactEvidence fx, fxImpactEvidenceOther fx]
          ambiguous @?= [PrerequisiteBlocked impact (AmbiguousEvidence ImpactAssessment)]
          unverified <- blockedBy [(fxImpactEvidence fx) {evidenceVerifiedBy = []}]
          unverified @?= [PrerequisiteBlocked impact (Unverified ImpactAssessment [VerifyHumanInspection])]
          unapproved <- blockedBy [fxImpactUnapproved fx]
          unapproved @?= [PrerequisiteBlocked impact (NeedsApproval ImpactAssessment ApprovalSupervisor)]
    , testCase "dependencies: completed is satisfied; superseded and canceled are unsatisfiable; others incomplete; absent unknown" $
        withFx $ \fx -> do
          o1 <- order fx 1
          context <- traverse (order fx) [2, 3, 4, 5, 6]
          let
            states = [Completed (claim 2) [], Superseded (wo 9), Canceled, Pending, Claimed (claim 2)]
            others = L.zipWith (\s o -> (inState s o) {orderRepository = repo 2}) states context
          d <- decided (worldOf fx (o1 {orderDependencies = [wo 7, wo 6, wo 5, wo 4, wo 3, wo 2]} : others))
          reasons d 1
            @?= [ DependencyUnsatisfiable (wo 3)
                , DependencyUnsatisfiable (wo 4)
                , DependencyIncomplete (wo 5)
                , DependencyIncomplete (wo 6)
                , DependencyUnknown (wo 7)
                ]
    , testCase "repository-not-owned" $
        withFx $ \fx -> do
          rs <- reasonsFor fx id (\w -> w {inputOwners = L.filter ((/= repo 1) . fst) (inputOwners w)})
          rs @?= [RepositoryNotOwned]
    , testCase "resources: absent and reported unknown are resource-unknown; unavailable; available" $
        withFx $ \fx -> do
          let
            needs o = o {orderResources = [fxGpu fx, fxCpu fx]}
          absent <- reasonsFor fx needs id
          absent @?= [ResourceUnknownReason (fxCpu fx), ResourceUnknownReason (fxGpu fx)]
          mixed <- reasonsFor fx needs (\w -> w {inputResources = [(fxGpu fx, ResourceUnavailable), (fxCpu fx, ResourceUnknown)]})
          mixed @?= [ResourceUnknownReason (fxCpu fx), ResourceUnavailableReason (fxGpu fx)]
          available <- reasonsFor fx needs (\w -> w {inputResources = [(fxGpu fx, ResourceAvailable), (fxCpu fx, ResourceAvailable)]})
          available @?= []
    , testCase "source-unknown and source-stale" $
        withFx $ \fx -> do
          unknown <- reasonsFor fx id (\w -> w {inputRevisions = L.filter ((/= ticket 1) . fst) (inputRevisions w)})
          unknown @?= [SourceUnknown]
          newer <- reasonsFor fx id (\w -> w {inputRevisions = (ticket 1, 2) : L.filter ((/= ticket 1) . fst) (inputRevisions w)})
          newer @?= [SourceStale]
          older <- reasonsFor fx (\o -> o {orderSource = SourceBasis (ticket 1) 3}) id
          older @?= [SourceStale]
    , testCase "every reason is reported, in the S3 order" $
        withFx $ \fx -> do
          sched <- maybe (assertFailure "profile id") pure (mkProfileId "sched")
          o1 <- order fx 1
          o2 <- order fx 2
          let
            o1' = o1 {orderEvidence = [], orderDependencies = [wo 8], orderResources = [fxCpu fx]}
            w0 = worldOf fx [o1', inState (Claimed (claim 1)) o2]
          d <-
            decided
              w0
                { inputDefaults = (repo 1, fxRefV2 fx) : L.filter ((/= repo 1) . fst) (inputDefaults w0)
                , inputCatalog = [fxRefV1 fx, fxRefV2 fx]
                , inputOwners = L.filter ((/= repo 1) . fst) (inputOwners w0)
                , inputRevisions = (ticket 1, 2) : L.filter ((/= ticket 1) . fst) (inputRevisions w0)
                }
          reasons d 1
            @?= [ ProfileChangedSince [sched]
                , PrerequisiteBlocked (fxImpact fx) (MissingArtifact ImpactAssessment)
                , DependencyUnknown (wo 8)
                , RepositoryNotOwned
                , RepositoryReserved (wo 2)
                , ResourceUnknownReason (fxCpu fx)
                , SourceStale
                ]
          fmap ineligibilityCode (reasons d 1)
            @?= [ "profile-changed"
                , "prerequisite-blocked"
                , "dependency-unknown"
                , "repository-not-owned"
                , "repository-reserved"
                , "resource-unknown"
                , "source-stale"
                ]
    , testCase "reason and refusal codes" $
        withFx $ \fx -> do
          fmap
            ineligibilityCode
            [ BindingMismatch
            , ProfileDefaultUnset
            , ProfileChangedSince []
            , PrerequisiteBlocked (fxImpact fx) (MissingArtifact ImpactAssessment)
            , DependencyUnknown (wo 1)
            , DependencyUnsatisfiable (wo 1)
            , DependencyIncomplete (wo 1)
            , RepositoryNotOwned
            , RepositoryReserved (wo 1)
            , ResourceUnknownReason (fxCpu fx)
            , ResourceUnavailableReason (fxCpu fx)
            , SourceUnknown
            , SourceStale
            ]
            @?= [ "binding-mismatch"
                , "profile-default-unset"
                , "profile-changed"
                , "prerequisite-blocked"
                , "dependency-unknown"
                , "dependency-unsatisfiable"
                , "dependency-incomplete"
                , "repository-not-owned"
                , "repository-reserved"
                , "resource-unknown"
                , "resource-unavailable"
                , "source-unknown"
                , "source-stale"
                ]
          fmap
            schedulerRefusalCode
            [PriorityNotHuman Agent, InvalidPriority 1000, InvalidResource "X", ConflictingInput "orders"]
            @?= ["priority-not-human", "invalid-priority", "invalid-resource", "conflicting-input"]
    ]

-- Clarifications -------------------------------------------------------------

clarificationTests :: TestTree
clarificationTests =
  testGroup
    "DG-05 clarifications 1 and 3 (S4, S5)"
    [ testCase "an unsatisfied before-acceptance gate never blocks scheduling" $
        withFx $ \fx -> do
          o <- order fx 1
          acceptanceGateIds (orderBinding o) @?= ["verify"]
          d <- decided (worldOf fx [o])
          decisionSelected d @?= Just (wo 1, engineer 1)
    , testCase "an excepted before-execution gate does not block" $
        withFx $ \fx -> do
          excepted <- maybe (assertFailure "binding") pure (fxExceptedBinding fx (wo 1))
          rs <- reasonsFor fx (\o -> o {orderBinding = excepted, orderEvidence = []}) id
          rs @?= []
    , testCase "two queued orders for one repository are both eligible; only the first is selected" $
        withFx $ \fx -> do
          a <- order fx 1
          b <- order fx 2
          d <- decided (worldOf fx [a, inState Eligible b])
          decisionEligible d @?= [wo 1, wo 2]
          decisionSelected d @?= Just (wo 1, engineer 1)
    , testCase "a claimed, active or waiting order reserves its repository" $
        withFx $ \fx ->
          traverse_
            ( \state -> do
                a <- order fx 1
                b <- order fx 2
                c <- order fx 3
                d <- decided (worldOf fx [a, inState state b, c {orderRepository = repo 2}])
                reasons d 1 @?= [RepositoryReserved (wo 2)]
                decisionSelected d @?= Just (wo 3, engineer 2)
            )
            [Claimed (claim 1), Active (claim 1), Waiting (claim 1) "input"]
    , testCase "halted, completed, superseded and canceled orders reserve nothing" $
        withFx $ \fx ->
          traverse_
            ( \state -> do
                a <- order fx 1
                b <- order fx 2
                d <- decided (worldOf fx [a, inState state b])
                reasons d 1 @?= []
                decisionSelected d @?= Just (wo 1, engineer 1)
            )
            [Halted "operator", Completed (claim 1) [], Superseded (wo 9), Canceled]
    ]

-- Context orders ---------------------------------------------------------------

contextTests :: TestTree
contextTests =
  testGroup
    "context orders (S1, S9)"
    [ testCase "orders in non-candidate states never appear in the decision" $
        withFx $ \fx -> do
          os <- traverse (order fx) [1 .. 7]
          let
            states = [Claimed (claim 1), Active (claim 1), Waiting (claim 1) "w", Halted "h", Completed (claim 1) [], Superseded (wo 9), Canceled]
            context = L.zipWith3 (\s r o -> (inState s o) {orderRepository = repo r, orderEvidence = []}) states [1, 2, 3, 1, 1, 1, 1] os
          d <- decided (worldOf fx context)
          decisionSelected d @?= Nothing
          decisionEligible d @?= []
          decisionIneligible d @?= []
    ]

-- Input integrity --------------------------------------------------------------

integrityTests :: TestTree
integrityTests =
  testGroup
    "input integrity (S8)"
    [ testCase "every duplicate input is conflicting-input" $
        withFx $ \fx -> do
          o1 <- order fx 1
          o2 <- order fx 2
          let
            w = worldOf fx [o1, o2 {orderRepository = repo 2}]
            conflicting = refusedWith "conflicting-input" . scheduleOrders
          conflicting w {inputOrders = [o1, o1]}
          conflicting w {inputOwners = (repo 1, engineer 2) : inputOwners w}
          conflicting w {inputDefaults = (repo 1, fxRefV2 fx) : inputDefaults w}
          conflicting w {inputResources = [(fxCpu fx, ResourceAvailable), (fxCpu fx, ResourceAvailable)]}
          conflicting w {inputRevisions = (ticket 1, 1) : inputRevisions w}
          conflicting w {inputOrders = [o1 {orderResources = [fxCpu fx, fxCpu fx]}]}
          conflicting w {inputOrders = [o1 {orderDependencies = [wo 2, wo 2]}, o2]}
    ]

-- Commands -------------------------------------------------------------------

commandTests :: TestTree
commandTests =
  testGroup
    "scheduling commands (S10)"
    [ testCase "mark-eligible for eligible pending, mark-ineligible for ineligible eligible, nothing else" $
        withFx $ \fx -> do
          os <- traverse (order fx) [1, 2, 3, 4, 5]
          let
            o1 = L.zipWith (\o r -> o {orderRepository = repo r}) os [1, 2, 3, 1, 3]
            orders = case o1 of
              [a, b, c, e, f] ->
                [ a -- pending, eligible
                , inState Eligible b -- eligible, stays eligible
                , c {orderEvidence = []} -- pending, ineligible
                , (inState Eligible e) {orderEvidence = []} -- eligible, now ineligible
                , inState (Claimed (claim 1)) f
                ]
              _ -> []
            input = worldOf fx orders
          d <- decided input
          let
            commands = schedulingCommands input d
          fmap (\(i, Command p c) -> (i, p, c)) commands
            @?= [(wo 1, Scheduler, WoMarkEligible), (wo 4, Scheduler, WoMarkIneligible)]
          traverse_
            ( \(i, command) ->
                case L.find ((== i) . workOrderId . orderWorkOrder) orders of
                  Nothing -> assertFailure "command for an unknown order"
                  Just o ->
                    case stepWorkOrder (orderWorkOrder o) command of
                      Left refusal -> assertFailure ("command refused: " <> show refusal)
                      Right next -> assertBool "moved" (workOrderStateName (workOrderState next) /= workOrderStateName (workOrderState (orderWorkOrder o)))
            )
            commands
    ]

-- Rendering ------------------------------------------------------------------

renderingTests :: TestTree
renderingTests =
  testGroup
    "rendering and digest (S11, §3)"
    [ testCase "the golden rendering of a mixed decision; the digest is its SHA-256" $
        withFx $ \fx -> do
          os <- traverse (order fx) [1, 2, 3, 4, 5]
          let
            orders = case os of
              [a, b, c, e, f] ->
                [ a
                , b {orderPriority = fxHigh fx, orderEvidence = []}
                , (inState Eligible c) {orderRepository = repo 2}
                , (inState (Claimed (claim 3)) e) {orderRepository = repo 3}
                , f {orderRepository = repo 3}
                ]
              _ -> []
          d <- decided (worldOf fx orders)
          let
            rendering = renderScheduleDecision d
          rendering
            @?= T.unlines
              [ "lockstep-schedule 1"
              , "selected " <> idText (wo 1) <> " engineer 00000000-0000-0002-0000-000000000001"
              , "eligible 1 00000000-0000-0000-0000-000000000001 priority=5 admitted-at=2026-10-19T00:01:00Z"
              , "eligible 2 00000000-0000-0000-0000-000000000003 priority=5 admitted-at=2026-10-19T00:03:00Z"
              , "ineligible 00000000-0000-0000-0000-000000000002 prerequisite-blocked impact missing-artifact impact-assessment"
              , "ineligible 00000000-0000-0000-0000-000000000005 repository-reserved 00000000-0000-0000-0000-000000000004"
              ]
          case h of
            Hasher f -> scheduleDigest h d @?= f rendering
          T.length (contentDigestText (scheduleDigest h d)) @?= 64
    , testCase "deciding twice gives the same rendering" $
        withFx $ \fx -> do
          os <- traverse (order fx) [1, 2]
          let
            input = worldOf fx os
          a <- decided input
          b <- decided input
          renderScheduleDecision a @?= renderScheduleDecision b
    ]
