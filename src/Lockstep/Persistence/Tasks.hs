{-# LANGUAGE TypeFamilies #-}

{- | Storage for tasks (contract C-P3.6 K1, K2): the task rows beside their
C-P2.2 Tickets, and the dependencies between tasks. Callers run these inside
one transaction; 'lockTasks' serializes changes.
-}
module Lockstep.Persistence.Tasks
  ( TaskRow (..)
  , lockTasks
  , findTaskByKey
  , findTaskRow
  , projectTaskRows
  , allTaskRows
  , insertTask
  , updateTask
  , dependenciesOf
  , projectEdges
  , replaceDependencies
  , taskTable
  , taskIdField
  ) where

import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text qualified as T
import Data.Time (UTCTime)
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Expr qualified as Expr
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql

import Lockstep.Kernel.Identity (ProjectId, TaskId (..))
import Lockstep.Persistence.Entity (EntityKey, foreignKeyTo, keyField)
import Lockstep.Persistence.Fields
  ( headMay
  , increment
  , joinedOn
  , qualified
  , qualifiedEquals
  , qualifiedOrder
  , qualifiedReference
  , selectJoined
  , setNow
  , tableReference
  )
import Lockstep.Persistence.Ledger (ticketIdField, ticketTable, ticketTitleField)
import Lockstep.Persistence.Projects (projectIdField, projectTable)

data TaskRow
  = TaskRow
  { rowTaskId :: TaskId
  , rowProjectId :: ProjectId
  , rowTitle :: T.Text
  , rowAcceptance :: T.Text
  , rowPriority :: Int32
  , rowRevision :: Int64
  , rowCreationDigest :: Maybe T.Text
  }

type instance EntityKey TaskRow = TaskId

-- | What a new task row is written with (its Ticket holds the title).
data NewTask
  = NewTask
  { newTaskId :: TaskId
  , newTaskProject :: ProjectId
  , newTaskKey :: T.Text
  , newTaskAcceptance :: T.Text
  , newTaskPriority :: Int32
  , newTaskDigest :: T.Text
  }

{- | @lockstep_project_tasks@. A 'TaskRow' carries its Ticket's title, which
lives in @lockstep_tickets@, so the table reads a row still waiting for it;
'tasksWhere' supplies it from the join. Its key is still 'TaskRow''s
('EntityKey'); only the read type differs from
'Lockstep.Persistence.Entity.Table', so it is built with 'O.mkTableDefinition'
directly.
-}
taskTable :: O.TableDefinition (O.HasKey (EntityKey TaskRow)) NewTask (T.Text -> TaskRow)
taskTable =
  O.mkTableDefinition "lockstep_project_tasks" (O.primaryKey taskIdField) $
    (\taskId projectId _key acceptance priority revision digest title -> TaskRow taskId projectId title acceptance priority revision digest)
      <$> O.marshallField newTaskId taskIdField
      <*> O.marshallField newTaskProject taskProjectField
      <*> O.marshallField newTaskKey taskKeyField
      <*> O.marshallField newTaskAcceptance taskAcceptanceField
      <*> O.marshallField newTaskPriority taskPriorityField
      <*> O.marshallReadOnlyField taskRevisionField
      <*> O.marshallField (Just . newTaskDigest) (O.nullableField (O.unboundedTextField "creation_digest"))

{- | The task's key, its @ticket_id@ column: a task and its Ticket share one
UUID (C-P3.6), but they are distinct identities, so the column is the task's
own 'TaskId' key rather than a 'Lockstep.Kernel.Identity.TicketId' foreign
key (the join to the Ticket is written as an expression in 'tasksWhere').
-}
taskIdField :: O.FieldDefinition O.NotNull TaskId
taskIdField =
  keyField "ticket_id"

taskProjectField :: O.FieldDefinition O.NotNull ProjectId
taskProjectField =
  foreignKeyTo projectTable projectIdField "project_id"

taskKeyField :: O.FieldDefinition O.NotNull T.Text
taskKeyField =
  O.unboundedTextField "creation_key"

taskAcceptanceField :: O.FieldDefinition O.NotNull T.Text
taskAcceptanceField =
  O.unboundedTextField "acceptance"

taskPriorityField :: O.FieldDefinition O.NotNull Int32
taskPriorityField =
  O.integerField "priority"

taskRevisionField :: O.FieldDefinition O.NotNull Int64
taskRevisionField =
  O.bigIntegerField "revision"

taskCreatedAtField :: O.FieldDefinition O.NotNull UTCTime
taskCreatedAtField =
  O.utcTimestampField "created_at"

taskUpdatedAtField :: O.FieldDefinition O.NotNull UTCTime
taskUpdatedAtField =
  O.utcTimestampField "updated_at"

-- | A column of @lockstep_project_tasks@ in a join.
ofTask :: O.FieldDefinition nullability a -> O.QualifiedFieldDefinition O.TableIdentifier nullability a
ofTask =
  qualified taskTable

{- | Serializes task changes until the transaction ends; reads stay possible.
Orville has no table-lock statement.
-}
lockTasks :: O.MonadOrville m => m ()
lockTasks =
  O.executeVoid O.OtherQuery (RawSql.fromString "LOCK TABLE lockstep_project_tasks IN EXCLUSIVE MODE")

-- | Task rows with their Tickets' titles, in the given order.
tasksWhere :: O.MonadOrville m => Expr.BooleanExpr -> Expr.OrderByExpr -> m [TaskRow]
tasksWhere condition order =
  selectJoined
    ( O.marshallQualifyFields (O.tableIdentifier taskTable) (O.unannotatedSqlMarshaller (O.tableMarshaller taskTable))
        <*> O.marshallReadOnly (O.marshallQualifyFields (O.tableIdentifier ticketTable) (O.marshallReadOnlyField ticketTitleField))
    )
    ( joinedOn
        taskTable
        [(Expr.innerJoinType, tableReference ticketTable, Expr.equals (qualifiedReference (qualified ticketTable ticketIdField)) (qualifiedReference (ofTask taskIdField)))]
    )
    (O.where_ condition <> O.orderBy order)

oldestFirst :: Expr.OrderByExpr
oldestFirst =
  qualifiedOrder (ofTask taskCreatedAtField) O.ascendingOrder

-- | Most important first, then the oldest, then by id.
importanceOrder :: Expr.OrderByExpr
importanceOrder =
  qualifiedOrder (ofTask taskPriorityField) O.descendingOrder
    <> oldestFirst
    <> qualifiedOrder (ofTask taskIdField) O.ascendingOrder

findTaskByKey :: O.MonadOrville m => T.Text -> m (Maybe TaskRow)
findTaskByKey key =
  headMay <$> tasksWhere (qualifiedEquals (ofTask taskKeyField) key) oldestFirst

findTaskRow :: O.MonadOrville m => TaskId -> m (Maybe TaskRow)
findTaskRow taskId =
  headMay <$> tasksWhere (qualifiedEquals (ofTask taskIdField) taskId) oldestFirst

-- | A project's tasks, most important first, then the oldest.
projectTaskRows :: O.MonadOrville m => ProjectId -> m [TaskRow]
projectTaskRows projectId =
  tasksWhere (qualifiedEquals (ofTask taskProjectField) projectId) importanceOrder

allTaskRows :: O.MonadOrville m => m [TaskRow]
allTaskRows =
  tasksWhere (Expr.literalBooleanExpr True) (qualifiedOrder (ofTask taskProjectField) O.ascendingOrder <> importanceOrder)

insertTask :: O.MonadOrville m => TaskId -> ProjectId -> T.Text -> T.Text -> Int -> T.Text -> m ()
insertTask taskId projectId key acceptance priority digest =
  O.insertEntity taskTable (NewTask taskId projectId key acceptance (fromIntegral priority) digest)

-- | Changes a task if it is still at the expected revision; True when it was.
updateTask :: O.MonadOrville m => TaskId -> Int64 -> T.Text -> Int -> m Bool
updateTask taskId expected acceptance priority =
  not . null
    <$> O.updateFieldsAndReturnEntities
      taskTable
      ( O.setField taskAcceptanceField acceptance
          :| [O.setField taskPriorityField (fromIntegral priority), increment taskRevisionField, setNow taskUpdatedAtField]
      )
      (Just (O.fieldEquals taskIdField taskId `O.andExpr` O.fieldEquals taskRevisionField expected))

-- lockstep_task_dependencies -------------------------------------------------------

-- | (task, the task it depends on).
dependencyTable :: O.TableDefinition O.NoKey (TaskId, TaskId) (TaskId, TaskId)
dependencyTable =
  O.mkTableDefinitionWithoutKey "lockstep_task_dependencies" $
    (,)
      <$> O.marshallField fst dependencyTaskField
      <*> O.marshallField snd dependencyDependsOnField

dependencyTaskField :: O.FieldDefinition O.NotNull TaskId
dependencyTaskField =
  foreignKeyTo taskTable taskIdField "task_id"

dependencyDependsOnField :: O.FieldDefinition O.NotNull TaskId
dependencyDependsOnField =
  foreignKeyTo taskTable taskIdField "depends_on"

ofDependency :: O.FieldDefinition nullability a -> O.QualifiedFieldDefinition O.TableIdentifier nullability a
ofDependency =
  qualified dependencyTable

-- | The tasks a task depends on, oldest first.
dependenciesOf :: O.MonadOrville m => TaskId -> m [TaskId]
dependenciesOf taskId =
  selectJoined
    (O.marshallQualifyFields (O.tableIdentifier dependencyTable) (O.marshallReadOnlyField dependencyDependsOnField))
    (joinedOn dependencyTable [(Expr.innerJoinType, tableReference taskTable, Expr.equals (qualifiedReference (ofTask taskIdField)) (qualifiedReference (ofDependency dependencyDependsOnField)))])
    ( O.where_ (qualifiedEquals (ofDependency dependencyTaskField) taskId)
        <> O.orderBy (oldestFirst <> qualifiedOrder (ofDependency dependencyDependsOnField) O.ascendingOrder)
    )

-- | Every dependency between tasks of a project, as (task, depends on).
projectEdges :: O.MonadOrville m => ProjectId -> m [(TaskId, TaskId)]
projectEdges projectId =
  selectJoined
    (O.marshallQualifyFields (O.tableIdentifier dependencyTable) (O.unannotatedSqlMarshaller (O.tableMarshaller dependencyTable)))
    (joinedOn dependencyTable [(Expr.innerJoinType, tableReference taskTable, Expr.equals (qualifiedReference (ofTask taskIdField)) (qualifiedReference (ofDependency dependencyTaskField)))])
    (O.where_ (qualifiedEquals (ofTask taskProjectField) projectId))

replaceDependencies :: O.MonadOrville m => TaskId -> [TaskId] -> m ()
replaceDependencies taskId deps = do
  O.deleteEntities dependencyTable (Just (O.fieldEquals dependencyTaskField taskId))
  traverse_ (\d -> O.insertEntity dependencyTable (taskId, d)) deps
