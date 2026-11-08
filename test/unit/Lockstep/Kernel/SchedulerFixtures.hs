{-# LANGUAGE OverloadedStrings #-}

{- | Shared C-P2.4 fixtures, built purely with the real C-P2.3 Profile API so
the property tests can use them. 'schedulerFixtures' is 'Nothing' if any
fixture is refused; the test "the fixture world builds" asserts it is not.

The repository default "sched" has a @before-execution@ gate "impact"
(impact assessment, human inspection, supervisor approval, exception path)
and a @before-acceptance@ gate "verify" (a verification record, which only
execution produces). Version 2 adds nothing but is a new source.
-}
module Lockstep.Kernel.SchedulerFixtures
  ( SchedulerFixtures (..)
  , schedulerFixtures
  , h
  , wo
  , repo
  , engineer
  , ticket
  , at
  , t0
  , claim
  , orderIn
  , worldOf
  , inState
  ) where

import Data.Text qualified as T
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, secondsToDiffTime)
import Flipstone.Prelude

import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Kernel.Identity (EngineerId (..), RepositoryId (..), TicketId (..), WorkOrderId (..), uuidFromWords)
import Lockstep.Kernel.Profile
  ( Approval (..)
  , ArtifactKind (..)
  , Behaviour (..)
  , ContentDigest
  , EffectiveProfile
  , ExceptionTarget (..)
  , GateEvidence (..)
  , GateId
  , Hasher (..)
  , PathClass (..)
  , ProfileBinding
  , ProfileDefinition
  , ProfileRef
  , RawGate (..)
  , RawProfile (..)
  , ResolutionInput (..)
  , VerifierKind (..)
  , WorkFacts
  , bindProfile
  , effectiveDigest
  , mkContentDigest
  , mkExceptionReceipt
  , mkGateId
  , mkProfileDefinition
  , mkWorkFacts
  , profileRef
  , resolveProfile
  )
import Lockstep.Kernel.Scheduler
  ( Priority
  , ResourceName
  , ScheduledOrder (..)
  , SchedulerInput (..)
  , SourceBasis (..)
  , mkPriority
  , mkResourceName
  )
import Lockstep.Kernel.Transition (Principal (..))
import Lockstep.Kernel.WorkOrder (Claim (..), WorkOrder (..), WorkOrderKind (..), WorkOrderState (..), newWorkOrder)

data SchedulerFixtures
  = SchedulerFixtures
  { fxDefaultV1 :: ProfileDefinition
  , fxDefaultV2 :: ProfileDefinition
  , fxRefV1 :: ProfileRef
  , fxRefV2 :: ProfileRef
  , fxFacts :: WorkFacts
  , fxEffective :: EffectiveProfile
  , fxImpact :: GateId
  , fxBinding :: WorkOrderId -> Maybe ProfileBinding
  -- ^ a plain Supervisor binding for the order
  , fxExceptedBinding :: WorkOrderId -> Maybe ProfileBinding
  -- ^ the same with a human exception receipt for "impact"
  , fxImpactEvidence :: GateEvidence
  , fxImpactEvidenceOther :: GateEvidence
  -- ^ the same artifact with another digest (ambiguous together with 'fxImpactEvidence')
  , fxImpactUnapproved :: GateEvidence
  -- ^ approval below the gate's
  , fxPriorities :: [Priority]
  -- ^ 0, 1, 2, 3
  , fxLow :: Priority
  , fxMid :: Priority
  , fxHigh :: Priority
  , fxCpu :: ResourceName
  , fxGpu :: ResourceName
  }

h :: Hasher
h =
  sha256Hasher

wo :: Word64 -> WorkOrderId
wo n =
  WorkOrderId (uuidFromWords 0 n)

repo :: Word64 -> RepositoryId
repo n =
  RepositoryId (uuidFromWords 1 n)

engineer :: Word64 -> EngineerId
engineer n =
  EngineerId (uuidFromWords 2 n)

ticket :: Word64 -> TicketId
ticket n =
  TicketId (uuidFromWords 3 n)

t0 :: UTCTime
t0 =
  UTCTime (fromGregorian 2026 10 19) (secondsToDiffTime 0)

-- | @n@ minutes after 't0'.
at :: Integer -> UTCTime
at n =
  addUTCTime (fromInteger (n * 60)) t0

claim :: Word64 -> Claim
claim n =
  Claim (engineer n) 1

gate :: T.Text -> T.Text -> [T.Text] -> [T.Text] -> T.Text -> Bool -> RawGate
gate gid stage artifacts verifiers approval exceptionPath =
  RawGate
    { rawGateId = gid
    , rawGateStage = stage
    , rawGateArtifacts = artifacts
    , rawGateKinds = Nothing
    , rawGateClasses = Nothing
    , rawGatePathClasses = Nothing
    , rawGateVerifiers = verifiers
    , rawGateApproval = approval
    , rawGateExceptionPath = exceptionPath
    }

defaultRaw :: Integer -> RawProfile
defaultRaw version =
  RawProfile
    { rawProfileId = "sched"
    , rawProfileVersion = version
    , rawAllowsNonBehavioural = Nothing
    , rawInvariantExceptions = []
    , rawGates =
        [ gate "impact" "before-execution" ["impact-assessment"] ["human-inspection"] "supervisor" True
        , gate "verify" "before-acceptance" ["verification-record"] ["deterministic-command"] "none" False
        ]
    , rawSpecializations = []
    }

evidence :: ContentDigest -> Approval -> GateEvidence
evidence digest approval =
  GateEvidence
    { evidenceArtifact = ImpactAssessment
    , evidenceDigest = digest
    , evidenceVerifiedBy = [VerifyHumanInspection]
    , evidenceApproval = approval
    }

schedulerFixtures :: Maybe SchedulerFixtures
schedulerFixtures = do
  v1 <- right (mkProfileDefinition (defaultRaw 1))
  v2 <- right (mkProfileDefinition (defaultRaw 2))
  workFacts <- right (mkWorkFacts Human Engineering [] [PathSource] BehaviourChanging)
  effective <- right (resolveProfile h (ResolutionInput v1 [v1] [] workFacts))
  impact <- mkGateId "impact"
  digestA <- mkContentDigest (hex 'a')
  digestB <- mkContentDigest (hex 'b')
  priorities <- traverse (right . mkPriority Human) [0, 1, 2, 3]
  low <- right (mkPriority Human 1)
  mid <- right (mkPriority Human 5)
  high <- right (mkPriority Human 9)
  cpu <- right (mkResourceName "cpu")
  gpu <- right (mkResourceName "gpu")
  let
    binding order = right (bindProfile h Supervisor order "operator" effective [])
    excepted order = do
      receipt <- right (mkExceptionReceipt Human (ForWorkOrder order) impact "accepted risk" "alice" t0 (effectiveDigest effective))
      right (bindProfile h Supervisor order "operator" effective [receipt])
  -- Every binding the tests use is built here once, so a refusal shows up as Nothing.
  traverse_ (binding . wo) [1 .. 9]
  traverse_ (excepted . wo) [1 .. 9]
  pure
    SchedulerFixtures
      { fxDefaultV1 = v1
      , fxDefaultV2 = v2
      , fxRefV1 = profileRef h v1
      , fxRefV2 = profileRef h v2
      , fxFacts = workFacts
      , fxEffective = effective
      , fxImpact = impact
      , fxBinding = binding
      , fxExceptedBinding = excepted
      , fxImpactEvidence = evidence digestA ApprovalSupervisor
      , fxImpactEvidenceOther = evidence digestB ApprovalSupervisor
      , fxImpactUnapproved = evidence digestA ApprovalNone
      , fxPriorities = priorities
      , fxLow = low
      , fxMid = mid
      , fxHigh = high
      , fxCpu = cpu
      , fxGpu = gpu
      }
 where
  right = either (const Nothing) Just
  hex c = T.replicate 64 (T.singleton c)

{- | An otherwise eligible pending order @n@: repository 1, middle priority,
admitted @n@ minutes after 't0', no dependencies, its own binding, the impact
evidence, no resources, source Ticket @n@ at revision 1.
-}
orderIn :: SchedulerFixtures -> Word64 -> Maybe ScheduledOrder
orderIn fx n = do
  binding <- fxBinding fx (wo n)
  pure
    ScheduledOrder
      { orderWorkOrder = newWorkOrder (wo n) Engineering
      , orderRepository = repo 1
      , orderPriority = fxMid fx
      , orderAdmittedAt = at (toInteger n)
      , orderDependencies = []
      , orderBinding = binding
      , orderConfirmations = []
      , orderEvidence = [fxImpactEvidence fx]
      , orderResources = []
      , orderSource = SourceBasis (ticket n) 1
      }

{- | The world around some orders: repositories 1–3 owned by Engineers 1–3,
each with default "sched" version 1, catalog version 1, no resources, and
Tickets 1–9 at revision 1.
-}
worldOf :: SchedulerFixtures -> [ScheduledOrder] -> SchedulerInput
worldOf fx orders =
  SchedulerInput
    { inputOrders = orders
    , inputOwners = [(repo n, engineer n) | n <- [1, 2, 3]]
    , inputDefaults = [(repo n, fxRefV1 fx) | n <- [1, 2, 3]]
    , inputCatalog = [fxRefV1 fx]
    , inputResources = []
    , inputRevisions = [(ticket n, 1) | n <- [1 .. 9]]
    }

-- | The order with another lifecycle state.
inState :: WorkOrderState -> ScheduledOrder -> ScheduledOrder
inState state order =
  order {orderWorkOrder = (orderWorkOrder order) {workOrderState = state}}
