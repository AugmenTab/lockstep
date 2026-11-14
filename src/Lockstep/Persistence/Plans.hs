{-# LANGUAGE TypeFamilies #-}

{- | Storage for Master Plans (contract C-P6.4 M4–M7, M10; migration 24).
Plans, revisions, decisions, units, edges and reconciliations are written once
and never changed; a draft is started once and finished once. Proposals and
decisions are serialized by 'lockPlans'.
-}
module Lockstep.Persistence.Plans
  ( PlanRow (..)
  , RevisionRow (..)
  , DecisionRow (..)
  , UnitRow (..)
  , EdgeRow (..)
  , ReconciliationRow (..)
  , DraftRow (..)
  , lockPlans
  , findPlanOf
  , insertPlan
  , planRevisions
  , findRevisionByKey
  , insertRevision
  , decisionOf
  , insertDecision
  , insertUnits
  , revisionUnits
  , insertEdges
  , revisionEdges
  , insertReconciliations
  , revisionReconciliations
  , findDraftByKey
  , insertDraft
  , projectDrafts
  , pendingDrafts
  , unfinishedDrafts
  , startDraft
  , finishDraft
  ) where

import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text qualified as T
import Data.Time (UTCTime)
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql
import Text.Show (Show)

import Lockstep.Kernel.Identity (PlanDraftId (..), PlanId (..), PlanRevisionId (..), ProjectId, TaskId)
import Lockstep.Persistence.Entity (EntityKey, Table, foreignKeyTo, keyField, mkEntityTable, nullableForeignKeyTo)
import Lockstep.Persistence.Fields (setNow)
import Lockstep.Persistence.Projects (projectIdField, projectTable)
import Lockstep.Persistence.Tasks (taskIdField, taskTable)

-- lockstep_plans ---------------------------------------------------------------------

data PlanRow
  = PlanRow
  { planRowId :: PlanId
  , planRowProject :: ProjectId
  }
  deriving (Eq, Show)

type instance EntityKey PlanRow = PlanId

planTable :: Table PlanRow PlanRow
planTable =
  mkEntityTable "lockstep_plans" planIdField $
    PlanRow
      <$> O.marshallField planRowId planIdField
      <*> O.marshallField planRowProject planProjectField

planIdField :: O.FieldDefinition O.NotNull PlanId
planIdField =
  keyField "id"

planProjectField :: O.FieldDefinition O.NotNull ProjectId
planProjectField =
  foreignKeyTo projectTable projectIdField "project_id"

{- | Serializes plan proposals, decisions and drafts until the transaction
ends; reads stay possible. Orville has no table-lock statement.
-}
lockPlans :: O.MonadOrville m => m ()
lockPlans =
  O.executeVoid O.OtherQuery (RawSql.fromString "LOCK TABLE lockstep_plans IN EXCLUSIVE MODE")

findPlanOf :: O.MonadOrville m => ProjectId -> m (Maybe PlanRow)
findPlanOf project =
  O.findFirstEntityBy planTable (O.where_ (O.fieldEquals planProjectField project))

insertPlan :: O.MonadOrville m => PlanRow -> m ()
insertPlan =
  O.insertEntity planTable

-- lockstep_plan_revisions --------------------------------------------------------------

data RevisionRow
  = RevisionRow
  { revisionRowId :: PlanRevisionId
  , revisionRowPlan :: PlanId
  , revisionRowNumber :: Int32
  , revisionRowDigest :: T.Text
  , revisionRowDocument :: T.Text
  , revisionRowProposedBy :: T.Text
  , revisionRowProposer :: T.Text
  , revisionRowDraft :: Maybe PlanDraftId
  , revisionRowKey :: T.Text
  , revisionRowUncertainties :: Int32
  }
  deriving (Eq, Show)

type instance EntityKey RevisionRow = PlanRevisionId

revisionTable :: Table RevisionRow RevisionRow
revisionTable =
  mkEntityTable "lockstep_plan_revisions" revisionIdField $
    RevisionRow
      <$> O.marshallField revisionRowId revisionIdField
      <*> O.marshallField revisionRowPlan revisionPlanField
      <*> O.marshallField revisionRowNumber revisionNumberField
      <*> O.marshallField revisionRowDigest (O.unboundedTextField "digest")
      <*> O.marshallField revisionRowDocument (O.unboundedTextField "document")
      <*> O.marshallField revisionRowProposedBy (O.unboundedTextField "proposed_by")
      <*> O.marshallField revisionRowProposer (O.unboundedTextField "proposer")
      <*> O.marshallField revisionRowDraft (nullableForeignKeyTo draftTable draftIdField "draft_id")
      <*> O.marshallField revisionRowKey revisionKeyField
      <*> O.marshallField revisionRowUncertainties (O.integerField "uncertainties")

revisionIdField :: O.FieldDefinition O.NotNull PlanRevisionId
revisionIdField =
  keyField "id"

revisionPlanField :: O.FieldDefinition O.NotNull PlanId
revisionPlanField =
  foreignKeyTo planTable planIdField "plan_id"

revisionNumberField :: O.FieldDefinition O.NotNull Int32
revisionNumberField =
  O.integerField "revision_number"

revisionKeyField :: O.FieldDefinition O.NotNull T.Text
revisionKeyField =
  O.unboundedTextField "idempotency_key"

-- | A plan's revisions, newest first.
planRevisions :: O.MonadOrville m => PlanId -> m [RevisionRow]
planRevisions plan =
  O.findEntitiesBy
    revisionTable
    (O.where_ (O.fieldEquals revisionPlanField plan) <> O.orderBy (O.orderByField revisionNumberField O.descendingOrder))

findRevisionByKey :: O.MonadOrville m => T.Text -> m (Maybe RevisionRow)
findRevisionByKey k =
  O.findFirstEntityBy revisionTable (O.where_ (O.fieldEquals revisionKeyField k))

insertRevision :: O.MonadOrville m => RevisionRow -> m ()
insertRevision =
  O.insertEntity revisionTable

-- lockstep_plan_decisions ---------------------------------------------------------------

data DecisionRow
  = DecisionRow
  { decisionRowRevision :: PlanRevisionId
  , decisionRowDecision :: T.Text
  , decisionRowDigest :: T.Text
  , decisionRowActor :: T.Text
  }
  deriving (Eq, Show)

type instance EntityKey DecisionRow = PlanRevisionId

decisionTable :: Table DecisionRow DecisionRow
decisionTable =
  mkEntityTable "lockstep_plan_decisions" decisionRevisionField $
    DecisionRow
      <$> O.marshallField decisionRowRevision decisionRevisionField
      <*> O.marshallField decisionRowDecision (O.unboundedTextField "decision")
      <*> O.marshallField decisionRowDigest (O.unboundedTextField "digest")
      <*> O.marshallField decisionRowActor (O.unboundedTextField "actor")

decisionRevisionField :: O.FieldDefinition O.NotNull PlanRevisionId
decisionRevisionField =
  foreignKeyTo revisionTable revisionIdField "revision_id"

decisionOf :: O.MonadOrville m => PlanRevisionId -> m (Maybe DecisionRow)
decisionOf =
  O.findEntity decisionTable

insertDecision :: O.MonadOrville m => DecisionRow -> m ()
insertDecision =
  O.insertEntity decisionTable

-- lockstep_plan_units -------------------------------------------------------------------

data UnitRow
  = UnitRow
  { unitRowRevision :: PlanRevisionId
  , unitRowKey :: T.Text
  , unitRowTask :: TaskId
  , unitRowDigest :: T.Text
  , unitRowWorkKind :: T.Text
  , unitRowProfile :: T.Text
  , unitRowProvisional :: Bool
  , unitRowPriority :: Int32
  , unitRowOrdinal :: Int32
  }
  deriving (Eq, Show)

unitTable :: O.TableDefinition O.NoKey UnitRow UnitRow
unitTable =
  O.mkTableDefinitionWithoutKey "lockstep_plan_units" $
    UnitRow
      <$> O.marshallField unitRowRevision unitRevisionField
      <*> O.marshallField unitRowKey (O.unboundedTextField "unit_key")
      <*> O.marshallField unitRowTask (foreignKeyTo taskTable taskIdField "task_id")
      <*> O.marshallField unitRowDigest (O.unboundedTextField "unit_digest")
      <*> O.marshallField unitRowWorkKind (O.unboundedTextField "work_kind")
      <*> O.marshallField unitRowProfile (O.unboundedTextField "profile_id")
      <*> O.marshallField unitRowProvisional (O.booleanField "provisional")
      <*> O.marshallField unitRowPriority (O.integerField "priority")
      <*> O.marshallField unitRowOrdinal unitOrdinalField

unitRevisionField :: O.FieldDefinition O.NotNull PlanRevisionId
unitRevisionField =
  keyField "revision_id"

unitOrdinalField :: O.FieldDefinition O.NotNull Int32
unitOrdinalField =
  O.integerField "ordinal"

insertUnits :: O.MonadOrville m => [UnitRow] -> m ()
insertUnits =
  traverse_ (O.insertEntity unitTable)

-- | A revision's units, in the plan's order.
revisionUnits :: O.MonadOrville m => PlanRevisionId -> m [UnitRow]
revisionUnits revision =
  O.findEntitiesBy unitTable (O.where_ (O.fieldEquals unitRevisionField revision) <> O.orderBy (O.orderByField unitOrdinalField O.ascendingOrder))

-- lockstep_plan_edges -------------------------------------------------------------------

data EdgeRow
  = EdgeRow
  { edgeRowRevision :: PlanRevisionId
  , edgeRowDependent :: T.Text
  , edgeRowPrerequisite :: T.Text
  , edgeRowKind :: T.Text
  }
  deriving (Eq, Show)

edgeTable :: O.TableDefinition O.NoKey EdgeRow EdgeRow
edgeTable =
  O.mkTableDefinitionWithoutKey "lockstep_plan_edges" $
    EdgeRow
      <$> O.marshallField edgeRowRevision edgeRevisionField
      <*> O.marshallField edgeRowDependent edgeDependentField
      <*> O.marshallField edgeRowPrerequisite (O.unboundedTextField "prerequisite_key")
      <*> O.marshallField edgeRowKind (O.unboundedTextField "kind")

edgeRevisionField :: O.FieldDefinition O.NotNull PlanRevisionId
edgeRevisionField =
  keyField "revision_id"

edgeDependentField :: O.FieldDefinition O.NotNull T.Text
edgeDependentField =
  O.unboundedTextField "dependent_key"

insertEdges :: O.MonadOrville m => [EdgeRow] -> m ()
insertEdges =
  traverse_ (O.insertEntity edgeTable)

revisionEdges :: O.MonadOrville m => PlanRevisionId -> m [EdgeRow]
revisionEdges revision =
  O.findEntitiesBy edgeTable (O.where_ (O.fieldEquals edgeRevisionField revision) <> O.orderBy (O.orderByField edgeDependentField O.ascendingOrder))

-- lockstep_plan_reconciliations ---------------------------------------------------------

data ReconciliationRow
  = ReconciliationRow
  { reconciliationRowRevision :: PlanRevisionId
  , reconciliationRowKey :: T.Text
  , reconciliationRowOutcome :: T.Text
  , reconciliationRowPrevious :: Maybe PlanRevisionId
  }
  deriving (Eq, Show)

reconciliationTable :: O.TableDefinition O.NoKey ReconciliationRow ReconciliationRow
reconciliationTable =
  O.mkTableDefinitionWithoutKey "lockstep_plan_reconciliations" $
    ReconciliationRow
      <$> O.marshallField reconciliationRowRevision reconciliationRevisionField
      <*> O.marshallField reconciliationRowKey reconciliationKeyField
      <*> O.marshallField reconciliationRowOutcome (O.unboundedTextField "outcome")
      <*> O.marshallField reconciliationRowPrevious (nullableForeignKeyTo revisionTable revisionIdField "previous_revision_id")

reconciliationRevisionField :: O.FieldDefinition O.NotNull PlanRevisionId
reconciliationRevisionField =
  keyField "revision_id"

reconciliationKeyField :: O.FieldDefinition O.NotNull T.Text
reconciliationKeyField =
  O.unboundedTextField "unit_key"

insertReconciliations :: O.MonadOrville m => [ReconciliationRow] -> m ()
insertReconciliations =
  traverse_ (O.insertEntity reconciliationTable)

revisionReconciliations :: O.MonadOrville m => PlanRevisionId -> m [ReconciliationRow]
revisionReconciliations revision =
  O.findEntitiesBy
    reconciliationTable
    (O.where_ (O.fieldEquals reconciliationRevisionField revision) <> O.orderBy (O.orderByField reconciliationKeyField O.ascendingOrder))

-- lockstep_plan_drafts ------------------------------------------------------------------

data DraftRow
  = DraftRow
  { draftRowId :: PlanDraftId
  , draftRowProject :: ProjectId
  , draftRowKey :: T.Text
  , draftRowRequestDigest :: T.Text
  , draftRowPrd :: T.Text
  , draftRowPrdDigest :: T.Text
  , draftRowArchitecture :: Maybe T.Text
  , draftRowArchitectureDigest :: Maybe T.Text
  , draftRowRequestedBy :: T.Text
  , draftRowStarted :: Maybe UTCTime
  , draftRowOutcome :: Maybe T.Text
  , draftRowCode :: Maybe T.Text
  }
  deriving (Eq, Show)

type instance EntityKey DraftRow = PlanDraftId

draftTable :: Table DraftRow DraftRow
draftTable =
  mkEntityTable "lockstep_plan_drafts" draftIdField $
    DraftRow
      <$> O.marshallField draftRowId draftIdField
      <*> O.marshallField draftRowProject draftProjectField
      <*> O.marshallField draftRowKey draftKeyField
      <*> O.marshallField draftRowRequestDigest (O.unboundedTextField "request_digest")
      <*> O.marshallField draftRowPrd (O.unboundedTextField "prd_text")
      <*> O.marshallField draftRowPrdDigest (O.unboundedTextField "prd_digest")
      <*> O.marshallField draftRowArchitecture (O.nullableField (O.unboundedTextField "architecture_text"))
      <*> O.marshallField draftRowArchitectureDigest (O.nullableField (O.unboundedTextField "architecture_digest"))
      <*> O.marshallField draftRowRequestedBy (O.unboundedTextField "requested_by")
      <*> O.marshallReadOnly (O.marshallField draftRowStarted draftStartedField)
      <*> O.marshallReadOnly (O.marshallField draftRowOutcome draftOutcomeField)
      <*> O.marshallReadOnly (O.marshallField draftRowCode draftCodeField)

draftIdField :: O.FieldDefinition O.NotNull PlanDraftId
draftIdField =
  keyField "id"

draftProjectField :: O.FieldDefinition O.NotNull ProjectId
draftProjectField =
  foreignKeyTo projectTable projectIdField "project_id"

draftKeyField :: O.FieldDefinition O.NotNull T.Text
draftKeyField =
  O.unboundedTextField "idempotency_key"

draftStartedField :: O.FieldDefinition O.Nullable (Maybe UTCTime)
draftStartedField =
  O.nullableField (O.utcTimestampField "started_at")

draftFinishedField :: O.FieldDefinition O.Nullable (Maybe UTCTime)
draftFinishedField =
  O.nullableField (O.utcTimestampField "finished_at")

draftRequestedAtField :: O.FieldDefinition O.NotNull UTCTime
draftRequestedAtField =
  O.utcTimestampField "requested_at"

draftOutcomeField :: O.FieldDefinition O.Nullable (Maybe T.Text)
draftOutcomeField =
  O.nullableField (O.unboundedTextField "outcome")

draftCodeField :: O.FieldDefinition O.Nullable (Maybe T.Text)
draftCodeField =
  O.nullableField (O.unboundedTextField "code")

draftOrder :: O.SelectOptions
draftOrder =
  O.orderBy (O.orderByField draftRequestedAtField O.ascendingOrder <> O.orderByField draftIdField O.ascendingOrder)

findDraftByKey :: O.MonadOrville m => T.Text -> m (Maybe DraftRow)
findDraftByKey k =
  O.findFirstEntityBy draftTable (O.where_ (O.fieldEquals draftKeyField k))

insertDraft :: O.MonadOrville m => DraftRow -> m ()
insertDraft =
  O.insertEntity draftTable

-- | A project's drafts, in request order.
projectDrafts :: O.MonadOrville m => ProjectId -> m [DraftRow]
projectDrafts project =
  O.findEntitiesBy draftTable (O.where_ (O.fieldEquals draftProjectField project) <> draftOrder)

-- | Drafts never started, in request order.
pendingDrafts :: O.MonadOrville m => m [DraftRow]
pendingDrafts =
  O.findEntitiesBy draftTable (O.where_ (O.fieldIsNull draftStartedField) <> draftOrder)

-- | Drafts started and never finished (the worker stopped while they ran).
unfinishedDrafts :: O.MonadOrville m => m [DraftRow]
unfinishedDrafts =
  O.findEntitiesBy draftTable (O.where_ (O.fieldIsNotNull draftStartedField `O.andExpr` O.fieldIsNull draftFinishedField) <> draftOrder)

-- | Marks a draft started; True only for the call that started it.
startDraft :: O.MonadOrville m => PlanDraftId -> m Bool
startDraft draft =
  not . null
    <$> O.updateFieldsAndReturnEntities
      draftTable
      (setNow draftStartedField :| [])
      (Just (O.fieldEquals draftIdField draft `O.andExpr` O.fieldIsNull draftStartedField))

-- | Finishes a started draft once, with its outcome and code.
finishDraft :: O.MonadOrville m => PlanDraftId -> T.Text -> Maybe T.Text -> m ()
finishDraft draft outcome code =
  void $
    O.updateFields
      draftTable
      (O.setField draftOutcomeField (Just outcome) :| [O.setField draftCodeField code, setNow draftFinishedField])
      (Just (O.fieldEquals draftIdField draft `O.andExpr` O.fieldIsNull draftFinishedField))
