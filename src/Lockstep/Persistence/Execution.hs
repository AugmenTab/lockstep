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
  , enablementTable
  , enablementProjectField
  , enablementRepositoryField
  , enablementEngineerField
  , enablementFolderField
  , admissionTable
  , admissionIdField
  , admissionTaskField
  , admissionProjectField
  , admissionWorkOrderField
  ) where

import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O

import Lockstep.Persistence.Fields (headMay, selectJoined, tableReference, uuidField)
import Lockstep.Persistence.Ledger (WorkOrderRow (..), workOrderIdField, workOrderTable)
import Lockstep.Persistence.Projects (projectIdField, projectRepositoryField, projectTable)

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

{- | The time a row was recorded, as text in UTC to the second (what
@to_char(... AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || ' UTC'@ gave).
The column is set by the database, so it is read only.
-}
recordedAt :: String -> O.SqlMarshaller w T.Text
recordedAt column =
  T.pack . formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S UTC" <$> O.marshallReadOnlyField (O.utcTimestampField column :: O.FieldDefinition O.NotNull UTCTime)

-- lockstep_execution_enablements --------------------------------------------------

enablementTable :: O.TableDefinition O.NoKey EnablementRow EnablementRow
enablementTable =
  O.mkTableDefinitionWithoutKey "lockstep_execution_enablements" $
    EnablementRow
      <$> O.marshallField enablementRowKey enablementKeyField
      <*> O.marshallField enablementRowDigest (O.unboundedTextField "payload_digest")
      <*> O.marshallField enablementRowProject enablementProjectField
      <*> O.marshallField enablementRowRepository enablementRepositoryField
      <*> O.marshallField enablementRowEngineer enablementEngineerField
      <*> O.marshallField enablementRowFolder enablementFolderField
      <*> O.marshallField enablementRowProfile (O.unboundedTextField "profile_id")
      <*> O.marshallField enablementRowProfileVersion (O.integerField "profile_version")
      <*> O.marshallField enablementRowProfileDigest (O.unboundedTextField "profile_digest")
      <*> O.marshallField enablementRowActor (O.unboundedTextField "actor")
      <*> recordedAt "enabled_at"

enablementKeyField :: O.FieldDefinition O.NotNull T.Text
enablementKeyField =
  O.unboundedTextField "idempotency_key"

enablementProjectField :: O.FieldDefinition O.NotNull T.Text
enablementProjectField =
  uuidField "project_id"

enablementRepositoryField :: O.FieldDefinition O.NotNull T.Text
enablementRepositoryField =
  uuidField "repository_id"

enablementEngineerField :: O.FieldDefinition O.NotNull T.Text
enablementEngineerField =
  O.unboundedTextField "engineer_name"

enablementFolderField :: O.FieldDefinition O.NotNull T.Text
enablementFolderField =
  O.unboundedTextField "folder"

findEnablementByProject :: O.MonadOrville m => T.Text -> m (Maybe EnablementRow)
findEnablementByProject project =
  O.findFirstEntityBy enablementTable (O.where_ (O.fieldEquals enablementProjectField project))

findEnablementByKey :: O.MonadOrville m => T.Text -> m (Maybe EnablementRow)
findEnablementByKey key =
  O.findFirstEntityBy enablementTable (O.where_ (O.fieldEquals enablementKeyField key))

insertEnablement :: O.MonadOrville m => EnablementRow -> m ()
insertEnablement =
  O.insertEntity enablementTable

-- lockstep_bug_admissions ---------------------------------------------------------

admissionTable :: O.TableDefinition O.NoKey AdmissionRow AdmissionRow
admissionTable =
  O.mkTableDefinitionWithoutKey "lockstep_bug_admissions" $
    AdmissionRow
      <$> O.marshallField admissionRowKey admissionKeyField
      <*> O.marshallField admissionRowDigest (O.unboundedTextField "payload_digest")
      <*> O.marshallField admissionRowTask admissionTaskField
      <*> O.marshallField admissionRowProject admissionProjectField
      <*> O.marshallField admissionRowWorkOrder admissionWorkOrderField
      <*> O.marshallField admissionRowEffectiveDigest (O.unboundedTextField "effective_digest")
      <*> O.marshallField admissionRowActor (O.unboundedTextField "actor")
      <*> recordedAt "admitted_at"

admissionKeyField :: O.FieldDefinition O.NotNull T.Text
admissionKeyField =
  O.unboundedTextField "idempotency_key"

-- | The identity column: the order bugs were handed over in.
admissionIdField :: O.FieldDefinition O.NotNull Int64
admissionIdField =
  O.bigIntegerField "id"

admissionTaskField :: O.FieldDefinition O.NotNull T.Text
admissionTaskField =
  uuidField "task_id"

admissionProjectField :: O.FieldDefinition O.NotNull T.Text
admissionProjectField =
  uuidField "project_id"

admissionWorkOrderField :: O.FieldDefinition O.NotNull T.Text
admissionWorkOrderField =
  uuidField "work_order_id"

findAdmissionByTask :: O.MonadOrville m => T.Text -> m (Maybe AdmissionRow)
findAdmissionByTask task =
  O.findFirstEntityBy admissionTable (O.where_ (O.fieldEquals admissionTaskField task))

findAdmissionByKey :: O.MonadOrville m => T.Text -> m (Maybe AdmissionRow)
findAdmissionByKey key =
  O.findFirstEntityBy admissionTable (O.where_ (O.fieldEquals admissionKeyField key))

insertAdmission :: O.MonadOrville m => AdmissionRow -> m ()
insertAdmission =
  O.insertEntity admissionTable

-- Facts from other tables ---------------------------------------------------------

-- | The repository a project was connected to (C-P3.5 J1), if any.
projectRepository :: O.MonadOrville m => T.Text -> m (Maybe T.Text)
projectRepository project =
  headMay
    <$> selectJoined
      (O.marshallReadOnlyField (uuidField "repository_id"))
      (tableReference projectTable)
      (O.where_ (O.fieldIsNotNull projectRepositoryField `O.andExpr` O.fieldEquals projectIdField project))

-- | The effective Profile digest a Work Order was created with (C-P2.5).
workOrderEffectiveDigest :: O.MonadOrville m => T.Text -> m (Maybe T.Text)
workOrderEffectiveDigest workOrder =
  fmap workOrderRowEffectiveDigest <$> O.findFirstEntityBy workOrderTable (O.where_ (O.fieldEquals workOrderIdField workOrder))
