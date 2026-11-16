{- | Update 2, DG-08 local Phase signoff. Stub. -}
module Lockstep.Kernel.PhaseGate
  ( PhaseGate (..)
  , humanGates
  , gatesRemoved
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Plan (PlanDocument, UnitKey)

-- | A human gate: the dependent (of a later phase) starts only after the person's acceptance of the prerequisite.
data PhaseGate
  = PhaseGate
  { gateDependent :: UnitKey
  , gatePrerequisite :: UnitKey
  , gateFromPhase :: T.Text
  , gateToPhase :: T.Text
  }
  deriving (Eq, Show)

-- | Stub.
humanGates :: PlanDocument -> [PhaseGate]
humanGates _ =
  []

-- | Stub.
gatesRemoved :: PlanDocument -> PlanDocument -> [PhaseGate]
gatesRemoved _ _ =
  []
