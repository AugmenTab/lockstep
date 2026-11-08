{- | Storage for the projects Lockstep may work in and the bugs handed to it
(contract C-P4.1 X9). Rows are never updated or deleted; the migration's
triggers refuse it. Callers run these inside their own transaction.
-}
module Lockstep.Persistence.Execution
  ( EnablementRow (..)
  , findEnablementByProject
  , findEnablementByKey
  , insertEnablement
  , AdmissionRow (..)
  , findAdmissionByTask
  , findAdmissionByKey
  , insertAdmission
  , projectRepository
  , workOrderEffectiveDigest
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql
import Orville.PostgreSQL.Raw.SqlValue qualified as SqlValue

data EnablementRow
  = EnablementRow
  { enablementRowKey :: T.Text
  , enablementRowDigest :: T.Text
  , enablementRowProject :: T.Text
  , enablementRowRepository :: T.Text
  , enablementRowEngineer :: T.Text
  , enablementRowFolder :: T.Text
  , enablementRowProfile :: T.Text
  , enablementRowProfileVersion :: Int32
  , enablementRowProfileDigest :: T.Text
  , enablementRowActor :: T.Text
  , enablementRowAt :: T.Text
  }

data AdmissionRow
  = AdmissionRow
  { admissionRowKey :: T.Text
  , admissionRowDigest :: T.Text
  , admissionRowTask :: T.Text
  , admissionRowProject :: T.Text
  , admissionRowWorkOrder :: T.Text
  , admissionRowEffectiveDigest :: T.Text
  , admissionRowActor :: T.Text
  , admissionRowAt :: T.Text
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

-- | The time a row was recorded, as text in UTC to the second.
timeColumn :: String -> String
timeColumn column =
  "to_char(" <> column <> " AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC' AS " <> column

enablementMarshaller :: O.AnnotatedSqlMarshaller EnablementRow EnablementRow
enablementMarshaller =
  O.annotateSqlMarshallerEmptyAnnotation $
    EnablementRow
      <$> O.marshallField enablementRowKey (O.unboundedTextField "idempotency_key")
      <*> O.marshallField enablementRowDigest (O.unboundedTextField "payload_digest")
      <*> O.marshallField enablementRowProject (O.unboundedTextField "project_id")
      <*> O.marshallField enablementRowRepository (O.unboundedTextField "repository_id")
      <*> O.marshallField enablementRowEngineer (O.unboundedTextField "engineer_name")
      <*> O.marshallField enablementRowFolder (O.unboundedTextField "folder")
      <*> O.marshallField enablementRowProfile (O.unboundedTextField "profile_id")
      <*> O.marshallField enablementRowProfileVersion (O.integerField "profile_version")
      <*> O.marshallField enablementRowProfileDigest (O.unboundedTextField "profile_digest")
      <*> O.marshallField enablementRowActor (O.unboundedTextField "actor")
      <*> O.marshallField enablementRowAt (O.unboundedTextField "enabled_at")

selectEnablements :: O.MonadOrville m => RawSql.RawSql -> m [EnablementRow]
selectEnablements condition =
  O.executeAndDecode
    O.SelectQuery
    ( sql
        ( "SELECT idempotency_key, payload_digest, project_id::text AS project_id, repository_id::text AS repository_id, engineer_name, folder, profile_id, profile_version, profile_digest, actor, "
            <> timeColumn "enabled_at"
            <> " FROM lockstep_execution_enablements WHERE "
        )
        <> condition
    )
    enablementMarshaller

findEnablementByProject :: O.MonadOrville m => T.Text -> m (Maybe EnablementRow)
findEnablementByProject project =
  headMay <$> selectEnablements (sql "project_id = " <> uuid project)

findEnablementByKey :: O.MonadOrville m => T.Text -> m (Maybe EnablementRow)
findEnablementByKey key =
  headMay <$> selectEnablements (sql "idempotency_key = " <> text key)

insertEnablement :: O.MonadOrville m => EnablementRow -> m ()
insertEnablement row =
  O.executeVoid O.InsertQuery $
    sql "INSERT INTO lockstep_execution_enablements (idempotency_key, payload_digest, project_id, repository_id, engineer_name, folder, profile_id, profile_version, profile_digest, actor) VALUES ("
      <> text (enablementRowKey row)
      <> sql ", "
      <> text (enablementRowDigest row)
      <> sql ", "
      <> uuid (enablementRowProject row)
      <> sql ", "
      <> uuid (enablementRowRepository row)
      <> sql ", "
      <> text (enablementRowEngineer row)
      <> sql ", "
      <> text (enablementRowFolder row)
      <> sql ", "
      <> text (enablementRowProfile row)
      <> sql ", "
      <> RawSql.parameter (SqlValue.fromInt32 (enablementRowProfileVersion row))
      <> sql ", "
      <> text (enablementRowProfileDigest row)
      <> sql ", "
      <> text (enablementRowActor row)
      <> sql ")"

admissionMarshaller :: O.AnnotatedSqlMarshaller AdmissionRow AdmissionRow
admissionMarshaller =
  O.annotateSqlMarshallerEmptyAnnotation $
    AdmissionRow
      <$> O.marshallField admissionRowKey (O.unboundedTextField "idempotency_key")
      <*> O.marshallField admissionRowDigest (O.unboundedTextField "payload_digest")
      <*> O.marshallField admissionRowTask (O.unboundedTextField "task_id")
      <*> O.marshallField admissionRowProject (O.unboundedTextField "project_id")
      <*> O.marshallField admissionRowWorkOrder (O.unboundedTextField "work_order_id")
      <*> O.marshallField admissionRowEffectiveDigest (O.unboundedTextField "effective_digest")
      <*> O.marshallField admissionRowActor (O.unboundedTextField "actor")
      <*> O.marshallField admissionRowAt (O.unboundedTextField "admitted_at")

selectAdmissions :: O.MonadOrville m => RawSql.RawSql -> m [AdmissionRow]
selectAdmissions condition =
  O.executeAndDecode
    O.SelectQuery
    ( sql
        ( "SELECT idempotency_key, payload_digest, task_id::text AS task_id, project_id::text AS project_id, work_order_id::text AS work_order_id, effective_digest, actor, "
            <> timeColumn "admitted_at"
            <> " FROM lockstep_bug_admissions WHERE "
        )
        <> condition
    )
    admissionMarshaller

findAdmissionByTask :: O.MonadOrville m => T.Text -> m (Maybe AdmissionRow)
findAdmissionByTask task =
  headMay <$> selectAdmissions (sql "task_id = " <> uuid task)

findAdmissionByKey :: O.MonadOrville m => T.Text -> m (Maybe AdmissionRow)
findAdmissionByKey key =
  headMay <$> selectAdmissions (sql "idempotency_key = " <> text key)

-- | The repository a project was connected to (C-P3.5 J1), if any.
projectRepository :: O.MonadOrville m => T.Text -> m (Maybe T.Text)
projectRepository project =
  singleText (sql "SELECT repository_id::text AS v FROM lockstep_projects WHERE repository_id IS NOT NULL AND id = " <> uuid project)

-- | The effective Profile digest a Work Order was created with (C-P2.5).
workOrderEffectiveDigest :: O.MonadOrville m => T.Text -> m (Maybe T.Text)
workOrderEffectiveDigest workOrder =
  singleText (sql "SELECT effective_digest AS v FROM lockstep_work_orders WHERE id = " <> uuid workOrder)

singleText :: O.MonadOrville m => RawSql.RawSql -> m (Maybe T.Text)
singleText query =
  headMay <$> O.executeAndDecode O.SelectQuery query (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.unboundedTextField "v")))

insertAdmission :: O.MonadOrville m => AdmissionRow -> m ()
insertAdmission row =
  O.executeVoid O.InsertQuery $
    sql "INSERT INTO lockstep_bug_admissions (idempotency_key, payload_digest, task_id, project_id, work_order_id, effective_digest, actor) VALUES ("
      <> text (admissionRowKey row)
      <> sql ", "
      <> text (admissionRowDigest row)
      <> sql ", "
      <> uuid (admissionRowTask row)
      <> sql ", "
      <> uuid (admissionRowProject row)
      <> sql ", "
      <> uuid (admissionRowWorkOrder row)
      <> sql ", "
      <> text (admissionRowEffectiveDigest row)
      <> sql ", "
      <> text (admissionRowActor row)
      <> sql ")"
