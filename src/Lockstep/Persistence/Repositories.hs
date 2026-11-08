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
  , engineerTable
  , engineerIdField
  , engineerNameField
  , repositoryTable
  , repositoryIdField
  , repositoryOwnerField
  , repositoryReleasedAtField
  , activeRepositoryCondition
  ) where

import Data.ByteString qualified as BS
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text qualified as T
import Data.Time (UTCTime)
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Expr qualified as Expr
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql

import Lockstep.Persistence.Fields
  ( ConflictTarget (..)
  , digestField
  , headMay
  , insertIgnoringConflict
  , joinedOn
  , qualified
  , qualifiedOrder
  , qualifiedReference
  , selectJoined
  , tableReference
  , uuidField
  )

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

-- lockstep_engineers -------------------------------------------------------------

-- | (id, name).
engineerTable :: O.TableDefinition (O.HasKey T.Text) (T.Text, T.Text) (T.Text, T.Text)
engineerTable =
  O.mkTableDefinition "lockstep_engineers" (O.primaryKey engineerIdField) $
    (,)
      <$> O.marshallField fst engineerIdField
      <*> O.marshallField snd engineerNameField

engineerIdField :: O.FieldDefinition O.NotNull T.Text
engineerIdField =
  uuidField "id"

engineerNameField :: O.FieldDefinition O.NotNull T.Text
engineerNameField =
  O.unboundedTextField "name"

-- | Inserts an Engineer unless the name is taken; True when inserted.
insertEngineer :: O.MonadOrville m => T.Text -> T.Text -> m Bool
insertEngineer engineerId name =
  insertIgnoringConflict (ConflictOn "name") engineerTable (engineerId, name)

findEngineerByName :: O.MonadOrville m => T.Text -> m (Maybe T.Text)
findEngineerByName name =
  fmap fst <$> O.findFirstEntityBy engineerTable (O.where_ (O.fieldEquals engineerNameField name))

-- lockstep_repositories ----------------------------------------------------------

{- | A repository and the digest of its rendered observation. The rows read
back carry their owner's name, which lives in @lockstep_engineers@, so the
table reads a row still waiting for it; 'activeRepositories' supplies it.
-}
repositoryTable :: O.TableDefinition (O.HasKey T.Text) (RepositoryRow, BS.ByteString) (T.Text -> RepositoryRow)
repositoryTable =
  O.mkTableDefinition "lockstep_repositories" (O.primaryKey repositoryIdField) $
    (\repositoryId ownerId commonDir physicalId remote identity others _digest ownerName -> RepositoryRow repositoryId ownerId ownerName commonDir physicalId remote identity others)
      <$> O.marshallField (rowRepositoryId . fst) repositoryIdField
      <*> O.marshallField (rowOwnerId . fst) repositoryOwnerField
      <*> O.marshallField (rowCommonDir . fst) (O.unboundedTextField "common_dir")
      <*> O.marshallField (rowPhysicalId . fst) (O.unboundedTextField "physical_id")
      <*> O.marshallField (rowRemoteName . fst) (O.nullableField (O.unboundedTextField "authoritative_remote"))
      <*> O.marshallField (rowRemoteIdentity . fst) (O.nullableField (O.unboundedTextField "authoritative_identity"))
      <*> O.marshallField (rowOtherRemotes . fst) (O.unboundedTextField "other_remotes")
      <*> O.marshallField snd (digestField "observation_digest")

repositoryIdField :: O.FieldDefinition O.NotNull T.Text
repositoryIdField =
  uuidField "id"

repositoryOwnerField :: O.FieldDefinition O.NotNull T.Text
repositoryOwnerField =
  uuidField "owner_engineer_id"

repositoryRegisteredAtField :: O.FieldDefinition O.NotNull UTCTime
repositoryRegisteredAtField =
  O.utcTimestampField "registered_at"

repositoryReleasedAtField :: O.FieldDefinition O.Nullable (Maybe UTCTime)
repositoryReleasedAtField =
  O.nullableField (O.utcTimestampField "released_at")

-- | The repository is still owned (it has not been released).
activeRepositoryCondition :: Expr.BooleanExpr
activeRepositoryCondition =
  O.fieldIsNull repositoryReleasedAtField

{- | Serializes registrations until the transaction ends; reads stay possible.
Orville has no table-lock statement.
-}
lockRepositories :: O.MonadOrville m => m ()
lockRepositories =
  O.executeVoid O.OtherQuery (RawSql.fromString "LOCK TABLE lockstep_repositories IN EXCLUSIVE MODE")

-- | Every active repository, by registration time then id.
activeRepositories :: O.MonadOrville m => m [RepositoryRow]
activeRepositories =
  selectJoined
    ( O.marshallReadOnly (O.marshallQualifyFields (O.tableIdentifier repositoryTable) (O.unannotatedSqlMarshaller (O.tableMarshaller repositoryTable)))
        <*> O.marshallReadOnly (O.marshallQualifyFields (O.tableIdentifier engineerTable) (O.marshallReadOnlyField engineerNameField))
    )
    ( joinedOn
        repositoryTable
        [
          ( Expr.innerJoinType
          , tableReference engineerTable
          , Expr.equals (qualifiedReference (qualified engineerTable engineerIdField)) (qualifiedReference (ofRepository repositoryOwnerField))
          )
        ]
    )
    ( O.where_ (Expr.isNull (qualifiedReference (ofRepository repositoryReleasedAtField)))
        <> O.orderBy (qualifiedOrder (ofRepository repositoryRegisteredAtField) O.ascendingOrder <> qualifiedOrder (ofRepository repositoryIdField) O.ascendingOrder)
    )

-- | A column of @lockstep_repositories@ in a join.
ofRepository :: O.FieldDefinition nullability a -> O.QualifiedFieldDefinition O.TableIdentifier nullability a
ofRepository =
  qualified repositoryTable

-- | Inserts a repository with the SHA-256 digest of its rendered observation.
insertRepository :: O.MonadOrville m => RepositoryRow -> BS.ByteString -> m ()
insertRepository row digest =
  O.insertEntity repositoryTable (row, digest)

-- lockstep_identity_decisions ----------------------------------------------------

-- | A decision as written; read back as its id.
decisionTable :: O.TableDefinition O.NoKey NewDecision Int64
decisionTable =
  O.mkTableDefinitionWithoutKey "lockstep_identity_decisions" $
    O.marshallReadOnlyField (O.bigIntegerField "id")
      <* O.marshallField decisionOperation (O.unboundedTextField "operation")
      <* O.marshallField decisionEngineerName (O.unboundedTextField "engineer_name")
      <* O.marshallField decisionPath (O.nullableField (O.unboundedTextField "requested_path"))
      <* O.marshallField decisionRemote (O.nullableField (O.unboundedTextField "requested_remote"))
      <* O.marshallField (T.pack . maybe "accepted" (const "refused") . decisionRefusal) (O.unboundedTextField "outcome")
      <* O.marshallField decisionRefusal (O.nullableField (O.unboundedTextField "refusal_code"))
      <* O.marshallField decisionEngineerId (O.nullableField (uuidField "engineer_id"))
      <* O.marshallField decisionRepositoryId (O.nullableField (uuidField "repository_id"))
      <* O.marshallField decisionObservation (O.nullableField (O.unboundedTextField "observation"))

-- | Records one decision; returns its id.
insertDecision :: O.MonadOrville m => NewDecision -> m (Maybe Int64)
insertDecision decision =
  headMay <$> O.insertAndReturnEntities decisionTable (decision :| [])
