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
  , ticketTable
  , ticketIdField
  , ticketTitleField
  , WorkOrderRow (..)
  , insertWorkOrder
  , findWorkOrder
  , allWorkOrders
  , workOrderTable
  , workOrderIdField
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
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Maybe (isNothing)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Expr qualified as Expr
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql
import System.IO.Error (userError)

import Lockstep.Persistence.Fields
  ( clockTimestamp
  , forUpdate
  , forUpdateOf
  , headMay
  , joinedOn
  , qualified
  , qualifiedEquals
  , qualifiedOrder
  , qualifiedReference
  , selectJoined
  , selectValue
  , setExpression
  , setNow
  , tableReference
  , uuidField
  )
import Lockstep.Persistence.Repositories (activeRepositoryCondition, repositoryIdField, repositoryOwnerField, repositoryTable)

-- Subjects ---------------------------------------------------------------------

data SubjectRow
  = SubjectRow
  { subjectRowId :: T.Text
  , subjectRowKind :: T.Text
  , subjectRowRevision :: Int32
  , subjectRowState :: T.Text
  }

subjectTable :: O.TableDefinition (O.HasKey T.Text) SubjectRow SubjectRow
subjectTable =
  O.mkTableDefinition "lockstep_subjects" (O.primaryKey subjectIdField) $
    SubjectRow
      <$> O.marshallField subjectRowId subjectIdField
      <*> O.marshallField subjectRowKind subjectKindField
      <*> O.marshallField subjectRowRevision subjectRevisionField
      <*> O.marshallField subjectRowState subjectStateField

subjectIdField :: O.FieldDefinition O.NotNull T.Text
subjectIdField =
  uuidField "id"

subjectKindField :: O.FieldDefinition O.NotNull T.Text
subjectKindField =
  O.unboundedTextField "kind"

subjectRevisionField :: O.FieldDefinition O.NotNull Int32
subjectRevisionField =
  O.integerField "revision"

subjectStateField :: O.FieldDefinition O.NotNull T.Text
subjectStateField =
  O.unboundedTextField "state"

subjectCreatedAtField :: O.FieldDefinition O.NotNull UTCTime
subjectCreatedAtField =
  O.utcTimestampField "created_at"

subjectUpdatedAtField :: O.FieldDefinition O.NotNull UTCTime
subjectUpdatedAtField =
  O.utcTimestampField "updated_at"

-- | The subject row, locked until the transaction ends.
lockSubject :: O.MonadOrville m => T.Text -> m (Maybe SubjectRow)
lockSubject subjectId =
  O.findFirstEntityBy subjectTable (O.where_ (O.fieldEquals subjectIdField subjectId) <> forUpdate)

-- | Every subject of one kind, by id, locked until the transaction ends.
lockSubjectsOfKind :: O.MonadOrville m => T.Text -> m [SubjectRow]
lockSubjectsOfKind kind =
  O.findEntitiesBy
    subjectTable
    (O.where_ (O.fieldEquals subjectKindField kind) <> O.orderBy (O.orderByField subjectIdField O.ascendingOrder) <> forUpdate)

-- | Every subject of one kind, by creation, without locking them (C-P2.8 V2).
subjectsOfKind :: O.MonadOrville m => T.Text -> m [SubjectRow]
subjectsOfKind kind =
  O.findEntitiesBy
    subjectTable
    ( O.where_ (O.fieldEquals subjectKindField kind)
        <> O.orderBy (O.orderByField subjectCreatedAtField O.ascendingOrder <> O.orderByField subjectIdField O.ascendingOrder)
    )

insertSubject :: O.MonadOrville m => T.Text -> T.Text -> T.Text -> m ()
insertSubject subjectId kind state =
  O.insertEntity subjectTable (SubjectRow subjectId kind 1 state)

updateSubject :: O.MonadOrville m => T.Text -> Int32 -> T.Text -> m ()
updateSubject subjectId revision state =
  O.updateFields
    subjectTable
    (O.setField subjectRevisionField revision :| [O.setField subjectStateField state, setNow subjectUpdatedAtField])
    (Just (O.fieldEquals subjectIdField subjectId))

-- | An unlocked subject row (C-P2.9-R1 selection).
subjectRow :: O.MonadOrville m => T.Text -> m (Maybe SubjectRow)
subjectRow subjectId =
  O.findFirstEntityBy subjectTable (O.where_ (O.fieldEquals subjectIdField subjectId))

-- Events -----------------------------------------------------------------------

data EventRow
  = EventRow
  { eventRowSequence :: Int32
  , eventRowPrincipal :: T.Text
  , eventRowCommand :: T.Text
  , eventRowStateAfter :: T.Text
  }

-- | An event row as stored: its identity, its subject and the event.
data StoredEvent
  = StoredEvent
  { storedEventId :: Int64
  , storedEvent :: EventRow
  }

eventTable :: O.TableDefinition O.NoKey (T.Text, EventRow) StoredEvent
eventTable =
  O.mkTableDefinitionWithoutKey "lockstep_events" $
    (\eventId _subject event -> StoredEvent eventId event)
      <$> O.marshallReadOnlyField eventIdField
      <*> O.marshallField fst eventSubjectField
      <*> ( EventRow
              <$> O.marshallField (eventRowSequence . snd) eventSequenceField
              <*> O.marshallField (eventRowPrincipal . snd) (O.unboundedTextField "principal")
              <*> O.marshallField (eventRowCommand . snd) (O.unboundedTextField "command")
              <*> O.marshallField (eventRowStateAfter . snd) (O.unboundedTextField "state_after")
          )

eventIdField :: O.FieldDefinition O.NotNull Int64
eventIdField =
  O.bigIntegerField "id"

eventSubjectField :: O.FieldDefinition O.NotNull T.Text
eventSubjectField =
  uuidField "subject_id"

eventSequenceField :: O.FieldDefinition O.NotNull Int32
eventSequenceField =
  O.integerField "sequence"

insertEvent :: O.MonadOrville m => T.Text -> EventRow -> m (Maybe Int64)
insertEvent subjectId row =
  fmap storedEventId . headMay <$> O.insertAndReturnEntities eventTable ((subjectId, row) :| [])

-- | The subject's events, in sequence order.
subjectEvents :: O.MonadOrville m => T.Text -> m [EventRow]
subjectEvents subjectId =
  fmap storedEvent
    <$> O.findEntitiesBy
      eventTable
      (O.where_ (O.fieldEquals eventSubjectField subjectId) <> O.orderBy (O.orderByField eventSequenceField O.ascendingOrder))

-- Decision refusals ------------------------------------------------------------

data NewRefusal
  = NewRefusal
  { refusalSubject :: T.Text
  , refusalExpectedRevision :: Int32
  , refusalPrincipal :: T.Text
  , refusalCommand :: T.Text
  , refusalCode :: T.Text
  }

refusalTable :: O.TableDefinition O.NoKey NewRefusal NewRefusal
refusalTable =
  O.mkTableDefinitionWithoutKey "lockstep_decision_refusals" $
    NewRefusal
      <$> O.marshallField refusalSubject (uuidField "subject_id")
      <*> O.marshallField refusalExpectedRevision (O.integerField "expected_revision")
      <*> O.marshallField refusalPrincipal (O.unboundedTextField "principal")
      <*> O.marshallField refusalCommand (O.unboundedTextField "command")
      <*> O.marshallField refusalCode (O.unboundedTextField "refusal_code")

insertRefusal :: O.MonadOrville m => NewRefusal -> m ()
insertRefusal =
  O.insertEntity refusalTable

-- | Every decision refusal, oldest first (C-P2.8 V2).
allRefusals :: O.MonadOrville m => m [NewRefusal]
allRefusals =
  O.findEntitiesBy refusalTable (O.orderBy (O.orderByField identityField O.ascendingOrder))

-- | The @id bigint GENERATED ALWAYS AS IDENTITY@ column of the append-only tables; only ordered by.
identityField :: O.FieldDefinition O.NotNull Int64
identityField =
  O.bigIntegerField "id"

-- Tickets ----------------------------------------------------------------------

data TicketRow
  = TicketRow
  { ticketRowId :: T.Text
  , ticketRowTitle :: T.Text
  , ticketRowContentRevision :: Int32
  }

ticketTable :: O.TableDefinition (O.HasKey T.Text) TicketRow TicketRow
ticketTable =
  O.mkTableDefinition "lockstep_tickets" (O.primaryKey ticketIdField) $
    TicketRow
      <$> O.marshallField ticketRowId ticketIdField
      <*> O.marshallField ticketRowTitle ticketTitleField
      <*> O.marshallField ticketRowContentRevision ticketContentRevisionField

ticketIdField :: O.FieldDefinition O.NotNull T.Text
ticketIdField =
  uuidField "id"

ticketTitleField :: O.FieldDefinition O.NotNull T.Text
ticketTitleField =
  O.unboundedTextField "title"

ticketContentRevisionField :: O.FieldDefinition O.NotNull Int32
ticketContentRevisionField =
  O.integerField "content_revision"

insertTicket :: O.MonadOrville m => T.Text -> T.Text -> m ()
insertTicket ticketId title =
  O.insertEntity ticketTable (TicketRow ticketId title 1)

findTicket :: O.MonadOrville m => T.Text -> m (Maybe TicketRow)
findTicket ticketId =
  O.findFirstEntityBy ticketTable (O.where_ (O.fieldEquals ticketIdField ticketId))

updateTicket :: O.MonadOrville m => T.Text -> T.Text -> Int32 -> m ()
updateTicket ticketId title contentRevision =
  O.updateFields
    ticketTable
    (O.setField ticketTitleField title :| [O.setField ticketContentRevisionField contentRevision])
    (Just (O.fieldEquals ticketIdField ticketId))

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

workOrderTable :: O.TableDefinition (O.HasKey T.Text) WorkOrderRow WorkOrderRow
workOrderTable =
  O.mkTableDefinition "lockstep_work_orders" (O.primaryKey workOrderIdField) $
    WorkOrderRow
      <$> O.marshallField workOrderRowId workOrderIdField
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

workOrderIdField :: O.FieldDefinition O.NotNull T.Text
workOrderIdField =
  uuidField "id"

insertWorkOrder :: O.MonadOrville m => WorkOrderRow -> m ()
insertWorkOrder =
  O.insertEntity workOrderTable

findWorkOrder :: O.MonadOrville m => T.Text -> m (Maybe WorkOrderRow)
findWorkOrder workOrderId =
  O.findFirstEntityBy workOrderTable (O.where_ (O.fieldEquals workOrderIdField workOrderId))

allWorkOrders :: O.MonadOrville m => m [WorkOrderRow]
allWorkOrders =
  O.findEntitiesBy workOrderTable (O.orderBy (O.orderByField workOrderIdField O.ascendingOrder))

-- | (Work Order, the Work Order it depends on).
dependencyTable :: O.TableDefinition O.NoKey (T.Text, T.Text) (T.Text, T.Text)
dependencyTable =
  O.mkTableDefinitionWithoutKey "lockstep_work_order_dependencies" $
    (,)
      <$> O.marshallField fst dependencyWorkOrderField
      <*> O.marshallField snd dependencyDependsOnField

dependencyWorkOrderField :: O.FieldDefinition O.NotNull T.Text
dependencyWorkOrderField =
  uuidField "work_order_id"

dependencyDependsOnField :: O.FieldDefinition O.NotNull T.Text
dependencyDependsOnField =
  uuidField "depends_on"

insertDependency :: O.MonadOrville m => T.Text -> T.Text -> m ()
insertDependency workOrderId dependsOn =
  O.insertEntity dependencyTable (workOrderId, dependsOn)

dependenciesOf :: O.MonadOrville m => T.Text -> m [T.Text]
dependenciesOf workOrderId =
  fmap snd
    <$> O.findEntitiesBy
      dependencyTable
      (O.where_ (O.fieldEquals dependencyWorkOrderField workOrderId) <> O.orderBy (O.orderByField dependencyDependsOnField O.ascendingOrder))

data SourceRow
  = SourceRow
  { sourceRowLevel :: T.Text
  , sourceRowProfile :: T.Text
  , sourceRowVersion :: Int32
  , sourceRowDigest :: T.Text
  }

-- | (Work Order, position, source); read back as the source alone.
sourceTable :: O.TableDefinition O.NoKey (T.Text, Int32, SourceRow) SourceRow
sourceTable =
  O.mkTableDefinitionWithoutKey "lockstep_work_order_profile_sources" $
    (\_workOrder _position source -> source)
      <$> O.marshallField (\(w, _, _) -> w) sourceWorkOrderField
      <*> O.marshallField (\(_, p, _) -> p) sourcePositionField
      <*> ( SourceRow
              <$> O.marshallField (\(_, _, s) -> sourceRowLevel s) (O.unboundedTextField "level")
              <*> O.marshallField (\(_, _, s) -> sourceRowProfile s) (O.unboundedTextField "profile_id")
              <*> O.marshallField (\(_, _, s) -> sourceRowVersion s) (O.integerField "version")
              <*> O.marshallField (\(_, _, s) -> sourceRowDigest s) (O.unboundedTextField "digest")
          )

sourceWorkOrderField :: O.FieldDefinition O.NotNull T.Text
sourceWorkOrderField =
  uuidField "work_order_id"

sourcePositionField :: O.FieldDefinition O.NotNull Int32
sourcePositionField =
  O.integerField "position"

insertSource :: O.MonadOrville m => T.Text -> Int32 -> SourceRow -> m ()
insertSource workOrderId position row =
  O.insertEntity sourceTable (workOrderId, position, row)

-- | The bound sources, in their order.
sourcesOf :: O.MonadOrville m => T.Text -> m [SourceRow]
sourcesOf workOrderId =
  O.findEntitiesBy
    sourceTable
    (O.where_ (O.fieldEquals sourceWorkOrderField workOrderId) <> O.orderBy (O.orderByField sourcePositionField O.ascendingOrder))

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

{- | The intent table's own columns. Its rows carry their subject's kind,
which lives in @lockstep_subjects@, so the table reads a row still waiting
for that kind; 'intentRows' supplies it from the join.
-}
intentTable :: O.TableDefinition (O.HasKey T.Text) IntentRow (T.Text -> IntentRow)
intentTable =
  O.mkTableDefinition "lockstep_effect_intents" (O.primaryKey intentOperationField) intentColumns

intentColumns :: O.SqlMarshaller IntentRow (T.Text -> IntentRow)
intentColumns =
  ( \operation subject basis key event spec class_ budget lifetime refuses authoritative excludesLate parameters digest state generation dispatches leaseOwner leaseUntil outcome settled activation firstDispatched kind ->
      IntentRow operation subject kind basis key event spec class_ budget lifetime refuses authoritative excludesLate parameters digest state generation dispatches leaseOwner leaseUntil outcome settled activation firstDispatched
  )
    <$> O.marshallField intentRowOperation intentOperationField
    <*> O.marshallField intentRowSubject intentSubjectField
    <*> O.marshallField intentRowBasisRevision (O.integerField "basis_revision")
    <*> O.marshallField intentRowKey (O.unboundedTextField "effect_key")
    <*> O.marshallField intentRowEvent (O.bigIntegerField "event_id")
    <*> O.marshallField intentRowSpecName (O.unboundedTextField "spec_name")
    <*> O.marshallField intentRowClass intentClassField
    <*> O.marshallField intentRowBudget intentBudgetField
    <*> O.marshallField intentRowKeyLifetime (O.nullableField (O.bigIntegerField "key_lifetime_seconds"))
    <*> O.marshallField intentRowRefusesChanged (O.nullableField (O.booleanField "refuses_changed_parameters"))
    <*> O.marshallField intentRowLookupAuthoritative (O.nullableField (O.booleanField "lookup_authoritative"))
    <*> O.marshallField intentRowLookupExcludesLate (O.nullableField (O.booleanField "lookup_excludes_late_application"))
    <*> O.marshallField intentRowParameters (O.unboundedTextField "parameters")
    <*> O.marshallField intentRowParametersDigest (O.unboundedTextField "parameters_digest")
    <*> O.marshallField intentRowState intentStateField
    <*> O.marshallField intentRowGeneration intentGenerationField
    <*> O.marshallField intentRowDispatches intentDispatchesField
    <*> O.marshallField intentRowLeaseOwner intentLeaseOwnerField
    <*> O.marshallField intentRowLeaseUntil intentLeaseUntilField
    <*> O.marshallField intentRowOutcome intentOutcomeField
    <*> O.marshallField intentRowSettledApplied intentSettledField
    <*> O.marshallField intentRowActivation intentActivationField
    <*> O.marshallField intentRowFirstDispatched intentFirstDispatchedField

intentOperationField :: O.FieldDefinition O.NotNull T.Text
intentOperationField =
  uuidField "operation_id"

intentSubjectField :: O.FieldDefinition O.NotNull T.Text
intentSubjectField =
  uuidField "subject_id"

intentClassField :: O.FieldDefinition O.NotNull T.Text
intentClassField =
  O.unboundedTextField "effect_class"

intentBudgetField :: O.FieldDefinition O.NotNull Int32
intentBudgetField =
  O.integerField "retry_budget"

intentStateField :: O.FieldDefinition O.NotNull T.Text
intentStateField =
  O.unboundedTextField "state"

intentGenerationField :: O.FieldDefinition O.NotNull Int32
intentGenerationField =
  O.integerField "generation"

intentDispatchesField :: O.FieldDefinition O.NotNull Int32
intentDispatchesField =
  O.integerField "dispatches"

intentLeaseOwnerField :: O.FieldDefinition O.Nullable (Maybe T.Text)
intentLeaseOwnerField =
  O.nullableField (O.unboundedTextField "lease_owner")

intentLeaseUntilField :: O.FieldDefinition O.Nullable (Maybe UTCTime)
intentLeaseUntilField =
  O.nullableField (O.utcTimestampField "lease_until")

intentOutcomeField :: O.FieldDefinition O.Nullable (Maybe T.Text)
intentOutcomeField =
  O.nullableField (O.unboundedTextField "outcome_text")

intentSettledField :: O.FieldDefinition O.Nullable (Maybe Bool)
intentSettledField =
  O.nullableField (O.booleanField "settled_applied")

intentActivationField :: O.FieldDefinition O.NotNull Int32
intentActivationField =
  O.integerField "activation_generation"

intentFirstDispatchedField :: O.FieldDefinition O.Nullable (Maybe UTCTime)
intentFirstDispatchedField =
  O.nullableField (O.utcTimestampField "first_dispatched_at")

intentUpdatedAtField :: O.FieldDefinition O.NotNull UTCTime
intentUpdatedAtField =
  O.utcTimestampField "updated_at"

{- | Inserts the intent's identity, spec, parameters and starting lifecycle.
Its lease, outcome, settlement and first dispatch start empty, whatever the
row says, as the columns' defaults always made them.
-}
insertIntent :: O.MonadOrville m => IntentRow -> m ()
insertIntent row =
  O.insertEntity
    intentTable
    row
      { intentRowLeaseOwner = Nothing
      , intentRowLeaseUntil = Nothing
      , intentRowOutcome = Nothing
      , intentRowSettledApplied = Nothing
      , intentRowFirstDispatched = Nothing
      }

-- | The intent row with its subject's kind, locked until the transaction ends.
lockIntent :: O.MonadOrville m => T.Text -> m (Maybe IntentRow)
lockIntent operation =
  headMay <$> intentRows (O.where_ (qualifiedEquals (qualified intentTable intentOperationField) operation) <> forUpdateOf intentTable)

-- | The intent row, without locking it (C-P2.9-R1 selection).
findIntent :: O.MonadOrville m => T.Text -> m (Maybe IntentRow)
findIntent operation =
  headMay <$> intentRows (O.where_ (qualifiedEquals (qualified intentTable intentOperationField) operation))

-- | A subject's intent rows, oldest first, without locking them (C-P2.8 V2).
intentsOfSubject :: O.MonadOrville m => T.Text -> m [IntentRow]
intentsOfSubject subjectId =
  intentRows
    ( O.where_ (qualifiedEquals (qualified intentTable intentSubjectField) subjectId)
        <> O.orderBy (qualifiedOrder (qualified intentTable identityField) O.ascendingOrder)
    )

-- | Intents joined to their subjects, which give each row its subject's kind.
intentRows :: O.MonadOrville m => O.SelectOptions -> m [IntentRow]
intentRows =
  selectJoined
    ( O.marshallQualifyFields (O.tableIdentifier intentTable) intentColumns
        <*> O.marshallReadOnly (O.marshallQualifyFields (O.tableIdentifier subjectTable) (O.marshallReadOnlyField subjectKindField))
    )
    intentsWithSubjects

intentsWithSubjects :: Expr.TableReference
intentsWithSubjects =
  joinedOn
    intentTable
    [
      ( Expr.innerJoinType
      , tableReference subjectTable
      , Expr.equals
          (qualifiedReference (qualified subjectTable subjectIdField))
          (qualifiedReference (qualified intentTable intentSubjectField))
      )
    ]

-- | C-P2.9-R1 M2: rebinds an intent to the activation a Human carried it into.
setActivation :: O.MonadOrville m => T.Text -> Int32 -> m ()
setActivation operation generation =
  O.updateFields
    intentTable
    (O.setField intentActivationField generation :| [setNow intentUpdatedAtField])
    (Just (O.fieldEquals intentOperationField operation))

{- | C-P2.9-R1 M3: this transaction reads one consistent snapshot and writes
nothing. It must be its first statement. Orville sets isolation only when it
begins a transaction, and the caller's transaction is already open, so the
statement is given as SQL.
-}
readOnlySnapshot :: O.MonadOrville m => m ()
readOnlySnapshot =
  O.executeVoid O.OtherQuery (RawSql.fromString "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")

-- | The statement's own time (PostgreSQL @clock_timestamp()@), for checks that must not use the transaction's start (C-P2.9-R1 M6).
databaseClock :: O.MonadOrville m => m UTCTime
databaseClock = do
  rows <- selectValue clockTimestamp (O.utcTimestampField "v")
  maybe (liftIO (throwIO (userError "lockstep: SELECT clock_timestamp() returned no row"))) pure (headMay rows)

{- | Writes the lifecycle columns only; a trigger refuses any change to the
identity, spec or parameters. The first time an intent is written as
dispatched, its first dispatch time is stamped from the database clock and
never changed again (C-P2.9-R1 M1).
-}
updateIntent :: O.MonadOrville m => IntentRow -> m ()
updateIntent row =
  O.updateFields
    intentTable
    ( O.setField intentStateField (intentRowState row)
        :| ( [ O.setField intentGenerationField (intentRowGeneration row)
             , O.setField intentDispatchesField (intentRowDispatches row)
             , O.setField intentLeaseOwnerField (intentRowLeaseOwner row)
             , O.setField intentLeaseUntilField (intentRowLeaseUntil row)
             , O.setField intentOutcomeField (intentRowOutcome row)
             , O.setField intentSettledField (intentRowSettledApplied row)
             , setNow intentUpdatedAtField
             ]
               <> [ setExpression intentFirstDispatchedField (Expr.coalesce (O.fieldColumnReference intentFirstDispatchedField :| [clockTimestamp]))
                  | intentRowState row == T.pack "dispatched"
                  ]
           )
    )
    (Just (O.fieldEquals intentOperationField (intentRowOperation row)))

-- Observations -------------------------------------------------------------------

data ObservationRow
  = ObservationRow
  { observationRowGeneration :: Int32
  , observationRowText :: T.Text
  , observationRowAccepted :: Bool
  , observationRowRefusal :: Maybe T.Text
  }

-- | (operation id, observation); read back as the observation.
observationTable :: O.TableDefinition O.NoKey (T.Text, ObservationRow) ObservationRow
observationTable =
  O.mkTableDefinitionWithoutKey "lockstep_effect_observations" $
    (\_operation observation -> observation)
      <$> O.marshallField fst operationReferenceField
      <*> ( ObservationRow
              <$> O.marshallField (observationRowGeneration . snd) (O.integerField "generation")
              <*> O.marshallField (observationRowText . snd) (O.unboundedTextField "observation")
              <*> O.marshallField (observationRowAccepted . snd) (O.booleanField "accepted")
              <*> O.marshallField (observationRowRefusal . snd) (O.nullableField (O.unboundedTextField "refusal_code"))
          )

-- | The @operation_id@ column of the tables recorded against an intent.
operationReferenceField :: O.FieldDefinition O.NotNull T.Text
operationReferenceField =
  uuidField "operation_id"

insertObservation :: O.MonadOrville m => T.Text -> Int32 -> T.Text -> Maybe T.Text -> m ()
insertObservation operation generation observation refusal =
  O.insertEntity observationTable (operation, ObservationRow generation observation (isNothing refusal) refusal)

observationsOf :: O.MonadOrville m => T.Text -> m [ObservationRow]
observationsOf operation =
  O.findEntitiesBy
    observationTable
    (O.where_ (O.fieldEquals operationReferenceField operation) <> O.orderBy (O.orderByField identityField O.ascendingOrder))

-- Execution and recovery (C-P2.6) ------------------------------------------------

-- | An intent's operation id alone.
operationIds :: O.MonadOrville m => O.SelectOptions -> m [T.Text]
operationIds =
  selectJoined (O.marshallReadOnlyField intentOperationField) (tableReference intentTable)

-- | The intent's subject, read without a lock (the caller locks the subject first, then the intent).
intentSubject :: O.MonadOrville m => T.Text -> m (Maybe T.Text)
intentSubject operation =
  headMay
    <$> selectJoined
      (O.marshallReadOnlyField intentSubjectField)
      (tableReference intentTable)
      (O.where_ (O.fieldEquals intentOperationField operation))

-- | X10: intents of active Work Orders that may be claimed now, oldest first.
runnableIntentIds :: O.MonadOrville m => m [T.Text]
runnableIntentIds =
  let
    stateIs value = qualifiedEquals (ofIntent intentStateField) (T.pack value)
    leaseEnded = Expr.lessThanOrEqualTo (qualifiedReference (ofIntent intentLeaseUntilField)) Expr.now
    retriesLeft = Expr.lessThanOrEqualTo (qualifiedReference (ofIntent intentDispatchesField)) (qualifiedReference (ofIntent intentBudgetField))
  in
    selectJoined
      (O.marshallQualifyFields (O.tableIdentifier intentTable) (O.marshallReadOnlyField intentOperationField))
      intentsWithSubjects
      ( O.where_
          ( qualifiedEquals (ofSubject subjectKindField) (T.pack "work-order")
              `O.andExpr` qualifiedEquals (ofSubject subjectStateField) (T.pack "active")
              `O.andExpr` Expr.parenthesized
                ( stateIs "pending"
                    `O.orExpr` Expr.parenthesized (stateIs "claimed" `O.andExpr` leaseEnded)
                    `O.orExpr` Expr.parenthesized (stateIs "confirmed-not-applied" `O.andExpr` retriesLeft)
                )
          )
          <> O.orderBy (qualifiedOrder (ofIntent identityField) O.ascendingOrder)
      )

-- | A column of @lockstep_effect_intents@ in a join.
ofIntent :: O.FieldDefinition nullability a -> O.QualifiedFieldDefinition O.TableIdentifier nullability a
ofIntent =
  qualified intentTable

-- | A column of @lockstep_subjects@ in a join.
ofSubject :: O.FieldDefinition nullability a -> O.QualifiedFieldDefinition O.TableIdentifier nullability a
ofSubject =
  qualified subjectTable

-- | X10: dispatched intents whose lease has ended, oldest first.
recoverableIntentIds :: O.MonadOrville m => m [T.Text]
recoverableIntentIds =
  operationIds
    ( O.where_
        ( O.fieldEquals intentStateField (T.pack "dispatched")
            `O.andExpr` Expr.lessThanOrEqualTo (O.fieldColumnReference intentLeaseUntilField) Expr.now
        )
        <> O.orderBy (O.orderByField identityField O.ascendingOrder)
    )

data RecoveryRow
  = RecoveryRow
  { recoveryRowGeneration :: Int32
  , recoveryRowDecision :: T.Text
  }

recoveryTable :: O.TableDefinition O.NoKey (T.Text, RecoveryRow) RecoveryRow
recoveryTable =
  O.mkTableDefinitionWithoutKey "lockstep_effect_recoveries" $
    (\_operation recovery -> recovery)
      <$> O.marshallField fst operationReferenceField
      <*> ( RecoveryRow
              <$> O.marshallField (recoveryRowGeneration . snd) (O.integerField "generation")
              <*> O.marshallField (recoveryRowDecision . snd) (O.unboundedTextField "decision")
          )

insertRecovery :: O.MonadOrville m => T.Text -> Int32 -> T.Text -> m ()
insertRecovery operation generation decision =
  O.insertEntity recoveryTable (operation, RecoveryRow generation decision)

recoveriesOf :: O.MonadOrville m => T.Text -> m [RecoveryRow]
recoveriesOf operation =
  O.findEntitiesBy
    recoveryTable
    (O.where_ (O.fieldEquals operationReferenceField operation) <> O.orderBy (O.orderByField identityField O.ascendingOrder))

-- Reconciliation and resolution (C-P2.7) ----------------------------------------

-- | R4: queryable intents whose outcome is unknown, or dispatched with an ended lease, oldest first.
reconcilableIntentIds :: O.MonadOrville m => m [T.Text]
reconcilableIntentIds =
  operationIds
    ( O.where_
        ( O.fieldEquals intentClassField (T.pack "queryable")
            `O.andExpr` Expr.parenthesized
              ( O.fieldEquals intentStateField (T.pack "outcome-unknown")
                  `O.orExpr` Expr.parenthesized
                    ( O.fieldEquals intentStateField (T.pack "dispatched")
                        `O.andExpr` Expr.lessThanOrEqualTo (O.fieldColumnReference intentLeaseUntilField) Expr.now
                    )
              )
        )
        <> O.orderBy (O.orderByField identityField O.ascendingOrder)
    )

data ResolutionRow
  = ResolutionRow
  { resolutionRowGeneration :: Int32
  , resolutionRowBasis :: T.Text
  , resolutionRowDecision :: T.Text
  , resolutionRowAcknowledged :: Bool
  }

resolutionTable :: O.TableDefinition O.NoKey (T.Text, ResolutionRow) ResolutionRow
resolutionTable =
  O.mkTableDefinitionWithoutKey "lockstep_effect_resolutions" $
    (\_operation resolution -> resolution)
      <$> O.marshallField fst operationReferenceField
      <*> ( ResolutionRow
              <$> O.marshallField (resolutionRowGeneration . snd) (O.integerField "generation")
              <*> O.marshallField (resolutionRowBasis . snd) (O.unboundedTextField "basis")
              <*> O.marshallField (resolutionRowDecision . snd) (O.unboundedTextField "decision")
              <*> O.marshallField (resolutionRowAcknowledged . snd) (O.booleanField "duplication_acknowledged")
          )

insertResolution :: O.MonadOrville m => T.Text -> Int32 -> T.Text -> T.Text -> Bool -> m ()
insertResolution operation generation basis decision acknowledged =
  O.insertEntity resolutionTable (operation, ResolutionRow generation basis decision acknowledged)

resolutionsOf :: O.MonadOrville m => T.Text -> m [ResolutionRow]
resolutionsOf operation =
  O.findEntitiesBy
    resolutionTable
    (O.where_ (O.fieldEquals operationReferenceField operation) <> O.orderBy (O.orderByField identityField O.ascendingOrder))

-- Evidence, schedule decisions, Work Units -------------------------------------

data EvidenceRow
  = EvidenceRow
  { evidenceRowArtifact :: T.Text
  , evidenceRowDigest :: T.Text
  , evidenceRowVerifiers :: T.Text
  , evidenceRowApproval :: T.Text
  }

-- | (Work Order, principal, evidence); read back as the evidence.
evidenceTable :: O.TableDefinition O.NoKey (T.Text, T.Text, EvidenceRow) EvidenceRow
evidenceTable =
  O.mkTableDefinitionWithoutKey "lockstep_gate_evidence" $
    (\_workOrder _principal evidence -> evidence)
      <$> O.marshallField (\(w, _, _) -> w) evidenceWorkOrderField
      <*> O.marshallField (\(_, p, _) -> p) (O.unboundedTextField "principal")
      <*> ( EvidenceRow
              <$> O.marshallField (\(_, _, e) -> evidenceRowArtifact e) (O.unboundedTextField "artifact")
              <*> O.marshallField (\(_, _, e) -> evidenceRowDigest e) (O.unboundedTextField "digest")
              <*> O.marshallField (\(_, _, e) -> evidenceRowVerifiers e) (O.unboundedTextField "verifiers")
              <*> O.marshallField (\(_, _, e) -> evidenceRowApproval e) (O.unboundedTextField "approval")
          )

evidenceWorkOrderField :: O.FieldDefinition O.NotNull T.Text
evidenceWorkOrderField =
  uuidField "work_order_id"

insertEvidence :: O.MonadOrville m => T.Text -> T.Text -> EvidenceRow -> m ()
insertEvidence workOrderId principal row =
  O.insertEntity evidenceTable (workOrderId, principal, row)

evidenceOf :: O.MonadOrville m => T.Text -> m [EvidenceRow]
evidenceOf workOrderId =
  O.findEntitiesBy
    evidenceTable
    (O.where_ (O.fieldEquals evidenceWorkOrderField workOrderId) <> O.orderBy (O.orderByField identityField O.ascendingOrder))

-- | (rendering, digest, selected Work Order); read back as (rendering, digest).
scheduleDecisionTable :: O.TableDefinition O.NoKey (T.Text, T.Text, Maybe T.Text) (T.Text, T.Text)
scheduleDecisionTable =
  O.mkTableDefinitionWithoutKey "lockstep_schedule_decisions" $
    (\rendering digest _selected -> (rendering, digest))
      <$> O.marshallField (\(r, _, _) -> r) (O.unboundedTextField "rendering")
      <*> O.marshallField (\(_, d, _) -> d) (O.unboundedTextField "digest")
      <*> O.marshallField (\(_, _, s) -> s) (O.nullableField (uuidField "selected_work_order"))

insertScheduleDecision :: O.MonadOrville m => T.Text -> T.Text -> Maybe T.Text -> m ()
insertScheduleDecision rendering digest selected =
  O.insertEntity scheduleDecisionTable (rendering, digest, selected)

-- | The latest schedule decision: (rendering, digest) (C-P2.8 V2).
latestScheduleDecision :: O.MonadOrville m => m (Maybe (T.Text, T.Text))
latestScheduleDecision =
  O.findFirstEntityBy scheduleDecisionTable (O.orderBy (O.orderByField identityField O.descendingOrder))

{- | Serializes scheduling runs until the transaction ends. Orville has no
advisory locks; the lock key is a constant.
-}
lockScheduling :: O.MonadOrville m => m ()
lockScheduling =
  O.executeVoid O.OtherQuery (RawSql.fromString "SELECT pg_advisory_xact_lock(hashtext('lockstep-scheduler'))")

data WorkUnitRow
  = WorkUnitRow
  { workUnitRowId :: T.Text
  , workUnitRowWorkOrder :: T.Text
  , workUnitRowTicket :: T.Text
  , workUnitRowRepository :: T.Text
  , workUnitRowEngineer :: T.Text
  , workUnitRowPlanRef :: Maybe T.Text
  }

workUnitTable :: O.TableDefinition (O.HasKey T.Text) WorkUnitRow WorkUnitRow
workUnitTable =
  O.mkTableDefinition "lockstep_work_units" (O.primaryKey (uuidField "id")) $
    WorkUnitRow
      <$> O.marshallField workUnitRowId (uuidField "id")
      <*> O.marshallField workUnitRowWorkOrder (uuidField "work_order_id")
      <*> O.marshallField workUnitRowTicket (uuidField "ticket_id")
      <*> O.marshallField workUnitRowRepository (uuidField "repository_id")
      <*> O.marshallField workUnitRowEngineer (uuidField "engineer_id")
      <*> O.marshallField workUnitRowPlanRef (O.nullableField (O.unboundedTextField "plan_ref"))

insertWorkUnit :: O.MonadOrville m => T.Text -> T.Text -> T.Text -> T.Text -> T.Text -> Maybe T.Text -> m ()
insertWorkUnit unitId workOrderId ticketId repositoryId engineerId planRef =
  O.insertEntity workUnitTable (WorkUnitRow unitId workOrderId ticketId repositoryId engineerId planRef)

-- | Every active repository ownership: (repository, owning Engineer).
activeOwners :: O.MonadOrville m => m [(T.Text, T.Text)]
activeOwners =
  selectJoined
    ( (,)
        <$> O.marshallReadOnlyField repositoryIdField
        <*> O.marshallReadOnlyField repositoryOwnerField
    )
    (tableReference repositoryTable)
    (O.where_ activeRepositoryCondition <> O.orderBy (O.orderByField repositoryIdField O.ascendingOrder))

-- | The transaction's time (PostgreSQL @now()@): the clock every lease uses.
databaseNow :: O.MonadOrville m => m UTCTime
databaseNow = do
  rows <- selectValue Expr.now (O.utcTimestampField "v")
  maybe (liftIO (throwIO (userError "lockstep: SELECT now() returned no row"))) pure (headMay rows)
