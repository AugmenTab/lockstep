{- | Update 2, DG-08 local Phase signoff (owner decision: option C, with B as
the default). An approved plan designates a human gate where a unit of one
phase depends, by a human-acceptance edge, on a unit of another phase: the
dependent starts only after the person's acceptance (Done) of the
prerequisite (C-P6.5 S1 never lets the scheduler pass such an edge). Every
other phase boundary advances provisionally inside the approved plan's
authority. The gate is part of the approved, digest-bound document, so it is
expressed by the plan and never inferred from scheduling being enabled. Pure.
-}
module Lockstep.Kernel.PhaseGate
  ( PhaseGate (..)
  , humanGates
  , gatesRemoved
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Plan (EdgeKind (HumanAcceptance), PlanDocument (..), PlanEdge (..), PlanUnit (..), UnitKey)

-- | A human gate: the dependent (of a later phase) starts only after the person's acceptance of the prerequisite.
data PhaseGate
  = PhaseGate
  { gateDependent :: UnitKey
  , gatePrerequisite :: UnitKey
  , gateFromPhase :: T.Text
  , gateToPhase :: T.Text
  }
  deriving (Eq, Show)

-- | The plan's human gates, by dependent then prerequisite.
humanGates :: PlanDocument -> [PhaseGate]
humanGates document =
  L.sortOn
    (\g -> (gateDependent g, gatePrerequisite g))
    [ PhaseGate (edgeDependent e) (edgePrerequisite e) (unitPhase prerequisite) (unitPhase dependent)
    | e <- planEdges document
    , edgeKind e == HumanAcceptance
    , Just dependent <- [unitOf (edgeDependent e)]
    , Just prerequisite <- [unitOf (edgePrerequisite e)]
    , unitPhase dependent /= unitPhase prerequisite
    ]
 where
  unitOf key =
    L.find ((== key) . unitKey) (planUnits document)

{- | The gates of the old plan the new one does not keep: its edge dropped or
made technical, one of its units withdrawn, or its units no longer in
different phases.
-}
gatesRemoved :: PlanDocument -> PlanDocument -> [PhaseGate]
gatesRemoved old new =
  [g | g <- humanGates old, not (L.any (same g) (humanGates new))]
 where
  same a b =
    gateDependent a == gateDependent b && gatePrerequisite a == gatePrerequisite b
