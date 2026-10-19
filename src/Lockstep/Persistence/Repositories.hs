{- | Storage for Engineers, repository ownership and identity decisions
(contract C-P2.1 I8, I9). Callers run these inside one transaction;
'lockRepositories' serializes registrations.
-}
module Lockstep.Persistence.Repositories
  ( RepositoryRow (..)
  , NewDecision (..)
  , insertEngineer
  , findEngineerByName
  , lockRepositories
  , activeRepositories
  , insertRepository
  , insertDecision
  ) where

import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString qualified as BS
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql
import Orville.PostgreSQL.Raw.SqlValue qualified as SqlValue

-- | An active repository with its owner's name; identities are canonical UUID text.
data RepositoryRow
  = RepositoryRow
  { rowRepositoryId :: T.Text
  , rowOwnerId :: T.Text
  , rowOwnerName :: T.Text
  , rowCommonDir :: T.Text
  , rowPhysicalId :: T.Text
  , rowRemoteName :: Maybe T.Text
  , rowRemoteIdentity :: Maybe T.Text
  , rowOtherRemotes :: T.Text
  }

data NewDecision
  = NewDecision
  { decisionOperation :: T.Text
  , decisionEngineerName :: T.Text
  , decisionPath :: Maybe T.Text
  , decisionRemote :: Maybe T.Text
  , decisionRefusal :: Maybe T.Text
  , decisionEngineerId :: Maybe T.Text
  , decisionRepositoryId :: Maybe T.Text
  , decisionObservation :: Maybe T.Text
  }

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

sql :: String -> RawSql.RawSql
sql =
  RawSql.fromString

-- | Inserts an Engineer unless the name is taken; True when inserted.
insertEngineer :: O.MonadOrville m => T.Text -> T.Text -> m Bool
insertEngineer engineerId name =
  not . null
    <$> O.executeAndDecode
      O.InsertQuery
      ( sql "INSERT INTO lockstep_engineers (id, name) VALUES ("
          <> uuid engineerId
          <> sql ", "
          <> text name
          <> sql ") ON CONFLICT (name) DO NOTHING RETURNING id::text AS id"
      )
      (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.unboundedTextField "id")))

findEngineerByName :: O.MonadOrville m => T.Text -> m (Maybe T.Text)
findEngineerByName name =
  headMay
    <$> O.executeAndDecode
      O.SelectQuery
      (sql "SELECT id::text AS id FROM lockstep_engineers WHERE name = " <> text name)
      (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.unboundedTextField "id")))

-- | Serializes registrations until the transaction ends; reads stay possible.
lockRepositories :: O.MonadOrville m => m ()
lockRepositories =
  O.executeVoid O.OtherQuery (sql "LOCK TABLE lockstep_repositories IN EXCLUSIVE MODE")

repositoryMarshaller :: O.AnnotatedSqlMarshaller RepositoryRow RepositoryRow
repositoryMarshaller =
  O.annotateSqlMarshallerEmptyAnnotation $
    RepositoryRow
      <$> O.marshallField rowRepositoryId (O.unboundedTextField "id")
      <*> O.marshallField rowOwnerId (O.unboundedTextField "owner_id")
      <*> O.marshallField rowOwnerName (O.unboundedTextField "owner_name")
      <*> O.marshallField rowCommonDir (O.unboundedTextField "common_dir")
      <*> O.marshallField rowPhysicalId (O.unboundedTextField "physical_id")
      <*> O.marshallField rowRemoteName (O.nullableField (O.unboundedTextField "authoritative_remote"))
      <*> O.marshallField rowRemoteIdentity (O.nullableField (O.unboundedTextField "authoritative_identity"))
      <*> O.marshallField rowOtherRemotes (O.unboundedTextField "other_remotes")

-- | Every active repository, by registration time then id.
activeRepositories :: O.MonadOrville m => m [RepositoryRow]
activeRepositories =
  O.executeAndDecode
    O.SelectQuery
    ( sql
        "SELECT r.id::text AS id, r.owner_engineer_id::text AS owner_id, e.name AS owner_name, r.common_dir, r.physical_id, r.authoritative_remote, r.authoritative_identity, r.other_remotes FROM lockstep_repositories r JOIN lockstep_engineers e ON e.id = r.owner_engineer_id WHERE r.released_at IS NULL ORDER BY r.registered_at, r.id"
    )
    repositoryMarshaller

-- | Inserts a repository with the SHA-256 digest of its rendered observation.
insertRepository :: O.MonadOrville m => RepositoryRow -> BS.ByteString -> m ()
insertRepository row digest =
  O.executeVoid O.InsertQuery $
    sql "INSERT INTO lockstep_repositories (id, owner_engineer_id, common_dir, physical_id, authoritative_remote, authoritative_identity, other_remotes, observation_digest) VALUES ("
      <> uuid (rowRepositoryId row)
      <> sql ", "
      <> uuid (rowOwnerId row)
      <> sql ", "
      <> text (rowCommonDir row)
      <> sql ", "
      <> text (rowPhysicalId row)
      <> sql ", "
      <> maybeText (rowRemoteName row)
      <> sql ", "
      <> maybeText (rowRemoteIdentity row)
      <> sql ", "
      <> text (rowOtherRemotes row)
      <> sql ", decode("
      <> text (TE.decodeLatin1 (convertToBase Base16 digest))
      <> sql ", 'hex'))"

-- | Records one decision; returns its id.
insertDecision :: O.MonadOrville m => NewDecision -> m (Maybe Int64)
insertDecision decision =
  headMay
    <$> O.executeAndDecode
      O.InsertQuery
      ( sql "INSERT INTO lockstep_identity_decisions (operation, engineer_name, requested_path, requested_remote, outcome, refusal_code, engineer_id, repository_id, observation) VALUES ("
          <> text (decisionOperation decision)
          <> sql ", "
          <> text (decisionEngineerName decision)
          <> sql ", "
          <> maybeText (decisionPath decision)
          <> sql ", "
          <> maybeText (decisionRemote decision)
          <> sql ", "
          <> text (T.pack (maybe "accepted" (const "refused") (decisionRefusal decision)))
          <> sql ", "
          <> maybeText (decisionRefusal decision)
          <> sql ", "
          <> maybeUuid (decisionEngineerId decision)
          <> sql ", "
          <> maybeUuid (decisionRepositoryId decision)
          <> sql ", "
          <> maybeText (decisionObservation decision)
          <> sql ") RETURNING id"
      )
      (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.bigIntegerField "id")))

headMay :: [a] -> Maybe a
headMay xs =
  case xs of
    [] -> Nothing
    x : _ -> Just x
