{- | Update 2 R6.4: the effective checks a handed-over task's latest fix runs
under, as they are: the Profile its Work Order is bound to (the repository's,
at that version — a version added later does not change it), the kind of work,
each floor check of the kind and how the bound checks hold it (as required, or
more strongly), the approved exceptions (none can lower a floor), whether the
work is non-behavioural, and the correction and attempt budgets. Reads only.
-}
module Lockstep.Application.EffectiveChecks
  ( EffectiveChecks (..)
  , effectiveChecksOf
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason, Readiness (..), checkReadiness, withDatabase)
import Lockstep.Application.Execution (kindGates)
import Lockstep.Application.Profiles (storedDefinition)
import Lockstep.Kernel.Identity (TaskId (..), parseIdentity)
import Lockstep.Kernel.Plan (workKindCode)
import Lockstep.Kernel.Profile (LayerLevel (LayerRepositoryDefault), profileIdText)
import Lockstep.Kernel.WorkPolicy (WorkPolicy (..), floorStandings, workPolicy)
import Lockstep.Persistence.Execution qualified as Execution
import Lockstep.Persistence.Ledger qualified as Ledger
import Lockstep.Persistence.Profiles qualified as Profiles

data EffectiveChecks
  = EffectiveChecks
  { checksProfile :: T.Text
  , checksVersion :: Int
  , checksKind :: T.Text
  , checksFloor :: [(T.Text, T.Text)]
  -- ^ Each floor check of the kind and how the bound checks hold it.
  , checksExceptions :: [T.Text]
  , checksCorrections :: Int
  , checksAttempts :: Int
  , checksNonBehavioural :: Bool
  }
  deriving (Eq, Show)

whenReady :: DatabaseRuntime -> IO (Either NotReadyReason a) -> IO (Either NotReadyReason a)
whenReady runtime action = do
  readiness <- checkReadiness (Just runtime)
  case readiness of
    NotReady reason -> pure (Left reason)
    Ready _ -> action

{- | The task's effective checks; Nothing before it is handed over. A bound
Profile that no longer resolves for the kind shows every floor check as
@missing@: it is never shown as held.
-}
effectiveChecksOf :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Maybe EffectiveChecks))
effectiveChecksOf runtime rawId =
  whenReady runtime $
    case parseIdentity rawId of
      Nothing -> pure (Right Nothing)
      Just tid ->
        withDatabase runtime $ do
          admission <- Execution.findAdmissionByTask tid
          case admission of
            Nothing -> pure Nothing
            Just a -> do
              sources <- Ledger.sourcesOf (Execution.admissionRowWorkOrder a)
              case L.find ((== LayerRepositoryDefault) . Ledger.sourceRowLevel) sources of
                Nothing -> pure Nothing
                Just source -> do
                  row <- Profiles.findProfile (Ledger.sourceRowProfile source) (Just (Ledger.sourceRowVersion source))
                  definition <- traverse storedDefinition row
                  catalog <- Profiles.latestProfiles >>= traverse storedDefinition
                  let
                    kind = Execution.admissionRowWorkKind a
                    policy = workPolicy kind
                    gates = fromRight [] (maybe (Left T.empty) (\d -> kindGates kind d catalog) definition)
                  pure . Just $
                    EffectiveChecks
                      { checksProfile = profileIdText (Ledger.sourceRowProfile source)
                      , checksVersion = fromIntegral (Ledger.sourceRowVersion source)
                      , checksKind = workKindCode kind
                      , checksFloor = floorStandings kind gates
                      , -- Lockstep stores no gate exception for a Work Order (no table holds one), so none applies or is
                        -- shown; a floor check is never excepted (C-P6.6 G2).
                        checksExceptions = []
                      , checksCorrections = policyCorrections policy
                      , checksAttempts = policyAttempts policy
                      , checksNonBehavioural = policyNonBehavioural policy
                      }
