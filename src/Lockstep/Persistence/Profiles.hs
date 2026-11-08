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

import Data.List qualified as L
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.List.NonEmpty qualified as NE
import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Expr qualified as Expr
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql

import Lockstep.Persistence.Fields
  ( headMay
  , joinedOn
  , qualified
  , qualifiedEquals
  , qualifiedReference
  , selectJoined
  , tableReference
  , uuidField
  )
import Lockstep.Persistence.Repositories
  ( engineerIdField
  , engineerNameField
  , engineerTable
  , repositoryIdField
  , repositoryOwnerField
  , repositoryReleasedAtField
  , repositoryTable
  )

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

-- lockstep_profiles ----------------------------------------------------------------

-- | Keyed by (profile id, version); the key is not used to look rows up, so the table is declared without one.
profileTable :: O.TableDefinition O.NoKey ProfileRow ProfileRow
profileTable =
  O.mkTableDefinitionWithoutKey "lockstep_profiles" $
    ProfileRow
      <$> O.marshallField profileRowId profileIdField
      <*> O.marshallField profileRowVersion profileVersionField
      <*> O.marshallField profileRowDigest (O.unboundedTextField "digest")
      <*> O.marshallField profileRowDocument (O.unboundedTextField "document")

profileIdField :: O.FieldDefinition O.NotNull T.Text
profileIdField =
  O.unboundedTextField "profile_id"

profileVersionField :: O.FieldDefinition O.NotNull Int32
profileVersionField =
  O.integerField "version"

{- | Serializes Profile additions until the transaction ends; reads stay
possible. Orville has no table-lock statement.
-}
lockProfiles :: O.MonadOrville m => m ()
lockProfiles =
  O.executeVoid O.OtherQuery (RawSql.fromString "LOCK TABLE lockstep_profiles IN EXCLUSIVE MODE")

insertProfile :: O.MonadOrville m => ProfileRow -> m ()
insertProfile =
  O.insertEntity profileTable

-- | Every stored version of one Profile, oldest first.
profileVersions :: O.MonadOrville m => T.Text -> m [ProfileRow]
profileVersions profileId =
  O.findEntitiesBy
    profileTable
    (O.where_ (O.fieldEquals profileIdField profileId) <> O.orderBy (O.orderByField profileVersionField O.ascendingOrder))

allProfiles :: O.MonadOrville m => m [ProfileRow]
allProfiles =
  O.findEntitiesBy profileTable (O.orderBy (O.orderByField profileIdField O.ascendingOrder <> O.orderByField profileVersionField O.ascendingOrder))

-- | One version, or the latest when none is given.
findProfile :: O.MonadOrville m => T.Text -> Maybe Int32 -> m (Maybe ProfileRow)
findProfile profileId version =
  O.findFirstEntityBy
    profileTable
    ( O.where_ (L.foldl' O.andExpr (O.fieldEquals profileIdField profileId) [O.fieldEquals profileVersionField v | Just v <- [version]])
        <> O.orderBy (O.orderByField profileVersionField O.descendingOrder)
    )

{- | The latest version of every Profile, by id: the last row of each id in
'allProfiles' order (one statement, as the former @(profile_id, version) IN
(SELECT ... max(version) ... GROUP BY profile_id)@ was).
-}
latestProfiles :: O.MonadOrville m => m [ProfileRow]
latestProfiles =
  fmap NE.last . NE.groupBy (\a b -> profileRowId a == profileRowId b) <$> allProfiles

-- The Engineer's active repository ---------------------------------------------------

{- | The Engineer named, and the repository it owns now, if any. Both tables
have an @id@ column, so the Engineer's is selected as @engineer_id@.
-}
engineerRepository :: O.MonadOrville m => T.Text -> m (Maybe EngineerRepository)
engineerRepository name =
  let
    engineerId = qualified engineerTable engineerIdField
  in
    headMay
      <$> selectJoined
        ( EngineerRepository
            <$> O.marshallSyntheticField (O.syntheticField (qualifiedReference engineerId) "engineer_id" (O.fieldType engineerIdField))
            <*> O.marshallQualifyFields (O.tableIdentifier repositoryTable) (O.marshallReadOnlyField (O.nullableField repositoryIdField))
        )
        ( joinedOn
            engineerTable
            [
              ( Expr.leftJoinType
              , tableReference repositoryTable
              , Expr.equals (qualifiedReference (qualified repositoryTable repositoryOwnerField)) (qualifiedReference engineerId)
                  `O.andExpr` Expr.isNull (qualifiedReference (qualified repositoryTable repositoryReleasedAtField))
              )
            ]
        )
        (O.where_ (qualifiedEquals (qualified engineerTable engineerNameField) name))

-- lockstep_repository_profiles -------------------------------------------------------

-- | (repository, Profile id): every assignment, newest last.
repositoryProfileTable :: O.TableDefinition O.NoKey (T.Text, T.Text) (T.Text, T.Text)
repositoryProfileTable =
  O.mkTableDefinitionWithoutKey "lockstep_repository_profiles" $
    (,)
      <$> O.marshallField fst repositoryProfileRepositoryField
      <*> O.marshallField snd profileIdField

repositoryProfileRepositoryField :: O.FieldDefinition O.NotNull T.Text
repositoryProfileRepositoryField =
  uuidField "repository_id"

insertRepositoryProfile :: O.MonadOrville m => T.Text -> T.Text -> m ()
insertRepositoryProfile repositoryId profileId =
  O.insertEntity repositoryProfileTable (repositoryId, profileId)

-- | The repository's current default Profile id: the latest assignment.
repositoryDefault :: O.MonadOrville m => T.Text -> m (Maybe T.Text)
repositoryDefault repositoryId =
  fmap snd
    <$> O.findFirstEntityBy
      repositoryProfileTable
      (O.where_ (O.fieldEquals repositoryProfileRepositoryField repositoryId) <> O.orderBy (O.orderByField (O.bigIntegerField "id") O.descendingOrder))

-- lockstep_profile_decisions ---------------------------------------------------------

-- | A decision as written; read back as its id.
profileDecisionTable :: O.TableDefinition O.NoKey NewProfileDecision Int64
profileDecisionTable =
  O.mkTableDefinitionWithoutKey "lockstep_profile_decisions" $
    O.marshallReadOnlyField (O.bigIntegerField "id")
      <* O.marshallField profileDecisionOperation (O.unboundedTextField "operation")
      <* O.marshallField profileDecisionProfile (O.nullableField profileIdField)
      <* O.marshallField profileDecisionVersion (O.nullableField profileVersionField)
      <* O.marshallField profileDecisionDigest (O.nullableField (O.unboundedTextField "digest"))
      <* O.marshallField profileDecisionEngineer (O.nullableField (O.unboundedTextField "engineer_name"))
      <* O.marshallField profileDecisionRepository (O.nullableField (uuidField "repository_id"))
      <* O.marshallField profileDecisionOutcome (O.unboundedTextField "outcome")
      <* O.marshallField profileDecisionRefusal (O.nullableField (O.unboundedTextField "refusal_code"))

-- | Records one decision; returns its id.
insertProfileDecision :: O.MonadOrville m => NewProfileDecision -> m (Maybe Int64)
insertProfileDecision decision =
  headMay <$> O.insertAndReturnEntities profileDecisionTable (decision :| [])
