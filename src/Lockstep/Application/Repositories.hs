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
  , observedIdentity
  , observeRegistration
  , registerRepository
  , registerObservedIn
  , listRepositories
  , ownershipHolds
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
import Lockstep.Effects.ProjectFolders (gitIdentity)
import Lockstep.Kernel.Identity (EngineerId, RepositoryId (..), identityText)
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
addEngineerIn engineerId name = do
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
      inserted <- Store.insertEngineer engineerId name
      if not inserted
        then refusedWith decision (T.pack "engineer-name-taken") (T.pack "an Engineer with this name exists")
        else do
          _ <- record decision {Store.decisionEngineerId = Just engineerId}
          pure (Right (EngineerRecord engineerId name))

-- | A folder as Git showed it, read-only, before any registration transaction.
data Observed
  = Observed FilePath (Maybe T.Text) RepositoryId (Either RegistrationRefusal RepositoryObservation)

-- | The physical identity of the Git common directory the observation saw, if it succeeded (C-C.R1 R5-2).
observedIdentity :: Observed -> Maybe PhysicalId
observedIdentity (Observed _ _ _ observed) =
  either (const Nothing) (Just . observedPhysical) observed

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
      withDatabase runtime . O.withTransaction $ fmap (fmap snd) (registerObservedIn (registrationEngineer request) observed)

{- | Registration of an observed folder inside the caller's transaction, under
the registration lock, with the same decision row (C-C.R1 R5). The caller
checks readiness. This is the only ownership check, for the command line and a
project's attempt alike (C-C.R1 R6-3); an attempt reaches it holding the
projects lock (projects → repositories). The registered repository's identity
comes back typed beside its record.
-}
registerObservedIn :: T.Text -> Observed -> O.Orville (Either Refused (RepositoryId, RepositoryRecord))
registerObservedIn engineerName (Observed path remote repositoryId observed) = do
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
  case (engineer, observed) of
    (Nothing, _) ->
      refusedWith decision (T.pack "unknown-engineer") (T.pack "there is no Engineer with this name")
    (Just _, Left refusal) ->
      refuse refusal
    (Just engineerId, Right observation) -> do
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
              row = rowFor repositoryId engineerId observation (registrationEngineer request)
            Store.insertRepository row (observationDigest observation)
            _ <- record decision {Store.decisionRepositoryId = Just repositoryId}
            pure (Right (repositoryId, recordFromRow row))

listRepositories :: DatabaseRuntime -> IO (Either NotReadyReason [RepositoryRecord])
listRepositories runtime =
  whenReady runtime (withDatabase runtime (fmap (fmap recordFromRow) Store.activeRepositories))

{- | C-P4.1 X5, read-only, inside the caller's transaction: the Engineer owns
exactly one active repository, it is this one, and the physical identity of
@<folder>/.git@ read now is the registered one. @ownership-invalid@ or
@repository-changed@ otherwise.
-}
ownershipHolds :: RepositoryId -> T.Text -> FilePath -> O.Orville (Either T.Text ())
ownershipHolds repositoryId engineer folder = do
  rows <- Store.activeRepositories
  current <- liftIO (gitIdentity folder)
  let
    owned = [r | r <- rows, Store.rowOwnerName r == engineer]
  pure $
    case owned of
      [row]
        | Store.rowRepositoryId row /= repositoryId -> Left (T.pack "ownership-invalid")
        | fmap physicalKey current /= Just (Store.rowPhysicalId row) -> Left (T.pack "repository-changed")
        | otherwise -> Right ()
      _ -> Left (T.pack "ownership-invalid")

rowFor :: RepositoryId -> EngineerId -> RepositoryObservation -> T.Text -> Store.RepositoryRow
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
  physical <- parsePhysical (Store.rowPhysicalId row)
  authoritative <-
    case (Store.rowRemoteName row, Store.rowRemoteIdentity row) of
      (Just name, Just identity) -> Just . AuthoritativeRemote name <$> identityFromKey identity
      (Nothing, Nothing) -> Just Nothing
      _ -> Nothing
  pure
    OwnedRepository
      { ownedOwnership = Ownership (Store.rowRepositoryId row) (Store.rowOwnerId row)
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
    { repositoryRecordId = identityText (Store.rowRepositoryId row)
    , repositoryRecordOwner = Store.rowOwnerName row
    , repositoryRecordAuthoritative = (,) <$> Store.rowRemoteName row <*> Store.rowRemoteIdentity row
    , repositoryRecordCommonDir = Store.rowCommonDir row
    }
