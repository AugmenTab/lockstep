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
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql
import Orville.PostgreSQL.Raw.SqlValue qualified as SqlValue
import Text.Show (show)

data TaskRow
  = TaskRow
  { rowTaskId :: T.Text
  , rowProjectId :: T.Text
  , rowTitle :: T.Text
  , rowAcceptance :: T.Text
  , rowPriority :: Int32
  , rowRevision :: Int64
  , rowCreationDigest :: Maybe T.Text
  }

sql :: String -> RawSql.RawSql
sql =
  RawSql.fromString

text :: T.Text -> RawSql.RawSql
text =
  RawSql.parameter . SqlValue.fromText

uuid :: T.Text -> RawSql.RawSql
uuid value =
  sql "CAST(" <> text value <> sql " AS uuid)"

headMay :: [a] -> Maybe a
headMay xs =
  case xs of
    [] -> Nothing
    x : _ -> Just x

taskMarshaller :: O.AnnotatedSqlMarshaller TaskRow TaskRow
taskMarshaller =
  O.annotateSqlMarshallerEmptyAnnotation $
    TaskRow
      <$> O.marshallField rowTaskId (O.unboundedTextField "task_id")
      <*> O.marshallField rowProjectId (O.unboundedTextField "project_id")
      <*> O.marshallField rowTitle (O.unboundedTextField "title")
      <*> O.marshallField rowAcceptance (O.unboundedTextField "acceptance")
      <*> O.marshallField rowPriority (O.integerField "priority")
      <*> O.marshallField rowRevision (O.bigIntegerField "revision")
      <*> O.marshallField rowCreationDigest (O.nullableField (O.unboundedTextField "creation_digest"))

-- | Serializes task changes until the transaction ends; reads stay possible.
lockTasks :: O.MonadOrville m => m ()
lockTasks =
  O.executeVoid O.OtherQuery (sql "LOCK TABLE lockstep_project_tasks IN EXCLUSIVE MODE")

selectWhere :: O.MonadOrville m => RawSql.RawSql -> String -> m [TaskRow]
selectWhere condition order =
  O.executeAndDecode
    O.SelectQuery
    ( sql "SELECT t.ticket_id::text AS task_id, t.project_id::text AS project_id, k.title, t.acceptance, t.priority, t.revision, t.creation_digest FROM lockstep_project_tasks t JOIN lockstep_tickets k ON k.id = t.ticket_id WHERE "
        <> condition
        <> sql (" ORDER BY " <> order)
    )
    taskMarshaller

findTaskByKey :: O.MonadOrville m => T.Text -> m (Maybe TaskRow)
findTaskByKey key =
  headMay <$> selectWhere (sql "t.creation_key = " <> text key) "t.created_at"

findTaskRow :: O.MonadOrville m => T.Text -> m (Maybe TaskRow)
findTaskRow taskId =
  headMay <$> selectWhere (sql "t.ticket_id = " <> uuid taskId) "t.created_at"

-- | A project's tasks, most important first, then the oldest.
projectTaskRows :: O.MonadOrville m => T.Text -> m [TaskRow]
projectTaskRows projectId =
  selectWhere (sql "t.project_id = " <> uuid projectId) "t.priority DESC, t.created_at, t.ticket_id"

allTaskRows :: O.MonadOrville m => m [TaskRow]
allTaskRows =
  selectWhere (sql "TRUE") "t.project_id, t.priority DESC, t.created_at, t.ticket_id"

insertTask :: O.MonadOrville m => T.Text -> T.Text -> T.Text -> T.Text -> Int -> T.Text -> m ()
insertTask taskId projectId key acceptance priority digest =
  O.executeVoid O.InsertQuery $
    sql "INSERT INTO lockstep_project_tasks (ticket_id, project_id, creation_key, acceptance, priority, creation_digest) VALUES ("
      <> uuid taskId
      <> sql ", "
      <> uuid projectId
      <> sql ", "
      <> text key
      <> sql ", "
      <> text acceptance
      <> sql (", " <> show priority <> ", ")
      <> text digest
      <> sql ")"

-- | Changes a task if it is still at the expected revision; True when it was.
updateTask :: O.MonadOrville m => T.Text -> Int64 -> T.Text -> Int -> m Bool
updateTask taskId expected acceptance priority =
  not . null
    <$> O.executeAndDecode
      O.UpdateQuery
      ( sql "UPDATE lockstep_project_tasks SET acceptance = "
          <> text acceptance
          <> sql (", priority = " <> show priority <> ", revision = revision + 1, updated_at = now() WHERE ticket_id = ")
          <> uuid taskId
          <> sql (" AND revision = " <> show expected <> " RETURNING ticket_id::text AS task_id")
      )
      (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.unboundedTextField "task_id")))

dependenciesOf :: O.MonadOrville m => T.Text -> m [T.Text]
dependenciesOf taskId =
  O.executeAndDecode
    O.SelectQuery
    (sql "SELECT d.depends_on::text AS depends_on FROM lockstep_task_dependencies d JOIN lockstep_project_tasks t ON t.ticket_id = d.depends_on WHERE d.task_id = " <> uuid taskId <> sql " ORDER BY t.created_at, d.depends_on")
    (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.unboundedTextField "depends_on")))

-- | Every dependency between tasks of a project, as (task, depends on).
projectEdges :: O.MonadOrville m => T.Text -> m [(T.Text, T.Text)]
projectEdges projectId =
  O.executeAndDecode
    O.SelectQuery
    (sql "SELECT d.task_id::text AS task_id, d.depends_on::text AS depends_on FROM lockstep_task_dependencies d JOIN lockstep_project_tasks t ON t.ticket_id = d.task_id WHERE t.project_id = " <> uuid projectId)
    ( O.annotateSqlMarshallerEmptyAnnotation $
        (,)
          <$> O.marshallField fst (O.unboundedTextField "task_id")
          <*> O.marshallField snd (O.unboundedTextField "depends_on")
    )

replaceDependencies :: O.MonadOrville m => T.Text -> [T.Text] -> m ()
replaceDependencies taskId deps = do
  O.executeVoid O.DeleteQuery (sql "DELETE FROM lockstep_task_dependencies WHERE task_id = " <> uuid taskId)
  traverse_
    ( \d ->
        O.executeVoid O.InsertQuery $
          sql "INSERT INTO lockstep_task_dependencies (task_id, depends_on) VALUES (" <> uuid taskId <> sql ", " <> uuid d <> sql ")"
    )
    deps
