{- | Update 2, DG-08 local Phase signoff: the human gates of a project's
effective plan ('Lockstep.Kernel.PhaseGate.humanGates') and where each
stands: @signed-off@ once the person accepted the gate's prerequisite (its fix
is Done, or its Ticket is), @waiting-for-signoff@ otherwise. Automatic
scheduling never passes a gate by itself (C-P6.5 S1). Reads only.
-}
module Lockstep.Application.PhaseGates
  ( phaseGatesOf
  ) where

import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude

import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason, Readiness (..), checkReadiness, withDatabase)
import Lockstep.Application.PlanDocument (decodePlanDocumentText)
import Lockstep.Application.Tasks (TaskView (..), findTaskIn, fixFactOf)
import Lockstep.Kernel.Dispatch (FixFact (FixDone))
import Lockstep.Kernel.Identity (ProjectId (..), parseIdentity)
import Lockstep.Kernel.PhaseGate (PhaseGate (..), humanGates)
import Lockstep.Kernel.Plan (unitKeyText)
import Lockstep.Persistence.Plans qualified as Plans

whenReady :: DatabaseRuntime -> IO (Either NotReadyReason a) -> IO (Either NotReadyReason a)
whenReady runtime action = do
  readiness <- checkReadiness (Just runtime)
  case readiness of
    NotReady reason -> pure (Left reason)
    Ready _ -> action

-- | Each gate of the effective plan: its dependent unit, its prerequisite unit, and where it stands.
phaseGatesOf :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Either T.Text [(T.Text, T.Text, T.Text)]))
phaseGatesOf runtime rawProject =
  whenReady runtime $
    case parseIdentity rawProject of
      Nothing -> pure (Right (Left (T.pack "unknown-project")))
      Just project ->
        withDatabase runtime $ do
          effective <- Plans.effectiveRevision project
          case effective of
            Nothing -> pure (Left (T.pack "no-effective-plan"))
            Just revision ->
              case decodePlanDocumentText (Plans.revisionRowDocument revision) of
                Left _ -> pure (Left (T.pack "plan-unreadable"))
                Right document -> do
                  units <- Plans.revisionUnits (Plans.revisionRowId revision)
                  Right <$> traverse (standing units) (humanGates document)
 where
  standing units gate = do
    let
      prerequisite = unitKeyText (gatePrerequisite gate)
    signed <-
      case L.find ((== prerequisite) . Plans.unitRowKey) units of
        Nothing -> pure False
        Just u -> do
          fix <- fixFactOf (Plans.unitRowTask u)
          task <- findTaskIn (Plans.unitRowTask u)
          pure (fix == FixDone || either (const False) ((== T.pack "done") . taskState) (fromMaybe (Left T.empty) task))
    pure (unitKeyText (gateDependent gate), prerequisite, T.pack (if signed then "signed-off" else "waiting-for-signoff"))
