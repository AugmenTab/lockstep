{- | Engineers and exclusive repository ownership (contract C-P2.1 I8–I10).
Registration observes the repository through 'Lockstep.Effects.Git' first,
then, in one transaction under the registration lock, lets the pure Kernel
decide and stores the repository row and its decision row together. Every
attempt that reaches the database leaves exactly one decision row.
-}
module Lockstep.Application.Repositories
  ( Refused (..)
  , EngineerRecord (..)
  , RepositoryRecord (..)
  , RegisterRequest (..)
  , addEngineer
  , addEngineerIn
  , Observed
  , observeRegistration
  , registerRepository
  , registerObservedIn
  , listRepositories
  ) where

import Control.Exception (throwIO)
import Crypto.Hash (SHA256 (SHA256), hashWith)
import Data.ByteArray qualified as BA
import Data.ByteString qualified as BS
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Maybe (mapMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import System.IO (FilePath)
import System.IO.Error (userError)
import Text.Read (readMaybe)
import Text.Show (show)

import Lockstep.Application.Database
  ( DatabaseRuntime
  , NotReadyReason
  , Readiness (..)
  , checkReadiness
  , withDatabase
  )
import Lockstep.Application.Identity (newEngineerId, newRepositoryId)
import Lockstep.Effects.Git (observeRepository)
import Lockstep.Kernel.Identity (EngineerId (..), RepositoryId (..), parseUuid, uuidText)
import Lockstep.Kernel.Repository
  ( AuthoritativeRemote (..)
  , OwnedRepository (..)
  , Ownership (..)
  , PhysicalId (..)
  , RegistrationRefusal
  , RegistrationRequest (..)
  , RemoteIdentity (..)
  , RepositoryObservation (..)
  , decideRegistration
  , refusalCode
  , remoteIdentityText
  , renderObservation
  , renderRefusal
  )
import Lockstep.Persistence.Repositories qualified as Store

-- | A refusal with its stable code, a message and the decision row that records it.
data Refused
  = Refused
  { refusedCode :: T.Text
  , refusedMessage :: T.Text
  , refusedDecision :: Int64
  }

data EngineerRecord
  = EngineerRecord
  { engineerRecordId :: EngineerId
  , engineerRecordName :: T.Text
  }

data RepositoryRecord
  = RepositoryRecord
  { repositoryRecordId :: T.Text
  , repositoryRecordOwner :: T.Text
  , repositoryRecordAuthoritative :: Maybe (T.Text, T.Text)
  , repositoryRecordCommonDir :: T.Text
  }

data RegisterRequest
  = RegisterRequest
  { registrationEngineer :: T.Text
  , registrationPath :: FilePath
  , registrationRemote :: Maybe T.Text
  }

whenReady :: DatabaseRuntime -> IO (Either NotReadyReason a) -> IO (Either NotReadyReason a)
whenReady runtime action = do
  readiness <- checkReadiness (Just runtime)
  case readiness of
    NotReady reason -> pure (Left reason)
    Ready _ -> action

validEngineerName :: T.Text -> Bool
validEngineerName name =
  case T.uncons name of
    Just (first, rest) ->
      Char.isAsciiLower first
        && T.length name <= 40
        && T.all (\c -> Char.isAsciiLower c || Char.isDigit c || c == '-') rest
    Nothing -> False

-- | Inserts a decision row; an insert that returns no row aborts the transaction.
record :: Store.NewDecision -> O.Orville Int64
record decision = do
  inserted <- Store.insertDecision decision
  maybe (liftIO (throwIO (userError "lockstep: the decision insert returned no row"))) pure inserted

refusedWith :: Store.NewDecision -> T.Text -> T.Text -> O.Orville (Either Refused a)
refusedWith decision code message = do
  n <- record decision {Store.decisionRefusal = Just code}
  pure (Left (Refused code message n))

addEngineer :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Either Refused EngineerRecord))
addEngineer runtime name = do
  engineerId <- newEngineerId
  whenReady runtime . withDatabase runtime . O.withTransaction $ addEngineerIn engineerId name

{- | 'addEngineer' inside the caller's transaction, with the same decision rows
(C-C.R1 R5: a project's Engineer, registration and setup are one transaction).
The caller checks readiness.
-}
addEngineerIn :: EngineerId -> T.Text -> O.Orville (Either Refused EngineerRecord)
addEngineerIn engineerId@(EngineerId uuid) name = do
  let
    decision =
      Store.NewDecision
        { Store.decisionOperation = T.pack "engineer-add"
        , Store.decisionEngineerName = name
        , Store.decisionPath = Nothing
        , Store.decisionRemote = Nothing
        , Store.decisionRefusal = Nothing
        , Store.decisionEngineerId = Nothing
        , Store.decisionRepositoryId = Nothing
        , Store.decisionObservation = Nothing
        }
  if not (validEngineerName name)
    then
      refusedWith
        decision
        (T.pack "engineer-name-invalid")
        (T.pack "an Engineer name is a-z followed by up to 39 of a-z, 0-9 and -")
    else do
      inserted <- Store.insertEngineer (uuidText uuid) name
      if not inserted
        then refusedWith decision (T.pack "engineer-name-taken") (T.pack "an Engineer with this name exists")
        else do
          _ <- record decision {Store.decisionEngineerId = Just (uuidText uuid)}
          pure (Right (EngineerRecord engineerId name))

-- | A folder as Git showed it, read-only, before any registration transaction.
data Observed
  = Observed FilePath (Maybe T.Text) RepositoryId (Either RegistrationRefusal RepositoryObservation)

-- | The read-only C-P2.1 observation of a folder (and the remote chosen, if any).
observeRegistration :: FilePath -> Maybe T.Text -> IO Observed
observeRegistration path remote = do
  observed <- observeRepository path remote
  Observed path remote <$> newRepositoryId <*> pure observed

registerRepository :: DatabaseRuntime -> RegisterRequest -> IO (Either NotReadyReason (Either Refused RepositoryRecord))
registerRepository runtime request = do
  readiness <- checkReadiness (Just runtime)
  case readiness of
    NotReady reason ->
      pure (Left reason)
    Ready _ -> do
      observed <- observeRegistration (registrationPath request) (registrationRemote request)
      withDatabase runtime . O.withTransaction $ registerObservedIn (registrationEngineer request) observed

{- | Registration of an observed folder inside the caller's transaction, under
the registration lock, with the same decision row (C-C.R1 R5). The caller
checks readiness.
-}
registerObservedIn :: T.Text -> Observed -> O.Orville (Either Refused RepositoryRecord)
registerObservedIn engineerName (Observed path remote repositoryId@(RepositoryId repositoryUuid) observed) = do
  let
    request = RegisterRequest engineerName path remote
  Store.lockRepositories
  engineer <- Store.findEngineerByName (registrationEngineer request)
  let
    decision =
      Store.NewDecision
        { Store.decisionOperation = T.pack "repository-register"
        , Store.decisionEngineerName = registrationEngineer request
        , Store.decisionPath = Just (T.pack (registrationPath request))
        , Store.decisionRemote = registrationRemote request
        , Store.decisionRefusal = Nothing
        , Store.decisionEngineerId = engineer
        , Store.decisionRepositoryId = Nothing
        , Store.decisionObservation = either (const Nothing) (Just . renderObservation) observed
        }
    refuse refusal = refusedWith decision (refusalCode refusal) (renderRefusal refusal)
  case (engineer >>= fmap EngineerId . either (const Nothing) Just . parseUuid, observed) of
    (Nothing, _) ->
      refusedWith decision (T.pack "unknown-engineer") (T.pack "there is no Engineer with this name")
    (Just _, Left refusal) ->
      refuse refusal
    (Just engineerId@(EngineerId engineerUuid), Right observation) -> do
      rows <- Store.activeRepositories
      let
        owned = mapMaybe ownedFromRow rows
      if L.length owned /= L.length rows
        then liftIO (throwIO (userError "lockstep: a stored repository row is malformed"))
        else case decideRegistration owned (RegistrationRequest repositoryId engineerId observation) of
          Left refusal ->
            refuse refusal
          Right _ -> do
            let
              row = rowFor (uuidText repositoryUuid) (uuidText engineerUuid) observation (registrationEngineer request)
            Store.insertRepository row (observationDigest observation)
            _ <- record decision {Store.decisionRepositoryId = Just (uuidText repositoryUuid)}
            pure (Right (recordFromRow row))

listRepositories :: DatabaseRuntime -> IO (Either NotReadyReason [RepositoryRecord])
listRepositories runtime =
  whenReady runtime (withDatabase runtime (fmap (fmap recordFromRow) Store.activeRepositories))

rowFor :: T.Text -> T.Text -> RepositoryObservation -> T.Text -> Store.RepositoryRow
rowFor repositoryId ownerId observation ownerName =
  Store.RepositoryRow
    { Store.rowRepositoryId = repositoryId
    , Store.rowOwnerId = ownerId
    , Store.rowOwnerName = ownerName
    , Store.rowCommonDir = observedCommonDir observation
    , Store.rowPhysicalId = physicalKey (observedPhysical observation)
    , Store.rowRemoteName = fmap authoritativeName (observedAuthoritative observation)
    , Store.rowRemoteIdentity = fmap (remoteIdentityText . authoritativeIdentity) (observedAuthoritative observation)
    , Store.rowOtherRemotes = T.intercalate (T.pack ",") (observedOtherRemotes observation)
    }

observationDigest :: RepositoryObservation -> BS.ByteString
observationDigest observation =
  BA.convert (hashWith SHA256 (TE.encodeUtf8 (renderObservation observation)))

physicalKey :: PhysicalId -> T.Text
physicalKey physical =
  T.pack (show (physicalDevice physical) <> ":" <> show (physicalInode physical))

parsePhysical :: T.Text -> Maybe PhysicalId
parsePhysical key =
  case T.splitOn (T.pack ":") key of
    [device, inode] -> PhysicalId <$> readMaybe (T.unpack device) <*> readMaybe (T.unpack inode)
    _ -> Nothing

-- | Rebuilds the Kernel's view of a stored repository; Nothing for a malformed row.
ownedFromRow :: Store.RepositoryRow -> Maybe OwnedRepository
ownedFromRow row = do
  repositoryUuid <- either (const Nothing) Just (parseUuid (Store.rowRepositoryId row))
  ownerUuid <- either (const Nothing) Just (parseUuid (Store.rowOwnerId row))
  physical <- parsePhysical (Store.rowPhysicalId row)
  authoritative <-
    case (Store.rowRemoteName row, Store.rowRemoteIdentity row) of
      (Just name, Just identity) -> Just . AuthoritativeRemote name <$> identityFromKey identity
      (Nothing, Nothing) -> Just Nothing
      _ -> Nothing
  pure
    OwnedRepository
      { ownedOwnership = Ownership (RepositoryId repositoryUuid) (EngineerId ownerUuid)
      , ownedObservation =
          RepositoryObservation
            { observedCommonDir = Store.rowCommonDir row
            , observedPhysical = physical
            , observedAuthoritative = authoritative
            , observedOtherRemotes = L.filter (not . T.null) (T.splitOn (T.pack ",") (Store.rowOtherRemotes row))
            }
      }

-- | The inverse of 'remoteIdentityText' (a local display path is not stored).
identityFromKey :: T.Text -> Maybe RemoteIdentity
identityFromKey key =
  case T.stripPrefix (T.pack "local:") key of
    Just physical -> (`LocalIdentity` T.empty) <$> parsePhysical physical
    Nothing ->
      case T.breakOn (T.pack "/") key of
        (host, path) | not (T.null host) && not (T.null path) -> Just (NetworkIdentity host (T.drop 1 path))
        _ -> Nothing

recordFromRow :: Store.RepositoryRow -> RepositoryRecord
recordFromRow row =
  RepositoryRecord
    { repositoryRecordId = Store.rowRepositoryId row
    , repositoryRecordOwner = Store.rowOwnerName row
    , repositoryRecordAuthoritative = (,) <$> Store.rowRemoteName row <*> Store.rowRemoteIdentity row
    , repositoryRecordCommonDir = Store.rowCommonDir row
    }
