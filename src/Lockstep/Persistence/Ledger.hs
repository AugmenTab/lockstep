{- | Storage for durable subjects, events, effect intents, observations,
gate evidence, schedule decisions and Work Units (contract C-P2.5 E9–E18).
Statements only: every decision is made by the Kernel and sequenced by
"Lockstep.Application.Ledger" inside one transaction.
-}
module Lockstep.Persistence.Ledger
  ( SubjectRow (..)
  , lockSubject
  , lockSubjectsOfKind
  , subjectsOfKind
  , insertSubject
  , updateSubject
  , EventRow (..)
  , insertEvent
  , subjectEvents
  , NewRefusal (..)
  , insertRefusal
  , allRefusals
  , TicketRow (..)
  , insertTicket
  , findTicket
  , updateTicket
  , WorkOrderRow (..)
  , insertWorkOrder
  , findWorkOrder
  , allWorkOrders
  , insertDependency
  , dependenciesOf
  , SourceRow (..)
  , insertSource
  , sourcesOf
  , IntentRow (..)
  , insertIntent
  , lockIntent
  , intentsOfSubject
  , findIntent
  , setActivation
  , subjectRow
  , readOnlySnapshot
  , databaseClock
  , updateIntent
  , insertObservation
  , ObservationRow (..)
  , observationsOf
  , intentSubject
  , runnableIntentIds
  , recoverableIntentIds
  , insertRecovery
  , RecoveryRow (..)
  , recoveriesOf
  , reconcilableIntentIds
  , insertResolution
  , ResolutionRow (..)
  , resolutionsOf
  , EvidenceRow (..)
  , insertEvidence
  , evidenceOf
  , insertScheduleDecision
  , latestScheduleDecision
  , lockScheduling
  , insertWorkUnit
  , activeOwners
  , databaseNow
  ) where

import Control.Exception (throwIO)
import Data.Maybe (isNothing)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql
import Orville.PostgreSQL.Raw.SqlValue qualified as SqlValue
import System.IO.Error (userError)

sql :: String -> RawSql.RawSql
sql =
  RawSql.fromString

text :: T.Text -> RawSql.RawSql
text =
  RawSql.parameter . SqlValue.fromText

int :: Int32 -> RawSql.RawSql
int =
  RawSql.parameter . SqlValue.fromInt32

int64 :: Int64 -> RawSql.RawSql
int64 =
  RawSql.parameter . SqlValue.fromInt64

bool :: Bool -> RawSql.RawSql
bool =
  RawSql.parameter . SqlValue.fromBool

time :: UTCTime -> RawSql.RawSql
time =
  RawSql.parameter . SqlValue.fromUTCTime

maybeOf :: (a -> RawSql.RawSql) -> Maybe a -> RawSql.RawSql
maybeOf =
  maybe (sql "NULL")

uuid :: T.Text -> RawSql.RawSql
uuid value =
  sql "CAST(" <> text value <> sql " AS uuid)"

commaSeparated :: [RawSql.RawSql] -> RawSql.RawSql
commaSeparated =
  RawSql.intercalate (sql ", ")

marshal :: O.SqlMarshaller a a -> O.AnnotatedSqlMarshaller a a
marshal =
  O.annotateSqlMarshallerEmptyAnnotation

uuidField :: String -> O.FieldDefinition O.NotNull T.Text
uuidField =
  O.unboundedTextField

-- Subjects ---------------------------------------------------------------------

data SubjectRow
  = SubjectRow
  { subjectRowId :: T.Text
  , subjectRowKind :: T.Text
  , subjectRowRevision :: Int32
  , subjectRowState :: T.Text
  }

subjectMarshaller :: O.AnnotatedSqlMarshaller SubjectRow SubjectRow
subjectMarshaller =
  marshal $
    SubjectRow
      <$> O.marshallField subjectRowId (uuidField "id")
      <*> O.marshallField subjectRowKind (O.unboundedTextField "kind")
      <*> O.marshallField subjectRowRevision (O.integerField "revision")
      <*> O.marshallField subjectRowState (O.unboundedTextField "state")

subjectColumns :: String
subjectColumns =
  "SELECT id::text AS id, kind, revision, state FROM lockstep_subjects "

-- | The subject row, locked until the transaction ends.
lockSubject :: O.MonadOrville m => T.Text -> m (Maybe SubjectRow)
lockSubject subjectId =
  headMay
    <$> O.executeAndDecode O.SelectQuery (sql subjectColumns <> sql "WHERE id = " <> uuid subjectId <> sql " FOR UPDATE") subjectMarshaller

-- | Every subject of one kind, by id, locked until the transaction ends.
lockSubjectsOfKind :: O.MonadOrville m => T.Text -> m [SubjectRow]
lockSubjectsOfKind kind =
  O.executeAndDecode O.SelectQuery (sql subjectColumns <> sql "WHERE kind = " <> text kind <> sql " ORDER BY id FOR UPDATE") subjectMarshaller

-- | Every subject of one kind, by creation, without locking them (C-P2.8 V2).
subjectsOfKind :: O.MonadOrville m => T.Text -> m [SubjectRow]
subjectsOfKind kind =
  O.executeAndDecode O.SelectQuery (sql subjectColumns <> sql "WHERE kind = " <> text kind <> sql " ORDER BY created_at, id") subjectMarshaller

insertSubject :: O.MonadOrville m => T.Text -> T.Text -> T.Text -> m ()
insertSubject subjectId kind state =
  O.executeVoid O.InsertQuery $
    sql "INSERT INTO lockstep_subjects (id, kind, revision, state) VALUES ("
      <> commaSeparated [uuid subjectId, text kind, int 1, text state]
      <> sql ")"

updateSubject :: O.MonadOrville m => T.Text -> Int32 -> T.Text -> m ()
updateSubject subjectId revision state =
  O.executeVoid O.UpdateQuery $
    sql "UPDATE lockstep_subjects SET revision = "
      <> int revision
      <> sql ", state = "
      <> text state
      <> sql ", updated_at = now() WHERE id = "
      <> uuid subjectId

-- Events -----------------------------------------------------------------------

data EventRow
  = EventRow
  { eventRowSequence :: Int32
  , eventRowPrincipal :: T.Text
  , eventRowCommand :: T.Text
  , eventRowStateAfter :: T.Text
  }

insertEvent :: O.MonadOrville m => T.Text -> EventRow -> m (Maybe Int64)
insertEvent subjectId row =
  headMay
    <$> O.executeAndDecode
      O.InsertQuery
      ( sql "INSERT INTO lockstep_events (subject_id, sequence, principal, command, state_after) VALUES ("
          <> commaSeparated [uuid subjectId, int (eventRowSequence row), text (eventRowPrincipal row), text (eventRowCommand row), text (eventRowStateAfter row)]
          <> sql ") RETURNING id"
      )
      (marshal (O.marshallField id (O.bigIntegerField "id")))

-- | The subject's events, in sequence order.
subjectEvents :: O.MonadOrville m => T.Text -> m [EventRow]
subjectEvents subjectId =
  O.executeAndDecode
    O.SelectQuery
    (sql "SELECT sequence, principal, command, state_after FROM lockstep_events WHERE subject_id = " <> uuid subjectId <> sql " ORDER BY sequence")
    ( marshal $
        EventRow
          <$> O.marshallField eventRowSequence (O.integerField "sequence")
          <*> O.marshallField eventRowPrincipal (O.unboundedTextField "principal")
          <*> O.marshallField eventRowCommand (O.unboundedTextField "command")
          <*> O.marshallField eventRowStateAfter (O.unboundedTextField "state_after")
    )

data NewRefusal
  = NewRefusal
  { refusalSubject :: T.Text
  , refusalExpectedRevision :: Int32
  , refusalPrincipal :: T.Text
  , refusalCommand :: T.Text
  , refusalCode :: T.Text
  }

insertRefusal :: O.MonadOrville m => NewRefusal -> m ()
insertRefusal r =
  O.executeVoid O.InsertQuery $
    sql "INSERT INTO lockstep_decision_refusals (subject_id, expected_revision, principal, command, refusal_code) VALUES ("
      <> commaSeparated [uuid (refusalSubject r), int (refusalExpectedRevision r), text (refusalPrincipal r), text (refusalCommand r), text (refusalCode r)]
      <> sql ")"

-- | Every decision refusal, oldest first (C-P2.8 V2).
allRefusals :: O.MonadOrville m => m [NewRefusal]
allRefusals =
  O.executeAndDecode
    O.SelectQuery
    (sql "SELECT subject_id::text AS subject_id, expected_revision, principal, command, refusal_code FROM lockstep_decision_refusals ORDER BY id")
    ( marshal $
        NewRefusal
          <$> O.marshallField refusalSubject (uuidField "subject_id")
          <*> O.marshallField refusalExpectedRevision (O.integerField "expected_revision")
          <*> O.marshallField refusalPrincipal (O.unboundedTextField "principal")
          <*> O.marshallField refusalCommand (O.unboundedTextField "command")
          <*> O.marshallField refusalCode (O.unboundedTextField "refusal_code")
    )

-- Tickets ----------------------------------------------------------------------

data TicketRow
  = TicketRow
  { ticketRowId :: T.Text
  , ticketRowTitle :: T.Text
  , ticketRowContentRevision :: Int32
  }

insertTicket :: O.MonadOrville m => T.Text -> T.Text -> m ()
insertTicket ticketId title =
  O.executeVoid O.InsertQuery $
    sql "INSERT INTO lockstep_tickets (id, title, content_revision) VALUES (" <> commaSeparated [uuid ticketId, text title, int 1] <> sql ")"

findTicket :: O.MonadOrville m => T.Text -> m (Maybe TicketRow)
findTicket ticketId =
  headMay <$> tickets (sql "WHERE id = " <> uuid ticketId)

tickets :: O.MonadOrville m => RawSql.RawSql -> m [TicketRow]
tickets condition =
  O.executeAndDecode
    O.SelectQuery
    (sql "SELECT id::text AS id, title, content_revision FROM lockstep_tickets " <> condition)
    ( marshal $
        TicketRow
          <$> O.marshallField ticketRowId (uuidField "id")
          <*> O.marshallField ticketRowTitle (O.unboundedTextField "title")
          <*> O.marshallField ticketRowContentRevision (O.integerField "content_revision")
    )

updateTicket :: O.MonadOrville m => T.Text -> T.Text -> Int32 -> m ()
updateTicket ticketId title contentRevision =
  O.executeVoid O.UpdateQuery $
    sql "UPDATE lockstep_tickets SET title = " <> text title <> sql ", content_revision = " <> int contentRevision <> sql " WHERE id = " <> uuid ticketId

-- Work Orders ------------------------------------------------------------------

data WorkOrderRow
  = WorkOrderRow
  { workOrderRowId :: T.Text
  , workOrderRowKind :: T.Text
  , workOrderRowTicket :: T.Text
  , workOrderRowTicketRevision :: Int32
  , workOrderRowRepository :: T.Text
  , workOrderRowPriority :: Int32
  , workOrderRowAdmittedAt :: UTCTime
  , workOrderRowClasses :: T.Text
  , workOrderRowPathClasses :: T.Text
  , workOrderRowNonBehavioural :: Maybe T.Text
  , workOrderRowApprover :: T.Text
  , workOrderRowEffectiveDigest :: T.Text
  , workOrderRowBindingDigest :: T.Text
  }

insertWorkOrder :: O.MonadOrville m => WorkOrderRow -> m ()
insertWorkOrder row =
  O.executeVoid O.InsertQuery $
    sql "INSERT INTO lockstep_work_orders (id, kind, ticket_id, ticket_content_revision, repository_id, priority, admitted_at, classes, path_classes, non_behavioural_rationale, binding_approver, effective_digest, binding_digest) VALUES ("
      <> commaSeparated
        [ uuid (workOrderRowId row)
        , text (workOrderRowKind row)
        , uuid (workOrderRowTicket row)
        , int (workOrderRowTicketRevision row)
        , uuid (workOrderRowRepository row)
        , int (workOrderRowPriority row)
        , time (workOrderRowAdmittedAt row)
        , text (workOrderRowClasses row)
        , text (workOrderRowPathClasses row)
        , maybeOf text (workOrderRowNonBehavioural row)
        , text (workOrderRowApprover row)
        , text (workOrderRowEffectiveDigest row)
        , text (workOrderRowBindingDigest row)
        ]
      <> sql ")"

workOrders :: O.MonadOrville m => RawSql.RawSql -> m [WorkOrderRow]
workOrders condition =
  O.executeAndDecode
    O.SelectQuery
    ( sql "SELECT id::text AS id, kind, ticket_id::text AS ticket_id, ticket_content_revision, repository_id::text AS repository_id, priority, admitted_at, classes, path_classes, non_behavioural_rationale, binding_approver, effective_digest, binding_digest FROM lockstep_work_orders "
        <> condition
    )
    ( marshal $
        WorkOrderRow
          <$> O.marshallField workOrderRowId (uuidField "id")
          <*> O.marshallField workOrderRowKind (O.unboundedTextField "kind")
          <*> O.marshallField workOrderRowTicket (uuidField "ticket_id")
          <*> O.marshallField workOrderRowTicketRevision (O.integerField "ticket_content_revision")
          <*> O.marshallField workOrderRowRepository (uuidField "repository_id")
          <*> O.marshallField workOrderRowPriority (O.integerField "priority")
          <*> O.marshallField workOrderRowAdmittedAt (O.utcTimestampField "admitted_at")
          <*> O.marshallField workOrderRowClasses (O.unboundedTextField "classes")
          <*> O.marshallField workOrderRowPathClasses (O.unboundedTextField "path_classes")
          <*> O.marshallField workOrderRowNonBehavioural (O.nullableField (O.unboundedTextField "non_behavioural_rationale"))
          <*> O.marshallField workOrderRowApprover (O.unboundedTextField "binding_approver")
          <*> O.marshallField workOrderRowEffectiveDigest (O.unboundedTextField "effective_digest")
          <*> O.marshallField workOrderRowBindingDigest (O.unboundedTextField "binding_digest")
    )

findWorkOrder :: O.MonadOrville m => T.Text -> m (Maybe WorkOrderRow)
findWorkOrder workOrderId =
  headMay <$> workOrders (sql "WHERE id = " <> uuid workOrderId)

allWorkOrders :: O.MonadOrville m => m [WorkOrderRow]
allWorkOrders =
  workOrders (sql "ORDER BY id")

insertDependency :: O.MonadOrville m => T.Text -> T.Text -> m ()
insertDependency workOrderId dependsOn =
  O.executeVoid O.InsertQuery $
    sql "INSERT INTO lockstep_work_order_dependencies (work_order_id, depends_on) VALUES (" <> commaSeparated [uuid workOrderId, uuid dependsOn] <> sql ")"

dependenciesOf :: O.MonadOrville m => T.Text -> m [T.Text]
dependenciesOf workOrderId =
  O.executeAndDecode
    O.SelectQuery
    (sql "SELECT depends_on::text AS v FROM lockstep_work_order_dependencies WHERE work_order_id = " <> uuid workOrderId <> sql " ORDER BY depends_on")
    (marshal (O.marshallField id (uuidField "v")))

data SourceRow
  = SourceRow
  { sourceRowLevel :: T.Text
  , sourceRowProfile :: T.Text
  , sourceRowVersion :: Int32
  , sourceRowDigest :: T.Text
  }

insertSource :: O.MonadOrville m => T.Text -> Int32 -> SourceRow -> m ()
insertSource workOrderId position row =
  O.executeVoid O.InsertQuery $
    sql "INSERT INTO lockstep_work_order_profile_sources (work_order_id, position, level, profile_id, version, digest) VALUES ("
      <> commaSeparated [uuid workOrderId, int position, text (sourceRowLevel row), text (sourceRowProfile row), int (sourceRowVersion row), text (sourceRowDigest row)]
      <> sql ")"

-- | The bound sources, in their order.
sourcesOf :: O.MonadOrville m => T.Text -> m [SourceRow]
sourcesOf workOrderId =
  O.executeAndDecode
    O.SelectQuery
    (sql "SELECT level, profile_id, version, digest FROM lockstep_work_order_profile_sources WHERE work_order_id = " <> uuid workOrderId <> sql " ORDER BY position")
    ( marshal $
        SourceRow
          <$> O.marshallField sourceRowLevel (O.unboundedTextField "level")
          <*> O.marshallField sourceRowProfile (O.unboundedTextField "profile_id")
          <*> O.marshallField sourceRowVersion (O.integerField "version")
          <*> O.marshallField sourceRowDigest (O.unboundedTextField "digest")
    )

-- Intents ----------------------------------------------------------------------

data IntentRow
  = IntentRow
  { intentRowOperation :: T.Text
  , intentRowSubject :: T.Text
  , intentRowSubjectKind :: T.Text
  , intentRowBasisRevision :: Int32
  , intentRowKey :: T.Text
  , intentRowEvent :: Int64
  , intentRowSpecName :: T.Text
  , intentRowClass :: T.Text
  , intentRowBudget :: Int32
  , intentRowKeyLifetime :: Maybe Int64
  , intentRowRefusesChanged :: Maybe Bool
  , intentRowLookupAuthoritative :: Maybe Bool
  , intentRowLookupExcludesLate :: Maybe Bool
  , intentRowParameters :: T.Text
  , intentRowParametersDigest :: T.Text
  , intentRowState :: T.Text
  , intentRowGeneration :: Int32
  , intentRowDispatches :: Int32
  , intentRowLeaseOwner :: Maybe T.Text
  , intentRowLeaseUntil :: Maybe UTCTime
  , intentRowOutcome :: Maybe T.Text
  , intentRowSettledApplied :: Maybe Bool
  , intentRowActivation :: Int32
  , intentRowFirstDispatched :: Maybe UTCTime
  }

insertIntent :: O.MonadOrville m => IntentRow -> m ()
insertIntent row =
  O.executeVoid O.InsertQuery $
    sql "INSERT INTO lockstep_effect_intents (operation_id, subject_id, basis_revision, effect_key, event_id, spec_name, effect_class, retry_budget, key_lifetime_seconds, refuses_changed_parameters, lookup_authoritative, lookup_excludes_late_application, parameters, parameters_digest, state, generation, dispatches, activation_generation) VALUES ("
      <> commaSeparated
        [ uuid (intentRowOperation row)
        , uuid (intentRowSubject row)
        , int (intentRowBasisRevision row)
        , text (intentRowKey row)
        , int64 (intentRowEvent row)
        , text (intentRowSpecName row)
        , text (intentRowClass row)
        , int (intentRowBudget row)
        , maybeOf int64 (intentRowKeyLifetime row)
        , maybeOf bool (intentRowRefusesChanged row)
        , maybeOf bool (intentRowLookupAuthoritative row)
        , maybeOf bool (intentRowLookupExcludesLate row)
        , text (intentRowParameters row)
        , text (intentRowParametersDigest row)
        , text (intentRowState row)
        , int (intentRowGeneration row)
        , int (intentRowDispatches row)
        , int (intentRowActivation row)
        ]
      <> sql ")"

-- | The intent row with its subject's kind, locked until the transaction ends.
lockIntent :: O.MonadOrville m => T.Text -> m (Maybe IntentRow)
lockIntent operation =
  headMay <$> intentRows (sql "WHERE i.operation_id = " <> uuid operation <> sql " FOR UPDATE OF i")

-- | The intent row, without locking it (C-P2.9-R1 selection).
findIntent :: O.MonadOrville m => T.Text -> m (Maybe IntentRow)
findIntent operation =
  headMay <$> intentRows (sql "WHERE i.operation_id = " <> uuid operation)

-- | A subject's intent rows, oldest first, without locking them (C-P2.8 V2).
intentsOfSubject :: O.MonadOrville m => T.Text -> m [IntentRow]
intentsOfSubject subjectId =
  intentRows (sql "WHERE i.subject_id = " <> uuid subjectId <> sql " ORDER BY i.id")

intentRows :: O.MonadOrville m => RawSql.RawSql -> m [IntentRow]
intentRows condition =
  O.executeAndDecode
    O.SelectQuery
    ( sql "SELECT i.operation_id::text AS operation_id, i.subject_id::text AS subject_id, s.kind AS subject_kind, i.basis_revision, i.effect_key, i.event_id, i.spec_name, i.effect_class, i.retry_budget, i.key_lifetime_seconds, i.refuses_changed_parameters, i.lookup_authoritative, i.lookup_excludes_late_application, i.parameters, i.parameters_digest, i.state, i.generation, i.dispatches, i.lease_owner, i.lease_until, i.outcome_text, i.settled_applied, i.activation_generation, i.first_dispatched_at FROM lockstep_effect_intents i JOIN lockstep_subjects s ON s.id = i.subject_id "
        <> condition
    )
    ( marshal $
        IntentRow
          <$> O.marshallField intentRowOperation (uuidField "operation_id")
          <*> O.marshallField intentRowSubject (uuidField "subject_id")
          <*> O.marshallField intentRowSubjectKind (O.unboundedTextField "subject_kind")
          <*> O.marshallField intentRowBasisRevision (O.integerField "basis_revision")
          <*> O.marshallField intentRowKey (O.unboundedTextField "effect_key")
          <*> O.marshallField intentRowEvent (O.bigIntegerField "event_id")
          <*> O.marshallField intentRowSpecName (O.unboundedTextField "spec_name")
          <*> O.marshallField intentRowClass (O.unboundedTextField "effect_class")
          <*> O.marshallField intentRowBudget (O.integerField "retry_budget")
          <*> O.marshallField intentRowKeyLifetime (O.nullableField (O.bigIntegerField "key_lifetime_seconds"))
          <*> O.marshallField intentRowRefusesChanged (O.nullableField (O.booleanField "refuses_changed_parameters"))
          <*> O.marshallField intentRowLookupAuthoritative (O.nullableField (O.booleanField "lookup_authoritative"))
          <*> O.marshallField intentRowLookupExcludesLate (O.nullableField (O.booleanField "lookup_excludes_late_application"))
          <*> O.marshallField intentRowParameters (O.unboundedTextField "parameters")
          <*> O.marshallField intentRowParametersDigest (O.unboundedTextField "parameters_digest")
          <*> O.marshallField intentRowState (O.unboundedTextField "state")
          <*> O.marshallField intentRowGeneration (O.integerField "generation")
          <*> O.marshallField intentRowDispatches (O.integerField "dispatches")
          <*> O.marshallField intentRowLeaseOwner (O.nullableField (O.unboundedTextField "lease_owner"))
          <*> O.marshallField intentRowLeaseUntil (O.nullableField (O.utcTimestampField "lease_until"))
          <*> O.marshallField intentRowOutcome (O.nullableField (O.unboundedTextField "outcome_text"))
          <*> O.marshallField intentRowSettledApplied (O.nullableField (O.booleanField "settled_applied"))
          <*> O.marshallField intentRowActivation (O.integerField "activation_generation")
          <*> O.marshallField intentRowFirstDispatched (O.nullableField (O.utcTimestampField "first_dispatched_at"))
    )

-- | C-P2.9-R1 M2: rebinds an intent to the activation a Human carried it into.
setActivation :: O.MonadOrville m => T.Text -> Int32 -> m ()
setActivation operation generation =
  O.executeVoid O.UpdateQuery $
    sql "UPDATE lockstep_effect_intents SET activation_generation = " <> int generation <> sql ", updated_at = now() WHERE operation_id = " <> uuid operation

-- | An unlocked subject row (C-P2.9-R1 selection).
subjectRow :: O.MonadOrville m => T.Text -> m (Maybe SubjectRow)
subjectRow subjectId =
  headMay <$> O.executeAndDecode O.SelectQuery (sql subjectColumns <> sql "WHERE id = " <> uuid subjectId) subjectMarshaller

-- | C-P2.9-R1 M3: this transaction reads one consistent snapshot and writes nothing. It must be its first statement.
readOnlySnapshot :: O.MonadOrville m => m ()
readOnlySnapshot =
  O.executeVoid O.OtherQuery (sql "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")

-- | The statement's own time (PostgreSQL @clock_timestamp()@), for checks that must not use the transaction's start (C-P2.9-R1 M6).
databaseClock :: O.MonadOrville m => m UTCTime
databaseClock = do
  rows <- O.executeAndDecode O.SelectQuery (sql "SELECT clock_timestamp() AS v") (marshal (O.marshallField id (O.utcTimestampField "v")))
  maybe (liftIO (throwIO (userError "lockstep: SELECT clock_timestamp() returned no row"))) pure (headMay rows)

{- | Writes the lifecycle columns only; a trigger refuses any change to the
identity, spec or parameters. The first time an intent is written as
dispatched, its first dispatch time is stamped from the database clock and
never changed again (C-P2.9-R1 M1).
-}
updateIntent :: O.MonadOrville m => IntentRow -> m ()
updateIntent row =
  O.executeVoid O.UpdateQuery $
    sql "UPDATE lockstep_effect_intents SET first_dispatched_at = CASE WHEN "
      <> text (intentRowState row)
      <> sql " = 'dispatched' THEN coalesce(first_dispatched_at, clock_timestamp()) ELSE first_dispatched_at END, state = "
      <> text (intentRowState row)
      <> sql ", generation = "
      <> int (intentRowGeneration row)
      <> sql ", dispatches = "
      <> int (intentRowDispatches row)
      <> sql ", lease_owner = "
      <> maybeOf text (intentRowLeaseOwner row)
      <> sql ", lease_until = "
      <> maybeOf time (intentRowLeaseUntil row)
      <> sql ", outcome_text = "
      <> maybeOf text (intentRowOutcome row)
      <> sql ", settled_applied = "
      <> maybeOf bool (intentRowSettledApplied row)
      <> sql ", updated_at = now() WHERE operation_id = "
      <> uuid (intentRowOperation row)

insertObservation :: O.MonadOrville m => T.Text -> Int32 -> T.Text -> Maybe T.Text -> m ()
insertObservation operation generation observation refusal =
  O.executeVoid O.InsertQuery $
    sql "INSERT INTO lockstep_effect_observations (operation_id, generation, observation, accepted, refusal_code) VALUES ("
      <> commaSeparated [uuid operation, int generation, text observation, bool (isNothing refusal), maybeOf text refusal]
      <> sql ")"

data ObservationRow
  = ObservationRow
  { observationRowGeneration :: Int32
  , observationRowText :: T.Text
  , observationRowAccepted :: Bool
  , observationRowRefusal :: Maybe T.Text
  }

observationsOf :: O.MonadOrville m => T.Text -> m [ObservationRow]
observationsOf operation =
  O.executeAndDecode
    O.SelectQuery
    (sql "SELECT generation, observation, accepted, refusal_code FROM lockstep_effect_observations WHERE operation_id = " <> uuid operation <> sql " ORDER BY id")
    ( marshal $
        ObservationRow
          <$> O.marshallField observationRowGeneration (O.integerField "generation")
          <*> O.marshallField observationRowText (O.unboundedTextField "observation")
          <*> O.marshallField observationRowAccepted (O.booleanField "accepted")
          <*> O.marshallField observationRowRefusal (O.nullableField (O.unboundedTextField "refusal_code"))
    )

-- Execution and recovery (C-P2.6) ------------------------------------------------

-- | The intent's subject, read without a lock (the caller locks the subject first, then the intent).
intentSubject :: O.MonadOrville m => T.Text -> m (Maybe T.Text)
intentSubject operation =
  headMay <$> operationIds (sql "SELECT subject_id::text AS v FROM lockstep_effect_intents WHERE operation_id = " <> uuid operation)

-- | X10: intents of active Work Orders that may be claimed now, oldest first.
runnableIntentIds :: O.MonadOrville m => m [T.Text]
runnableIntentIds =
  operationIds $
    sql "SELECT i.operation_id::text AS v FROM lockstep_effect_intents i JOIN lockstep_subjects s ON s.id = i.subject_id"
      <> sql " WHERE s.kind = 'work-order' AND s.state = 'active' AND (i.state = 'pending'"
      <> sql " OR (i.state = 'claimed' AND i.lease_until <= now())"
      <> sql " OR (i.state = 'confirmed-not-applied' AND i.dispatches <= i.retry_budget)) ORDER BY i.id"

-- | X10: dispatched intents whose lease has ended, oldest first.
recoverableIntentIds :: O.MonadOrville m => m [T.Text]
recoverableIntentIds =
  operationIds (sql "SELECT operation_id::text AS v FROM lockstep_effect_intents WHERE state = 'dispatched' AND lease_until <= now() ORDER BY id")

operationIds :: O.MonadOrville m => RawSql.RawSql -> m [T.Text]
operationIds statement =
  O.executeAndDecode O.SelectQuery statement (marshal (O.marshallField id (uuidField "v")))

insertRecovery :: O.MonadOrville m => T.Text -> Int32 -> T.Text -> m ()
insertRecovery operation generation decision =
  O.executeVoid O.InsertQuery $
    sql "INSERT INTO lockstep_effect_recoveries (operation_id, generation, decision) VALUES ("
      <> commaSeparated [uuid operation, int generation, text decision]
      <> sql ")"

data RecoveryRow
  = RecoveryRow
  { recoveryRowGeneration :: Int32
  , recoveryRowDecision :: T.Text
  }

recoveriesOf :: O.MonadOrville m => T.Text -> m [RecoveryRow]
recoveriesOf operation =
  O.executeAndDecode
    O.SelectQuery
    (sql "SELECT generation, decision FROM lockstep_effect_recoveries WHERE operation_id = " <> uuid operation <> sql " ORDER BY id")
    ( marshal $
        RecoveryRow
          <$> O.marshallField recoveryRowGeneration (O.integerField "generation")
          <*> O.marshallField recoveryRowDecision (O.unboundedTextField "decision")
    )

-- Reconciliation and resolution (C-P2.7) ----------------------------------------

-- | R4: queryable intents whose outcome is unknown, or dispatched with an ended lease, oldest first.
reconcilableIntentIds :: O.MonadOrville m => m [T.Text]
reconcilableIntentIds =
  operationIds $
    sql "SELECT operation_id::text AS v FROM lockstep_effect_intents WHERE effect_class = 'queryable'"
      <> sql " AND (state = 'outcome-unknown' OR (state = 'dispatched' AND lease_until <= now())) ORDER BY id"

insertResolution :: O.MonadOrville m => T.Text -> Int32 -> T.Text -> T.Text -> Bool -> m ()
insertResolution operation generation basis decision acknowledged =
  O.executeVoid O.InsertQuery $
    sql "INSERT INTO lockstep_effect_resolutions (operation_id, generation, basis, decision, duplication_acknowledged) VALUES ("
      <> commaSeparated [uuid operation, int generation, text basis, text decision, bool acknowledged]
      <> sql ")"

data ResolutionRow
  = ResolutionRow
  { resolutionRowGeneration :: Int32
  , resolutionRowBasis :: T.Text
  , resolutionRowDecision :: T.Text
  , resolutionRowAcknowledged :: Bool
  }

resolutionsOf :: O.MonadOrville m => T.Text -> m [ResolutionRow]
resolutionsOf operation =
  O.executeAndDecode
    O.SelectQuery
    (sql "SELECT generation, basis, decision, duplication_acknowledged FROM lockstep_effect_resolutions WHERE operation_id = " <> uuid operation <> sql " ORDER BY id")
    ( marshal $
        ResolutionRow
          <$> O.marshallField resolutionRowGeneration (O.integerField "generation")
          <*> O.marshallField resolutionRowBasis (O.unboundedTextField "basis")
          <*> O.marshallField resolutionRowDecision (O.unboundedTextField "decision")
          <*> O.marshallField resolutionRowAcknowledged (O.booleanField "duplication_acknowledged")
    )

-- Evidence, schedule decisions, Work Units -------------------------------------

data EvidenceRow
  = EvidenceRow
  { evidenceRowArtifact :: T.Text
  , evidenceRowDigest :: T.Text
  , evidenceRowVerifiers :: T.Text
  , evidenceRowApproval :: T.Text
  }

insertEvidence :: O.MonadOrville m => T.Text -> T.Text -> EvidenceRow -> m ()
insertEvidence workOrderId principal row =
  O.executeVoid O.InsertQuery $
    sql "INSERT INTO lockstep_gate_evidence (work_order_id, artifact, digest, verifiers, approval, principal) VALUES ("
      <> commaSeparated [uuid workOrderId, text (evidenceRowArtifact row), text (evidenceRowDigest row), text (evidenceRowVerifiers row), text (evidenceRowApproval row), text principal]
      <> sql ")"

evidenceOf :: O.MonadOrville m => T.Text -> m [EvidenceRow]
evidenceOf workOrderId =
  O.executeAndDecode
    O.SelectQuery
    (sql "SELECT artifact, digest, verifiers, approval FROM lockstep_gate_evidence WHERE work_order_id = " <> uuid workOrderId <> sql " ORDER BY id")
    ( marshal $
        EvidenceRow
          <$> O.marshallField evidenceRowArtifact (O.unboundedTextField "artifact")
          <*> O.marshallField evidenceRowDigest (O.unboundedTextField "digest")
          <*> O.marshallField evidenceRowVerifiers (O.unboundedTextField "verifiers")
          <*> O.marshallField evidenceRowApproval (O.unboundedTextField "approval")
    )

insertScheduleDecision :: O.MonadOrville m => T.Text -> T.Text -> Maybe T.Text -> m ()
insertScheduleDecision rendering digest selected =
  O.executeVoid O.InsertQuery $
    sql "INSERT INTO lockstep_schedule_decisions (rendering, digest, selected_work_order) VALUES ("
      <> commaSeparated [text rendering, text digest, maybeOf uuid selected]
      <> sql ")"

-- | The latest schedule decision: (rendering, digest) (C-P2.8 V2).
latestScheduleDecision :: O.MonadOrville m => m (Maybe (T.Text, T.Text))
latestScheduleDecision =
  headMay
    <$> O.executeAndDecode
      O.SelectQuery
      (sql "SELECT rendering, digest FROM lockstep_schedule_decisions ORDER BY id DESC LIMIT 1")
      ( marshal $
          (,)
            <$> O.marshallField fst (O.unboundedTextField "rendering")
            <*> O.marshallField snd (O.unboundedTextField "digest")
      )

-- | Serializes scheduling runs until the transaction ends.
lockScheduling :: O.MonadOrville m => m ()
lockScheduling =
  O.executeVoid O.OtherQuery (sql "SELECT pg_advisory_xact_lock(hashtext('lockstep-scheduler'))")

insertWorkUnit :: O.MonadOrville m => T.Text -> T.Text -> T.Text -> T.Text -> T.Text -> Maybe T.Text -> m ()
insertWorkUnit unitId workOrderId ticketId repositoryId engineerId planRef =
  O.executeVoid O.InsertQuery $
    sql "INSERT INTO lockstep_work_units (id, work_order_id, ticket_id, repository_id, engineer_id, plan_ref) VALUES ("
      <> commaSeparated [uuid unitId, uuid workOrderId, uuid ticketId, uuid repositoryId, uuid engineerId, maybeOf text planRef]
      <> sql ")"

-- | Every active repository ownership: (repository, owning Engineer).
activeOwners :: O.MonadOrville m => m [(T.Text, T.Text)]
activeOwners =
  O.executeAndDecode
    O.SelectQuery
    (sql "SELECT id::text AS repository_id, owner_engineer_id::text AS engineer_id FROM lockstep_repositories WHERE released_at IS NULL ORDER BY id")
    ( marshal $
        (,)
          <$> O.marshallField fst (uuidField "repository_id")
          <*> O.marshallField snd (uuidField "engineer_id")
    )

-- | The transaction's time (PostgreSQL @now()@): the clock every lease uses.
databaseNow :: O.MonadOrville m => m UTCTime
databaseNow = do
  rows <- O.executeAndDecode O.SelectQuery (sql "SELECT now() AS v") (marshal (O.marshallField id (O.utcTimestampField "v")))
  maybe (liftIO (throwIO (userError "lockstep: SELECT now() returned no row"))) pure (headMay rows)

headMay :: [a] -> Maybe a
headMay xs =
  case xs of
    [] -> Nothing
    x : _ -> Just x
