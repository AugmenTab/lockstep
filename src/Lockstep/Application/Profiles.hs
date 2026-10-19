{- | The Profile registry, repository default Profiles and dry-run resolution
(contract C-P2.3 F11, F13, F14). Every @profile add@ and @repository
set-profile@ attempt that reaches the database leaves one decision row. A
stored document is used only after its recomputed digest matches the stored
one.
-}
module Lockstep.Application.Profiles
  ( sha256Hasher
  , ProfileFailure (..)
  , AddOutcome (..)
  , StoredProfile (..)
  , ResolveRequest (..)
  , readProfileDocument
  , addProfile
  , listProfiles
  , showProfile
  , setRepositoryProfile
  , resolveForEngineer
  , loadStoredDefinition
  ) where

import Control.Exception (IOException, throwIO, try)
import Crypto.Hash (SHA256 (SHA256), hashWith)
import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import System.IO (FilePath)
import System.IO.Error (userError)
import Text.Show (show)

import Lockstep.Application.Database
  ( DatabaseRuntime
  , NotReadyReason
  , Readiness (..)
  , checkReadiness
  , withDatabase
  )
import Lockstep.Application.ProfileDocument (decodeProfileDocument)
import Lockstep.Kernel.Profile
  ( Behaviour (..)
  , ContentDigest
  , Hasher (..)
  , ProfileDefinition
  , ProfileRef (..)
  , ResolutionInput (..)
  , contentDigestText
  , definitionId
  , definitionVersion
  , effectiveDigest
  , mkClassTag
  , mkContentDigest
  , mkNonBehaviouralBasis
  , mkProfileDefinition
  , mkWorkFacts
  , parsePathClass
  , profileIdText
  , profileRef
  , profileRefusalCode
  , renderEffectiveProfile
  , renderProfileDefinition
  , renderProfileRefusal
  , resolveProfile
  )
import Lockstep.Kernel.Transition (Principal (Human))
import Lockstep.Kernel.WorkOrder (parseWorkOrderKind)
import Lockstep.Persistence.Profiles qualified as Store

-- | SHA-256 of the UTF-8 text, as 64 lowercase hex characters.
sha256Hasher :: Hasher
sha256Hasher =
  Hasher (digestOf . T.pack . show . hashWith SHA256 . TE.encodeUtf8)

-- | The 'show' of a SHA-256 digest is always 64 lowercase hex characters.
digestOf :: T.Text -> ContentDigest
digestOf text =
  fromMaybe (digestOf (T.replicate 64 (T.pack "0"))) (mkContentDigest text)

data ProfileFailure
  = -- | A refusal: code, reason and the decision row when one was recorded (exit 65).
    ProfileRefused T.Text T.Text (Maybe Int64)
  | -- | A stored document whose digest does not reproduce (exit 70).
    ProfileIntegrity T.Text

data AddOutcome
  = Added
  | Unchanged

data StoredProfile
  = StoredProfile
  { storedId :: T.Text
  , storedVersion :: Int
  , storedDigest :: T.Text
  }

data ResolveRequest
  = ResolveRequest
  { resolveRequestEngineer :: T.Text
  , resolveRequestKind :: T.Text
  , resolveRequestClasses :: [T.Text]
  , resolveRequestPathClasses :: [T.Text]
  , resolveRequestNonBehavioural :: Maybe T.Text
  }

-- | The approver of a CLI dry run: the operator trusted by the local OS account (C-P1.3).
operatorApprover :: T.Text
operatorApprover =
  T.pack "operator"

whenReady :: DatabaseRuntime -> IO (Either NotReadyReason a) -> IO (Either NotReadyReason a)
whenReady runtime action = do
  readiness <- checkReadiness (Just runtime)
  case readiness of
    NotReady reason -> pure (Left reason)
    Ready _ -> action

refused :: T.Text -> T.Text -> Either ProfileFailure a
refused code message =
  Left (ProfileRefused code message Nothing)

record :: Store.NewProfileDecision -> O.Orville Int64
record decision = do
  inserted <- Store.insertProfileDecision decision
  maybe (liftIO (throwIO (userError "lockstep: the decision insert returned no row"))) pure inserted

recordRefusal :: Store.NewProfileDecision -> T.Text -> T.Text -> O.Orville (Either ProfileFailure a)
recordRefusal decision code message = do
  n <- record decision {Store.profileDecisionOutcome = T.pack "refused", Store.profileDecisionRefusal = Just code}
  pure (Left (ProfileRefused code message (Just n)))

addDecision :: Store.NewProfileDecision
addDecision =
  Store.NewProfileDecision
    { Store.profileDecisionOperation = T.pack "profile-add"
    , Store.profileDecisionProfile = Nothing
    , Store.profileDecisionVersion = Nothing
    , Store.profileDecisionDigest = Nothing
    , Store.profileDecisionEngineer = Nothing
    , Store.profileDecisionRepository = Nothing
    , Store.profileDecisionOutcome = T.pack "accepted"
    , Store.profileDecisionRefusal = Nothing
    }

-- | A document file, or standard input for @-@.
readProfileDocument :: FilePath -> IO (Either String LBS.ByteString)
readProfileDocument path = do
  result <- try (if path == "-" then LBS.getContents else LBS.readFile path)
  pure (either (\err -> Left (show (err :: IOException))) Right result)

-- | F13: decode, validate, then store the next version or recognise an identical one.
addProfile :: DatabaseRuntime -> LBS.ByteString -> IO (Either NotReadyReason (Either ProfileFailure (StoredProfile, AddOutcome)))
addProfile runtime bytes =
  whenReady runtime . withDatabase runtime . O.withTransaction $ do
    Store.lockProfiles
    case (TE.decodeUtf8' (LBS.toStrict bytes), decodeProfileDocument bytes) of
      (Left _, _) ->
        recordRefusal addDecision (T.pack "profile-document-invalid") (T.pack "the document is not UTF-8")
      (_, Left reason) ->
        recordRefusal addDecision (T.pack "profile-document-invalid") reason
      (Right document, Right raw) ->
        case mkProfileDefinition raw of
          Left refusal ->
            recordRefusal addDecision (profileRefusalCode refusal) (renderProfileRefusal refusal)
          Right definition -> do
            let
              ref = profileRef sha256Hasher definition
              profileId = profileIdText (definitionId definition)
              version = definitionVersion definition
              digest = contentDigestText (refDigest ref)
              decision =
                addDecision
                  { Store.profileDecisionProfile = Just profileId
                  , Store.profileDecisionVersion = Just (fromIntegral version)
                  , Store.profileDecisionDigest = Just digest
                  }
              stored = StoredProfile profileId version digest
            existing <- Store.profileVersions profileId
            case L.find ((== fromIntegral version) . Store.profileRowVersion) existing of
              Just row
                | Store.profileRowDigest row == digest -> do
                    _ <- record decision {Store.profileDecisionOutcome = T.pack "unchanged"}
                    pure (Right (stored, Unchanged))
                | otherwise ->
                    recordRefusal decision (T.pack "profile-version-exists") (T.pack "this version is registered with other content; add the next version")
              Nothing ->
                let
                  next = 1 + L.foldl' max 0 (fmap (fromIntegral . Store.profileRowVersion) existing)
                in
                  if version /= next
                    then recordRefusal decision (T.pack "profile-version-not-next") (T.pack ("the next version of this profile is " <> show next))
                    else do
                      Store.insertProfile (Store.ProfileRow profileId (fromIntegral version) digest document)
                      _ <- record decision
                      pure (Right (stored, Added))

listProfiles :: DatabaseRuntime -> IO (Either NotReadyReason [StoredProfile])
listProfiles runtime =
  whenReady runtime . withDatabase runtime $
    fmap
      (fmap (\row -> StoredProfile (Store.profileRowId row) (fromIntegral (Store.profileRowVersion row)) (Store.profileRowDigest row)))
      Store.allProfiles

-- | Rebuilds a stored definition; a digest that does not reproduce is an integrity failure.
loadStoredDefinition :: Store.ProfileRow -> Either ProfileFailure ProfileDefinition
loadStoredDefinition row =
  let
    failure = Left (ProfileIntegrity (T.pack "stored profile " <> Store.profileRowId row <> T.pack " version " <> T.pack (show (Store.profileRowVersion row)) <> T.pack " fails its integrity check"))
  in
    case decodeProfileDocument (LBS.fromStrict (TE.encodeUtf8 (Store.profileRowDocument row))) of
      Left _ -> failure
      Right raw ->
        case mkProfileDefinition raw of
          Left _ -> failure
          Right definition
            | profileIdText (definitionId definition) /= Store.profileRowId row -> failure
            | fromIntegral (definitionVersion definition) /= Store.profileRowVersion row -> failure
            | contentDigestText (refDigest (profileRef sha256Hasher definition)) /= Store.profileRowDigest row -> failure
            | otherwise -> Right definition

showProfile :: DatabaseRuntime -> T.Text -> Maybe Integer -> IO (Either NotReadyReason (Either ProfileFailure (T.Text, T.Text)))
showProfile runtime profileId version =
  whenReady runtime . withDatabase runtime $
    case version of
      Just v | v < 1 || v > 2147483647 -> pure unknownProfile
      _ -> do
        found <- Store.findProfile profileId (fmap fromInteger version)
        pure $
          case found of
            Nothing -> unknownProfile
            Just row -> do
              definition <- loadStoredDefinition row
              pure (renderProfileDefinition definition, Store.profileRowDigest row)

unknownProfile :: Either ProfileFailure a
unknownProfile =
  refused (T.pack "profile-unknown") (T.pack "there is no such profile version")

-- | Records a new default for the Engineer's repository.
setRepositoryProfile :: DatabaseRuntime -> T.Text -> T.Text -> IO (Either NotReadyReason (Either ProfileFailure T.Text))
setRepositoryProfile runtime engineer profileId =
  whenReady runtime . withDatabase runtime . O.withTransaction $ do
    let
      decision =
        Store.NewProfileDecision
          { Store.profileDecisionOperation = T.pack "repository-set-profile"
          , Store.profileDecisionProfile = Just profileId
          , Store.profileDecisionVersion = Nothing
          , Store.profileDecisionDigest = Nothing
          , Store.profileDecisionEngineer = Just engineer
          , Store.profileDecisionRepository = Nothing
          , Store.profileDecisionOutcome = T.pack "accepted"
          , Store.profileDecisionRefusal = Nothing
          }
    owner <- Store.engineerRepository engineer
    case owner of
      Nothing ->
        recordRefusal decision (T.pack "unknown-engineer") (T.pack "there is no Engineer with this name")
      Just (Store.EngineerRepository _ Nothing) ->
        recordRefusal decision (T.pack "engineer-has-no-repository") (T.pack "the Engineer owns no repository")
      Just (Store.EngineerRepository _ (Just repositoryId)) -> do
        found <- Store.findProfile profileId Nothing
        case found of
          Nothing ->
            recordRefusal decision {Store.profileDecisionRepository = Just repositoryId} (T.pack "profile-unknown") (T.pack "there is no such profile")
          Just _ -> do
            Store.insertRepositoryProfile repositoryId profileId
            _ <- record decision {Store.profileDecisionRepository = Just repositoryId}
            pure (Right repositoryId)

-- | F14: the effective Profile this work would bind, by the human operator; nothing is recorded.
resolveForEngineer :: DatabaseRuntime -> ResolveRequest -> IO (Either NotReadyReason (Either ProfileFailure (T.Text, T.Text)))
resolveForEngineer runtime request =
  whenReady runtime . withDatabase runtime $ do
    owner <- Store.engineerRepository (resolveRequestEngineer request)
    case owner of
      Nothing -> pure (refused (T.pack "unknown-engineer") (T.pack "there is no Engineer with this name"))
      Just (Store.EngineerRepository _ Nothing) -> pure (refused (T.pack "engineer-has-no-repository") (T.pack "the Engineer owns no repository"))
      Just (Store.EngineerRepository _ (Just repositoryId)) -> do
        defaultId <- Store.repositoryDefault repositoryId
        defaultRow <- maybe (pure Nothing) (`Store.findProfile` Nothing) defaultId
        catalogRows <- Store.latestProfiles
        pure $ do
          facts <- workFacts request
          row <- maybe (refused (T.pack "repository-default-profile-unset") (T.pack "the repository has no default profile; see repository set-profile")) Right defaultRow
          d <- loadStoredDefinition row
          catalog <- traverse loadStoredDefinition catalogRows
          eff <- either kernelRefusal Right (resolveProfile sha256Hasher (ResolutionInput d catalog [] facts))
          pure (renderEffectiveProfile eff, contentDigestText (effectiveDigest eff))
 where
  kernelRefusal refusal =
    refused (profileRefusalCode refusal) (renderProfileRefusal refusal)
  invalidFacts what =
    refused (T.pack "invalid-facts") (T.pack ("not a valid " <> what))
  workFacts r = do
    kind <- maybe (invalidFacts "work order kind") Right (parseWorkOrderKind (resolveRequestKind r))
    classes <- maybe (invalidFacts "class tag") Right (traverse mkClassTag (resolveRequestClasses r))
    paths <- maybe (invalidFacts "path class") Right (traverse parsePathClass (resolveRequestPathClasses r))
    behaviour <-
      case resolveRequestNonBehavioural r of
        Nothing -> Right BehaviourChanging
        Just rationale -> maybe (invalidFacts "non-behavioural rationale") (Right . NonBehavioural) (mkNonBehaviouralBasis rationale operatorApprover)
    either kernelRefusal Right (mkWorkFacts Human kind classes paths behaviour)
