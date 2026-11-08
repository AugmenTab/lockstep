{- | Storage for projects (contract C-P3.5 J1, J2). Callers run these inside
one transaction; 'lockProjects' serializes creations and connections.
-}
module Lockstep.Persistence.Projects
  ( ProjectRow (..)
  , lockProjects
  , findProjectByKey
  , findProjectById
  , projectNameTaken
  , insertProject
  , updateProjectSetup
  , allProjects
  , connectedFolders
  , projectTable
  , projectIdField
  , projectRepositoryField
  ) where

import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text qualified as T
import Data.Time (UTCTime)
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Expr qualified as Expr
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql
import Orville.PostgreSQL.Raw.SqlValue qualified as SqlValue

import Lockstep.Persistence.Fields (increment, selectJoined, setNow, tableReference, uuidField)

data ProjectRow
  = ProjectRow
  { rowId :: T.Text
  , rowName :: T.Text
  , rowOutcome :: T.Text
  , rowSetup :: T.Text
  , rowRefusal :: Maybe T.Text
  , rowFolder :: Maybe T.Text
  , rowEngineerName :: Maybe T.Text
  , rowRevision :: Int64
  , rowCreationDigest :: Maybe T.Text
  }

-- | What a new project is created with; everything else starts at its default.
data NewProject
  = NewProject
  { newProjectId :: T.Text
  , newProjectKey :: T.Text
  , newProjectName :: T.Text
  , newProjectOutcome :: T.Text
  , newProjectDigest :: T.Text
  }

{- | A project is written with its creation facts and read back as a
'ProjectRow'. The setup refusal, folder, Engineer and revision are read only:
the connection steps change them with 'updateProjectSetup'.
-}
projectTable :: O.TableDefinition (O.HasKey T.Text) NewProject ProjectRow
projectTable =
  O.mkTableDefinition "lockstep_projects" (O.primaryKey projectIdField) $
    (\projectId _key name outcome setup refusal folder engineer revision digest -> ProjectRow projectId name outcome setup refusal folder engineer revision digest)
      <$> O.marshallField newProjectId projectIdField
      <*> O.marshallField newProjectKey projectKeyField
      <*> O.marshallField newProjectName projectNameField
      <*> O.marshallField newProjectOutcome (O.unboundedTextField "outcome")
      <*> O.marshallField (const (T.pack "organized")) projectSetupField
      <*> O.marshallReadOnlyField projectRefusalField
      <*> O.marshallReadOnlyField projectFolderField
      <*> O.marshallReadOnlyField projectEngineerField
      <*> O.marshallReadOnlyField projectRevisionField
      <*> O.marshallField (Just . newProjectDigest) (O.nullableField (O.unboundedTextField "creation_digest"))

projectIdField :: O.FieldDefinition O.NotNull T.Text
projectIdField =
  uuidField "id"

projectKeyField :: O.FieldDefinition O.NotNull T.Text
projectKeyField =
  O.unboundedTextField "creation_key"

projectNameField :: O.FieldDefinition O.NotNull T.Text
projectNameField =
  O.unboundedTextField "name"

projectSetupField :: O.FieldDefinition O.NotNull T.Text
projectSetupField =
  O.unboundedTextField "setup"

projectRefusalField :: O.FieldDefinition O.Nullable (Maybe T.Text)
projectRefusalField =
  O.nullableField (O.unboundedTextField "setup_refusal")

projectFolderField :: O.FieldDefinition O.Nullable (Maybe T.Text)
projectFolderField =
  O.nullableField (O.unboundedTextField "folder")

projectEngineerField :: O.FieldDefinition O.Nullable (Maybe T.Text)
projectEngineerField =
  O.nullableField (O.unboundedTextField "engineer_name")

projectRevisionField :: O.FieldDefinition O.NotNull Int64
projectRevisionField =
  O.bigIntegerField "revision"

projectRepositoryField :: O.FieldDefinition O.Nullable (Maybe T.Text)
projectRepositoryField =
  O.nullableField (uuidField "repository_id")

projectCreatedAtField :: O.FieldDefinition O.NotNull UTCTime
projectCreatedAtField =
  O.utcTimestampField "created_at"

projectUpdatedAtField :: O.FieldDefinition O.NotNull UTCTime
projectUpdatedAtField =
  O.utcTimestampField "updated_at"

{- | Serializes project changes until the transaction ends; reads stay
possible. Orville has no table-lock statement.
-}
lockProjects :: O.MonadOrville m => m ()
lockProjects =
  O.executeVoid O.OtherQuery (RawSql.fromString "LOCK TABLE lockstep_projects IN EXCLUSIVE MODE")

-- | Matching projects, by creation then id.
projectsWhere :: O.MonadOrville m => Expr.BooleanExpr -> m [ProjectRow]
projectsWhere condition =
  O.findEntitiesBy projectTable (O.where_ condition <> creationOrder)

creationOrder :: O.SelectOptions
creationOrder =
  O.orderBy (O.orderByField projectCreatedAtField O.ascendingOrder <> O.orderByField projectIdField O.ascendingOrder)

findProjectByKey :: O.MonadOrville m => T.Text -> m (Maybe ProjectRow)
findProjectByKey key =
  O.findFirstEntityBy projectTable (O.where_ (O.fieldEquals projectKeyField key) <> creationOrder)

findProjectById :: O.MonadOrville m => T.Text -> m (Maybe ProjectRow)
findProjectById projectId =
  O.findFirstEntityBy projectTable (O.where_ (O.fieldEquals projectIdField projectId) <> creationOrder)

-- | Whether another project has this name, ignoring case (the unique index is on @lower(name)@).
projectNameTaken :: O.MonadOrville m => T.Text -> m Bool
projectNameTaken name =
  let
    lower value = Expr.functionCall (Expr.functionName "lower") [value]
  in
    not . null
      <$> projectsWhere (Expr.equals (lower (O.fieldColumnReference projectNameField)) (lower (Expr.valueExpression (SqlValue.fromText name))))

insertProject :: O.MonadOrville m => T.Text -> T.Text -> T.Text -> T.Text -> T.Text -> m ()
insertProject projectId key name outcome digest =
  O.insertEntity projectTable (NewProject projectId key name outcome digest)

{- | Records one connection attempt if the project is still at the expected
revision; True when it was. The revision goes up by one.
-}
updateProjectSetup :: O.MonadOrville m => T.Text -> Int64 -> T.Text -> Maybe T.Text -> Maybe T.Text -> Maybe T.Text -> Maybe T.Text -> m Bool
updateProjectSetup projectId expected setup refusal folder engineerName repositoryId =
  not . null
    <$> O.updateFieldsAndReturnEntities
      projectTable
      ( O.setField projectSetupField setup
          :| [ O.setField projectRefusalField refusal
             , O.setField projectFolderField folder
             , O.setField projectEngineerField engineerName
             , O.setField projectRepositoryField repositoryId
             , increment projectRevisionField
             , setNow projectUpdatedAtField
             ]
      )
      (Just (O.fieldEquals projectIdField projectId `O.andExpr` O.fieldEquals projectRevisionField expected))

allProjects :: O.MonadOrville m => m [ProjectRow]
allProjects =
  O.findEntitiesBy projectTable creationOrder

connectedFolders :: O.MonadOrville m => m [T.Text]
connectedFolders =
  selectJoined
    (O.marshallReadOnlyField (O.unboundedTextField "folder"))
    (tableReference projectTable)
    (O.where_ (O.fieldEquals projectSetupField (T.pack "connected") `O.andExpr` O.fieldIsNotNull projectFolderField))
