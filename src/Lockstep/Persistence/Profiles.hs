{- | Storage for Profile documents, repository default Profiles and Profile
decisions (contract C-P2.3 F13). Rows are never updated or deleted; the
migration's triggers refuse it.
-}
module Lockstep.Persistence.Profiles
  ( ProfileRow (..)
  , NewProfileDecision (..)
  , lockProfiles
  , insertProfile
  , profileVersions
  , allProfiles
  , findProfile
  , latestProfiles
  , EngineerRepository (..)
  , engineerRepository
  , insertRepositoryProfile
  , repositoryDefault
  , insertProfileDecision
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql
import Orville.PostgreSQL.Raw.SqlValue qualified as SqlValue

data ProfileRow
  = ProfileRow
  { profileRowId :: T.Text
  , profileRowVersion :: Int32
  , profileRowDigest :: T.Text
  , profileRowDocument :: T.Text
  }

data NewProfileDecision
  = NewProfileDecision
  { profileDecisionOperation :: T.Text
  , profileDecisionProfile :: Maybe T.Text
  , profileDecisionVersion :: Maybe Int32
  , profileDecisionDigest :: Maybe T.Text
  , profileDecisionEngineer :: Maybe T.Text
  , profileDecisionRepository :: Maybe T.Text
  , profileDecisionOutcome :: T.Text
  , profileDecisionRefusal :: Maybe T.Text
  }

-- | An Engineer and its active repository, if any (identities as UUID text).
data EngineerRepository
  = EngineerRepository
  { engineerRowId :: T.Text
  , engineerRowRepository :: Maybe T.Text
  }

sql :: String -> RawSql.RawSql
sql =
  RawSql.fromString

text :: T.Text -> RawSql.RawSql
text =
  RawSql.parameter . SqlValue.fromText

int :: Int32 -> RawSql.RawSql
int =
  RawSql.parameter . SqlValue.fromInt32

maybeOf :: (a -> RawSql.RawSql) -> Maybe a -> RawSql.RawSql
maybeOf =
  maybe (sql "NULL")

uuid :: T.Text -> RawSql.RawSql
uuid value =
  sql "CAST(" <> text value <> sql " AS uuid)"

-- | Serializes Profile additions until the transaction ends; reads stay possible.
lockProfiles :: O.MonadOrville m => m ()
lockProfiles =
  O.executeVoid O.OtherQuery (sql "LOCK TABLE lockstep_profiles IN EXCLUSIVE MODE")

insertProfile :: O.MonadOrville m => ProfileRow -> m ()
insertProfile row =
  O.executeVoid O.InsertQuery $
    sql "INSERT INTO lockstep_profiles (profile_id, version, digest, document) VALUES ("
      <> text (profileRowId row)
      <> sql ", "
      <> int (profileRowVersion row)
      <> sql ", "
      <> text (profileRowDigest row)
      <> sql ", "
      <> text (profileRowDocument row)
      <> sql ")"

profileMarshaller :: O.AnnotatedSqlMarshaller ProfileRow ProfileRow
profileMarshaller =
  O.annotateSqlMarshallerEmptyAnnotation $
    ProfileRow
      <$> O.marshallField profileRowId (O.unboundedTextField "profile_id")
      <*> O.marshallField profileRowVersion (O.integerField "version")
      <*> O.marshallField profileRowDigest (O.unboundedTextField "digest")
      <*> O.marshallField profileRowDocument (O.unboundedTextField "document")

selectProfiles :: O.MonadOrville m => RawSql.RawSql -> m [ProfileRow]
selectProfiles rest =
  O.executeAndDecode
    O.SelectQuery
    (sql "SELECT profile_id, version, digest, document FROM lockstep_profiles " <> rest)
    profileMarshaller

-- | Every stored version of one Profile, oldest first.
profileVersions :: O.MonadOrville m => T.Text -> m [ProfileRow]
profileVersions profileId =
  selectProfiles (sql "WHERE profile_id = " <> text profileId <> sql " ORDER BY version")

allProfiles :: O.MonadOrville m => m [ProfileRow]
allProfiles =
  selectProfiles (sql "ORDER BY profile_id, version")

-- | One version, or the latest when none is given.
findProfile :: O.MonadOrville m => T.Text -> Maybe Int32 -> m (Maybe ProfileRow)
findProfile profileId version =
  headMay
    <$> selectProfiles
      ( sql "WHERE profile_id = "
          <> text profileId
          <> maybe (sql "") (\v -> sql " AND version = " <> int v) version
          <> sql " ORDER BY version DESC LIMIT 1"
      )

-- | The latest version of every Profile, by id.
latestProfiles :: O.MonadOrville m => m [ProfileRow]
latestProfiles =
  selectProfiles
    (sql "WHERE (profile_id, version) IN (SELECT profile_id, max(version) FROM lockstep_profiles GROUP BY profile_id) ORDER BY profile_id")

engineerRepository :: O.MonadOrville m => T.Text -> m (Maybe EngineerRepository)
engineerRepository name =
  headMay
    <$> O.executeAndDecode
      O.SelectQuery
      ( sql "SELECT e.id::text AS engineer_id, r.id::text AS repository_id FROM lockstep_engineers e LEFT JOIN lockstep_repositories r ON r.owner_engineer_id = e.id AND r.released_at IS NULL WHERE e.name = "
          <> text name
      )
      ( O.annotateSqlMarshallerEmptyAnnotation $
          EngineerRepository
            <$> O.marshallField engineerRowId (O.unboundedTextField "engineer_id")
            <*> O.marshallField engineerRowRepository (O.nullableField (O.unboundedTextField "repository_id"))
      )

insertRepositoryProfile :: O.MonadOrville m => T.Text -> T.Text -> m ()
insertRepositoryProfile repositoryId profileId =
  O.executeVoid O.InsertQuery $
    sql "INSERT INTO lockstep_repository_profiles (repository_id, profile_id) VALUES ("
      <> uuid repositoryId
      <> sql ", "
      <> text profileId
      <> sql ")"

-- | The repository's current default Profile id: the latest assignment.
repositoryDefault :: O.MonadOrville m => T.Text -> m (Maybe T.Text)
repositoryDefault repositoryId =
  headMay
    <$> O.executeAndDecode
      O.SelectQuery
      ( sql "SELECT profile_id FROM lockstep_repository_profiles WHERE repository_id = "
          <> uuid repositoryId
          <> sql " ORDER BY id DESC LIMIT 1"
      )
      (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.unboundedTextField "profile_id")))

-- | Records one decision; returns its id.
insertProfileDecision :: O.MonadOrville m => NewProfileDecision -> m (Maybe Int64)
insertProfileDecision decision =
  headMay
    <$> O.executeAndDecode
      O.InsertQuery
      ( sql "INSERT INTO lockstep_profile_decisions (operation, profile_id, version, digest, engineer_name, repository_id, outcome, refusal_code) VALUES ("
          <> text (profileDecisionOperation decision)
          <> sql ", "
          <> maybeOf text (profileDecisionProfile decision)
          <> sql ", "
          <> maybeOf int (profileDecisionVersion decision)
          <> sql ", "
          <> maybeOf text (profileDecisionDigest decision)
          <> sql ", "
          <> maybeOf text (profileDecisionEngineer decision)
          <> sql ", "
          <> maybeOf uuid (profileDecisionRepository decision)
          <> sql ", "
          <> text (profileDecisionOutcome decision)
          <> sql ", "
          <> maybeOf text (profileDecisionRefusal decision)
          <> sql ") RETURNING id"
      )
      (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.bigIntegerField "id")))

headMay :: [a] -> Maybe a
headMay xs =
  case xs of
    [] -> Nothing
    x : _ -> Just x
