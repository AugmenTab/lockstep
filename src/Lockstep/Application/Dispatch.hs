{- | The deterministic dispatcher (contract C-P6.5): for each project with an
owner-approved effective plan, the pure 'dispatchDecision' over the durable
facts, then the existing hand-over of the chosen unit ('admitTask'). Inside the
hand-over's transaction, under the task lock, the decision is made again and
must still choose that unit of that revision (R-P6.5-3), so a revision replaced
or a writer taken in between is refused. No model, no queue, nothing in memory:
the engine worker runs it before it starts and advances fixes.
-}
module Lockstep.Application.Dispatch
  ( DispatchReport (..)
  , DispatchView (..)
  , dispatchOnce
  , dispatchView
  , handOverUnit
  ) where

import Data.Bifunctor (second)
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
import Lockstep.Kernel.Dispatch
  ( BudgetFact (..)
  , DispatchDecision (..)
  , FixFact (..)
  , ProjectFacts (..)
  , UnitFacts (..)
  , WaitReason (RefusedHandOver)
  , dispatchDecision
  , waitReasonCode
  , waitReasonWords
  )
import Lockstep.Kernel.Identity (PlanRevisionId (..), ProjectId (..), TaskId (..), identityText, parseIdentity)
import Lockstep.Kernel.Plan (EffectClass (..), Envelope (..), PlanDocument (..), PlanUnit (..), mkUnitKey, parseWorkKind, unitKeyText)
import Lockstep.Kernel.Profile (Hasher (..), contentDigestText)
import Lockstep.Kernel.Task (TaskReadiness (StateUnrecognised))
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
  , dispatchViewRefusal :: Maybe (T.Text, T.Text)
  -- ^ The next unit whose last hand-over was refused, and the refusal's code (R-P6.6-8: the page's offer reads it).
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

-- | The effective revision, its units' facts and the decision over them.
data Facts
  = Facts
  { factsRevision :: Plans.RevisionRow
  , factsUnits :: [UnitFacts]
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
      pure (Just (Facts revision facts (dispatchDecision projectFacts facts)))
 where
  -- S2: the title of a handed-over task whose fix holds the repository's one writer (R-P6.5-8: else its identity).
  busyWriter admission = do
    let
      task = Execution.admissionRowTask admission
    fix <- fixFactOf task
    case fix of
      FixUnderWay -> Just . maybe (identityText task) (either (const (identityText task)) taskTitle) <$> findTaskIn task
      _ -> pure Nothing
  unitFacts document u = do
    found <- findTaskIn (Plans.unitRowTask u)
    fix <- fixFactOf (Plans.unitRowTask u)
    let
      planUnit = L.find ((== Plans.unitRowKey u) . unitKeyText . unitKey) (planUnits document)
      -- R-P6.5-7: a unit whose task does not replay, or that its stored document lacks, is shown as unknown, never handed over.
      (title, readiness) =
        case (found, planUnit) of
          (Just (Right task), Just _) -> (taskTitle task, taskReadinessOf task)
          (Just (Left code), _) -> (Plans.unitRowKey u, StateUnrecognised code)
          (Nothing, _) -> (Plans.unitRowKey u, StateUnrecognised (T.pack "task-missing"))
          (_, Nothing) -> (Plans.unitRowKey u, StateUnrecognised (T.pack "unit-missing"))
    pure $
      fmap
        ( \key ->
            UnitFacts
              { unitFactKey = key
              , unitFactTitle = title
              , unitFactPriority = fromIntegral (Plans.unitRowPriority u)
              , unitFactOrdinal = fromIntegral (Plans.unitRowOrdinal u)
              , unitFactReadiness = readiness
              , -- R-P6.5-12: a fix exists exactly when the task was handed over.
                unitFactHandedOver = if fix == NoFix then Nothing else Just fix
              , unitFactLocal = maybe False ((== LocalOnly) . unitEffect) planUnit
              }
        )
        (mkUnitKey (Plans.unitRowKey u))

-- | Codes of a refusal that is a race with another dispatcher or an approval, not a reason the unit waits.
transient :: T.Text -> Bool
transient code =
  code `L.elem` fmap T.pack ["not-next", "stale-plan-revision", "stale-revision"]

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
    decided <- withDatabase runtime (O.withTransaction (decideIn project))
    case decided of
      Left reason -> pure (Left reason)
      Right Nothing -> pure (Right Nothing)
      Right (Just facts) ->
        case decisionNext (factsDecision facts) of
          Nothing -> pure (Right Nothing)
          Just key -> do
            let
              unit = unitKeyText key
              revision = factsRevision facts
              report = DispatchReport (identityText project) unit
            handed <- handOver runtime folders project (Plans.revisionRowDigest revision) unit
            case handed of
              Left reason -> pure (Left reason)
              -- Another dispatcher handed it over first: not reported twice.
              Right (Right (_, False)) -> pure (Right Nothing)
              Right (Right (workOrder, True)) -> pure (Right (Just (report (Right workOrder))))
              Right (Left code)
                | transient code -> pure (Right Nothing)
                | otherwise -> do
                    -- R-P6.5-6: recorded, reported and logged once; tried again on each pass.
                    fresh <- withDatabase runtime (recordRefusal (Plans.revisionRowId revision) unit code)
                    -- A refused hand-over that is not the last one recorded is new: reported (and so logged) once.
                    pure (fmap (\new -> if new then Just (report (Left code)) else Nothing) fresh)

{- | Records a refusal unless it is the last one recorded for the unit of the
revision; whether it was recorded. Serialized by the plan lock, so two
dispatchers record it once.
-}
recordRefusal :: PlanRevisionId -> T.Text -> T.Text -> O.Orville Bool
recordRefusal revision unit code =
  O.withTransaction $ do
    Plans.lockPlans
    latest <- Dispatches.latestRefusal revision unit
    if fmap Dispatches.refusalCode latest == Just code
      then pure False
      else do
        Dispatches.insertRefusal (Dispatches.RefusalRow revision unit (T.take 200 code))
        pure True

{- | S4: hands over one unit of the revision with this digest. Inside the
hand-over's transaction that revision must still be the project's effective
one (else @stale-plan-revision@) and the decision made again must choose this
unit (else @not-next@, R-P6.5-3, R-P6.5-4); either refusal writes nothing. The
new Work Order.
-}
handOverUnit :: DatabaseRuntime -> ProjectFolders -> T.Text -> T.Text -> T.Text -> IO (Either NotReadyReason (Either T.Text T.Text))
handOverUnit runtime folders rawProject digest unit =
  case parseIdentity rawProject of
    Nothing -> whenReady runtime (pure (Right (Left (T.pack "unknown-project"))))
    Just project -> fmap (fmap fst) <$> handOver runtime folders project digest unit

handOver :: DatabaseRuntime -> ProjectFolders -> ProjectId -> T.Text -> T.Text -> IO (Either NotReadyReason (Either T.Text (T.Text, Bool)))
handOver runtime folders project digest unit =
  whenReady runtime $ do
    -- The unit's task and its Ticket revision in the revision with this digest; the guard reads it all again under the task lock.
    found <-
      withDatabase runtime $ do
        effective <- Plans.effectiveRevision project
        case effective of
          Just r | Plans.revisionRowDigest r == digest -> do
            units <- Plans.revisionUnits (Plans.revisionRowId r)
            case L.find ((== unit) . Plans.unitRowKey) units of
              Nothing -> pure (Left (T.pack "unknown-unit"))
              Just u -> maybe (Left (T.pack "unknown-unit")) (\t -> Right (r, u, t)) <$> findTaskIn (Plans.unitRowTask u)
          _ -> pure (Left (T.pack "stale-plan-revision"))
    case found of
      Left reason -> pure (Left reason)
      Right (Left code) -> pure (Right (Left code))
      Right (Right (_, _, Left code)) -> pure (Right (Left code))
      Right (Right (revision, u, Right task)) ->
        -- R-P6.5-11: the key is fixed by the revision's identity (a digest may come back in a later revision) and the unit.
        case (mkIdempotencyKey (T.pack "plan-" <> T.take 40 (sha (identityText project <> T.pack "\n" <> identityText (Plans.revisionRowId revision) <> T.pack "\n" <> unit))), parseWorkKind (Plans.unitRowWorkKind u)) of
          (Left _, _) -> pure (Right (Left (T.pack "invalid-key")))
          (_, Nothing) -> pure (Right (Left (T.pack "unknown-work-kind")))
          (Right key, Just kind) -> do
            let
              stillNext = do
                decided <- decideIn project
                pure $
                  case decided of
                    Just facts
                      | Plans.revisionRowId (factsRevision facts) /= Plans.revisionRowId revision -> Left (T.pack "stale-plan-revision")
                      | fmap unitKeyText (decisionNext (factsDecision facts)) == Just unit -> Right ()
                      | otherwise -> Left (T.pack "not-next")
                    Nothing -> Left (T.pack "stale-plan-revision")
              recordDispatch workOrder =
                Dispatches.insertDispatch (Dispatches.DispatchRow (Plans.unitRowRevision u) unit (Plans.unitRowTask u) workOrder (idempotencyKeyText key))
            result <-
              admitTask
                runtime
                folders
                AdmitOptions
                  { admitActor = T.pack "scheduler"
                  , admitGuard = stillNext
                  , admitAfter = recordDispatch
                  , -- C-P6.6 G4: the unit's kind and the Profile it names.
                    admitKind = kind
                  , admitProfile = Just (Plans.unitRowProfile u)
                  }
                key
                (identityText (Plans.unitRowTask u))
                (taskTicketRevision task)
            pure (fmap (fmap (\(a, fresh) -> (admissionWorkOrder a, fresh))) result)

{- | S7: the effective revision's next unit and each other unit's waiting
reason. R-P6.5-6: a next unit whose last hand-over was refused is shown as
refused, not as next, until it is handed over.
-}
dispatchView :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Either T.Text DispatchView))
dispatchView runtime rawProject =
  whenReady runtime $
    case parseIdentity rawProject of
      Nothing -> pure (Right (Left (T.pack "unknown-project")))
      Just project ->
        withDatabase runtime . O.withTransaction $ do
          decided <- decideIn project
          case decided of
            Nothing -> pure (Left (T.pack "no-effective-plan"))
            Just facts -> do
              let
                decision = factsDecision facts
              refusal <-
                case decisionNext decision of
                  Nothing -> pure Nothing
                  Just k -> fmap (\r -> (k, Dispatches.refusalCode r)) <$> Dispatches.latestRefusal (Plans.revisionRowId (factsRevision facts)) (unitKeyText k)
              let
                refused = fmap (second RefusedHandOver) refusal
                ordinal k = maybe 0 unitFactOrdinal (L.find ((== k) . unitFactKey) (factsUnits facts))
                waiting = L.sortOn (\(k, _) -> (ordinal k, k)) (maybe [] pure refused <> decisionWaiting decision)
              pure $
                Right
                  DispatchView
                    { dispatchViewNext = if isJust refused then Nothing else unitKeyText <$> decisionNext decision
                    , dispatchViewWaiting = [(unitKeyText k, waitReasonCode r) | (k, r) <- waiting]
                    , dispatchViewWords = [(unitKeyText k, waitReasonWords r) | (k, r) <- waiting]
                    , dispatchViewRefusal = fmap (\(k, code) -> (unitKeyText k, code)) refusal
                    }
