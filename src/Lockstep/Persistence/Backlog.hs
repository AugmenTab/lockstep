{-# LANGUAGE TypeFamilies #-}

{- | Storage for backlog sources, the provenance of imported tasks and the
import records (contract C-P6.1 B3, B8, B13; migration 22). Callers run these
inside one transaction, after 'Lockstep.Persistence.Tasks.lockTasks' and then
'lockBacklog'.
-}
module Lockstep.Persistence.Backlog
  ( SourceRow (..)
  , TaskSourceRow (..)
  , ImportRow (..)
  , lockBacklog
  , findSource
  , projectSources
  , insertSource
  , advanceSourceRevision
  , sourceItems
  , findTaskSource
  , insertTaskSource
  , updateTaskSource
  , advanceItemRevision
  , insertImport
  ) where

import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text qualified as T
import Data.Time (UTCTime)
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql

import Lockstep.Kernel.Backlog (SourceProvider, parseSourceProvider, sourceProviderCode)
import Lockstep.Kernel.Identity (BacklogSourceId (..), ProjectId, TaskId)
import Lockstep.Persistence.Entity (EntityKey, Table, foreignKeyTo, keyField, mkEntityTable)
import Lockstep.Persistence.Fields (codeField, setNow)
import Lockstep.Persistence.Projects (projectIdField, projectTable)
import Lockstep.Persistence.Tasks (taskIdField, taskTable)

-- lockstep_backlog_sources ---------------------------------------------------------

data SourceRow
  = SourceRow
  { sourceRowId :: BacklogSourceId
  , sourceRowProject :: ProjectId
  , sourceRowProvider :: SourceProvider
  , sourceRowLocator :: T.Text
  , sourceRowRevision :: Int64
  }

type instance EntityKey SourceRow = BacklogSourceId

sourceTable :: Table SourceRow SourceRow
sourceTable =
  mkEntityTable "lockstep_backlog_sources" sourceIdField $
    SourceRow
      <$> O.marshallField sourceRowId sourceIdField
      <*> O.marshallField sourceRowProject sourceProjectField
      <*> O.marshallField sourceRowProvider sourceProviderField
      <*> O.marshallField sourceRowLocator sourceLocatorField
      <*> O.marshallField sourceRowRevision sourceRevisionField

sourceIdField :: O.FieldDefinition O.NotNull BacklogSourceId
sourceIdField =
  keyField "id"

sourceProjectField :: O.FieldDefinition O.NotNull ProjectId
sourceProjectField =
  foreignKeyTo projectTable projectIdField "project_id"

-- | A stored code the Kernel does not know fails the read.
sourceProviderField :: O.FieldDefinition O.NotNull SourceProvider
sourceProviderField =
  codeField "backlog provider" sourceProviderCode parseSourceProvider "provider"

sourceLocatorField :: O.FieldDefinition O.NotNull T.Text
sourceLocatorField =
  O.unboundedTextField "locator"

sourceRevisionField :: O.FieldDefinition O.NotNull Int64
sourceRevisionField =
  O.bigIntegerField "source_revision"

sourceUpdatedAtField :: O.FieldDefinition O.NotNull UTCTime
sourceUpdatedAtField =
  O.utcTimestampField "updated_at"

sourceCreatedAtField :: O.FieldDefinition O.NotNull UTCTime
sourceCreatedAtField =
  O.utcTimestampField "created_at"

{- | Serializes imports until the transaction ends; reads stay possible.
Orville has no table-lock statement.
-}
lockBacklog :: O.MonadOrville m => m ()
lockBacklog =
  O.executeVoid O.OtherQuery (RawSql.fromString "LOCK TABLE lockstep_backlog_sources IN EXCLUSIVE MODE")

findSource :: O.MonadOrville m => SourceProvider -> T.Text -> m (Maybe SourceRow)
findSource provider locator =
  O.findFirstEntityBy sourceTable (O.where_ (O.fieldEquals sourceProviderField provider `O.andExpr` O.fieldEquals sourceLocatorField locator))

-- | A project's sources, oldest first.
projectSources :: O.MonadOrville m => ProjectId -> m [SourceRow]
projectSources projectId =
  O.findEntitiesBy
    sourceTable
    (O.where_ (O.fieldEquals sourceProjectField projectId) <> O.orderBy (O.orderByField sourceCreatedAtField O.ascendingOrder <> O.orderByField sourceIdField O.ascendingOrder))

insertSource :: O.MonadOrville m => SourceRow -> m ()
insertSource =
  O.insertEntity sourceTable

-- | Records a newer source revision; an older one is never written (the trigger refuses it too).
advanceSourceRevision :: O.MonadOrville m => BacklogSourceId -> Int64 -> m ()
advanceSourceRevision sourceId revision =
  void $
    O.updateFields
      sourceTable
      (O.setField sourceRevisionField revision :| [setNow sourceUpdatedAtField])
      (Just (O.fieldEquals sourceIdField sourceId `O.andExpr` O.fieldLessThan sourceRevisionField revision))

-- lockstep_task_sources ------------------------------------------------------------

data TaskSourceRow
  = TaskSourceRow
  { taskSourceRowTask :: TaskId
  , taskSourceRowSource :: BacklogSourceId
  , taskSourceRowKey :: T.Text
  , taskSourceRowItemRevision :: Int64
  , taskSourceRowDigest :: T.Text
  , taskSourceRowBlockers :: T.Text
  -- ^ The item's blocker keys, sorted, one a line.
  , taskSourceRowCriteria :: T.Text
  -- ^ The item's criteria in the document's own form ('Lockstep.Application.BacklogDocument.criteriaText').
  , taskSourceRowTaskRevision :: Int64
  -- ^ The task row's revision as the import last left it (B6).
  }

type instance EntityKey TaskSourceRow = TaskId

taskSourceTable :: Table TaskSourceRow TaskSourceRow
taskSourceTable =
  mkEntityTable "lockstep_task_sources" taskSourceTaskField $
    TaskSourceRow
      <$> O.marshallField taskSourceRowTask taskSourceTaskField
      <*> O.marshallField taskSourceRowSource taskSourceSourceField
      <*> O.marshallField taskSourceRowKey taskSourceKeyField
      <*> O.marshallField taskSourceRowItemRevision taskSourceItemRevisionField
      <*> O.marshallField taskSourceRowDigest taskSourceDigestField
      <*> O.marshallField taskSourceRowBlockers taskSourceBlockersField
      <*> O.marshallField taskSourceRowCriteria taskSourceCriteriaField
      <*> O.marshallField taskSourceRowTaskRevision taskSourceTaskRevisionField

taskSourceTaskField :: O.FieldDefinition O.NotNull TaskId
taskSourceTaskField =
  foreignKeyTo taskTable taskIdField "task_id"

taskSourceSourceField :: O.FieldDefinition O.NotNull BacklogSourceId
taskSourceSourceField =
  foreignKeyTo sourceTable sourceIdField "source_id"

taskSourceKeyField :: O.FieldDefinition O.NotNull T.Text
taskSourceKeyField =
  O.unboundedTextField "source_key"

taskSourceItemRevisionField :: O.FieldDefinition O.NotNull Int64
taskSourceItemRevisionField =
  O.bigIntegerField "item_revision"

taskSourceDigestField :: O.FieldDefinition O.NotNull T.Text
taskSourceDigestField =
  O.unboundedTextField "content_digest"

taskSourceBlockersField :: O.FieldDefinition O.NotNull T.Text
taskSourceBlockersField =
  O.unboundedTextField "blockers"

taskSourceCriteriaField :: O.FieldDefinition O.NotNull T.Text
taskSourceCriteriaField =
  O.unboundedTextField "criteria"

taskSourceTaskRevisionField :: O.FieldDefinition O.NotNull Int64
taskSourceTaskRevisionField =
  O.bigIntegerField "task_revision"

taskSourceImportedAtField :: O.FieldDefinition O.NotNull UTCTime
taskSourceImportedAtField =
  O.utcTimestampField "imported_at"

taskSourceUpdatedAtField :: O.FieldDefinition O.NotNull UTCTime
taskSourceUpdatedAtField =
  O.utcTimestampField "updated_at"

-- | A source's imported items, in the order they were first imported.
sourceItems :: O.MonadOrville m => BacklogSourceId -> m [TaskSourceRow]
sourceItems sourceId =
  O.findEntitiesBy
    taskSourceTable
    (O.where_ (O.fieldEquals taskSourceSourceField sourceId) <> O.orderBy (O.orderByField taskSourceImportedAtField O.ascendingOrder <> O.orderByField taskSourceKeyField O.ascendingOrder))

-- | The provenance of one task, if it was imported.
findTaskSource :: O.MonadOrville m => TaskId -> m (Maybe TaskSourceRow)
findTaskSource =
  O.findEntity taskSourceTable

insertTaskSource :: O.MonadOrville m => TaskSourceRow -> m ()
insertTaskSource =
  O.insertEntity taskSourceTable

-- | What an update of the item wrote (its identity is unchanged).
updateTaskSource :: O.MonadOrville m => TaskSourceRow -> m ()
updateTaskSource row =
  void $
    O.updateFields
      taskSourceTable
      ( O.setField taskSourceItemRevisionField (taskSourceRowItemRevision row)
          :| [ O.setField taskSourceDigestField (taskSourceRowDigest row)
             , O.setField taskSourceBlockersField (taskSourceRowBlockers row)
             , O.setField taskSourceCriteriaField (taskSourceRowCriteria row)
             , O.setField taskSourceTaskRevisionField (taskSourceRowTaskRevision row)
             , setNow taskSourceUpdatedAtField
             ]
      )
      (Just (O.fieldEquals taskSourceTaskField (taskSourceRowTask row)))

-- | Records a newer revision of an item whose content did not change.
advanceItemRevision :: O.MonadOrville m => TaskId -> Int64 -> m ()
advanceItemRevision taskId revision =
  void $
    O.updateFields
      taskSourceTable
      (O.setField taskSourceItemRevisionField revision :| [setNow taskSourceUpdatedAtField])
      (Just (O.fieldEquals taskSourceTaskField taskId `O.andExpr` O.fieldLessThan taskSourceItemRevisionField revision))

-- lockstep_backlog_imports ---------------------------------------------------------

data ImportRow
  = ImportRow
  { importRowSource :: BacklogSourceId
  , importRowDigest :: T.Text
  , importRowRevision :: Int64
  , importRowCreated :: Int32
  , importRowUpdated :: Int32
  , importRowUnchanged :: Int32
  , importRowRefused :: Int32
  , importRowDecision :: T.Text
  }

-- | Append only (its key and time are the database's).
importTable :: O.TableDefinition O.NoKey ImportRow ImportRow
importTable =
  O.mkTableDefinitionWithoutKey "lockstep_backlog_imports" $
    ImportRow
      <$> O.marshallField importRowSource (foreignKeyTo sourceTable sourceIdField "source_id")
      <*> O.marshallField importRowDigest (O.unboundedTextField "document_digest")
      <*> O.marshallField importRowRevision (O.bigIntegerField "source_revision")
      <*> O.marshallField importRowCreated (O.integerField "created")
      <*> O.marshallField importRowUpdated (O.integerField "updated")
      <*> O.marshallField importRowUnchanged (O.integerField "unchanged")
      <*> O.marshallField importRowRefused (O.integerField "refused")
      <*> O.marshallField importRowDecision (O.unboundedTextField "decision")

insertImport :: O.MonadOrville m => ImportRow -> m ()
insertImport =
  O.insertEntity importTable
