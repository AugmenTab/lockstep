{-# LANGUAGE OverloadedStrings #-}

{- | Update 2, DG-08 local Phase signoff (owner decision: option C, B by
default): an approved plan designates a human gate where a unit of a later
phase needs the person's acceptance of a unit of an earlier phase (a
human-acceptance edge across a phase boundary). Any other boundary advances
provisionally. A revision that drops such an edge, weakens it to a technical
one, or withdraws one of its units removes the gate.
-}
module Lockstep.Kernel.PhaseGateTest
  ( tests
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Lockstep.Kernel.PhaseGate (PhaseGate (..), gatesRemoved, humanGates)
import Lockstep.Kernel.Plan
  ( EdgeKind (..)
  , EffectClass (..)
  , Envelope (..)
  , PlanCriterion (..)
  , PlanDocument (..)
  , PlanEdge (..)
  , PlanMode (..)
  , PlanSource (..)
  , PlanUnit (..)
  , RiskClass (..)
  , UnitKey
  , mkUnitKey
  )
import Lockstep.Kernel.Task (Priority (..))

k :: T.Text -> UnitKey
k text =
  case mkUnitKey text of
    Just u -> u
    Nothing -> k "invalid-key-in-test"

unit :: T.Text -> T.Text -> PlanUnit
unit key phase =
  PlanUnit
    { unitKey = k key
    , unitTitle = "Build " <> key
    , unitPhase = phase
    , unitSubphase = phase <> ".1"
    , unitWorkKind = "feature"
    , unitProfile = "lockstep-engineering"
    , unitPriority = Normal
    , unitEffect = LocalOnly
    , unitRisk = RiskLow
    , unitProvisional = True
    , unitOutputs = [key <> ".py"]
    , unitAcceptance = [PlanCriterion ("It builds " <> key <> ".") ["prd"]]
    , unitNegative = []
    , unitChecks = []
    , unitPrerequisites = []
    , unitResources = []
    }

plan :: [PlanUnit] -> [PlanEdge] -> PlanDocument
plan units edges =
  PlanDocument
    { planTitle = "Gated"
    , planMode = Brownfield
    , planSources = [PlanSource "prd" "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"]
    , planEnvelope = Envelope False 10 Nothing
    , planUnits = units
    , planEdges = edges
    , planUncertainties = []
    }

gated :: PlanDocument
gated =
  plan
    [unit "a" "P1", unit "b" "P2", unit "c" "P2", unit "d" "P1"]
    [PlanEdge (k "b") (k "a") HumanAcceptance, PlanEdge (k "c") (k "a") Technical, PlanEdge (k "d") (k "a") HumanAcceptance]

gate :: PhaseGate
gate =
  PhaseGate {gateDependent = k "b", gatePrerequisite = k "a", gateFromPhase = "P1", gateToPhase = "P2"}

tests :: TestTree
tests =
  testGroup
    "DG-08 Phase signoff: human gates in an approved plan"
    [ testCase "a human-acceptance edge across a phase boundary is a gate; inside a phase, or technical, it is not" $
        humanGates gated @?= [gate]
    , testCase "keeping the plan, or adding a gate, removes nothing" $ do
        gatesRemoved gated gated @?= []
        gatesRemoved (plan [unit "a" "P1", unit "b" "P2"] []) gated @?= []
    , testCase "dropping the edge, weakening it to technical, or withdrawing one of its units removes the gate" $ do
        gatesRemoved gated gated {planEdges = [PlanEdge (k "c") (k "a") Technical]} @?= [gate]
        gatesRemoved gated gated {planEdges = [PlanEdge (k "b") (k "a") Technical, PlanEdge (k "c") (k "a") Technical]} @?= [gate]
        gatesRemoved gated (plan [unit "a" "P1", unit "c" "P2"] [PlanEdge (k "c") (k "a") Technical]) @?= [gate]
    , testCase "moving both units into one phase removes the gate too" $
        gatesRemoved gated gated {planUnits = [unit "a" "P1", unit "b" "P1", unit "c" "P2", unit "d" "P1"]} @?= [gate]
    ]
