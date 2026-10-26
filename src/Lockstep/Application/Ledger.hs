{- | The durable ledger (contract C-P2.5; DG-04 D-4.1, D-4.2, D-4.4, D-4.7).
Every operation is one PostgreSQL transaction: it locks what it decides on,
rebuilds the current state by replaying the stored events through the
Kernel, lets the Kernel decide, and only then writes. A refused decision
writes nothing but its refusal evidence. A stored record that does not
reproduce (a projection, a Profile source, an intent's parameter digest) is
an integrity failure and is never used. Nothing here performs an effect.
-}
module Lockstep.Application.Ledger
  ( LedgerFailure (..)
  , ledgerFailureCode
  , Faults (..)
  , noFaults
  , Receipt (..)
  , SubjectView (..)
  , createTicket
  , createTicketIn
  , reviseTicket
  , reviseTicketIn
  , ticketFactsIn
  , decideTicket
  , showTicket
  , NewWorkOrder (..)
  , createWorkOrder
  , decideWorkOrder
  , WorkOrderView (..)
  , showWorkOrder
  , recordGateEvidence
  , gateEvidenceNamed
  , ScheduleReceipt (..)
  , scheduleOnce
  , SchedulePreview (..)
  , previewSchedule
  , admitWorkUnit
  , loadIntent
  , claimIntent
  , dispatchIntent
  , observeIntent
  , settleIntent
  , abandonIntent
  , abandonIntentAcknowledged
  , StoredObservation (..)
  , intentObservations
  , claimForExecution
  , beginDispatch
  , beginDispatchLeased
  , concludeIntent
  , recoverDispatched
  , runnableIntents
  , recoverableIntents
  , StoredRecovery (..)
  , intentRecoveries
  , prepareLookup
  , applyLookup
  , resolveOutcome
  , reconcilableIntents
  , StoredResolution (..)
  , intentResolutions
  , IntentFacts (..)
  , OrderFacts (..)
  , LedgerFacts (..)
  , readLedger
  , carryIntent
  , carryIntentAs
  , carryIntentChecked
  , intentActivation
  , probeIntegrityRollback
  ) where

import Control.Exception (Exception, SomeException, throwIO, try)
import Control.Monad (filterM, foldM, unless)
import Data.Char qualified as Char
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List qualified as L
import Data.Maybe (catMaybes, fromMaybe, isJust)
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime)
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Text.Show (Show, show)

import Lockstep.Application.Database (DatabaseRuntime, checkReadiness, readinessCode, withDatabase)
import Lockstep.Application.Database qualified as Database
import Lockstep.Application.Identity (newUuid)
import Lockstep.Application.Profiles (ProfileFailure (..), loadStoredDefinition, sha256Hasher)
import Lockstep.Kernel.Activation (CarryInput (..), CarryRequest (..), carryChecked, carryRefusalCode)
import Lockstep.Kernel.Effect
  ( ClassTerms (..)
  , EffectRefusal (..)
  , IdempotencyTerms (..)
  , Intent (..)
  , IntentInput (..)
  , IntentRequest
  , IntentState (..)
  , Lease (..)
  , LookupTerms (..)
  , Observation (..)
  , OperationId (..)
  , Settlement (..)
  , SubjectRef (..)
  , effectClassName
  , effectKeyText
  , effectRefusalCode
  , effectSpecBudget
  , effectSpecClass
  , effectSpecName
  , effectSpecTerms
  , intentStateName
  , mkEffectKey
  , mkEffectSpec
  , newIntents
  , stepIntent
  )
import Lockstep.Kernel.EventCodec
  ( TicketEvent (..)
  , WorkOrderEvent (..)
  , decodeTicketEvent
  , decodeWorkOrderEvent
  , encodeTicketEvent
  , encodeWorkOrderEvent
  , parsePrincipal
  , principalName
  )
import Lockstep.Kernel.Identity (EngineerId (..), RepositoryId (..), TicketId (..), Uuid, WorkOrderId (..), WorkUnitId (..), parseUuid, uuidText)
import Lockstep.Kernel.KeyLifetime (idempotencyHolds)
import Lockstep.Kernel.Profile
  ( Approval (..)
  , ArtifactKind (..)
  , Behaviour (..)
  , EffectiveProfile
  , GateEvidence (..)
  , Hasher (..)
  , LayerLevel (..)
  , ProfileBinding
  , ProfileDefinition
  , ProfileRef (..)
  , ResolutionInput (..)
  , VerifierKind (..)
  , bindProfile
  , bindingDigest
  , contentDigestText
  , effectiveDigest
  , effectiveSources
  , installationBaseline
  , mkClassTag
  , mkContentDigest
  , mkNonBehaviouralBasis
  , mkWorkFacts
  , parsePathClass
  , profileIdText
  , profileRef
  , profileRefusalCode
  , renderProfileRefusal
  , resolveProfile
  )
import Lockstep.Kernel.Reconciliation
  ( LateVerdict (..)
  , LookupResult (..)
  , ReconcileInput (..)
  , ReconcileRefusal
  , Resolution (..)
  , judgeLateObservation
  , reconcileIntent
  , reconcileRefusalCode
  , renderLookup
  , renderResolution
  , resolveIntent
  )
import Lockstep.Kernel.Recovery (Recovery (..), RecoveryInput (..), recoverIntent, recoveryIntent, recoveryRefusalCode, renderRecovery)
import Lockstep.Kernel.Repository (Ownership (..))
import Lockstep.Kernel.Scheduler
  ( ScheduleDecision
  , ScheduledOrder (..)
  , SchedulerInput (..)
  , SourceBasis (..)
  , decisionSelected
  , mkPriority
  , renderScheduleDecision
  , scheduleDigest
  , scheduleOrders
  , schedulerRefusalCode
  , schedulingCommands
  )
import Lockstep.Kernel.Ticket (TicketInput, TicketState (..), stepTicket, ticketInputName, ticketStateName)
import Lockstep.Kernel.Transition (Command (..), Principal (..), transitionRefusalCode)
import Lockstep.Kernel.WorkOrder
  ( Claim (..)
  , WorkOrder (..)
  , WorkOrderInput (..)
  , WorkOrderKind
  , WorkOrderState (..)
  , newWorkOrder
  , parseWorkOrderKind
  , stepWorkOrder
  , workOrderInputName
  , workOrderKindName
  , workOrderStateName
  )
import Lockstep.Kernel.WorkUnit qualified as WorkUnit
import Lockstep.Persistence.Ledger qualified as Store
import Lockstep.Persistence.Profiles qualified as Profiles

data LedgerFailure
  = LedgerRefused T.Text T.Text
  | LedgerIntegrity T.Text
  | LedgerUnavailable T.Text
  deriving (Eq, Show)

ledgerFailureCode :: LedgerFailure -> T.Text
ledgerFailureCode failure =
  case failure of
    LedgerRefused code _ -> code
    LedgerIntegrity _ -> T.pack "integrity"
    LedgerUnavailable _ -> T.pack "unavailable"

-- | Test-only fault hooks (E11); the binary always uses 'noFaults'.
data Faults
  = Faults
  { faultAfterEvent :: IO ()
  , faultAfterIntents :: IO ()
  }

noFaults :: Faults
noFaults =
  Faults (pure ()) (pure ())

data Receipt
  = Receipt
  { receiptRevision :: Int
  , receiptState :: T.Text
  , receiptOperations :: [OperationId]
  }
  deriving (Eq, Show)

data SubjectView
  = SubjectView
  { viewRevision :: Int
  , viewState :: T.Text
  , viewContentRevision :: Int
  }
  deriving (Eq, Show)

-- Transactions -------------------------------------------------------------------

type Hook = IO () -> O.Orville ()

{- | One transaction, after a readiness check. A hook's exception rolls the
transaction back and is rethrown to the caller (E11); any other database
failure is 'LedgerUnavailable'. An integrity failure rolls back whatever the
transaction wrote before it was found (C-P2.9-R1 M3): only a pure refusal
commits, with its refusal evidence.
-}
transaction :: DatabaseRuntime -> (Hook -> O.Orville (Either LedgerFailure a)) -> IO (Either LedgerFailure a)
transaction runtime action = do
  readiness <- checkReadiness (Just runtime)
  case readiness of
    Database.NotReady _ -> pure (Left (LedgerUnavailable (readinessCode readiness)))
    Database.Ready _ -> do
      fault <- newIORef Nothing
      rolledBack <- newIORef Nothing
      let
        guarded = do
          r <- action (hook fault)
          case r of
            Left failure@(LedgerIntegrity _) -> liftIO (writeIORef rolledBack (Just failure) >> throwIO RollBack)
            _ -> pure r
      result <- withDatabase runtime (O.withTransaction guarded)
      case result of
        Right value -> pure value
        Left reason -> do
          injected <- readIORef fault
          aborted <- readIORef rolledBack
          case (injected, aborted) of
            (Just e, _) -> throwIO e
            (Nothing, Just failure) -> pure (Left failure)
            (Nothing, Nothing) -> pure (Left (LedgerUnavailable (readinessCode (Database.NotReady reason))))

-- | Aborts a transaction that found an integrity failure after writing.
data RollBack
  = RollBack
  deriving (Show)

instance Exception RollBack

hook :: IORef (Maybe SomeException) -> Hook
hook fault action =
  liftIO $ do
    result <- try action
    case result of
      Right () -> pure ()
      Left e -> do
        writeIORef fault (Just e)
        throwIO e

refused :: T.Text -> String -> Either LedgerFailure a
refused code message =
  Left (LedgerRefused code (T.pack message))

integrity :: String -> Either LedgerFailure a
integrity message =
  Left (LedgerIntegrity (T.pack message))

-- | Runs a decision step and records its refusal (the only write a refused decision makes).
refuseWith :: Store.NewRefusal -> LedgerFailure -> O.Orville (Either LedgerFailure a)
refuseWith row failure = do
  Store.insertRefusal row {Store.refusalCode = ledgerFailureCode failure}
  pure (Left failure)

uuidOf :: T.Text -> Either LedgerFailure Uuid
uuidOf text =
  either (const (integrity ("a stored identity is malformed: " <> T.unpack text))) Right (parseUuid text)

wid :: WorkOrderId -> T.Text
wid (WorkOrderId u) =
  uuidText u

tid :: TicketId -> T.Text
tid (TicketId u) =
  uuidText u

oid :: OperationId -> T.Text
oid (OperationId u) =
  uuidText u

int32 :: Int -> Int32
int32 =
  fromIntegral

-- Tickets --------------------------------------------------------------------

validTitle :: T.Text -> Bool
validTitle title =
  not (T.null title) && T.length title <= 200 && not (T.any Char.isControl title)

createTicket :: DatabaseRuntime -> T.Text -> IO (Either LedgerFailure TicketId)
createTicket runtime title
  | not (validTitle title) = pure (refused (T.pack "invalid-record") "a title has 1 to 200 characters and no control characters")
  | otherwise = do
      u <- newUuid
      transaction runtime $ \_ -> createTicketIn u title

{- | The writes of 'createTicket' inside the caller's transaction (C-P3.6 K2: a
task's Ticket and its task row are made together). The caller checks readiness.
-}
createTicketIn :: Uuid -> T.Text -> O.Orville (Either LedgerFailure TicketId)
createTicketIn u title
  | not (validTitle title) = pure (refused (T.pack "invalid-record") "a title has 1 to 200 characters and no control characters")
  | otherwise =
      case encodeTicketEvent (TicketCreated title) of
        Left reason -> pure (Left (LedgerRefused (T.pack "not-durable") reason))
        Right command -> do
          let
            state = ticketStateName Proposed
          Store.insertSubject (uuidText u) (T.pack "ticket") state
          Store.insertTicket (uuidText u) title
          _ <- Store.insertEvent (uuidText u) (Store.EventRow 1 (principalName Human) command state)
          pure (Right (TicketId u))

{- | A new title for a Ticket as one @TicketRevised@ event, inside the caller's
transaction, at the Ticket's current revision (C-P3.6 K2: the caller's own
revision guards the edit). Returns the Ticket's new revision.
-}
reviseTicketIn :: T.Text -> T.Text -> O.Orville (Either LedgerFailure Int)
reviseTicketIn ticketId title = do
  loaded <- loadTicket ticketId
  case loaded of
    Left failure -> pure (Left failure)
    Right (s, _, state, content)
      | not (validTitle title) -> pure (refused (T.pack "invalid-record") "a title has 1 to 200 characters and no control characters")
      | otherwise ->
          case encodeTicketEvent (TicketRevised title) of
            Left reason -> pure (Left (LedgerRefused (T.pack "not-durable") reason))
            Right text -> do
              let
                revision = fromIntegral (Store.subjectRowRevision s)
                name = ticketStateName state
              _ <- Store.insertEvent ticketId (Store.EventRow (int32 (revision + 1)) (principalName Human) text name)
              Store.updateTicket ticketId title (int32 (content + 1))
              Store.updateSubject ticketId (int32 (revision + 1)) name
              pure (Right (revision + 1))

{- | A Ticket's replayed facts inside the caller's transaction: its state name,
the reason it is blocked (if it is), its revision and its title.
-}
ticketFactsIn :: T.Text -> O.Orville (Either LedgerFailure (T.Text, Maybe T.Text, Int, T.Text))
ticketFactsIn ticketId = do
  loaded <- loadTicket ticketId
  pure $ do
    (s, row, state, _) <- loaded
    let
      reason =
        case state of
          Blocked r _ -> Just r
          _ -> Nothing
    pure (ticketStateName state, reason, fromIntegral (Store.subjectRowRevision s), Store.ticketRowTitle row)

-- | The Ticket rebuilt from its events: its state and content revision.
replayTicket :: Store.SubjectRow -> Store.TicketRow -> [Store.EventRow] -> Either LedgerFailure (TicketState, Int)
replayTicket subject row events =
  case events of
    first : rest
      | Store.eventRowSequence first == 1
      , Just (TicketCreated _) <- decodeTicketEvent (Store.eventRowCommand first) -> do
          (state, content) <- foldM step (Proposed, 1) (L.zip [2 ..] rest)
          checkProjection subject (ticketStateName state) (L.length events)
          unless (content == fromIntegral (Store.ticketRowContentRevision row)) (integrity "a ticket's content revision does not match its events")
          pure (state, content)
    _ -> integrity "a ticket's first event is not its creation"
 where
  step (state, content) (n, event) = do
    unless (Store.eventRowSequence event == n) (integrity "a ticket's event sequence has a gap")
    principal <- maybe (integrity "an event principal is unreadable") Right (parsePrincipal (Store.eventRowPrincipal event))
    next <-
      case decodeTicketEvent (Store.eventRowCommand event) of
        Just (TicketRevised _) -> Right (state, content + 1)
        Just (TicketStep input) ->
          either (const (integrity "a stored ticket event does not replay")) (\s -> Right (s, content)) (stepTicket state (Command principal input))
        _ -> integrity "a stored ticket event is unreadable"
    unless (ticketStateName (fst next) == Store.eventRowStateAfter event) (integrity "a ticket event's recorded state does not replay")
    pure next

checkProjection :: Store.SubjectRow -> T.Text -> Int -> Either LedgerFailure ()
checkProjection subject state revision =
  unless
    (Store.subjectRowState subject == state && fromIntegral (Store.subjectRowRevision subject) == revision)
    (integrity "a stored projection differs from its replayed events")

loadTicket :: T.Text -> O.Orville (Either LedgerFailure (Store.SubjectRow, Store.TicketRow, TicketState, Int))
loadTicket ticketId = do
  subject <- Store.lockSubject ticketId
  row <- Store.findTicket ticketId
  case (subject, row) of
    (Just s, Just r) | Store.subjectRowKind s == T.pack "ticket" -> do
      events <- Store.subjectEvents ticketId
      pure (fmap (\(state, content) -> (s, r, state, content)) (replayTicket s r events))
    _ -> pure (refused (T.pack "unknown-ticket") "there is no such ticket")

showTicket :: DatabaseRuntime -> TicketId -> IO (Either LedgerFailure SubjectView)
showTicket runtime t =
  transaction runtime $ \_ -> do
    loaded <- loadTicket (tid t)
    pure $ do
      (s, _, state, content) <- loaded
      pure (SubjectView (fromIntegral (Store.subjectRowRevision s)) (ticketStateName state) content)

decideTicket :: DatabaseRuntime -> Faults -> TicketId -> Int -> Command TicketInput -> IO (Either LedgerFailure Receipt)
decideTicket runtime faults t expected command@(Command principal input) =
  transaction runtime $ \run -> do
    loaded <- loadTicket (tid t)
    case loaded of
      Left failure -> pure (Left failure)
      Right (s, _, state, _) -> do
        let
          refusal = Store.NewRefusal (tid t) (int32 expected) (principalName principal) (fromRight (ticketInputName input) (encodeTicketEvent (TicketStep input))) T.empty
          revision = fromIntegral (Store.subjectRowRevision s)
        if revision /= expected
          then refuseWith refusal (LedgerRefused (T.pack "stale-revision") (T.pack "the ticket has moved on; re-read it"))
          else case stepTicket state command of
            Left r -> refuseWith refusal (LedgerRefused (transitionRefusalCode r) (T.pack (show r)))
            Right next ->
              case encodeTicketEvent (TicketStep input) of
                Left reason -> refuseWith refusal (LedgerRefused (T.pack "not-durable") reason)
                Right text -> do
                  let
                    name = ticketStateName next
                  _ <- Store.insertEvent (tid t) (Store.EventRow (int32 (revision + 1)) (principalName principal) text name)
                  run (faultAfterEvent faults)
                  Store.updateSubject (tid t) (int32 (revision + 1)) name
                  pure (Right (Receipt (revision + 1) name []))

reviseTicket :: DatabaseRuntime -> TicketId -> Int -> T.Text -> IO (Either LedgerFailure Receipt)
reviseTicket runtime t expected title =
  transaction runtime $ \_ -> do
    loaded <- loadTicket (tid t)
    case loaded of
      Left failure -> pure (Left failure)
      Right (s, _, state, content) ->
        case encodeTicketEvent (TicketRevised title) of
          Left reason -> pure (Left (LedgerRefused (T.pack "not-durable") reason))
          Right text -> do
            let
              refusal = Store.NewRefusal (tid t) (int32 expected) (principalName Human) text T.empty
              revision = fromIntegral (Store.subjectRowRevision s)
              name = ticketStateName state
            if revision /= expected
              then refuseWith refusal (LedgerRefused (T.pack "stale-revision") (T.pack "the ticket has moved on; re-read it"))
              else
                if not (validTitle title)
                  then refuseWith refusal (LedgerRefused (T.pack "invalid-record") (T.pack "a title has 1 to 200 characters and no control characters"))
                  else do
                    _ <- Store.insertEvent (tid t) (Store.EventRow (int32 (revision + 1)) (principalName Human) text name)
                    Store.updateTicket (tid t) title (int32 (content + 1))
                    Store.updateSubject (tid t) (int32 (revision + 1)) name
                    pure (Right (Receipt (revision + 1) name []))

-- Work Orders ----------------------------------------------------------------

data NewWorkOrder
  = NewWorkOrder
  { newTicket :: TicketId
  , newEngineer :: T.Text
  , newKind :: WorkOrderKind
  , newPriority :: Int
  , newDependencies :: [WorkOrderId]
  , newClasses :: [T.Text]
  , newPathClasses :: [T.Text]
  , newNonBehavioural :: Maybe T.Text
  }
  deriving (Eq, Show)

-- | The approver of an operator's binding: the operator trusted by the local OS account (C-P1.3).
operatorApprover :: T.Text
operatorApprover =
  T.pack "operator"

kernelProfileRefusal :: Either ProfileFailure a -> Either LedgerFailure a
kernelProfileRefusal =
  either profileFailure Right
 where
  profileFailure failure =
    case failure of
      ProfileRefused code message _ -> Left (LedgerRefused code message)
      ProfileIntegrity message -> Left (LedgerIntegrity message)

-- | The work facts from their stored or requested names (C-P2.3 F6–F7).
factsFrom :: WorkOrderKind -> [T.Text] -> [T.Text] -> Maybe T.Text -> Either LedgerFailure (Behaviour, [T.Text], [T.Text])
factsFrom _ classes paths nonBehavioural = do
  _ <- maybe (refused (T.pack "invalid-facts") "not a valid class tag") Right (traverse mkClassTag classes)
  _ <- maybe (refused (T.pack "invalid-facts") "not a valid path class") Right (traverse parsePathClass paths)
  behaviour <-
    case nonBehavioural of
      Nothing -> Right BehaviourChanging
      Just rationale -> maybe (refused (T.pack "invalid-facts") "not a valid non-behavioural rationale") (Right . NonBehavioural) (mkNonBehaviouralBasis rationale operatorApprover)
  pure (behaviour, classes, paths)

resolveFor :: WorkOrderKind -> [T.Text] -> [T.Text] -> Maybe T.Text -> ProfileDefinition -> [ProfileDefinition] -> Either LedgerFailure EffectiveProfile
resolveFor kind classes paths nonBehavioural defaultDefinition catalog = do
  (behaviour, _, _) <- factsFrom kind classes paths nonBehavioural
  tags <- maybe (refused (T.pack "invalid-facts") "not a valid class tag") Right (traverse mkClassTag classes)
  pathClasses <- maybe (refused (T.pack "invalid-facts") "not a valid path class") Right (traverse parsePathClass paths)
  facts <- either kernel Right (mkWorkFacts Human kind tags pathClasses behaviour)
  either kernel Right (resolveProfile sha256Hasher (ResolutionInput defaultDefinition catalog [] facts))
 where
  kernel refusal =
    Left (LedgerRefused (profileRefusalCode refusal) (renderProfileRefusal refusal))

levelName :: LayerLevel -> Maybe T.Text
levelName level =
  T.pack
    <$> case level of
      LayerBaseline -> Just "baseline"
      LayerRepositoryDefault -> Just "repository-default"
      LayerSpecialization -> Just "specialization"
      LayerOverride -> Nothing

createWorkOrder :: DatabaseRuntime -> NewWorkOrder -> IO (Either LedgerFailure WorkOrderId)
createWorkOrder runtime request = do
  u <- newUuid
  transaction runtime $ \_ -> do
    loaded <- loadTicket (tid (newTicket request))
    case loaded of
      Left failure -> pure (Left failure)
      Right (_, _, ticketState, content)
        | ticketState /= Ready && ticketState /= InProgress ->
            pure (refused (T.pack "ticket-not-ready") "a work order needs a ready or in-progress ticket")
        | otherwise -> do
            owner <- Profiles.engineerRepository (newEngineer request)
            case owner of
              Nothing -> pure (refused (T.pack "unknown-engineer") "there is no Engineer with this name")
              Just (Profiles.EngineerRepository _ Nothing) -> pure (refused (T.pack "engineer-has-no-repository") "the Engineer owns no repository")
              Just (Profiles.EngineerRepository _ (Just repositoryId)) -> do
                defaultId <- Profiles.repositoryDefault repositoryId
                defaultRow <- maybe (pure Nothing) (`Profiles.findProfile` Nothing) defaultId
                catalogRows <- Profiles.latestProfiles
                dependencies <- traverse (Store.findWorkOrder . wid) (newDependencies request)
                now <- Store.databaseNow
                case decideCreation u defaultRow catalogRows dependencies of
                  Left failure -> pure (Left failure)
                  Right (effective, binding, sources) -> do
                    let
                      text = uuidText u
                      state = workOrderStateName Pending
                    Store.insertSubject text (T.pack "work-order") state
                    Store.insertWorkOrder
                      Store.WorkOrderRow
                        { Store.workOrderRowId = text
                        , Store.workOrderRowKind = workOrderKindName (newKind request)
                        , Store.workOrderRowTicket = tid (newTicket request)
                        , Store.workOrderRowTicketRevision = int32 content
                        , Store.workOrderRowRepository = repositoryId
                        , Store.workOrderRowPriority = int32 (newPriority request)
                        , Store.workOrderRowAdmittedAt = now
                        , Store.workOrderRowClasses = joinNames (newClasses request)
                        , Store.workOrderRowPathClasses = joinNames (newPathClasses request)
                        , Store.workOrderRowNonBehavioural = newNonBehavioural request
                        , Store.workOrderRowApprover = operatorApprover
                        , Store.workOrderRowEffectiveDigest = contentDigestText (effectiveDigest effective)
                        , Store.workOrderRowBindingDigest = contentDigestText (bindingDigest binding)
                        }
                    _ <- Store.insertEvent text (Store.EventRow 1 (principalName Human) createCommand state)
                    traverse_
                      (\(position, (level, ref)) -> Store.insertSource text position (Store.SourceRow level (profileIdText (refId ref)) (int32 (refVersion ref)) (contentDigestText (refDigest ref))))
                      (L.zip [1 ..] sources)
                    traverse_ (Store.insertDependency text . wid) (L.nub (newDependencies request))
                    pure (Right (WorkOrderId u))
 where
  decideCreation u defaultRow catalogRows dependencies = do
    row <- maybe (refused (T.pack "repository-default-profile-unset") "the repository has no default profile; see repository set-profile") Right defaultRow
    defaultDefinition <- kernelProfileRefusal (loadStoredDefinition row)
    catalog <- kernelProfileRefusal (traverse loadStoredDefinition catalogRows)
    _ <- either (\r -> Left (LedgerRefused (schedulerRefusalCode r) (T.pack (show r)))) Right (mkPriority Human (newPriority request))
    unless (L.all isJust dependencies) (refused (T.pack "unknown-dependency") "a dependency is not a known work order")
    effective <- resolveFor (newKind request) (newClasses request) (newPathClasses request) (newNonBehavioural request) defaultDefinition catalog
    binding <- bindingFor (WorkOrderId u) effective
    sources <- storedSources effective
    pure (effective, binding, sources)

createCommand :: T.Text
createCommand =
  fromRight (T.pack "create") (encodeWorkOrderEvent WorkOrderCreated)

bindingFor :: WorkOrderId -> EffectiveProfile -> Either LedgerFailure ProfileBinding
bindingFor w effective =
  either
    (\r -> Left (LedgerRefused (profileRefusalCode r) (renderProfileRefusal r)))
    Right
    (bindProfile sha256Hasher Human w operatorApprover effective [])

storedSources :: EffectiveProfile -> Either LedgerFailure [(T.Text, ProfileRef)]
storedSources effective =
  maybe
    (integrity "an effective profile has an override source; overrides are not durable in Phase 2")
    Right
    (traverse (\(level, ref) -> fmap (\l -> (l, ref)) (levelName level)) (effectiveSources effective))

joinNames :: [T.Text] -> T.Text
joinNames =
  T.intercalate (T.pack ",")

splitNames :: T.Text -> [T.Text]
splitNames text =
  if T.null text then [] else T.splitOn (T.pack ",") text

-- | A Work Order rebuilt from its events, with its claim-generation history.
replayWorkOrder :: Store.SubjectRow -> Store.WorkOrderRow -> [Store.EventRow] -> Either LedgerFailure (WorkOrder, [Int])
replayWorkOrder subject row events = do
  u <- uuidOf (Store.subjectRowId subject)
  kind <- maybe (integrity "a stored work order kind is unreadable") Right (parseWorkOrderKind (Store.workOrderRowKind row))
  case events of
    first : rest
      | Store.eventRowSequence first == 1
      , decodeWorkOrderEvent (Store.eventRowCommand first) == Just WorkOrderCreated -> do
          (order, generations) <- foldM step (newWorkOrder (WorkOrderId u) kind, []) (L.zip [2 ..] rest)
          checkProjection subject (workOrderStateName (workOrderState order)) (L.length events)
          pure (order, generations)
    _ -> integrity "a work order's first event is not its creation"
 where
  step (order, generations) (n, event) = do
    unless (Store.eventRowSequence event == n) (integrity "a work order's event sequence has a gap")
    principal <- maybe (integrity "an event principal is unreadable") Right (parsePrincipal (Store.eventRowPrincipal event))
    input <-
      case decodeWorkOrderEvent (Store.eventRowCommand event) of
        Just (WorkOrderStep i) -> Right i
        _ -> integrity "a stored work order event is unreadable"
    next <- either (const (integrity "a stored work order event does not replay")) Right (stepWorkOrder order (Command principal input))
    unless (workOrderStateName (workOrderState next) == Store.eventRowStateAfter event) (integrity "a work order event's recorded state does not replay")
    let
      claimed =
        case input of
          WoClaim c -> [claimGeneration c]
          _ -> []
    pure (next, generations <> claimed)

-- | The binding rebuilt from its stored sources; anything that does not reproduce is an integrity failure.
loadBinding :: WorkOrderId -> Store.WorkOrderRow -> O.Orville (Either LedgerFailure ProfileBinding)
loadBinding w row = do
  sources <- Store.sourcesOf (wid w)
  definitions <- traverse definitionFor sources
  pure $ do
    loaded <- sequenceA definitions
    kind <- maybe (integrity "a stored work order kind is unreadable") Right (parseWorkOrderKind (Store.workOrderRowKind row))
    defaultDefinition <-
      case [d | (level, d) <- loaded, level == T.pack "repository-default"] of
        [d] -> Right d
        _ -> integrity "a work order's profile sources have no single repository default"
    let
      specializations = [d | (level, d) <- loaded, level == T.pack "specialization"]
    effective <-
      either
        (const (integrity "a work order's bound profile no longer resolves"))
        Right
        (resolveFor kind (splitNames (Store.workOrderRowClasses row)) (splitNames (Store.workOrderRowPathClasses row)) (Store.workOrderRowNonBehavioural row) defaultDefinition specializations)
    stored <- storedSources effective
    unless
      (fmap (\(level, ref) -> (level, profileIdText (refId ref), refVersion ref, contentDigestText (refDigest ref))) stored == fmap sourceKey sources)
      (integrity "a work order's profile sources do not reproduce")
    unless (contentDigestText (effectiveDigest effective) == Store.workOrderRowEffectiveDigest row) (integrity "a work order's effective profile digest does not reproduce")
    binding <- either (const (integrity "a work order's binding does not reproduce")) Right (bindingFor w effective)
    unless (contentDigestText (bindingDigest binding) == Store.workOrderRowBindingDigest row) (integrity "a work order's binding digest does not reproduce")
    pure binding
 where
  sourceKey source =
    (Store.sourceRowLevel source, Store.sourceRowProfile source, fromIntegral (Store.sourceRowVersion source), Store.sourceRowDigest source)
  definitionFor source
    | Store.sourceRowLevel source == T.pack "baseline" = pure (checked source installationBaseline)
    | otherwise = do
        found <- Profiles.findProfile (Store.sourceRowProfile source) (Just (Store.sourceRowVersion source))
        pure $
          case found of
            Nothing -> integrity "a work order's bound profile version is missing"
            Just profileRow -> kernelProfileRefusal (loadStoredDefinition profileRow) >>= checked source
  checked source definition
    | contentDigestText (refDigest (profileRef sha256Hasher definition)) /= Store.sourceRowDigest source = integrity "a work order's profile source digest does not reproduce"
    | otherwise = Right (Store.sourceRowLevel source, definition)

data LoadedOrder
  = LoadedOrder
  { loadedSubject :: Store.SubjectRow
  , loadedRow :: Store.WorkOrderRow
  , loadedOrder :: WorkOrder
  , loadedGenerations :: [Int]
  , loadedBinding :: ProfileBinding
  }

loadWorkOrder :: Store.SubjectRow -> O.Orville (Either LedgerFailure LoadedOrder)
loadWorkOrder subject = do
  row <- Store.findWorkOrder (Store.subjectRowId subject)
  case row of
    Nothing -> pure (integrity "a work order subject has no work order row")
    Just r -> do
      events <- Store.subjectEvents (Store.subjectRowId subject)
      case replayWorkOrder subject r events of
        Left failure -> pure (Left failure)
        Right (order, generations) -> do
          binding <- loadBinding (workOrderId order) r
          pure (fmap (LoadedOrder subject r order generations) binding)

lockWorkOrder :: WorkOrderId -> O.Orville (Either LedgerFailure LoadedOrder)
lockWorkOrder w = do
  subject <- Store.lockSubject (wid w)
  case subject of
    Just s | Store.subjectRowKind s == T.pack "work-order" -> loadWorkOrder s
    _ -> pure (refused (T.pack "unknown-work-order") "there is no such work order")

data WorkOrderView
  = WorkOrderView
  { woRevision :: Int
  , woState :: WorkOrderState
  , woBindingDigest :: T.Text
  }
  deriving (Eq, Show)

showWorkOrder :: DatabaseRuntime -> WorkOrderId -> IO (Either LedgerFailure WorkOrderView)
showWorkOrder runtime w =
  transaction runtime $ \_ -> do
    loaded <- lockWorkOrder w
    pure $ do
      l <- loaded
      pure (WorkOrderView (fromIntegral (Store.subjectRowRevision (loadedSubject l))) (workOrderState (loadedOrder l)) (contentDigestText (bindingDigest (loadedBinding l))))

-- | E11: intents only with a Supervisor's start or resume.
intentsPermitted :: Command WorkOrderInput -> Bool
intentsPermitted (Command principal input) =
  principal == Supervisor
    && case input of
      WoStart _ -> True
      WoResume _ -> True
      _ -> False

decideWorkOrder :: DatabaseRuntime -> Faults -> WorkOrderId -> Int -> Command WorkOrderInput -> [IntentRequest] -> IO (Either LedgerFailure Receipt)
decideWorkOrder runtime faults w expected command@(Command principal input) requests = do
  operations <- traverse (const (fmap OperationId newUuid)) requests
  transaction runtime $ \run -> do
    loaded <- lockWorkOrder w
    case loaded of
      Left failure -> pure (Left failure)
      Right l -> do
        let
          refusal = Store.NewRefusal (wid w) (int32 expected) (principalName principal) (fromRight (workOrderInputName input) (encodeWorkOrderEvent (WorkOrderStep input))) T.empty
          revision = fromIntegral (Store.subjectRowRevision (loadedSubject l))
          decided = do
            when (revision /= expected) (refused (T.pack "stale-revision") "the work order has moved on; re-read it")
            unless (validReason input) (refused (T.pack "invalid-record") "a reason is 1-4096 characters without control characters")
            unless (L.null requests || intentsPermitted command) (refused (T.pack "intents-not-authorized") "only a Supervisor's start or resume may authorize effect intents")
            next <- either (\r -> Left (LedgerRefused (transitionRefusalCode r) (T.pack (show r)))) Right (stepWorkOrder (loadedOrder l) command)
            text <- either (Left . LedgerRefused (T.pack "not-durable")) Right (encodeWorkOrderEvent (WorkOrderStep input))
            intents <-
              either
                (\r -> Left (LedgerRefused (effectRefusalCode r) (T.pack (show r))))
                Right
                (newIntents sha256Hasher (SubjectWorkOrder w) expected (L.zip operations requests))
            pure (next, text, intents)
        case decided of
          Left failure -> refuseWith refusal failure
          Right (next, text, intents) -> do
            let
              name = workOrderStateName (workOrderState next)
            event <- Store.insertEvent (wid w) (Store.EventRow (int32 (revision + 1)) (principalName principal) text name)
            run (faultAfterEvent faults)
            Store.updateSubject (wid w) (int32 (revision + 1)) name
            case event of
              Nothing -> pure (integrity "the event insert returned no row")
              Just eventId -> do
                traverse_ (Store.insertIntent . (\i -> (newIntentRow eventId i) {Store.intentRowActivation = int32 (activationOf input)})) intents
                run (faultAfterIntents faults)
                pure (Right (Receipt (revision + 1) name (fmap intentOperation intents)))

-- | C-P2.9-R1 M2: the claim generation of the start or resume that authorizes intents.
activationOf :: WorkOrderInput -> Int
activationOf input =
  case input of
    WoStart c -> claimGeneration c
    WoResume c -> claimGeneration c
    _ -> 1

-- | C-P2.9-R1 M6 (finding 13): a halt or wait reason is one line of 1-4096 characters.
validReason :: WorkOrderInput -> Bool
validReason input =
  case input of
    WoHalt r -> validText r
    WoWait _ r -> validText r
    _ -> True

validText :: T.Text -> Bool
validText r =
  not (T.null r) && T.length r <= 4096 && not (T.any Char.isControl r)

-- Gate evidence ----------------------------------------------------------------

artifactName :: ArtifactKind -> T.Text
artifactName kind =
  T.pack $
    case kind of
      RequirementsBasis -> "requirements-basis"
      Reproduction -> "reproduction"
      ImpactAssessment -> "impact-assessment"
      ThreatModel -> "threat-model"
      ArchitectureAssessment -> "architecture-assessment"
      ClassificationRationale -> "classification-rationale"
      HumanApprovalRecord -> "human-approval"
      FrozenTests -> "frozen-tests"
      VerificationRecord -> "verification-record"
      ReviewRecord -> "review-record"
      RegressionEvidence -> "regression-evidence"
      IntegrationRecord -> "integration-record"
      Documentation -> "documentation"

verifierName :: VerifierKind -> T.Text
verifierName verifier =
  T.pack $
    case verifier of
      VerifyDigest -> "digest-check"
      VerifyCommand -> "deterministic-command"
      VerifyIndependentReview -> "independent-review"
      VerifyHumanInspection -> "human-inspection"

approvalName :: Approval -> T.Text
approvalName approval =
  T.pack $
    case approval of
      ApprovalNone -> "none"
      ApprovalSupervisor -> "supervisor"
      ApprovalHuman -> "human"

parseBy :: (Enum a, Bounded a) => (a -> T.Text) -> T.Text -> Maybe a
parseBy name text =
  L.find ((== text) . name) [minBound .. maxBound]

recordGateEvidence :: DatabaseRuntime -> Principal -> WorkOrderId -> GateEvidence -> IO (Either LedgerFailure ())
recordGateEvidence runtime principal w evidence
  | principal /= Human && principal /= Supervisor = pure (refused (T.pack "not-authorized") "only a human or the Supervisor records gate evidence")
  | otherwise =
      transaction runtime $ \_ -> do
        row <- Store.findWorkOrder (wid w)
        case row of
          Nothing -> pure (refused (T.pack "unknown-work-order") "there is no such work order")
          Just _ -> do
            Store.insertEvidence
              (wid w)
              (principalName principal)
              Store.EvidenceRow
                { Store.evidenceRowArtifact = artifactName (evidenceArtifact evidence)
                , Store.evidenceRowDigest = contentDigestText (evidenceDigest evidence)
                , Store.evidenceRowVerifiers = joinNames (fmap verifierName (L.sort (L.nub (evidenceVerifiedBy evidence))))
                , Store.evidenceRowApproval = approvalName (evidenceApproval evidence)
                }
            pure (Right ())

storedEvidence :: Store.EvidenceRow -> Either LedgerFailure GateEvidence
storedEvidence row = do
  artifact <- maybe unreadable Right (parseBy artifactName (Store.evidenceRowArtifact row))
  digest <- maybe unreadable Right (mkContentDigest (Store.evidenceRowDigest row))
  verifiers <- maybe unreadable Right (traverse (parseBy verifierName) (splitNames (Store.evidenceRowVerifiers row)))
  approval <- maybe unreadable Right (parseBy approvalName (Store.evidenceRowApproval row))
  pure (GateEvidence artifact digest verifiers approval)
 where
  unreadable = integrity "stored gate evidence is unreadable"

-- | Gate evidence from its names, as an operator gives them (C-P2.8 §5); a name that is not known is @invalid-evidence@.
gateEvidenceNamed :: T.Text -> T.Text -> [T.Text] -> T.Text -> Either LedgerFailure GateEvidence
gateEvidenceNamed artifact digest verifiers approval = do
  a <- maybe (bad "an unknown artifact") Right (parseBy artifactName artifact)
  d <- maybe (bad "a digest must be 64 lowercase hex characters") Right (mkContentDigest digest)
  vs <- maybe (bad "an unknown verifier") Right (traverse (parseBy verifierName) verifiers)
  ap <- maybe (bad "an unknown approval (none, supervisor or human)") Right (parseBy approvalName approval)
  pure (GateEvidence a d vs ap)
 where
  bad = refused (T.pack "invalid-evidence")

-- Scheduling -----------------------------------------------------------------

data ScheduleReceipt
  = ScheduleReceipt
  { scheduleRendering :: T.Text
  , scheduleDigestText :: T.Text
  , scheduleClaimed :: Maybe (WorkOrderId, Claim)
  }
  deriving (Eq, Show)

{- | E15: one scheduling decision over every Work Order, its commands, and
the claim of the selected order, in one transaction.
-}
scheduleOnce :: DatabaseRuntime -> IO (Either LedgerFailure ScheduleReceipt)
scheduleOnce runtime =
  transaction runtime $ \_ -> do
    Store.lockScheduling
    subjects <- Store.lockSubjectsOfKind (T.pack "work-order")
    loaded <- traverse loadWorkOrder subjects
    case sequenceA loaded of
      Left failure -> pure (Left failure)
      Right orders -> do
        owners <- Store.activeOwners
        defaults <- fmap catMaybes (traverse repositoryDefaultRow owners)
        catalogRows <- Profiles.latestProfiles
        extras <- traverse orderExtras orders
        case assemble orders owners defaults catalogRows extras of
          Left failure -> pure (Left failure)
          Right input ->
            case scheduleOrders input of
              Left r -> pure (Left (LedgerRefused (schedulerRefusalCode r) (T.pack (show r))))
              Right decision -> do
                applied <- foldM (applyCommand orders) (Right []) (schedulingCommands input decision)
                case applied of
                  Left failure -> pure (Left failure)
                  Right marked -> do
                    claimed <-
                      case decisionSelected decision of
                        Nothing -> pure (Right Nothing)
                        Just (w, engineer) -> claimSelected orders marked w engineer
                    case claimed of
                      Left failure -> pure (Left failure)
                      Right claim -> do
                        let
                          rendering = renderScheduleDecision decision
                          digest = contentDigestText (scheduleDigest sha256Hasher decision)
                        Store.insertScheduleDecision rendering digest (fmap (wid . fst) claim)
                        pure (Right (ScheduleReceipt rendering digest claim))

repositoryDefaultRow :: (T.Text, T.Text) -> O.Orville (Maybe (T.Text, Profiles.ProfileRow))
repositoryDefaultRow (repositoryId, _) = do
  profileId <- Profiles.repositoryDefault repositoryId
  row <- maybe (pure Nothing) (`Profiles.findProfile` Nothing) profileId
  pure (fmap (\r -> (repositoryId, r)) row)

orderExtras :: LoadedOrder -> O.Orville ([T.Text], [Store.EvidenceRow], Maybe Store.TicketRow)
orderExtras l = do
  dependencies <- Store.dependenciesOf (Store.subjectRowId (loadedSubject l))
  evidence <- Store.evidenceOf (Store.subjectRowId (loadedSubject l))
  ticket <- Store.findTicket (Store.workOrderRowTicket (loadedRow l))
  pure (dependencies, evidence, ticket)

-- | Every Work Order with its repository, priority and Ticket title, and the decision the Scheduler would make now.
data SchedulePreview
  = SchedulePreview
  { previewOrders :: [(WorkOrderId, T.Text, Int, T.Text)]
  , previewDecision :: ScheduleDecision
  }
  deriving (Eq, Show)

{- | C-P3.7 L6: the load and assembly of 'scheduleOnce' in a read-only
snapshot, then the C-P2.4 decision, with no lock, Scheduler command, claim or
decision row.
-}
previewSchedule :: DatabaseRuntime -> IO (Either LedgerFailure SchedulePreview)
previewSchedule runtime =
  transaction runtime $ \_ -> do
    Store.readOnlySnapshot
    subjects <- Store.subjectsOfKind (T.pack "work-order")
    loaded <- traverse loadWorkOrder subjects
    case sequenceA loaded of
      Left failure -> pure (Left failure)
      Right orders -> do
        owners <- Store.activeOwners
        defaults <- fmap catMaybes (traverse repositoryDefaultRow owners)
        catalogRows <- Profiles.latestProfiles
        extras <- traverse orderExtras orders
        pure $ do
          input <- assemble orders owners defaults catalogRows extras
          decision <- either (\r -> Left (LedgerRefused (schedulerRefusalCode r) (T.pack (show r)))) Right (scheduleOrders input)
          pure
            SchedulePreview
              { previewOrders =
                  [ (workOrderId (loadedOrder l), Store.workOrderRowRepository (loadedRow l), fromIntegral (Store.workOrderRowPriority (loadedRow l)), maybe T.empty Store.ticketRowTitle ticket)
                  | (l, (_, _, ticket)) <- L.zip orders extras
                  ]
              , previewDecision = decision
              }

-- | The C-P2.4 input from the loaded ledger. Phase 2 has no resources.
assemble :: [LoadedOrder] -> [(T.Text, T.Text)] -> [(T.Text, Profiles.ProfileRow)] -> [Profiles.ProfileRow] -> [([T.Text], [Store.EvidenceRow], Maybe Store.TicketRow)] -> Either LedgerFailure SchedulerInput
assemble orders owners defaults catalogRows extras = do
  scheduled <- traverse order (L.zip orders extras)
  ownerIds <- traverse (\(r, e) -> (,) <$> fmap RepositoryId (uuidOf r) <*> fmap EngineerId (uuidOf e)) owners
  defaultRefs <- traverse (\(r, row) -> (,) <$> fmap RepositoryId (uuidOf r) <*> fmap (profileRef sha256Hasher) (kernelProfileRefusal (loadStoredDefinition row))) defaults
  catalog <- traverse (fmap (profileRef sha256Hasher) . kernelProfileRefusal . loadStoredDefinition) catalogRows
  revisions <- traverse revision (L.nubBy (\a b -> fst a == fst b) [(Store.ticketRowId t, t) | (_, _, Just t) <- extras])
  pure
    SchedulerInput
      { inputOrders = scheduled
      , inputOwners = ownerIds
      , inputDefaults = defaultRefs
      , inputCatalog = catalog
      , inputResources = []
      , inputRevisions = revisions
      }
 where
  revision (ticketId, t) = do
    u <- uuidOf ticketId
    pure (TicketId u, fromIntegral (Store.ticketRowContentRevision t))
  order (l, (dependencies, evidence, _)) = do
    let
      row = loadedRow l
    repository <- fmap RepositoryId (uuidOf (Store.workOrderRowRepository row))
    priority <- either (const (integrity "a stored priority is invalid")) Right (mkPriority Human (fromIntegral (Store.workOrderRowPriority row)))
    dependencyIds <- traverse (fmap WorkOrderId . uuidOf) dependencies
    gateEvidence <- traverse storedEvidence evidence
    ticket <- fmap TicketId (uuidOf (Store.workOrderRowTicket row))
    pure
      ScheduledOrder
        { orderWorkOrder = loadedOrder l
        , orderRepository = repository
        , orderPriority = priority
        , orderAdmittedAt = Store.workOrderRowAdmittedAt row
        , orderDependencies = dependencyIds
        , orderBinding = loadedBinding l
        , orderConfirmations = []
        , orderEvidence = gateEvidence
        , orderResources = []
        , orderSource = SourceBasis ticket (fromIntegral (Store.workOrderRowTicketRevision row))
        }

-- | Appends one Scheduler command to its order; returns the orders changed so far, with their new state.
applyCommand :: [LoadedOrder] -> Either LedgerFailure [(WorkOrderId, (Int, WorkOrder))] -> (WorkOrderId, Command WorkOrderInput) -> O.Orville (Either LedgerFailure [(WorkOrderId, (Int, WorkOrder))])
applyCommand orders acc (w, command@(Command principal input)) =
  case acc of
    Left failure -> pure (Left failure)
    Right done ->
      case L.find ((== w) . workOrderId . loadedOrder) orders of
        Nothing -> pure (integrity "the scheduler commanded an unknown order")
        Just l -> do
          let
            revision = fromIntegral (Store.subjectRowRevision (loadedSubject l))
          case (stepWorkOrder (loadedOrder l) command, encodeWorkOrderEvent (WorkOrderStep input)) of
            (Right next, Right text) -> do
              appendStep w (revision + 1) principal text next
              pure (Right ((w, (revision + 1, next)) : done))
            _ -> pure (integrity "a scheduler command was refused by the lifecycle")

appendStep :: WorkOrderId -> Int -> Principal -> T.Text -> WorkOrder -> O.Orville ()
appendStep w revision principal text next = do
  let
    name = workOrderStateName (workOrderState next)
  _ <- Store.insertEvent (wid w) (Store.EventRow (int32 revision) (principalName principal) text name)
  Store.updateSubject (wid w) (int32 revision) name

-- | The selected order's claim: the next generation it has ever had.
claimSelected :: [LoadedOrder] -> [(WorkOrderId, (Int, WorkOrder))] -> WorkOrderId -> EngineerId -> O.Orville (Either LedgerFailure (Maybe (WorkOrderId, Claim)))
claimSelected orders marked w engineer =
  case L.find ((== w) . workOrderId . loadedOrder) orders of
    Nothing -> pure (integrity "the scheduler selected an unknown order")
    Just l -> do
      let
        (revision, current) =
          fromMaybe (fromIntegral (Store.subjectRowRevision (loadedSubject l)), loadedOrder l) (L.lookup w marked)
        claim = Claim engineer (1 + L.foldl' max 0 (loadedGenerations l))
        input = WoClaim claim
      case (stepWorkOrder current (Command Scheduler input), encodeWorkOrderEvent (WorkOrderStep input)) of
        (Right next, Right text) -> do
          appendStep w (revision + 1) Scheduler text next
          pure (Right (Just (w, claim)))
        _ -> pure (integrity "the scheduler's claim was refused by the lifecycle")

-- Work Units -------------------------------------------------------------------

admitWorkUnit :: DatabaseRuntime -> WorkOrderId -> Maybe T.Text -> IO (Either LedgerFailure WorkUnitId)
admitWorkUnit runtime w planRef = do
  u <- newUuid
  transaction runtime $ \_ -> do
    loaded <- lockWorkOrder w
    owners <- Store.activeOwners
    case loaded of
      Left failure -> pure (Left failure)
      Right l -> do
        let
          row = loadedRow l
          decided = do
            case workOrderState (loadedOrder l) of
              Claimed _ -> Right ()
              Active _ -> Right ()
              _ -> refused (T.pack "work-order-not-active") "a work unit is admitted only for a claimed or active work order"
            ownerships <- traverse (\(r, e) -> Ownership <$> fmap RepositoryId (uuidOf r) <*> fmap EngineerId (uuidOf e)) owners
            repository <- fmap RepositoryId (uuidOf (Store.workOrderRowRepository row))
            ticket <- fmap TicketId (uuidOf (Store.workOrderRowTicket row))
            plan <- traverse planReference planRef
            either
              (const (refused (T.pack "repository-not-owned") "the work order's repository has no active owner"))
              Right
              (admitWorkUnit' ownerships (WorkUnit.WorkUnitRequest (WorkUnitId u) repository ticket w plan))
        case decided of
          Left failure -> pure (Left failure)
          Right admitted -> do
            Store.insertWorkUnit (uuidText u) (wid w) (Store.workOrderRowTicket row) (Store.workOrderRowRepository row) (engineerText admitted) planRef
            pure (Right (WorkUnitId u))

planReference :: T.Text -> Either LedgerFailure WorkUnit.PlanRef
planReference p =
  maybe (refused (T.pack "invalid-record") "a plan reference has 1 to 200 characters and no control characters") Right (WorkUnit.mkPlanRef p)

admitWorkUnit' :: [Ownership] -> WorkUnit.WorkUnitRequest -> Either WorkUnit.WorkUnitRefusal WorkUnit.AdmittedWorkUnit
admitWorkUnit' =
  WorkUnit.admitWorkUnit

engineerText :: WorkUnit.AdmittedWorkUnit -> T.Text
engineerText admitted =
  case WorkUnit.admittedEngineer admitted of
    EngineerId u -> uuidText u

-- Intents --------------------------------------------------------------------

termsColumns :: ClassTerms -> (Maybe Int64, Maybe Bool, Maybe Bool, Maybe Bool)
termsColumns terms =
  case terms of
    TermsRepeatable -> (Nothing, Nothing, Nothing, Nothing)
    TermsIdempotent i -> (Just (fromInteger (keyLifetimeSeconds i)), Just (refusesChangedParameters i), Nothing, Nothing)
    TermsQueryable l -> (Nothing, Nothing, Just (lookupAuthoritative l), Just (lookupExcludesLateApplication l))
    TermsUnqueryable -> (Nothing, Nothing, Nothing, Nothing)

subjectColumns :: SubjectRef -> T.Text
subjectColumns subject =
  case subject of
    SubjectTicket t -> tid t
    SubjectWorkOrder w -> wid w

newIntentRow :: Int64 -> Intent -> Store.IntentRow
newIntentRow eventId intent =
  let
    spec = intentSpec intent
    (lifetime, refuses, authoritative, excludesLate) = termsColumns (effectSpecTerms spec)
  in
    lifecycleColumns
      intent
      Store.IntentRow
        { Store.intentRowOperation = oid (intentOperation intent)
        , Store.intentRowSubject = subjectColumns (intentSubject intent)
        , Store.intentRowSubjectKind = T.empty
        , Store.intentRowBasisRevision = int32 (intentBasisRevision intent)
        , Store.intentRowKey = effectKeyText (intentKey intent)
        , Store.intentRowEvent = eventId
        , Store.intentRowSpecName = effectSpecName spec
        , Store.intentRowClass = effectClassName (effectSpecClass spec)
        , Store.intentRowBudget = int32 (effectSpecBudget spec)
        , Store.intentRowKeyLifetime = lifetime
        , Store.intentRowRefusesChanged = refuses
        , Store.intentRowLookupAuthoritative = authoritative
        , Store.intentRowLookupExcludesLate = excludesLate
        , Store.intentRowParameters = intentParameters intent
        , Store.intentRowParametersDigest = contentDigestText (intentParametersDigest intent)
        , Store.intentRowState = T.empty
        , Store.intentRowGeneration = 0
        , Store.intentRowDispatches = 0
        , Store.intentRowLeaseOwner = Nothing
        , Store.intentRowLeaseUntil = Nothing
        , Store.intentRowOutcome = Nothing
        , Store.intentRowSettledApplied = Nothing
        , Store.intentRowActivation = 1
        , Store.intentRowFirstDispatched = Nothing
        }

-- | The row's lifecycle columns from the intent.
lifecycleColumns :: Intent -> Store.IntentRow -> Store.IntentRow
lifecycleColumns intent row =
  let
    (lease, outcome, settled) =
      case intentState intent of
        IntentPending -> (Nothing, Nothing, Nothing)
        IntentClaimed l -> (Just l, Nothing, Nothing)
        IntentDispatched l -> (Just l, Nothing, Nothing)
        IntentApplied r -> (Nothing, Just r, Nothing)
        IntentNotApplied r -> (Nothing, Just r, Nothing)
        IntentUnknown r -> (Nothing, Just r, Nothing)
        IntentSettled (SettledApplied r) -> (Nothing, Just r, Just True)
        IntentSettled (SettledNotApplied r) -> (Nothing, Just r, Just False)
        IntentAbandoned r -> (Nothing, Just r, Nothing)
  in
    row
      { Store.intentRowState = intentStateName (intentState intent)
      , Store.intentRowGeneration = int32 (intentGeneration intent)
      , Store.intentRowDispatches = int32 (intentDispatches intent)
      , Store.intentRowLeaseOwner = fmap leaseOwner lease
      , Store.intentRowLeaseUntil = fmap leaseUntil lease
      , Store.intentRowOutcome = outcome
      , Store.intentRowSettledApplied = settled
      }

-- | The intent rebuilt from its row; anything that does not reproduce is an integrity failure.
restoreIntent :: Store.IntentRow -> Either LedgerFailure Intent
restoreIntent row = do
  operation <- fmap OperationId (uuidOf (Store.intentRowOperation row))
  subjectId <- uuidOf (Store.intentRowSubject row)
  subject <-
    case T.unpack (Store.intentRowSubjectKind row) of
      "ticket" -> Right (SubjectTicket (TicketId subjectId))
      "work-order" -> Right (SubjectWorkOrder (WorkOrderId subjectId))
      _ -> unreadable
  key <- either (const unreadable) Right (mkEffectKey (Store.intentRowKey row))
  terms <-
    case (T.unpack (Store.intentRowClass row), Store.intentRowKeyLifetime row, Store.intentRowRefusesChanged row, Store.intentRowLookupAuthoritative row, Store.intentRowLookupExcludesLate row) of
      ("repeatable", Nothing, _, Nothing, _) -> Right TermsRepeatable
      ("idempotent", Just lifetime, Just refuses, Nothing, _) -> Right (TermsIdempotent (IdempotencyTerms (toInteger lifetime) refuses))
      ("queryable", Nothing, _, Just a, Just b) -> Right (TermsQueryable (LookupTerms a b))
      ("unqueryable", Nothing, _, Nothing, _) -> Right TermsUnqueryable
      _ -> unreadable
  spec <- either (const unreadable) Right (mkEffectSpec (Store.intentRowSpecName row) terms (fromIntegral (Store.intentRowBudget row)))
  digest <- maybe unreadable Right (mkContentDigest (Store.intentRowParametersDigest row))
  unless (digest == hashed (Store.intentRowParameters row)) (integrity "an intent's parameters do not match their digest")
  let
    generation = fromIntegral (Store.intentRowGeneration row)
    lease = Lease <$> Store.intentRowLeaseOwner row <*> Just generation <*> Store.intentRowLeaseUntil row
    outcome = Store.intentRowOutcome row
  state <-
    case (T.unpack (Store.intentRowState row), lease, outcome, Store.intentRowSettledApplied row) of
      ("pending", Nothing, Nothing, Nothing) -> Right IntentPending
      ("claimed", Just l, Nothing, Nothing) -> Right (IntentClaimed l)
      ("dispatched", Just l, Nothing, Nothing) -> Right (IntentDispatched l)
      ("confirmed-applied", Nothing, Just r, Nothing) -> Right (IntentApplied r)
      ("confirmed-not-applied", Nothing, Just r, Nothing) -> Right (IntentNotApplied r)
      ("outcome-unknown", Nothing, Just r, Nothing) -> Right (IntentUnknown r)
      ("settled", Nothing, Just r, Just True) -> Right (IntentSettled (SettledApplied r))
      ("settled", Nothing, Just r, Just False) -> Right (IntentSettled (SettledNotApplied r))
      ("abandoned", Nothing, Just r, Nothing) -> Right (IntentAbandoned r)
      _ -> unreadable
  pure
    Intent
      { intentOperation = operation
      , intentSubject = subject
      , intentBasisRevision = fromIntegral (Store.intentRowBasisRevision row)
      , intentKey = key
      , intentSpec = spec
      , intentParameters = Store.intentRowParameters row
      , intentParametersDigest = digest
      , intentState = state
      , intentGeneration = generation
      , intentDispatches = fromIntegral (Store.intentRowDispatches row)
      }
 where
  unreadable = integrity "a stored intent is unreadable"
  hashed =
    case sha256Hasher of
      Hasher f -> f

lockedIntent :: OperationId -> O.Orville (Either LedgerFailure (Store.IntentRow, Intent))
lockedIntent operation = do
  row <- Store.lockIntent (oid operation)
  pure $
    case row of
      Nothing -> refused (T.pack "unknown-intent") "there is no such effect intent"
      Just r -> fmap (\i -> (r, i)) (restoreIntent r)

-- | One Kernel step on a locked intent, written back when accepted.
stepStored :: OperationId -> (UTCTime -> Command IntentInput) -> O.Orville (Either LedgerFailure Intent)
stepStored operation command = do
  locked <- lockedIntent operation
  case locked of
    Left failure -> pure (Left failure)
    Right (row, intent) -> do
      now <- Store.databaseNow
      case stepIntent intent (command now) of
        Left r -> pure (Left (effectRefused r))
        Right next -> do
          Store.updateIntent (lifecycleColumns next row)
          pure (Right next)

effectRefused :: EffectRefusal -> LedgerFailure
effectRefused r =
  LedgerRefused (effectRefusalCode r) (T.pack (show r))

loadIntent :: DatabaseRuntime -> OperationId -> IO (Either LedgerFailure Intent)
loadIntent runtime operation =
  transaction runtime $ \_ -> fmap (fmap snd) (lockedIntent operation)

{- | 'claimIntent', 'dispatchIntent', 'observeIntent' and 'settleIntent' are
the C-P2.5 single steps. They do not check the order's state, the activation
or the key guarantee, so they are a test-level API with no product caller
(C-P2.9-R1 §4.2 N7). The executor uses 'claimForExecution',
'beginDispatchLeased' and 'concludeIntent'.
-}
claimIntent :: DatabaseRuntime -> T.Text -> Int -> OperationId -> IO (Either LedgerFailure Intent)
claimIntent runtime owner seconds operation
  | seconds < 1 || seconds > 3600 = pure (refused (T.pack "invalid-record") "a lease lasts 1 to 3600 seconds")
  | T.null owner || T.any Char.isControl owner = pure (refused (T.pack "invalid-record") "a claim needs an owner")
  | otherwise =
      transaction runtime $ \_ ->
        stepStored operation (\now -> Command Supervisor (IntentClaim owner now (addUTCTime (fromIntegral seconds) now)))

dispatchIntent :: DatabaseRuntime -> OperationId -> Int -> IO (Either LedgerFailure Intent)
dispatchIntent runtime operation generation =
  transaction runtime $ \_ ->
    stepStored operation (Command Supervisor . IntentDispatch generation)

-- | E4: a stale observation is refused for the state but stored as evidence.
observeIntent :: DatabaseRuntime -> OperationId -> Int -> Observation -> IO (Either LedgerFailure Intent)
observeIntent runtime operation generation observation =
  transaction runtime $ \_ -> do
    result <- stepStored operation (const (Command Supervisor (IntentObserve generation observation)))
    case result of
      Right intent -> do
        Store.insertObservation (oid operation) (int32 generation) (observationText observation) Nothing
        pure (Right intent)
      Left failure@(LedgerRefused code _)
        | code == effectRefusalCode StaleClaim -> do
            Store.insertObservation (oid operation) (int32 generation) (observationText observation) (Just code)
            pure (Left failure)
      Left failure -> pure (Left failure)

observationText :: Observation -> T.Text
observationText observation =
  case observation of
    DestinationApplied result -> field "applied result" result
    DestinationNotApplied reason -> field "not-applied reason" reason
    NoAnswer reason -> field "no-answer reason" reason
 where
  field key value =
    T.pack (key <> "=\"") <> T.concatMap escape value <> T.pack "\""
  escape c =
    case c of
      '\\' -> T.pack "\\\\"
      '"' -> T.pack "\\\""
      _ -> T.singleton c

settleIntent :: DatabaseRuntime -> OperationId -> Int -> IO (Either LedgerFailure Intent)
settleIntent runtime operation generation =
  transaction runtime $ \_ ->
    stepStored operation (const (Command Supervisor (IntentSettle generation)))

{- | DG-04 D-4.6 (C-P2.9-R1 M4): a Human abandons the intent, the decision is
recorded, and its Work Order halts, in one transaction.
-}
abandonIntent :: DatabaseRuntime -> OperationId -> T.Text -> IO (Either LedgerFailure Intent)
abandonIntent runtime operation reason =
  abandonIntentAcknowledged runtime operation reason False

{- | The abandonment with the Human's duplication-risk acknowledgment, which is
recorded (C-P2.9-R1 §4.7 F1). An abandoned intent that was dispatched still
counts as live for its effect key until its abandonment is acknowledged: the
earlier dispatch may have applied.
-}
abandonIntentAcknowledged :: DatabaseRuntime -> OperationId -> T.Text -> Bool -> IO (Either LedgerFailure Intent)
abandonIntentAcknowledged runtime operation reason acknowledged
  | not (validText reason) = pure (refused (T.pack "invalid-record") "a reason is 1-4096 characters without control characters")
  | otherwise =
      transaction runtime $ \_ -> do
        locked <- lockForExecution operation
        case locked of
          Left failure -> pure (Left failure)
          Right (l, row, intent) ->
            case stepIntent intent (Command Human (IntentAbandon reason)) of
              Left r -> pure (Left (effectRefused r))
              Right next -> do
                Store.updateIntent (lifecycleColumns next row)
                Store.insertResolution (oid operation) (int32 (intentGeneration intent)) (T.pack "human-abandon") (T.pack "abandoned reason=" <> quotedText reason) acknowledged
                haltForIntentBy Human l (T.pack "abandoned") operation
                pure (Right next)

quotedText :: T.Text -> T.Text
quotedText text =
  T.pack "\"" <> T.concatMap escape text <> T.pack "\""
 where
  escape c =
    case c of
      '\\' -> T.pack "\\\\"
      '"' -> T.pack "\\\""
      _ -> T.singleton c

data StoredObservation
  = StoredObservation
  { storedGeneration :: Int
  , storedObservation :: T.Text
  , storedAccepted :: Bool
  , storedRefusal :: Maybe T.Text
  }
  deriving (Eq, Show)

intentObservations :: DatabaseRuntime -> OperationId -> IO (Either LedgerFailure [StoredObservation])
intentObservations runtime operation =
  transaction runtime $ \_ -> do
    rows <- Store.observationsOf (oid operation)
    pure
      ( Right
          [ StoredObservation (fromIntegral (Store.observationRowGeneration r)) (Store.observationRowText r) (Store.observationRowAccepted r) (Store.observationRowRefusal r)
          | r <- rows
          ]
      )

-- Execution (C-P2.6) -----------------------------------------------------------

{- | Locks the intent's Work Order, then the intent: the lock order of every
C-P2.6 write, so no two of them (nor a decision on the order) can deadlock.
-}
lockForExecution :: OperationId -> O.Orville (Either LedgerFailure (LoadedOrder, Store.IntentRow, Intent))
lockForExecution operation = do
  subject <- Store.intentSubject (oid operation)
  case subject of
    Nothing -> pure (refused (T.pack "unknown-intent") "there is no such effect intent")
    Just s ->
      case uuidOf s of
        Left failure -> pure (Left failure)
        Right u -> do
          loaded <- lockWorkOrder (WorkOrderId u)
          case loaded of
            Left failure -> pure (Left failure)
            Right l -> fmap (fmap (\(row, intent) -> (l, row, intent))) (lockedIntent operation)

orderActive :: LoadedOrder -> Bool
orderActive l =
  case workOrderState (loadedOrder l) of
    Active _ -> True
    _ -> False

-- | C-P2.9-R1 M2: the claim generation of the order's current activation, if it is active.
currentActivation :: LoadedOrder -> Maybe Int
currentActivation l =
  case workOrderState (loadedOrder l) of
    Active c -> Just (claimGeneration c)
    _ -> Nothing

-- | The intent may run only for an active order, under the activation that authorized it.
runsHere :: LoadedOrder -> Store.IntentRow -> Bool
runsHere l row =
  currentActivation l == Just (fromIntegral (Store.intentRowActivation row))

{- | X5 steps (2) and (3): the C-P2.5 step decides; an accepted one for an
order that is not active is refused, and so is one for an intent of an earlier
activation (C-P2.9-R1 M2), with nothing written. The step's time is the
database clock (C-P2.9-R1 M6); a dispatch with a lease length renews the lease
from it. A dispatch of an idempotent intent that was dispatched before needs
its key guarantee (C-P2.9-R1 §4.2 N1): without it the intent's outcome becomes
unknown, the order halts, and the dispatch is refused, so nothing is sent.
-}
stepForActive :: OperationId -> Maybe Int -> (UTCTime -> Command IntentInput) -> O.Orville (Either LedgerFailure Intent)
stepForActive operation renew command = do
  locked <- lockForExecution operation
  case locked of
    Left failure -> pure (Left failure)
    Right (l, row, intent) -> do
      now <- Store.databaseClock
      holders <- liveSameKey row
      case stepIntent intent (command now) of
        Left r -> pure (Left (effectRefused r))
        Right next
          | not (orderActive l) -> pure (refused (T.pack "subject-not-active") "the work order is not active; nothing may be dispatched for it")
          | not (runsHere l row) -> pure (refused (T.pack "activation-superseded") "the intent belongs to an earlier activation of its work order; a Human must carry it first")
          | isDispatch next && intentDispatches intent >= 1 && not (idempotencyHolds (Store.intentRowFirstDispatched row) now intent) -> do
              Store.updateIntent (lifecycleColumns intent {intentState = IntentUnknown keyExpiredReason} row)
              haltForIntent l (T.pack "outcome-unknown") operation
              pure (refused (T.pack "idempotency-key-expired") "the idempotency key's guarantee has ended; the earlier dispatch may still apply, so nothing was sent")
          -- §4.5 P1: one logical effect, one live intent; neither claimed nor dispatched beside another.
          | not (L.null holders) -> do
              haltForIntent l (T.pack "effect-key-in-use") operation
              pure
                ( refused
                    (T.pack "effect-key-in-use")
                    ( "the same effect key is held by "
                        <> T.unpack (T.intercalate (T.pack ", ") (fmap Store.intentRowOperation holders))
                        <> "; abandon one (with --acknowledge-duplication-risk if it was dispatched), requeue without declaring the key again, and carry the other"
                    )
                )
          | otherwise -> do
              let
                renewed =
                  case (renew, intentState next) of
                    (Just seconds, IntentDispatched lease) -> next {intentState = IntentDispatched lease {leaseUntil = addUTCTime (fromIntegral seconds) now}}
                    _ -> next
              Store.updateIntent (lifecycleColumns renewed row)
              pure (Right renewed)
 where
  isDispatch next =
    case intentState next of
      IntentDispatched _ -> True
      _ -> False

keyExpiredReason :: T.Text
keyExpiredReason =
  T.pack "dispatch-interrupted: idempotency key may have expired"

{- | §4.5 P1, §4.7 F1: the other intents of the order that hold the intent's
effect key. That is any one not settled as not applied, except an abandoned
one that was never dispatched or whose abandonment acknowledged the
duplication risk. A dispatched intent may have applied even after it is
abandoned.
-}
liveSameKey :: Store.IntentRow -> O.Orville [Store.IntentRow]
liveSameKey row = do
  siblings <- Store.intentsOfSubject (Store.intentRowSubject row)
  filterM holds (L.filter same siblings)
 where
  same s =
    Store.intentRowOperation s /= Store.intentRowOperation row
      && Store.intentRowKey s == Store.intentRowKey row
      && Store.intentRowSettledApplied s /= Just False
  holds s
    | Store.intentRowState s /= intentStateName (IntentAbandoned T.empty) = pure True
    | Store.intentRowDispatches s < 1 = pure False
    | otherwise = do
        resolutions <- Store.resolutionsOf (Store.intentRowOperation s)
        pure (not (L.any (\r -> Store.resolutionRowBasis r == T.pack "human-abandon" && Store.resolutionRowAcknowledged r) resolutions))

claimForExecution :: DatabaseRuntime -> T.Text -> Int -> OperationId -> IO (Either LedgerFailure Intent)
claimForExecution runtime owner seconds operation
  | seconds < 1 || seconds > 3600 = pure (refused (T.pack "invalid-record") "a lease lasts 1 to 3600 seconds")
  | T.null owner || T.any Char.isControl owner = pure (refused (T.pack "invalid-record") "a claim needs an owner")
  | otherwise =
      transaction runtime $ \_ ->
        stepForActive operation Nothing (\now -> Command Supervisor (IntentClaim owner now (addUTCTime (fromIntegral seconds) now)))

-- | X5 step (3): the dispatch marker, committed before the adapter runs.
beginDispatch :: DatabaseRuntime -> OperationId -> Int -> IO (Either LedgerFailure Intent)
beginDispatch runtime operation generation =
  transaction runtime $ \_ ->
    stepForActive operation Nothing (Command Supervisor . IntentDispatch generation)

-- | C-P2.9-R1 M6: the dispatch marker with the lease renewed for the given seconds.
beginDispatchLeased :: DatabaseRuntime -> OperationId -> Int -> Int -> IO (Either LedgerFailure Intent)
beginDispatchLeased runtime operation generation seconds =
  transaction runtime $ \_ ->
    stepForActive operation (Just seconds) (Command Supervisor . IntentDispatch generation)

-- | X6: a halt of the order by the Supervisor, when its lifecycle accepts one.
haltForIntent :: LoadedOrder -> T.Text -> OperationId -> O.Orville ()
haltForIntent =
  haltForIntentBy Supervisor

-- | The halt as the given principal's event (a Human's abandonment, C-P2.9-R1 §4.2 N8).
haltForIntentBy :: Principal -> LoadedOrder -> T.Text -> OperationId -> O.Orville ()
haltForIntentBy principal l code operation = do
  let
    order = loadedOrder l
    input = WoHalt (code <> T.pack " operation=" <> oid operation)
    revision = fromIntegral (Store.subjectRowRevision (loadedSubject l))
  case (stepWorkOrder order (Command principal input), encodeWorkOrderEvent (WorkOrderStep input)) of
    (Right next, Right text) -> appendStep (workOrderId order) (revision + 1) principal text next
    _ -> pure ()

{- | X6: stores the observation (a refused one as evidence, checked for a
late-application conflict by C-P2.7 R7), then settles an applied one, keeps a
not-applied one claimable while a retry is left, and halts the order on an
unknown outcome or an exhausted budget.
-}
concludeIntent :: DatabaseRuntime -> OperationId -> Int -> Observation -> IO (Either LedgerFailure Intent)
concludeIntent runtime operation generation observation =
  transaction runtime $ \_ -> do
    locked <- lockForExecution operation
    case locked of
      Left failure -> pure (Left failure)
      Right (l, row, intent) ->
        case stepIntent intent (Command Supervisor (IntentObserve generation observation)) of
          Left r -> do
            Store.insertObservation (oid operation) (int32 generation) (observationText observation) (Just (effectRefusalCode r))
            lateConflict l row intent operation generation observation
            pure (Left (effectRefused r))
          Right observed -> do
            Store.insertObservation (oid operation) (int32 generation) (observationText observation) Nothing
            let
              exhausted = intentDispatches observed > effectSpecBudget (intentSpec observed)
              settle = stepIntent observed (Command Supervisor (IntentSettle generation))
            final <-
              case intentState observed of
                IntentApplied _ -> pure settle
                IntentNotApplied _
                  | exhausted -> do
                      haltForIntent l (T.pack "retries-exhausted") operation
                      pure settle
                IntentUnknown _ -> do
                  haltForIntent l (T.pack "outcome-unknown") operation
                  pure (Right observed)
                _ -> pure (Right observed)
            case final of
              -- C-P2.9-R1 §4.2 N5: the observation is written, so a refused settle rolls back.
              Left r -> pure (integrity ("an observed intent could not be settled: " <> show r))
              Right next -> do
                Store.updateIntent (lifecycleColumns next row)
                pure (Right next)

-- | X8: the Kernel's recovery, written with its record; an unknown result halts the order.
recoverDispatched :: DatabaseRuntime -> T.Text -> Int -> OperationId -> IO (Either LedgerFailure Intent)
recoverDispatched runtime owner seconds operation
  | seconds < 1 || seconds > 3600 = pure (refused (T.pack "invalid-record") "a lease lasts 1 to 3600 seconds")
  | T.null owner || T.any Char.isControl owner = pure (refused (T.pack "invalid-record") "a recovery needs an owner")
  | otherwise =
      transaction runtime $ \_ -> do
        locked <- lockForExecution operation
        case locked of
          Left failure -> pure (Left failure)
          Right (l, row, intent) -> do
            now <- Store.databaseClock
            let
              -- C-P2.9-R1 M2: an earlier activation's intent is never re-dispatched.
              input = RecoveryInput owner now (addUTCTime (fromIntegral seconds) now) (orderActive l && runsHere l row)
              -- C-P2.9-R1 M1: nor an idempotent one whose key guarantee no longer holds.
              superseded = orderActive l && not (runsHere l row)
              guarded r =
                case r of
                  RecoverRedispatch _
                    | not (idempotencyHolds (Store.intentRowFirstDispatched row) now intent) ->
                        RecoverUnknown intent {intentState = IntentUnknown keyExpiredReason}
                  -- §4.2 N6: the order is active, under a later activation.
                  RecoverUnknown _
                    | superseded -> RecoverUnknown intent {intentState = IntentUnknown (T.pack "dispatch-interrupted: activation superseded")}
                  _ -> r
            case guarded <$> recoverIntent intent (Command Supervisor input) of
              Left r -> pure (Left (LedgerRefused (recoveryRefusalCode r) (T.pack (show r))))
              Right recovery -> do
                let
                  next = recoveryIntent recovery
                Store.updateIntent (lifecycleColumns next row)
                Store.insertRecovery (oid operation) (int32 (intentGeneration intent)) (renderRecovery recovery)
                case recovery of
                  -- N6: the current activation is not halted for an earlier one's intent.
                  RecoverUnknown _ | not superseded -> haltForIntent l (T.pack "outcome-unknown") operation
                  _ -> pure ()
                pure (Right next)

operationsFrom :: [T.Text] -> Either LedgerFailure [OperationId]
operationsFrom =
  traverse (fmap OperationId . uuidOf)

-- | X10, without the intents of an earlier activation (C-P2.9-R1 M2).
runnableIntents :: DatabaseRuntime -> IO (Either LedgerFailure [OperationId])
runnableIntents runtime =
  transaction runtime $ \_ -> do
    candidates <- Store.runnableIntentIds
    kept <- filterM current candidates
    pure (operationsFrom kept)
 where
  current operation = do
    rows <- Store.findIntent operation
    case rows of
      Just row -> do
        subject <- Store.subjectRow (Store.intentRowSubject row)
        case subject of
          Nothing -> pure False
          Just s -> either (const False) (`runsHere` row) <$> loadWorkOrder s
      Nothing -> pure False

recoverableIntents :: DatabaseRuntime -> IO (Either LedgerFailure [OperationId])
recoverableIntents runtime =
  transaction runtime $ \_ -> operationsFrom <$> Store.recoverableIntentIds

data StoredRecovery
  = StoredRecovery
  { recoveredGeneration :: Int
  , recoveryDecision :: T.Text
  }
  deriving (Eq, Show)

intentRecoveries :: DatabaseRuntime -> OperationId -> IO (Either LedgerFailure [StoredRecovery])
intentRecoveries runtime operation =
  transaction runtime $ \_ -> do
    rows <- Store.recoveriesOf (oid operation)
    pure (Right [StoredRecovery (fromIntegral (Store.recoveryRowGeneration r)) (Store.recoveryRowDecision r) | r <- rows])

-- Reconciliation (C-P2.7) --------------------------------------------------------

{- | R7: a refused applied observation that contradicts the durable state is
recorded, halts the order, and blocks an intent that could still run.
-}
lateConflict :: LoadedOrder -> Store.IntentRow -> Intent -> OperationId -> Int -> Observation -> O.Orville ()
lateConflict l row intent operation generation observation =
  case judgeLateObservation intent observation of
    LateConsistent -> pure ()
    LateConflict next -> do
      when (next /= intent) (Store.updateIntent (lifecycleColumns next row))
      Store.insertResolution (oid operation) (int32 generation) (T.pack "late-observation") (T.pack "late-application " <> observationText observation) False
      haltForIntent l (T.pack "late-application") operation

reconcileRefused :: ReconcileRefusal -> LedgerFailure
reconcileRefused r =
  LedgerRefused (reconcileRefusalCode r) (T.pack (show r))

-- | R4: the Kernel's checks before a lookup, with nothing written; the generation the lookup is made against.
prepareLookup :: DatabaseRuntime -> OperationId -> IO (Either LedgerFailure Int)
prepareLookup runtime operation =
  transaction runtime $ \_ -> do
    locked <- lockForExecution operation
    case locked of
      Left failure -> pure (Left failure)
      Right (_, _, intent) -> do
        now <- Store.databaseNow
        pure $
          case reconcileIntent intent (Command Supervisor (ReconcileInput now LookupNotFound)) of
            Left r -> Left (reconcileRefused r)
            Right _ -> Right (intentGeneration intent)

-- | R4: the lookup's result, under the generation it was made against, with its record.
applyLookup :: DatabaseRuntime -> OperationId -> Int -> LookupResult -> IO (Either LedgerFailure Intent)
applyLookup runtime operation generation result =
  transaction runtime $ \_ -> do
    locked <- lockForExecution operation
    case locked of
      Left failure -> pure (Left failure)
      Right (l, row, intent)
        | intentGeneration intent /= generation -> pure (refused (T.pack "stale-claim") "the intent moved on while it was looked up")
        | otherwise -> do
            now <- Store.databaseNow
            case reconcileIntent intent (Command Supervisor (ReconcileInput now result)) of
              Left r -> pure (Left (reconcileRefused r))
              Right next -> do
                Store.insertResolution (oid operation) (int32 generation) (T.pack "lookup") (renderLookup result) False
                let
                  settle = stepIntent next (Command Supervisor (IntentSettle (intentGeneration next)))
                  exhausted = intentDispatches next > effectSpecBudget (intentSpec next)
                final <-
                  case intentState next of
                    IntentApplied _ -> pure settle
                    IntentNotApplied _
                      | exhausted -> do
                          haltForIntent l (T.pack "retries-exhausted") operation
                          pure settle
                    IntentUnknown _ -> do
                      haltForIntent l (T.pack "outcome-unknown") operation
                      pure (Right next)
                    _ -> pure (Right next)
                case final of
                  -- N5: the lookup is recorded, so a refused settle rolls back.
                  Left r -> pure (integrity ("a looked-up intent could not be settled: " <> show r))
                  Right written -> do
                    Store.updateIntent (lifecycleColumns written row)
                    pure (Right written)

-- | R5, R6: a Human's resolution of an unknown outcome, recorded apart from observations.
resolveOutcome :: DatabaseRuntime -> OperationId -> Int -> Resolution -> IO (Either LedgerFailure Intent)
resolveOutcome runtime operation generation resolution =
  transaction runtime $ \_ -> do
    locked <- lockForExecution operation
    case locked of
      Left failure -> pure (Left failure)
      Right (_, row, intent) -> do
        now <- Store.databaseClock
        let
          -- §4.5 P3: a retry that the dispatch would only turn back into unknown is refused.
          retryPastKey =
            case resolution of
              RetryAcknowledgingDuplication _ -> intentDispatches intent >= 1 && not (idempotencyHolds (Store.intentRowFirstDispatched row) now intent)
              _ -> False
        case resolveIntent intent (Command Human (generation, resolution)) of
          Left r -> pure (Left (reconcileRefused r))
          Right _
            | retryPastKey -> pure (refused (T.pack "idempotency-key-expired") "the idempotency key's guarantee has ended; attest that it applied, or abandon the effect with --acknowledge-duplication-risk (a not-applied attestation would only be refused again at dispatch)")
          Right next -> do
            Store.updateIntent (lifecycleColumns next row)
            let
              (basis, acknowledged) =
                case resolution of
                  RetryAcknowledgingDuplication a -> (T.pack "human-retry", a)
                  _ -> (T.pack "human-attested", False)
            Store.insertResolution (oid operation) (int32 generation) basis (renderResolution resolution) acknowledged
            pure (Right next)

reconcilableIntents :: DatabaseRuntime -> IO (Either LedgerFailure [OperationId])
reconcilableIntents runtime =
  transaction runtime $ \_ -> operationsFrom <$> Store.reconcilableIntentIds

data StoredResolution
  = StoredResolution
  { resolvedGeneration :: Int
  , resolutionBasis :: T.Text
  , resolutionDecision :: T.Text
  , resolutionAcknowledged :: Bool
  }
  deriving (Eq, Show)

intentResolutions :: DatabaseRuntime -> OperationId -> IO (Either LedgerFailure [StoredResolution])
intentResolutions runtime operation =
  transaction runtime $ \_ -> Right <$> storedResolutions operation

storedResolutions :: OperationId -> O.Orville [StoredResolution]
storedResolutions operation = do
  rows <- Store.resolutionsOf (oid operation)
  pure [StoredResolution (fromIntegral (Store.resolutionRowGeneration r)) (Store.resolutionRowBasis r) (Store.resolutionRowDecision r) (Store.resolutionRowAcknowledged r) | r <- rows]

storedObservations :: OperationId -> O.Orville [StoredObservation]
storedObservations operation = do
  rows <- Store.observationsOf (oid operation)
  pure [StoredObservation (fromIntegral (Store.observationRowGeneration r)) (Store.observationRowText r) (Store.observationRowAccepted r) (Store.observationRowRefusal r) | r <- rows]

storedRecoveries :: OperationId -> O.Orville [StoredRecovery]
storedRecoveries operation = do
  rows <- Store.recoveriesOf (oid operation)
  pure [StoredRecovery (fromIntegral (Store.recoveryRowGeneration r)) (Store.recoveryRowDecision r) | r <- rows]

-- Reading the whole ledger (C-P2.8 V2) -------------------------------------------

data IntentFacts
  = IntentFacts
  { factIntent :: Intent
  , factObservations :: [StoredObservation]
  , factRecoveries :: [StoredRecovery]
  , factResolutions :: [StoredResolution]
  }

data OrderFacts
  = OrderFacts
  { factOrder :: WorkOrder
  , factTicket :: TicketId
  , factRevision :: Int
  , factBinding :: T.Text
  , factIntents :: [IntentFacts]
  }

-- | Everything the projection shows, read in one transaction; @(subject, expected, principal, command, code)@ per refusal.
data LedgerFacts
  = LedgerFacts
  { factTime :: UTCTime
  , factTickets :: [(TicketId, T.Text, T.Text, Int)]
  , factOrders :: [OrderFacts]
  , factRefusals :: [(T.Text, Int, T.Text, T.Text, T.Text)]
  , factSchedule :: Maybe (T.Text, T.Text)
  }

{- | Reads every Ticket and Work Order (replayed: one that does not reproduce
is an integrity failure), their intents with their evidence, the refusals and
the latest schedule decision. Nothing is locked or written, and everything comes
from one consistent snapshot (C-P2.9-R1 M3), so a decision committing during the
read cannot look like tampering.
-}
readLedger :: DatabaseRuntime -> IO (Either LedgerFailure LedgerFacts)
readLedger runtime =
  transaction runtime $ \_ -> do
    Store.readOnlySnapshot
    now <- Store.databaseNow
    ticketSubjects <- Store.subjectsOfKind (T.pack "ticket")
    ticketFacts <- traverse ticketFact ticketSubjects
    orderSubjects <- Store.subjectsOfKind (T.pack "work-order")
    orderFacts <- traverse orderFact orderSubjects
    refusalRows <- Store.allRefusals
    schedule <- Store.latestScheduleDecision
    pure $ do
      ts <- sequenceA ticketFacts
      os <- sequenceA orderFacts
      pure
        LedgerFacts
          { factTime = now
          , factTickets = ts
          , factOrders = os
          , factRefusals = [(Store.refusalSubject r, fromIntegral (Store.refusalExpectedRevision r), Store.refusalPrincipal r, Store.refusalCommand r, Store.refusalCode r) | r <- refusalRows]
          , factSchedule = schedule
          }
 where
  ticketFact subject = do
    row <- Store.findTicket (Store.subjectRowId subject)
    case row of
      Nothing -> pure (integrity "a ticket subject has no ticket row")
      Just r -> do
        events <- Store.subjectEvents (Store.subjectRowId subject)
        pure $ do
          (state, _) <- replayTicket subject r events
          u <- uuidOf (Store.subjectRowId subject)
          pure (TicketId u, Store.ticketRowTitle r, ticketStateName state, fromIntegral (Store.subjectRowRevision subject))
  orderFact subject = do
    loaded <- loadWorkOrder subject
    case loaded of
      Left failure -> pure (Left failure)
      Right l -> do
        rows <- Store.intentsOfSubject (Store.subjectRowId subject)
        intents <- traverse intentFact rows
        pure $ do
          is <- sequenceA intents
          u <- uuidOf (Store.workOrderRowTicket (loadedRow l))
          pure
            OrderFacts
              { factOrder = loadedOrder l
              , factTicket = TicketId u
              , factRevision = fromIntegral (Store.subjectRowRevision subject)
              , factBinding = contentDigestText (bindingDigest (loadedBinding l))
              , factIntents = is
              }
  intentFact row =
    case restoreIntent row of
      Left failure -> pure (Left failure)
      Right intent -> do
        observations <- storedObservations (intentOperation intent)
        recoveries <- storedRecoveries (intentOperation intent)
        resolutions <- storedResolutions (intentOperation intent)
        pure (Right (IntentFacts intent observations recoveries resolutions))

-- Carry-forward (C-P2.9-R1 M2, §2.1) -----------------------------------------------------

{- | A Human carries an earlier activation's intent into the order's current
activation. 'carryIntent' and 'carryIntentAs' state no expected activations
and no acknowledgment: they are library forms used by tests (§4.5 P4). The
command line uses 'carryIntentChecked'.
-}
carryIntent :: DatabaseRuntime -> OperationId -> IO (Either LedgerFailure Intent)
carryIntent runtime =
  carryIntentAs runtime Human

{- | §2.1, in one transaction: the Work Order, then the intent, are locked; the
Kernel decides; the claiming Engineer must still own the order's repository.
An accepted carry changes only the intent's activation and records the
decision; the intent itself (operation id, parameters, budget, history) is
untouched.
-}
carryIntentAs :: DatabaseRuntime -> Principal -> OperationId -> IO (Either LedgerFailure Intent)
carryIntentAs runtime principal operation =
  carryIntentChecked runtime principal operation Nothing False

{- | C-P2.9-R1 §4.2 N2-N4: the carry as the Human states it, with the
activations it expects to carry between (@stale-carry@ otherwise) and whether
it acknowledges the duplication risk of an attested intent, in any carryable
state (§4.5 P2). Another live intent of the order with the same effect key,
in any activation, is @carry-conflict@ (§4.5 P1, §4.7 F1). The
acknowledgment is recorded with the carry.
-}
carryIntentChecked :: DatabaseRuntime -> Principal -> OperationId -> Maybe (Int, Int) -> Bool -> IO (Either LedgerFailure Intent)
carryIntentChecked runtime principal operation expected acknowledged =
  transaction runtime $ \_ -> do
    locked <- lockForExecution operation
    case locked of
      Left failure -> pure (Left failure)
      Right (l, row, intent) -> do
        now <- Store.databaseClock
        owners <- Store.activeOwners
        holders <- liveSameKey row
        resolutions <- storedResolutions operation
        let
          source = fromIntegral (Store.intentRowActivation row)
          target = currentActivation l
          input = CarryInput now source target (idempotencyHolds (Store.intentRowFirstDispatched row) now intent)
          -- §4.5 P1, §4.7 F1: a live same-key intent of any activation.
          conflict =
            not (L.null holders)
          request =
            CarryRequest
              { requestInput = input
              , requestExpected = expected
              , requestAcknowledged = acknowledged
              , requestAttested = L.any ((== T.pack "human-attested") . resolutionBasis) resolutions
              , requestConflict = conflict
              }
          owned =
            case workOrderState (loadedOrder l) of
              Active c ->
                case claimEngineer c of
                  EngineerId u -> (Store.workOrderRowRepository (loadedRow l), uuidText u) `L.elem` owners
              _ -> True
        case carryChecked intent (Command principal request) of
          Left r -> pure (Left (LedgerRefused (carryRefusalCode r) (T.pack (show r))))
          Right ()
            | not owned -> pure (refused (T.pack "repository-not-owned") "the claiming Engineer no longer owns the order's repository")
            | otherwise ->
                case target of
                  Nothing -> pure (refused (T.pack "subject-not-active") "the work order is not active")
                  Just t -> do
                    Store.setActivation (oid operation) (int32 t)
                    Store.insertResolution
                      (oid operation)
                      (int32 (intentGeneration intent))
                      (T.pack "human-carry")
                      (T.pack ("carried principal=" <> T.unpack (principalName principal) <> " from-generation=" <> show source <> " to-generation=" <> show t))
                      acknowledged
                    pure (Right intent)

intentActivation :: DatabaseRuntime -> OperationId -> IO (Either LedgerFailure Int)
intentActivation runtime operation =
  transaction runtime $ \_ -> do
    row <- Store.findIntent (oid operation)
    pure (maybe (refused (T.pack "unknown-intent") "there is no such effect intent") (Right . fromIntegral . Store.intentRowActivation) row)

{- | A test seam for C-P2.9-R1 M3: writes a subject and a refusal row, then
finds an integrity failure. The transaction must roll both back.
-}
probeIntegrityRollback :: DatabaseRuntime -> IO (Either LedgerFailure ())
probeIntegrityRollback runtime = do
  subject <- newUuid
  transaction runtime $ \_ -> do
    Store.insertSubject (uuidText subject) (T.pack "ticket") (T.pack "proposed")
    Store.insertRefusal (Store.NewRefusal (uuidText subject) 1 (T.pack "human") (T.pack "probe") (T.pack "probe"))
    pure (integrity "a probe integrity failure after two writes")
