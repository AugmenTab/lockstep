{- | Master Plans (contract C-P6.4): proposals by a person or the Planner,
the owner's digest-bound decision, the units of an approved revision as
canonical tasks, reconciliation with the previous effective revision, and the
Planner's bounded drafts from a PRD. A proposal is never authority.
-}
module Lockstep.Application.Plans
  ( ProposalRefusal (..)
  , RevisionView (..)
  , PlanView (..)
  , DraftView (..)
  , PlanDecision (..)
  , DraftOutcome (..)
  , DraftReport (..)
  , proposePlan
  , proposePlanFile
  , decidePlan
  , planView
  , requestDraft
  , requestDraftFiles
  , draftPlans
  , draftPlansUntil
  , draftOutcomeCode
  , knownProfiles
  ) where

import Control.Exception.Safe (finally, tryIO)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Maybe (catMaybes, fromMaybe, isJust, isNothing, listToMaybe, mapMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Fleece.Core ((#+))
import Fleece.Core qualified as FC
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import System.IO (FilePath)
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, idempotencyKeyText)
import Lockstep.Application.Database (DatabaseRuntime, LockFailure (..), NotReadyReason, Readiness (..), SessionLock (PlanDraftLock), checkReadiness, withDatabase, withSessionLock)
import Lockstep.Application.Engine (Engine (..))
import Lockstep.Application.Identity (newUuid)
import Lockstep.Application.Invalidations (planChangedIn)
import Lockstep.Application.Ledger (createTicketIn, decideTicketIn, reviseTicketIn, ticketFactsIn)
import Lockstep.Application.LedgerRefusal (LedgerError (..), ledgerRefusalCode)
import Lockstep.Application.PlanDocument (decodePlanDocument, decodePlanDocumentText, encodePlanDocument, planDocumentErrorCode)
import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Application.Tasks (requestDigest)
import Lockstep.Effects.Roles (RoleOutcome (..), Runner (..), invokeRole)
import Lockstep.Foundation.Fleece (encodeText)
import Lockstep.Kernel.Identity (PlanDraftId (..), PlanId (..), PlanRevisionId (..), ProjectId (..), TaskId (..), TicketId (..), TransactionId, Uuid, identityText, parseIdentity)
import Lockstep.Kernel.PhaseGate (gatesRemoved)
import Lockstep.Kernel.Plan
  ( PlanContext (..)
  , PlanCriterion (..)
  , PlanDocument (..)
  , PlanEdge (..)
  , PlanSource (..)
  , PlanUnit (..)
  , UnitKey
  , edgeKindCode
  , planDigestText
  , planProblemText
  , reconcilePlan
  , unitDigestText
  , unitKeyText
  , unitOutcomeCode
  , validatePlan
  )
import Lockstep.Kernel.Profile (Hasher (..), contentDigestText, profileIdText)
import Lockstep.Kernel.Roles (PlanDraft (..), Role (Planner), RoleAnswer (..))
import Lockstep.Kernel.Task (mkAcceptance, mkTaskTitle, priorityOf, priorityValue)
import Lockstep.Kernel.Ticket (TicketInput (TicketAccept, TicketBlock, TicketUnblock))
import Lockstep.Kernel.Transaction (TxState (..))
import Lockstep.Kernel.Transition (Command (..), Principal (Human))
import Lockstep.Persistence.Execution qualified as Execution
import Lockstep.Persistence.Integrity (integrityViolation)
import Lockstep.Persistence.Plans qualified as Store
import Lockstep.Persistence.Profiles qualified as Profiles
import Lockstep.Persistence.Projects qualified as Projects
import Lockstep.Persistence.Tasks qualified as Tasks
import Lockstep.Persistence.Transactions qualified as Transactions

-- | A refused proposal: its code and, for an invalid plan, each problem in words.
data ProposalRefusal
  = ProposalRefusal
  { proposalRefusalCode :: T.Text
  , proposalRefusalProblems :: [T.Text]
  }
  deriving (Eq, Show)

data RevisionView
  = RevisionView
  { revisionNumber :: Int
  , revisionDigest :: T.Text
  , revisionState :: T.Text
  -- ^ @proposed@, @approved@, @rejected@ or @superseded@ (approved, then replaced by a newer approval).
  , revisionProposedBy :: T.Text
  -- ^ @Human@ or @Planner@.
  , revisionProposer :: T.Text
  , revisionDecidedBy :: Maybe T.Text
  , revisionDocument :: PlanDocument
  , revisionReconciliation :: [(T.Text, T.Text)]
  -- ^ Each unit's key and outcome, once approved.
  , revisionTasks :: [(T.Text, T.Text)]
  -- ^ Each unit's key and task, once approved.
  }
  deriving (Eq, Show)

data DraftView
  = DraftView
  { draftId :: T.Text
  , draftPrdDigest :: T.Text
  , draftArchitectureDigest :: Maybe T.Text
  , draftOutcome :: Maybe T.Text
  , draftCode :: Maybe T.Text
  }
  deriving (Eq, Show)

data PlanView
  = PlanView
  { planViewRevisions :: [RevisionView]
  -- ^ Newest first.
  , planViewEffective :: Maybe RevisionView
  , planViewDrafts :: [DraftView]
  -- ^ In request order.
  }
  deriving (Eq, Show)

data PlanDecision
  = ApprovePlan
  | RejectPlan
  deriving (Eq, Show)

data DraftOutcome
  = DraftProposed Int
  | DraftRefused [T.Text]
  | DraftFailed T.Text
  | DraftNoHelper
  | DraftUncertain
  deriving (Eq, Show)

data DraftReport
  = DraftReport
  { reportDraft :: T.Text
  , reportOutcome :: DraftOutcome
  }
  deriving (Eq, Show)

-- | The outcome's word in the worker's pass report.
draftOutcomeCode :: DraftOutcome -> T.Text
draftOutcomeCode o =
  case o of
    DraftProposed n -> T.pack "proposed revision " <> T.pack (show n)
    DraftRefused problems -> T.pack "refused " <> T.intercalate (T.pack "; ") problems
    DraftFailed code -> T.pack "failed " <> code
    DraftNoHelper -> T.pack "no-helper"
    DraftUncertain -> T.pack "uncertain"

-- Helpers ---------------------------------------------------------------------------

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

refusal :: String -> Either ProposalRefusal a
refusal code =
  Left (ProposalRefusal (T.pack code) [])

refuse :: String -> Either T.Text a
refuse =
  Left . T.pack

-- | A Ledger step inside a decision: a refusal is its code; stored state that does not replay aborts.
ledgerStep :: Either LedgerError a -> O.Orville (Either T.Text a)
ledgerStep result =
  case result of
    Right value -> pure (Right value)
    Left (LedgerRefusedBy r) -> pure (Left (ledgerRefusalCode r))
    Left (LedgerCorrupt message) -> integrityViolation (T.unpack message)

{- | The Profiles a plan may name: Lockstep's own and every Profile in the
catalog. P6.6 binds each work kind to its checks.
-}
knownProfiles :: O.Orville [T.Text]
knownProfiles = do
  rows <- Profiles.allProfiles
  pure (L.nub ([T.pack "lockstep-bug-fix", T.pack "lockstep-basic", T.pack "lockstep-engineering"] <> fmap (profileIdText . Profiles.profileRowId) rows))

-- Proposals -------------------------------------------------------------------------

data Proposer
  = ByHuman T.Text
  | ByPlanner PlanDraftId

-- | A person's proposal (M4): the document's bytes into the project's plan.
proposePlan :: DatabaseRuntime -> IdempotencyKey -> T.Text -> T.Text -> LBS.ByteString -> IO (Either NotReadyReason (Either ProposalRefusal RevisionView))
proposePlan runtime key rawProject actor bytes =
  case (parseIdentity rawProject, decodePlanDocument bytes) of
    (Nothing, _) -> whenReady runtime (pure (Right (refusal "unknown-project")))
    (_, Left e) -> whenReady runtime (pure (Right (Left (ProposalRefusal (planDocumentErrorCode e) []))))
    (Just project, Right document)
      | T.null (T.strip actor) -> whenReady runtime (pure (Right (refusal "forbidden")))
      | otherwise -> propose runtime (idempotencyKeyText key) project (ByHuman actor) document

-- | 'proposePlan' from a file; @file-unreadable@ when it cannot be read.
proposePlanFile :: DatabaseRuntime -> IdempotencyKey -> T.Text -> T.Text -> FilePath -> IO (Either NotReadyReason (Either ProposalRefusal RevisionView))
proposePlanFile runtime key rawProject actor file = do
  read' <- tryIO (LBS.readFile file)
  case read' of
    Left _ -> whenReady runtime (pure (Right (refusal "file-unreadable")))
    Right bytes -> proposePlan runtime key rawProject actor bytes

propose :: DatabaseRuntime -> T.Text -> ProjectId -> Proposer -> PlanDocument -> IO (Either NotReadyReason (Either ProposalRefusal RevisionView))
propose runtime keyText project proposer document =
  whenReady runtime $ do
    planUuid <- newUuid
    revisionUuid <- newUuid
    withDatabase runtime . O.withTransaction $ proposeIn planUuid revisionUuid keyText project proposer document

-- | 'propose' inside the caller's transaction (R-P6.4-6: a draft is finished in the same transaction).
proposeIn :: Uuid -> Uuid -> T.Text -> ProjectId -> Proposer -> PlanDocument -> O.Orville (Either ProposalRefusal RevisionView)
proposeIn planUuid revisionUuid keyText project proposer document = do
  Store.lockPlans
  found <- Projects.findProjectById project
  profiles <- knownProfiles
  case (found, validatePlan (PlanContext profiles) document) of
    (Nothing, _) -> pure (refusal "unknown-project")
    (_, Left problems) -> pure (Left (ProposalRefusal (T.pack "invalid-plan") (fmap planProblemText problems)))
    (Just _, Right valid) -> do
      let
        digest = planDigestText sha256Hasher valid
      existingPlan <- Store.findPlanOf project
      byKey <- Store.findRevisionByKey keyText
      case byKey of
        Just r
          | Just (Store.revisionRowPlan r) == fmap Store.planRowId existingPlan && Store.revisionRowDigest r == digest ->
              Right <$> revisionView r
          | otherwise -> pure (refusal "key-conflict")
        Nothing -> do
          plan <-
            case existingPlan of
              Just p -> pure p
              Nothing -> do
                let
                  p = Store.PlanRow (PlanId planUuid) project
                Store.insertPlan p
                pure p
          revisions <- Store.planRevisions (Store.planRowId plan)
          decided <- traverse (\r -> (,) r <$> Store.decisionOf (Store.revisionRowId r)) revisions
          let
            effective = effectiveNumber decided
            -- R-P6.4-4: the same plan is refused only while it waits for a decision or is in effect; a
            -- rejected or superseded one may be proposed again as a new revision.
            live (r, d) = Store.revisionRowDigest r == digest && (isNothing d || Just (Store.revisionRowNumber r) == effective)
          -- DG-08 Phase signoff (Update 2): a Planner refinement never removes a human gate of the plan in effect.
          inEffect <- traverse stored (L.find ((== effective) . Just . Store.revisionRowNumber) revisions)
          let
            removesGate =
              case (proposer, inEffect) of
                (ByPlanner _, Just current) -> not (L.null (gatesRemoved current valid))
                _ -> False
          case () of
            _
              | L.any live decided -> pure (refusal "already-proposed")
              | removesGate -> pure (refusal "human-gate-removed")
              | otherwise -> do
                  let
                    row =
                      Store.RevisionRow
                        { Store.revisionRowId = PlanRevisionId revisionUuid
                        , Store.revisionRowPlan = Store.planRowId plan
                        , Store.revisionRowNumber = 1 + L.foldl' max 0 (fmap Store.revisionRowNumber revisions)
                        , Store.revisionRowDigest = digest
                        , Store.revisionRowDocument = encodePlanDocument valid
                        , Store.revisionRowProposedBy = T.pack (case proposer of ByHuman _ -> "Human"; ByPlanner _ -> "Planner")
                        , Store.revisionRowProposer = case proposer of ByHuman a -> T.take 200 a; ByPlanner d -> identityText d
                        , Store.revisionRowDraft = case proposer of ByHuman _ -> Nothing; ByPlanner d -> Just d
                        , Store.revisionRowKey = keyText
                        , Store.revisionRowUncertainties = fromIntegral (L.length (planUncertainties valid))
                        }
                  Store.insertRevision row
                  Right <$> revisionView row

-- Views -----------------------------------------------------------------------------

stored :: Store.RevisionRow -> O.Orville PlanDocument
stored row =
  either (const (integrityViolation "a stored plan revision does not decode")) pure (decodePlanDocumentText (Store.revisionRowDocument row))

-- | One revision as it stands among its plan's revisions.
revisionView :: Store.RevisionRow -> O.Orville RevisionView
revisionView row = do
  revisions <- Store.planRevisions (Store.revisionRowPlan row)
  decided <- traverse (\r -> (,) r <$> Store.decisionOf (Store.revisionRowId r)) revisions
  viewAmong (effectiveNumber decided) row

effectiveNumber :: [(Store.RevisionRow, Maybe Store.DecisionRow)] -> Maybe Int32
effectiveNumber decided =
  case [Store.revisionRowNumber r | (r, Just d) <- decided, Store.decisionRowDecision d == T.pack "approved"] of
    [] -> Nothing
    n : ns -> Just (L.foldl' max n ns)

viewAmong :: Maybe Int32 -> Store.RevisionRow -> O.Orville RevisionView
viewAmong effective row = do
  document <- stored row
  decision <- Store.decisionOf (Store.revisionRowId row)
  units <- Store.revisionUnits (Store.revisionRowId row)
  reconciled <- Store.revisionReconciliations (Store.revisionRowId row)
  let
    state =
      case decision of
        Nothing -> "proposed"
        Just d
          | Store.decisionRowDecision d == T.pack "rejected" -> "rejected"
          | Just (Store.revisionRowNumber row) == effective -> "approved"
          | otherwise -> "superseded"
  pure
    RevisionView
      { revisionNumber = fromIntegral (Store.revisionRowNumber row)
      , revisionDigest = Store.revisionRowDigest row
      , revisionState = T.pack state
      , revisionProposedBy = Store.revisionRowProposedBy row
      , revisionProposer = Store.revisionRowProposer row
      , revisionDecidedBy = fmap Store.decisionRowActor decision
      , revisionDocument = document
      , revisionReconciliation = [(Store.reconciliationRowKey r, Store.reconciliationRowOutcome r) | r <- reconciled]
      , revisionTasks = [(Store.unitRowKey u, identityText (Store.unitRowTask u)) | u <- units]
      }

draftView :: Store.DraftRow -> DraftView
draftView row =
  DraftView
    { draftId = identityText (Store.draftRowId row)
    , draftPrdDigest = Store.draftRowPrdDigest row
    , draftArchitectureDigest = Store.draftRowArchitectureDigest row
    , draftOutcome = Store.draftRowOutcome row
    , draftCode = Store.draftRowCode row
    }

planView :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Either T.Text PlanView))
planView runtime rawProject =
  whenReady runtime $
    case parseIdentity rawProject of
      Nothing -> pure (Right (refuse "unknown-project"))
      Just project ->
        withDatabase runtime $ do
          found <- Projects.findProjectById project
          case found of
            Nothing -> pure (refuse "unknown-project")
            Just _ -> Right <$> planViewIn project

planViewIn :: ProjectId -> O.Orville PlanView
planViewIn project = do
  plan <- Store.findPlanOf project
  revisions <- maybe (pure []) (Store.planRevisions . Store.planRowId) plan
  decided <- traverse (\r -> (,) r <$> Store.decisionOf (Store.revisionRowId r)) revisions
  let
    effective = effectiveNumber decided
  views <- traverse (viewAmong effective) revisions
  drafts <- Store.projectDrafts project
  pure
    PlanView
      { planViewRevisions = views
      , planViewEffective = L.find ((== fmap fromIntegral effective) . Just . revisionNumber) views
      , planViewDrafts = fmap draftView drafts
      }

-- The owner's decision ---------------------------------------------------------------

-- | The owner's decision (M5), by an operator session, on a revision named by number and digest.
decidePlan :: DatabaseRuntime -> T.Text -> T.Text -> Int -> T.Text -> PlanDecision -> IO (Either NotReadyReason (Either T.Text RevisionView))
decidePlan runtime actor rawProject number digest decision =
  whenReady runtime $
    case parseIdentity rawProject of
      _ | T.null (T.strip actor) -> pure (Right (refuse "forbidden"))
      Nothing -> pure (Right (refuse "unknown-project"))
      Just project -> do
        uuids <- traverse (const newUuid) [1 .. 200 :: Int]
        withDatabase runtime . O.withTransaction $ do
          Tasks.lockTasks
          Store.lockPlans
          plan <- Store.findPlanOf project
          revisions <- maybe (pure []) (Store.planRevisions . Store.planRowId) plan
          decided <- traverse (\r -> (,) r <$> Store.decisionOf (Store.revisionRowId r)) revisions
          let
            effective = effectiveNumber decided
          case L.find ((== number) . fromIntegral . Store.revisionRowNumber . fst) decided of
            Nothing -> pure (refuse "unknown-revision")
            Just (row, earlier)
              | Store.revisionRowDigest row /= digest -> pure (refuse "stale-digest")
              | isJust earlier -> pure (refuse "already-decided")
              | decision == ApprovePlan && maybe False (> Store.revisionRowNumber row) effective -> pure (refuse "superseded")
              | decision == RejectPlan -> do
                  Store.insertDecision (Store.DecisionRow (Store.revisionRowId row) (T.pack "rejected") digest (T.take 200 actor))
                  Right <$> viewAmong effective row
              | otherwise -> do
                  let
                    previous = [r | n <- maybe [] pure effective, r <- revisions, Store.revisionRowNumber r == n]
                  approved <- approve project row previous [r | (r, Just d) <- decided, Store.decisionRowDecision d == T.pack "approved"] uuids actor
                  case approved of
                    Left code -> pure (Left code)
                    Right () -> Right <$> viewAmong (Just (Store.revisionRowNumber row)) row

{- | M6, M7: the approval's writes. Every refusal is decided before the first
write; a write that fails afterwards aborts the transaction.
-}
approve :: ProjectId -> Store.RevisionRow -> [Store.RevisionRow] -> [Store.RevisionRow] -> [Uuid] -> T.Text -> O.Orville (Either T.Text ())
approve project row previousEffective approvedBefore uuids actor = do
  document <- stored row
  previousDocument <- traverse stored (L.take 1 previousEffective)
  -- Earlier approved revisions, newest first: a unit keeps the task it had in the newest one that had it.
  let
    newestFirst = L.sortOn (negate . Store.revisionRowNumber) approvedBefore
  earlierUnits <- L.concat <$> traverse (Store.revisionUnits . Store.revisionRowId) newestFirst
  earlierDocuments <- traverse stored newestFirst
  let
    units = planUnits document
    existing k = L.find ((== unitKeyText k) . Store.unitRowKey) earlierUnits
    fresh = [u | u <- units, isNothing (existing (unitKey u))]
    newTasks = L.zip (fmap unitKey fresh) (fmap TaskId uuids)
    taskOf k = maybe (L.lookup k newTasks) (Just . Store.unitRowTask) (existing k)
    -- R-P6.4-1: the unit as the plan last wrote its task (the newest earlier approved revision that had it).
    lastWritten k = listToMaybe [u | d <- earlierDocuments, u <- planUnits d, unitKey u == k]
    planTasks = L.nub (mapMaybe (taskOf . unitKey) units <> fmap Store.unitRowTask earlierUnits)
    withdrawnKeys = [unitKey u | d <- previousDocument, u <- planUnits d, unitKey u `L.notElem` fmap unitKey units]
    checked = traverse (\u -> (,) u <$> either (const (Left (T.pack "acceptance-invalid"))) Right (mkAcceptance (acceptanceOf u))) units
  case (checked, L.length fresh > L.length uuids) of
    (Left code, _) -> pure (Left code)
    (_, True) -> pure (refuse "too-many-units")
    (Right withAcceptance, False) -> do
      -- R-P6.4-1: a unit whose task text the plan changes, on a task a person edited since the plan wrote it, is refused.
      conflicts <- traverse (\u -> conflictOf (taskOf (unitKey u)) (lastWritten (unitKey u)) u) units
      if L.or conflicts
        then pure (refuse "locally-edited")
        else do
          Store.insertDecision (Store.DecisionRow (Store.revisionRowId row) (T.pack "approved") (Store.revisionRowDigest row) (T.take 200 actor))
          written <- traverse (\(u, a) -> writeUnit project taskOf (lastWritten (unitKey u)) (u, a)) withAcceptance
          -- R-P6.4-2: a withdrawn unit's task is blocked, so it is no longer handed over.
          withdrew <- traverse (maybe (pure (Right ())) (withdrawTask (Store.revisionRowNumber row)) . taskOf) withdrawnKeys
          case sequenceA_ (written <> withdrew) of
            Left code -> integrityViolation ("the approval could not write a unit it had validated: " <> T.unpack code)
            Right () -> do
              -- The plan's edges are the units' dependencies (all kinds; P6.5–P6.7 read their kinds from the plan);
              -- R-P6.4-1: a person's own dependencies on tasks outside the plan are kept.
              traverse_
                ( \u ->
                    case taskOf (unitKey u) of
                      Nothing -> pure ()
                      Just t -> do
                        current <- Tasks.dependenciesOf t
                        let
                          own = [d | d <- current, d `L.notElem` planTasks]
                          wanted = L.nub (mapMaybe taskOf [edgePrerequisite e | e <- planEdges document, edgeDependent e == unitKey u] <> own)
                        when (L.sort wanted /= L.sort current) (Tasks.replaceDependencies t wanted)
                )
                units
          Store.insertUnits
            [ Store.UnitRow
                { Store.unitRowRevision = Store.revisionRowId row
                , Store.unitRowKey = unitKeyText (unitKey u)
                , Store.unitRowTask = t
                , Store.unitRowDigest = fromMaybe T.empty (unitDigestText sha256Hasher document (unitKey u))
                , Store.unitRowWorkKind = unitWorkKind u
                , Store.unitRowProfile = unitProfile u
                , Store.unitRowProvisional = unitProvisional u
                , Store.unitRowPriority = fromIntegral (priorityValue (unitPriority u))
                , Store.unitRowOrdinal = i
                }
            | (i, u) <- L.zip [0 ..] units
            , Just t <- [taskOf (unitKey u)]
            ]
          Store.insertEdges
            [ Store.EdgeRow (Store.revisionRowId row) (unitKeyText (edgeDependent e)) (unitKeyText (edgePrerequisite e)) (edgeKindCode (edgeKind e))
            | e <- planEdges document
            ]
          let
            reconciled = reconcilePlan sha256Hasher (listToMaybe previousDocument) document
          Store.insertReconciliations
            [ Store.ReconciliationRow (Store.revisionRowId row) (unitKeyText k) (unitOutcomeCode o) (fmap Store.revisionRowId (listToMaybe previousEffective))
            | (k, o) <- reconciled
            ]
          -- C-P6.7 V2 c: a changed unit's work, and work built on it, stops counting.
          redo <- catMaybes <$> traverse liveFix (mapMaybe taskOf [k | (k, o) <- reconciled, unitOutcomeCode o `L.elem` fmap T.pack ["changed", "invalidated"]])
          planChangedIn (Store.revisionRowId row) redo
          pure (Right ())

-- | A task's latest fix that has not ended (running, halted or accepted), if any.
liveFix :: TaskId -> O.Orville (Maybe TransactionId)
liveFix t = do
  admission <- Execution.findAdmissionByTask t
  tx <- maybe (pure Nothing) (Transactions.findTransactionByWorkOrder . Execution.admissionRowWorkOrder) admission
  pure $
    case fmap Transactions.txRowState tx of
      Just (Running _) -> Transactions.txRowId <$> tx
      Just (Halted _ _) -> Transactions.txRowId <$> tx
      Just Accepted -> Transactions.txRowId <$> tx
      _ -> Nothing

acceptanceOf :: PlanUnit -> T.Text
acceptanceOf u =
  T.intercalate (T.pack "\n") (fmap planCriterionText (unitAcceptance u))

-- | Whether the task text the unit gives (title, acceptance, priority) differs from the earlier unit's.
textChanged :: PlanUnit -> PlanUnit -> Bool
textChanged old u =
  T.strip (unitTitle old) /= T.strip (unitTitle u) || acceptanceOf old /= acceptanceOf u || unitPriority old /= unitPriority u

{- | R-P6.4-1: True when the plan would change the task's text but the task no
longer has the text the plan last wrote (a person edited it).
-}
conflictOf :: Maybe TaskId -> Maybe PlanUnit -> PlanUnit -> O.Orville Bool
conflictOf task previous u =
  case (task, previous) of
    (Just t, Just old)
      | textChanged old u -> do
          row <- Tasks.findTaskRow t
          pure $
            case row of
              Nothing -> False
              Just r ->
                Tasks.rowTitle r /= T.strip (unitTitle old)
                  || Tasks.rowAcceptance r /= acceptanceOf old
                  || priorityOf (fromIntegral (Tasks.rowPriority r)) /= unitPriority old
    _ -> pure False

{- | Creates a fresh unit's task (a Ticket accepted to ready by the owner's
approval); for a unit the plan had before, changes its task's text only when
the unit's text changed (R-P6.4-1), and makes a task its withdrawal blocked
ready again (R-P6.4-2).
-}
writeUnit :: ProjectId -> (UnitKey -> Maybe TaskId) -> Maybe PlanUnit -> (PlanUnit, T.Text) -> O.Orville (Either T.Text ())
writeUnit project taskOf previous (u, acceptance) =
  case (taskOf (unitKey u), mkTaskTitle (unitTitle u)) of
    (_, Left _) -> pure (refuse "title-invalid")
    (Nothing, _) -> pure (refuse "no-task")
    (Just t, Right title) -> do
      row <- Tasks.findTaskRow t
      case row of
        Nothing -> do
          made <- createTicketIn ((\(TaskId x) -> x) t) (T.strip (unitTitle u)) >>= ledgerStep
          case made of
            Left code -> pure (Left code)
            Right ticket -> do
              Tasks.insertTask t project (creationKey project (unitKey u)) acceptance (priorityValue (unitPriority u)) (requestDigest project title acceptance (unitPriority u) [])
              facts <- ticketFactsIn ticket >>= ledgerStep
              case facts of
                Left code -> pure (Left code)
                Right (_, _, revision, _) -> fmap (const ()) <$> (decideTicketIn ticket revision (Command Human TicketAccept) >>= ledgerStep)
        Just taskRow -> do
          restored <- restoreTask t
          case restored of
            Left code -> pure (Left code)
            Right ()
              | maybe False (`textChanged` u) previous -> do
                  revised <-
                    if T.strip (unitTitle u) /= Tasks.rowTitle taskRow
                      then fmap (const ()) <$> (reviseTicketIn (TicketId ((\(TaskId x) -> x) t)) (T.strip (unitTitle u)) >>= ledgerStep)
                      else pure (Right ())
                  case revised of
                    Left code -> pure (Left code)
                    Right () -> do
                      updated <- Tasks.updateTask t (Tasks.rowRevision taskRow) acceptance (priorityValue (unitPriority u))
                      pure (if updated then Right () else refuse "stale-revision")
              | otherwise -> pure (Right ())

-- | The reason a withdrawal blocks a task with; a task blocked with it is made ready again when its unit returns.
withdrawnReason :: Int32 -> T.Text
withdrawnReason number =
  withdrawnPrefix <> T.pack " by its revision " <> T.pack (show number) <> T.pack "."

withdrawnPrefix :: T.Text
withdrawnPrefix =
  T.pack "This work was withdrawn from the plan"

-- | R-P6.4-2: blocks a withdrawn unit's task, by the owner's approval; a finished, canceled or blocked task is left as it is.
withdrawTask :: Int32 -> TaskId -> O.Orville (Either T.Text ())
withdrawTask number t = do
  facts <- ticketFactsIn (TicketId ((\(TaskId x) -> x) t)) >>= ledgerStep
  case facts of
    Left code -> pure (Left code)
    Right (state, _, revision, _)
      | state `L.elem` fmap T.pack ["done", "canceled", "blocked"] -> pure (Right ())
      | otherwise -> fmap (const ()) <$> (decideTicketIn (TicketId ((\(TaskId x) -> x) t)) revision (Command Human (TicketBlock (withdrawnReason number))) >>= ledgerStep)

-- | R-P6.4-2: a task its unit's withdrawal blocked is unblocked when the unit returns; any other block stays.
restoreTask :: TaskId -> O.Orville (Either T.Text ())
restoreTask t = do
  facts <- ticketFactsIn (TicketId ((\(TaskId x) -> x) t)) >>= ledgerStep
  case facts of
    Left code -> pure (Left code)
    Right (state, reason, revision, _)
      | state == T.pack "blocked" && maybe False (T.isPrefixOf withdrawnPrefix) reason ->
          fmap (const ()) <$> (decideTicketIn (TicketId ((\(TaskId x) -> x) t)) revision (Command Human TicketUnblock) >>= ledgerStep)
      | otherwise -> pure (Right ())

-- | The task row's creation key for a unit: fixed by the project and the unit's key (61 characters).
creationKey :: ProjectId -> UnitKey -> T.Text
creationKey project k =
  T.pack "plan-" <> T.take 56 (sha (identityText project <> T.pack "\n" <> unitKeyText k))

-- Drafts ----------------------------------------------------------------------------

-- | A person's request that the Planner draft a plan (M10): the PRD and, optionally, the architecture.
requestDraft :: DatabaseRuntime -> IdempotencyKey -> T.Text -> T.Text -> T.Text -> Maybe T.Text -> IO (Either NotReadyReason (Either T.Text DraftView))
requestDraft runtime key rawProject actor prd architecture =
  whenReady runtime $
    case parseIdentity rawProject of
      _ | T.null (T.strip actor) -> pure (Right (refuse "forbidden"))
      _ | not (documentValid prd) -> pure (Right (refuse "prd-invalid"))
      _ | maybe False (not . documentValid) architecture -> pure (Right (refuse "architecture-invalid"))
      Nothing -> pure (Right (refuse "unknown-project"))
      Just project -> do
        uuid <- newUuid
        let
          keyText = idempotencyKeyText key
          prdDigest = sha prd
          archDigest = fmap sha architecture
          requestDigest' = sha (identityText project <> T.pack "\n" <> prdDigest <> T.pack "\n" <> fromMaybe (T.pack "none") archDigest)
        withDatabase runtime . O.withTransaction $ do
          Store.lockPlans
          found <- Projects.findProjectById project
          existing <- Store.findDraftByKey keyText
          case (found, existing) of
            (Nothing, _) -> pure (refuse "unknown-project")
            (_, Just row)
              | Store.draftRowRequestDigest row == requestDigest' -> pure (Right (draftView row))
              | otherwise -> pure (refuse "key-conflict")
            (Just _, Nothing) -> do
              let
                row =
                  Store.DraftRow
                    { Store.draftRowId = PlanDraftId uuid
                    , Store.draftRowProject = project
                    , Store.draftRowKey = keyText
                    , Store.draftRowRequestDigest = requestDigest'
                    , Store.draftRowPrd = prd
                    , Store.draftRowPrdDigest = prdDigest
                    , Store.draftRowArchitecture = architecture
                    , Store.draftRowArchitectureDigest = archDigest
                    , Store.draftRowRequestedBy = T.take 200 actor
                    , Store.draftRowStarted = Nothing
                    , Store.draftRowOutcome = Nothing
                    , Store.draftRowCode = Nothing
                    }
              Store.insertDraft row
              pure (Right (draftView row))
 where
  documentValid text = not (T.null (T.strip text)) && T.length text <= 200000

-- | 'requestDraft' from files (UTF-8); @file-unreadable@ when one cannot be read.
requestDraftFiles :: DatabaseRuntime -> IdempotencyKey -> T.Text -> T.Text -> FilePath -> Maybe FilePath -> IO (Either NotReadyReason (Either T.Text DraftView))
requestDraftFiles runtime key rawProject actor prdFile architectureFile = do
  prd <- readText prdFile
  architecture <- traverse readText architectureFile
  case (prd, sequenceA architecture) of
    (Right p, Right a) -> requestDraft runtime key rawProject actor p a
    _ -> whenReady runtime (pure (Right (refuse "file-unreadable")))
 where
  readText file = do
    read' <- tryIO (BS.readFile file)
    pure $
      case read' of
        Left _ -> refuse "file-unreadable"
        Right bytes -> either (const (refuse "file-unreadable")) Right (TE.decodeUtf8' bytes)

-- | One pass over the pending drafts (the worker's phase).
draftPlans :: DatabaseRuntime -> Engine -> IO (Either NotReadyReason [DraftReport])
draftPlans runtime engine =
  draftPlansUntil runtime engine (pure False)

{- | 'draftPlans', checking before each draft whether to stop. The phase runs
under its own session lock: another worker skips it while one holds it. A
draft a stopped worker left started is finished uncertain and never rerun.
-}
draftPlansUntil :: DatabaseRuntime -> Engine -> IO Bool -> IO (Either NotReadyReason [DraftReport])
draftPlansUntil runtime engine stopping = do
  halt <- stopping
  if halt
    then pure (Right [])
    else do
      locked <- withSessionLock runtime PlanDraftLock (T.pack "plan-drafts") (const (phase runtime engine stopping))
      pure $
        case locked of
          Right result -> result
          Left LockBusy -> Right []
          Left (LockUnavailable reason) -> Left reason

phase :: DatabaseRuntime -> Engine -> IO Bool -> IO (Either NotReadyReason [DraftReport])
phase runtime engine stopping = do
  settled <-
    withDatabase runtime . O.withTransaction $ do
      rows <- Store.unfinishedDrafts
      traverse (\r -> DraftReport (identityText (Store.draftRowId r)) DraftUncertain <$ Store.finishDraft (Store.draftRowId r) (T.pack "uncertain") (Just (T.pack "worker-stopped"))) rows
  pending <- withDatabase runtime Store.pendingDrafts
  case (settled, pending) of
    (Left reason, _) -> pure (Left reason)
    (_, Left reason) -> pure (Left reason)
    (Right cut, Right rows) -> fmap ((cut <>) . catMaybes) . sequenceA <$> each rows
 where
  each rows =
    case rows of
      [] -> pure []
      row : rest -> do
        stop <- stopping
        if stop
          then pure []
          else (:) <$> draftOne runtime engine row <*> each rest

draftOne :: DatabaseRuntime -> Engine -> Store.DraftRow -> IO (Either NotReadyReason (Maybe DraftReport))
draftOne runtime engine row = do
  started <-
    withDatabase runtime $ do
      siblings <- Store.projectDrafts (Store.draftRowProject row)
      ok <- Store.startDraft (Store.draftRowId row)
      pure (ok, L.length (L.takeWhile ((/= Store.draftRowId row) . Store.draftRowId) siblings))
  case started of
    Left reason -> pure (Left reason)
    Right (False, _) -> pure (Right Nothing)
    Right (True, earlier) -> do
      (outcome, settledAlready) <- run earlier
      finished <- if settledAlready then pure (Right ()) else withDatabase runtime (finishWith outcome)
      pure (Just (DraftReport (identityText (Store.draftRowId row)) outcome) <$ finished)
 where
  unsettled o = pure (o, False)
  run earlier =
    case engineAdapter engine Planner earlier of
      Nothing -> unsettled DraftNoHelper
      Just adapter -> do
        let
          runner = engineRunner engine
        prepared <- runnerPrepare runner
        case prepared of
          Left code -> unsettled (DraftFailed code)
          Right workspace -> do
            outcome <- invokeRole runner adapter Planner workspace (draftContext row) [] `finally` runnerRelease runner workspace
            case outcome of
              RoleAnswered (AnswerPlan p) _ -> judge (planDraftDocument p)
              RoleAnswered _ _ -> unsettled (DraftFailed (T.pack "wrong-kind"))
              RoleFailed code _ -> unsettled (DraftFailed code)
              RoleUncertain _ -> unsettled DraftUncertain
  {- R-P6.4-6: a valid draft's revision is proposed and the draft finished in one
  transaction, so a draft is never left unfinished with its revision proposed. -}
  judge text =
    case decodePlanDocumentText text of
      Left e -> unsettled (DraftRefused [planDocumentErrorCode e])
      Right document ->
        case sourceProblems document of
          problems@(_ : _) -> unsettled (DraftRefused problems)
          [] -> do
            planUuid <- newUuid
            revisionUuid <- newUuid
            proposed <-
              withDatabase runtime . O.withTransaction $ do
                p <- proposeIn planUuid revisionUuid (T.pack "plan-draft-" <> identityText (Store.draftRowId row)) (Store.draftRowProject row) (ByPlanner (Store.draftRowId row)) document
                let
                  outcome =
                    case p of
                      Right r -> DraftProposed (revisionNumber r)
                      Left (ProposalRefusal code []) -> DraftRefused [code]
                      Left (ProposalRefusal _ problems) -> DraftRefused problems
                finishWith outcome
                pure outcome
            pure $
              case proposed of
                Left _ -> (DraftFailed (T.pack "database-unavailable"), False)
                Right outcome -> (outcome, True)
  -- The plan must answer to exactly the documents the person gave, with their real digests.
  expected =
    (T.pack "prd", Store.draftRowPrdDigest row) : maybe [] (\d -> [(T.pack "architecture", d)]) (Store.draftRowArchitectureDigest row)
  sourceProblems document =
    let
      given = [(sourceName s, sourceDigest s) | s <- planSources document]
    in
      [T.pack "source-digest-mismatch: " <> n | (n, d) <- given, Just d' <- [L.lookup n expected], d /= d']
        <> [T.pack "unknown-source: " <> n | (n, _) <- given, isNothing (L.lookup n expected)]
        <> [T.pack "missing-source: " <> n | (n, _) <- expected, isNothing (L.lookup n given)]
  finishWith outcome =
    case outcome of
      DraftProposed n -> Store.finishDraft (Store.draftRowId row) (T.pack "proposed") (Just (T.pack ("revision " <> show n)))
      DraftRefused problems -> Store.finishDraft (Store.draftRowId row) (T.pack "refused") (Just (T.take 4000 (T.intercalate (T.pack "\n") problems)))
      DraftFailed code -> Store.finishDraft (Store.draftRowId row) (T.pack "failed") (Just (T.take 4000 code))
      DraftNoHelper -> Store.finishDraft (Store.draftRowId row) (T.pack "no-helper") Nothing
      -- R-P6.4-6: distinct from a worker stopped mid-draft (@worker-stopped@).
      DraftUncertain -> Store.finishDraft (Store.draftRowId row) (T.pack "uncertain") (Just (T.pack "planner-uncertain"))

-- The Planner's context (M10) ---------------------------------------------------------

data Context
  = Context
  { ctxRole :: T.Text
  , ctxStage :: T.Text
  , ctxAnswer :: T.Text
  , ctxDocuments :: [Document]
  , ctxRule :: T.Text
  }

data Document
  = Document T.Text T.Text T.Text

contextSchema :: FC.Fleece t => FC.Schema t Context
contextSchema =
  FC.object $
    FC.constructor Context
      #+ FC.required "role" ctxRole FC.text
      #+ FC.required "stage" ctxStage FC.text
      #+ FC.required "answer" ctxAnswer (FC.object (FC.constructor id #+ FC.required "kind" id FC.text))
      #+ FC.required "documents" ctxDocuments (FC.list documentSchema)
      #+ FC.required "rule" ctxRule FC.text
 where
  documentSchema =
    FC.object $
      FC.constructor Document
        #+ FC.required "name" (\(Document n _ _) -> n) FC.text
        #+ FC.required "sha256" (\(Document _ d _) -> d) FC.text
        #+ FC.required "text" (\(Document _ _ t) -> t) FC.text

draftContext :: Store.DraftRow -> T.Text
draftContext row =
  encodeText
    contextSchema
    Context
      { ctxRole = T.pack "planner"
      , ctxStage = T.pack "plan"
      , ctxAnswer = T.pack "plan"
      , ctxDocuments =
          Document (T.pack "prd") (Store.draftRowPrdDigest row) (Store.draftRowPrd row)
            : catMaybes [Document (T.pack "architecture") <$> Store.draftRowArchitectureDigest row <*> Store.draftRowArchitecture row]
      , ctxRule = T.pack "Propose a lockstep-plan version 1 document whose sources are exactly these documents with these sha256 digests. A proposal is not authority: the owner approves it or not."
      }
