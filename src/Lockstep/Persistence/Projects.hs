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
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql
import Orville.PostgreSQL.Raw.SqlValue qualified as SqlValue
import Text.Show (show)

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
  }

sql :: String -> RawSql.RawSql
sql =
  RawSql.fromString

text :: T.Text -> RawSql.RawSql
text =
  RawSql.parameter . SqlValue.fromText

maybeText :: Maybe T.Text -> RawSql.RawSql
maybeText =
  maybe (sql "NULL") text

uuid :: T.Text -> RawSql.RawSql
uuid value =
  sql "CAST(" <> text value <> sql " AS uuid)"

maybeUuid :: Maybe T.Text -> RawSql.RawSql
maybeUuid =
  maybe (sql "NULL") uuid

columns :: String
columns =
  "id::text AS id, name, outcome, setup, setup_refusal, folder, engineer_name, revision"

projectMarshaller :: O.AnnotatedSqlMarshaller ProjectRow ProjectRow
projectMarshaller =
  O.annotateSqlMarshallerEmptyAnnotation $
    ProjectRow
      <$> O.marshallField rowId (O.unboundedTextField "id")
      <*> O.marshallField rowName (O.unboundedTextField "name")
      <*> O.marshallField rowOutcome (O.unboundedTextField "outcome")
      <*> O.marshallField rowSetup (O.unboundedTextField "setup")
      <*> O.marshallField rowRefusal (O.nullableField (O.unboundedTextField "setup_refusal"))
      <*> O.marshallField rowFolder (O.nullableField (O.unboundedTextField "folder"))
      <*> O.marshallField rowEngineerName (O.nullableField (O.unboundedTextField "engineer_name"))
      <*> O.marshallField rowRevision (O.bigIntegerField "revision")

headMay :: [a] -> Maybe a
headMay xs =
  case xs of
    [] -> Nothing
    x : _ -> Just x

-- | Serializes project changes until the transaction ends; reads stay possible.
lockProjects :: O.MonadOrville m => m ()
lockProjects =
  O.executeVoid O.OtherQuery (sql "LOCK TABLE lockstep_projects IN EXCLUSIVE MODE")

selectWhere :: O.MonadOrville m => RawSql.RawSql -> m [ProjectRow]
selectWhere condition =
  O.executeAndDecode
    O.SelectQuery
    (sql ("SELECT " <> columns <> " FROM lockstep_projects WHERE ") <> condition <> sql " ORDER BY created_at, id")
    projectMarshaller

findProjectByKey :: O.MonadOrville m => T.Text -> m (Maybe ProjectRow)
findProjectByKey key =
  headMay <$> selectWhere (sql "creation_key = " <> text key)

findProjectById :: O.MonadOrville m => T.Text -> m (Maybe ProjectRow)
findProjectById projectId =
  headMay <$> selectWhere (sql "id = " <> uuid projectId)

projectNameTaken :: O.MonadOrville m => T.Text -> m Bool
projectNameTaken name =
  not . null <$> selectWhere (sql "lower(name) = lower(" <> text name <> sql ")")

insertProject :: O.MonadOrville m => T.Text -> T.Text -> T.Text -> T.Text -> m ()
insertProject projectId key name outcome =
  O.executeVoid O.InsertQuery $
    sql "INSERT INTO lockstep_projects (id, creation_key, name, outcome, setup) VALUES ("
      <> uuid projectId
      <> sql ", "
      <> text key
      <> sql ", "
      <> text name
      <> sql ", "
      <> text outcome
      <> sql ", 'organized')"

{- | Records one connection attempt if the project is still at the expected
revision; True when it was. The revision goes up by one.
-}
updateProjectSetup :: O.MonadOrville m => T.Text -> Int64 -> T.Text -> Maybe T.Text -> Maybe T.Text -> Maybe T.Text -> Maybe T.Text -> m Bool
updateProjectSetup projectId expected setup refusal folder engineerName repositoryId =
  not . null
    <$> O.executeAndDecode
      O.UpdateQuery
      ( sql "UPDATE lockstep_projects SET setup = "
          <> text setup
          <> sql ", setup_refusal = "
          <> maybeText refusal
          <> sql ", folder = "
          <> maybeText folder
          <> sql ", engineer_name = "
          <> maybeText engineerName
          <> sql ", repository_id = "
          <> maybeUuid repositoryId
          <> sql ", revision = revision + 1, updated_at = now() WHERE id = "
          <> uuid projectId
          <> sql (" AND revision = " <> show expected <> " RETURNING id::text AS id")
      )
      (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.unboundedTextField "id")))

allProjects :: O.MonadOrville m => m [ProjectRow]
allProjects =
  selectWhere (sql "TRUE")

connectedFolders :: O.MonadOrville m => m [T.Text]
connectedFolders =
  O.executeAndDecode
    O.SelectQuery
    (sql "SELECT folder FROM lockstep_projects WHERE setup = 'connected' AND folder IS NOT NULL")
    (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.unboundedTextField "folder")))
