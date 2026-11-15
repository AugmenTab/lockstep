{- | The deterministic dispatcher (contract C-P6.5): for each project with an
owner-approved effective plan, the pure 'dispatchDecision' over the durable
facts, then the existing hand-over of the chosen unit ('admitTask'), guarded so
that a revision replaced in between is refused. No model, no queue, nothing in
memory: the engine worker runs it before it starts and advances fixes.
-}
module Lockstep.Application.Dispatch
  ( DispatchReport (..)
  , DispatchView (..)
  , dispatchOnce
  , dispatchView
  , handOverUnit
  ) where

import Data.List qualified as L
import Data.Maybe (catMaybes, isJust, listToMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Text.Show (Show)

import Lockstep.Application.Command (idempotencyKeyText, mkIdempotencyKey)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason, Readiness (..), checkReadiness, withDatabase)
import Lockstep.Application.Execution (Admission (..), AdmitOptions (..), admitTask)
import Lockstep.Application.PlanDocument (decodePlanDocumentText)
import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Application.Projects (ProjectFolders)
import Lockstep.Application.Tasks (TaskView (..), findTaskIn, fixFactOf)
import Lockstep.Kernel.Dispatch (BudgetFact (..), DispatchDecision (..), FixFact (..), ProjectFacts (..), UnitFacts (..), dispatchDecision, waitReasonCode, waitReasonWords)
import Lockstep.Kernel.Identity (ProjectId (..), TaskId (..), identityText, parseIdentity)
import Lockstep.Kernel.Plan (EffectClass (..), Envelope (..), PlanDocument (..), PlanUnit (..), mkUnitKey, unitKeyText)
import Lockstep.Kernel.Profile (Hasher (..), contentDigestText)
import Lockstep.Persistence.Dispatch qualified as Dispatches
import Lockstep.Persistence.Execution qualified as Execution
import Lockstep.Persistence.Integrity (integrityViolation)
import Lockstep.Persistence.Plans qualified as Plans

data DispatchReport
  = DispatchReport
  { reportProject :: T.Text
  , reportUnit :: T.Text
  , reportResult :: Either T.Text T.Text
  -- ^ The new Work Order, or why the hand-over was refused.
  }
  deriving (Eq, Show)

data DispatchView
  = DispatchView
  { dispatchViewNext :: Maybe T.Text
  , dispatchViewWaiting :: [(T.Text, T.Text)]
  -- ^ Each other unit's key and waiting reason code, in the plan's order.
  , dispatchViewWords :: [(T.Text, T.Text)]
  -- ^ The same units' keys and their reasons in words.
  }
  deriving (Eq, Show)

whenReady :: DatabaseRuntime -> IO (Either NotReadyReason a) -> IO (Either NotReadyReason a)
whenReady runtime action = do
  readiness <- checkReadiness (Just runtime)
  case readiness of
    NotReady reason -> pure (Left reason)
    Ready _ -> action

sha :: T.Text -> T.Text
sha text =
  case sha256Hasher of
    Hasher f -> contentDigestText (f text)

-- | The effective revision and the decision over it, read in one transaction.
data Facts
  = Facts
  { factsRevision :: Plans.RevisionRow
  , factsDecision :: DispatchDecision
  }

decideIn :: ProjectId -> O.Orville (Maybe Facts)
decideIn project = do
  effective <- Plans.effectiveRevision project
  case effective of
    Nothing -> pure Nothing
    Just revision -> do
      document <- either (const (integrityViolation "a stored plan revision does not decode")) pure (decodePlanDocumentText (Plans.revisionRowDocument revision))
      units <- Plans.revisionUnits (Plans.revisionRowId revision)
      enablement <- Execution.findEnablementByProject project
      admissions <- Execution.projectAdmissions project
      writers <- catMaybes <$> traverse busyWriter admissions
      facts <- catMaybes <$> traverse (unitFacts document) units
      let
        projectFacts =
          ProjectFacts
            { projectEnabled = isJust enablement
            , projectWriter = listToMaybe writers
            , -- Lockstep records no usage yet: a plan with a budget has unknown usage, never "available".
              projectBudget = maybe NoBudget (const UsageUnknown) (envelopeTokenBudget (planEnvelope document))
            }
      pure (Just (Facts revision (dispatchDecision projectFacts facts)))
 where
  -- S2: the title of a handed-over task whose fix holds the repository's one writer.
  busyWriter admission = do
    fix <- fixFactOf (Execution.admissionRowTask admission)
    case fix of
      FixUnderWay -> fmap (either (const T.empty) taskTitle) <$> findTaskIn (Execution.admissionRowTask admission)
      _ -> pure Nothing
  unitFacts document u = do
    found <- findTaskIn (Plans.unitRowTask u)
    admission <- Execution.findAdmissionByTask (Plans.unitRowTask u)
    fix <- fixFactOf (Plans.unitRowTask u)
    let
      planUnit = L.find ((== Plans.unitRowKey u) . unitKeyText . unitKey) (planUnits document)
    pure $
      case (found, mkUnitKey (Plans.unitRowKey u), planUnit) of
        (Just (Right task), Just key, Just p) ->
          Just
            UnitFacts
              { unitFactKey = key
              , unitFactTitle = taskTitle task
              , unitFactPriority = fromIntegral (Plans.unitRowPriority u)
              , unitFactOrdinal = fromIntegral (Plans.unitRowOrdinal u)
              , unitFactReadiness = taskReadinessOf task
              , unitFactHandedOver = fix <$ admission
              , unitFactLocal = unitEffect p == LocalOnly
              }
        -- A unit whose task does not replay, or that its stored document lacks, is never handed over.
        _ -> Nothing

-- | One pass (S5): for each project with an effective plan, hand over its next unit, if any.
dispatchOnce :: DatabaseRuntime -> ProjectFolders -> IO (Either NotReadyReason [DispatchReport])
dispatchOnce runtime folders =
  whenReady runtime $ do
    plans <- withDatabase runtime Plans.allPlans
    case plans of
      Left reason -> pure (Left reason)
      Right ps -> fmap (fmap catMaybes . sequenceA) (traverse (one . Plans.planRowProject) ps)
 where
  one project = do
    decided <- withDatabase runtime (decideIn project)
    case decided of
      Left reason -> pure (Left reason)
      Right Nothing -> pure (Right Nothing)
      Right (Just facts) ->
        case decisionNext (factsDecision facts) of
          Nothing -> pure (Right Nothing)
          Just key -> do
            handed <- handOver runtime folders project (Plans.revisionRowDigest (factsRevision facts)) (unitKeyText key)
            pure $
              case handed of
                Left reason -> Left reason
                -- Another dispatcher handed it over first: not reported twice.
                Right (Right (_, False)) -> Right Nothing
                Right (Right (workOrder, True)) -> Right (Just (DispatchReport (identityText project) (unitKeyText key) (Right workOrder)))
                Right (Left code) -> Right (Just (DispatchReport (identityText project) (unitKeyText key) (Left code)))

{- | S4: hands over one unit of the revision with this digest, which must still
be the project's effective revision inside the hand-over's transaction (else
@stale-plan-revision@, nothing written). The new Work Order.
-}
handOverUnit :: DatabaseRuntime -> ProjectFolders -> T.Text -> T.Text -> T.Text -> IO (Either NotReadyReason (Either T.Text T.Text))
handOverUnit runtime folders rawProject digest unit =
  case parseIdentity rawProject of
    Nothing -> whenReady runtime (pure (Right (Left (T.pack "unknown-project"))))
    Just project -> fmap (fmap fst) <$> handOver runtime folders project digest unit

handOver :: DatabaseRuntime -> ProjectFolders -> ProjectId -> T.Text -> T.Text -> IO (Either NotReadyReason (Either T.Text (T.Text, Bool)))
handOver runtime folders project digest unit =
  whenReady runtime $ do
    -- The unit's task and its Ticket revision; the guard reads the effective revision again under the task lock.
    found <-
      withDatabase runtime $ do
        effective <- Plans.effectiveRevision project
        units <- maybe (pure []) (Plans.revisionUnits . Plans.revisionRowId) effective
        case L.find ((== unit) . Plans.unitRowKey) units of
          Nothing -> pure Nothing
          Just u -> fmap (\t -> (u, t)) <$> findTaskIn (Plans.unitRowTask u)
    case (found, mkIdempotencyKey (T.pack "plan-" <> T.take 40 (sha (identityText project <> T.pack "\n" <> digest <> T.pack "\n" <> unit)))) of
      (Left reason, _) -> pure (Left reason)
      (_, Left _) -> pure (Right (Left (T.pack "invalid-key")))
      (Right Nothing, _) -> pure (Right (Left (T.pack "stale-plan-revision")))
      (Right (Just (_, Left code)), _) -> pure (Right (Left code))
      (Right (Just (u, Right task)), Right key) -> do
        let
          stillEffective = do
            effective <- Plans.effectiveRevision project
            pure $
              case effective of
                Just r | Plans.revisionRowDigest r == digest -> Right ()
                _ -> Left (T.pack "stale-plan-revision")
          recordDispatch workOrder =
            Dispatches.insertDispatch (Dispatches.DispatchRow (Plans.unitRowRevision u) unit (Plans.unitRowTask u) workOrder (idempotencyKeyText key))
        result <-
          admitTask
            runtime
            folders
            AdmitOptions {admitActor = T.pack "scheduler", admitGuard = stillEffective, admitAfter = recordDispatch}
            key
            (identityText (Plans.unitRowTask u))
            (taskTicketRevision task)
        pure (fmap (fmap (\(a, fresh) -> (admissionWorkOrder a, fresh))) result)

-- | S7: the effective revision's next unit and each other unit's waiting reason.
dispatchView :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Either T.Text DispatchView))
dispatchView runtime rawProject =
  whenReady runtime $
    case parseIdentity rawProject of
      Nothing -> pure (Right (Left (T.pack "unknown-project")))
      Just project -> do
        decided <- withDatabase runtime (decideIn project)
        pure $
          fmap
            ( maybe
                (Left (T.pack "no-effective-plan"))
                ( \facts ->
                    Right
                      DispatchView
                        { dispatchViewNext = unitKeyText <$> decisionNext (factsDecision facts)
                        , dispatchViewWaiting = [(unitKeyText k, waitReasonCode r) | (k, r) <- decisionWaiting (factsDecision facts)]
                        , dispatchViewWords = [(unitKeyText k, waitReasonWords r) | (k, r) <- decisionWaiting (factsDecision facts)]
                        }
                )
            )
            decided
