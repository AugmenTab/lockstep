{- | Work Unit identity admission (contract C-P2.1 I7, FR-WRK-01). A Work Unit
originates from a Ticket and belongs to an owned repository; a plan reference
is optional ancestry and never part of its required identity. State
transitions arrive in P2.2.
-}
module Lockstep.Kernel.WorkUnit
  ( PlanRef
  , mkPlanRef
  , planRefText
  , WorkUnitRequest (..)
  , AdmittedWorkUnit (..)
  , WorkUnitRefusal (..)
  , admitWorkUnit
  ) where

import Data.Char qualified as Char
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Identity (EngineerId, RepositoryId, TicketId, WorkOrderId, WorkUnitId)
import Lockstep.Kernel.Repository (Ownership (..))

newtype PlanRef
  = PlanRef T.Text
  deriving (Eq, Show)

-- | 1–200 characters, no control characters.
mkPlanRef :: T.Text -> Maybe PlanRef
mkPlanRef text =
  if T.null text || T.length text > 200 || T.any Char.isControl text
    then Nothing
    else Just (PlanRef text)

planRefText :: PlanRef -> T.Text
planRefText (PlanRef text) =
  text

data WorkUnitRequest
  = WorkUnitRequest
  { wuId :: WorkUnitId
  , wuRepository :: RepositoryId
  , wuTicket :: TicketId
  , wuWorkOrder :: WorkOrderId
  , wuPlanRef :: Maybe PlanRef
  }
  deriving (Eq, Show)

data AdmittedWorkUnit
  = AdmittedWorkUnit
  { admittedRequest :: WorkUnitRequest
  , admittedEngineer :: EngineerId
  }
  deriving (Eq, Show)

newtype WorkUnitRefusal
  = WorkUnitRepositoryNotOwned RepositoryId
  deriving (Eq, Show)

admitWorkUnit :: [Ownership] -> WorkUnitRequest -> Either WorkUnitRefusal AdmittedWorkUnit
admitWorkUnit ownerships request =
  case L.find ((== wuRepository request) . ownershipRepository) ownerships of
    Just ownership -> Right (AdmittedWorkUnit request (ownershipEngineer ownership))
    Nothing -> Left (WorkUnitRepositoryNotOwned (wuRepository request))
