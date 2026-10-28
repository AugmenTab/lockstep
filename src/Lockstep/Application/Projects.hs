{- | Projects and their folders (contract C-P3.5 J1–J4, J7). A project is
created first, under the projects lock; connecting it to a folder is a separate
step that records each attempt as one revision, so a refused folder leaves an
organized project that says why, and Try again needs the current revision.
Attempts are serialized per project, and each one's database writes are one
transaction (C-C.R1 R5). A folder an attempt published is never removed, even
when the attempt does not end connected (C-C.R1 R6-1).
-}
module Lockstep.Application.Projects
  ( ProjectFolders (..)
  , parseProjectFolders
  , projectFoldersFromEnvironment
  , NewProject (..)
  , ProjectView (..)
  , createProject
  , connectProject
  , ProjectFaults (..)
  , noProjectFaults
  , connectProjectWith
  , connectProjectAround
  , listProjects
  , findProject
  , offeredFolders
  ) where

import Control.Applicative ((<|>))
import Control.Monad (filterM)
import Data.List qualified as L
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import System.Environment (lookupEnv)
import System.IO (FilePath)
import Text.Show (Show)

import Lockstep.Application.Command (IdempotencyKey, idempotencyKeyText)
import Lockstep.Application.Database (DatabaseRuntime, LockFailure (..), NotReadyReason, Readiness (..), SessionLock (..), checkReadiness, withDatabase, withSessionLock)
import Lockstep.Application.Identity (newEngineerId, newUuid)
import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Application.Repositories (Observed, Refused (..), RepositoryRecord (..), addEngineerIn, observeRegistration, observedIdentity, registerObservedIn)
import Lockstep.Effects.ProjectFolders (childFolders, gitIdentity, isProjectFolder, makeProjectFolder)
import Lockstep.Foundation.FolderProtocol (validFolderPath)
import Lockstep.Kernel.Identity (parseUuid, uuidText)
import Lockstep.Kernel.Profile (Hasher (..), contentDigestText)
import Lockstep.Kernel.Project
  ( FolderChoice (..)
  , SetupState (..)
  , engineerNameFor
  , mkProjectName
  , mkProjectOutcome
  , parseSetupState
  , projectNameText
  , projectOutcomeText
  , projectRequestText
  , projectSlug
  , ruleErrorCode
  , setupStateCode
  , slugCandidate
  )
import Lockstep.Persistence.Projects qualified as Store

-- | The folders the service may see: the projects folder (if any), then the added folders.
data ProjectFolders
  = ProjectFolders
  { foldersRoot :: Maybe FilePath
  , foldersAdded :: [FilePath]
  }
  deriving (Eq, Show)

{- | @LOCKSTEP_PROJECT_FOLDERS@: the projects folder or nothing, then the added
folders, joined with @:@. Anything that is not an absolute path makes the whole
value unusable, so nothing is offered.
-}
parseProjectFolders :: T.Text -> ProjectFolders
parseProjectFolders value =
  case T.splitOn (T.pack ":") value of
    [] -> none
    first : rest ->
      let
        root
          | T.null first = Right Nothing
          | validFolderPath first = Right (Just (T.unpack first))
          | otherwise = Left ()
        added = traverse (\p -> if validFolderPath p then Right (T.unpack p) else Left ()) rest
      in
        case (root, added) of
          (Right r, Right a) -> ProjectFolders r a
          _ -> none
 where
  none = ProjectFolders Nothing []

projectFoldersFromEnvironment :: IO ProjectFolders
projectFoldersFromEnvironment =
  maybe (ProjectFolders Nothing []) (parseProjectFolders . T.pack) <$> lookupEnv "LOCKSTEP_PROJECT_FOLDERS"

data NewProject
  = NewProject
  { newProjectKey :: IdempotencyKey
  , newProjectName :: T.Text
  , newProjectOutcome :: T.Text
  , newProjectFolder :: FolderChoice
  }

data ProjectView
  = ProjectView
  { projectId :: T.Text
  , projectName :: T.Text
  , projectOutcome :: T.Text
  , projectSetup :: SetupState
  , projectRefusal :: Maybe T.Text
  , projectFolder :: Maybe T.Text
  , projectEngineer :: Maybe T.Text
  , projectRevision :: Int64
  }
  deriving (Eq, Show)

viewOf :: Store.ProjectRow -> ProjectView
viewOf row =
  ProjectView
    { projectId = Store.rowId row
    , projectName = Store.rowName row
    , projectOutcome = Store.rowOutcome row
    , projectSetup = fromMaybe Organized (parseSetupState (Store.rowSetup row))
    , projectRefusal = Store.rowRefusal row
    , projectFolder = Store.rowFolder row
    , projectEngineer = Store.rowEngineerName row
    , projectRevision = Store.rowRevision row
    }

whenReady :: DatabaseRuntime -> IO (Either NotReadyReason a) -> IO (Either NotReadyReason a)
whenReady runtime action = do
  readiness <- checkReadiness (Just runtime)
  case readiness of
    NotReady reason -> pure (Left reason)
    Ready _ -> action

createProject :: DatabaseRuntime -> ProjectFolders -> NewProject -> IO (Either NotReadyReason (Either T.Text ProjectView))
createProject runtime folders request =
  whenReady runtime $
    case (mkProjectName (newProjectName request), mkProjectOutcome (newProjectOutcome request)) of
      (Left e, _) -> pure (Right (Left (ruleErrorCode e)))
      (_, Left e) -> pure (Right (Left (ruleErrorCode e)))
      (Right name, Right outcome) -> do
        projectUuid <- newUuid
        let
          choice = newProjectFolder request
          digest = sha256Text (projectRequestText name outcome choice)
          -- C-C.R1 R9: a row made before migration 17 replays only when the request is shown equal.
          sameAsStored row =
            Store.rowName row == projectNameText name
              && Store.rowOutcome row == projectOutcomeText outcome
              && case choice of
                DecideLater -> isNothing (Store.rowFolder row)
                ExistingFolder path -> Store.rowFolder row == Just path
                NewFolder -> False
        created <- withDatabase runtime . O.withTransaction $ do
          Store.lockProjects
          existing <- Store.findProjectByKey (idempotencyKeyText (newProjectKey request))
          case existing of
            Just row
              | maybe (sameAsStored row) (== digest) (Store.rowCreationDigest row) -> pure (Right (row, False))
              | otherwise -> pure (Left (T.pack "key-conflict"))
            Nothing -> do
              taken <- Store.projectNameTaken (projectNameText name)
              if taken
                then pure (Left (T.pack "project-name-taken"))
                else do
                  let
                    newId = uuidText projectUuid
                  Store.insertProject newId (idempotencyKeyText (newProjectKey request)) (projectNameText name) (projectOutcomeText outcome) digest
                  row <- Store.findProjectById newId
                  pure (maybe (Left (T.pack "unknown-project")) (\r -> Right (r, True)) row)
        case created of
          Left reason -> pure (Left reason)
          Right (Left code) -> pure (Right (Left code))
          Right (Right (row, False)) -> pure (Right (Right (viewOf row)))
          Right (Right (row, True)) ->
            case choice of
              DecideLater -> pure (Right (Right (viewOf row)))
              _ -> connectLocked noHooks runtime folders (Store.rowId row) (Store.rowRevision row) choice

-- | The SHA-256 of a canonical request text, as 64 lowercase hex.
sha256Text :: T.Text -> T.Text
sha256Text text =
  case sha256Hasher of
    Hasher f -> contentDigestText (f text)

connectProject :: DatabaseRuntime -> ProjectFolders -> T.Text -> Int64 -> FolderChoice -> IO (Either NotReadyReason (Either T.Text ProjectView))
connectProject =
  connectProjectWith noProjectFaults

{- | Test-only fault hooks (C-C.R1 §3b, as C-P2.5's ledger 'Faults'): run once
after a connection attempt's transaction, with what it returned. A hook can
throw or replace the result, to stand for an interruption after the commit or
a COMMIT whose answer was lost. The service always uses 'noProjectFaults'.
-}
newtype ProjectFaults
  = ProjectFaults
  { faultAfterCommit :: Either NotReadyReason (Either T.Text ProjectView) -> IO (Either NotReadyReason (Either T.Text ProjectView))
  }

noProjectFaults :: ProjectFaults
noProjectFaults =
  ProjectFaults pure

connectProjectWith :: ProjectFaults -> DatabaseRuntime -> ProjectFolders -> T.Text -> Int64 -> FolderChoice -> IO (Either NotReadyReason (Either T.Text ProjectView))
connectProjectWith =
  connectProjectAround (const (pure ()))

{- | Test-only (C-C.R1 §3c): also runs a hook once the attempt has its folder
and has observed it, right before its transaction, to let another request act
in that window. The service never calls it.
-}
connectProjectAround :: (FilePath -> IO ()) -> ProjectFaults -> DatabaseRuntime -> ProjectFolders -> T.Text -> Int64 -> FolderChoice -> IO (Either NotReadyReason (Either T.Text ProjectView))
connectProjectAround afterFolder faults runtime folders rawId expected choice =
  whenReady runtime $
    case parseUuid rawId of
      Left _ -> pure (Right (Left (T.pack "unknown-project")))
      Right parsed -> connectLocked (Hooks afterFolder faults) runtime folders (uuidText parsed) expected choice

-- | The test-only hooks of one connection attempt; the service uses 'noHooks'.
data Hooks
  = Hooks (FilePath -> IO ()) ProjectFaults

noHooks :: Hooks
noHooks =
  Hooks (const (pure ())) noProjectFaults

{- | C-C.R1 R5: one connection attempt at a time per project, under the session
lock for the project; the project is read again under it, so a stale or
already-connected request is answered before any side effect.
-}
connectLocked :: Hooks -> DatabaseRuntime -> ProjectFolders -> T.Text -> Int64 -> FolderChoice -> IO (Either NotReadyReason (Either T.Text ProjectView))
connectLocked hooks runtime folders pid expected choice = do
  locked <-
    withSessionLock runtime ProjectConnectLock pid $ \_ -> do
      found <- withDatabase runtime (Store.findProjectById pid)
      case fmap (fmap viewOf) found of
        Left reason -> pure (Left reason)
        Right Nothing -> pure (Right (Left (T.pack "unknown-project")))
        Right (Just view)
          | projectSetup view == Connected -> pure (Right (Left (T.pack "already-connected")))
          | projectRevision view /= expected -> pure (Right (Left (T.pack "stale-revision")))
          | choice == DecideLater -> pure (Right (Right view))
          | otherwise -> attempt hooks runtime folders view choice
  pure $
    case locked of
      Right result -> result
      Left LockBusy -> Right (Left (T.pack "project-busy"))
      Left (LockUnavailable reason) -> Left reason

{- | One connection attempt at the project's current revision: the folder and
the read-only Git observations first, then one transaction that adds the
Engineer, registers the repository and records the attempt, so a failure
leaves none of them. A folder this attempt made stays whatever the outcome
(C-C.R1 R6-1): once published it may already be someone else's, and a kept
folder no project is connected to is offered again, so Try again can connect it.
-}
attempt :: Hooks -> DatabaseRuntime -> ProjectFolders -> ProjectView -> FolderChoice -> IO (Either NotReadyReason (Either T.Text ProjectView))
attempt (Hooks afterFolder faults) runtime folders view choice = do
  let
    slug = either (const (T.pack "project")) projectSlug (mkProjectName (projectName view))
  folder <- chooseFolder runtime folders slug choice
  case folder of
    Left code -> settle (recordIn view SetupFailed (Just code) Nothing (projectEngineer view) Nothing)
    Right path -> do
      first <- observeRegistration path Nothing
      fallback <- observeRegistration path (Just (T.pack "origin"))
      afterFolder path
      settle (connectIn view slug path first fallback)
 where
  settle action = do
    committed <-
      withDatabase runtime . O.withTransaction $ do
        Store.lockProjects
        current <- Store.findProjectById (projectId view)
        case current of
          Nothing -> pure (Left (T.pack "unknown-project"))
          Just row
            | Store.rowRevision row /= projectRevision view -> pure (Left (T.pack "stale-revision"))
            | otherwise -> action
    faultAfterCommit faults committed

-- | The Engineer, the registration and the recorded attempt, inside the attempt's transaction.
connectIn :: ProjectView -> T.Text -> FilePath -> Observed -> Observed -> O.Orville (Either T.Text ProjectView)
connectIn view slug path first fallback = do
  -- C-C.R1 R13b, R5-2, R6-2: under the projects lock, the folder must still be there and be
  -- the one the registrable observation saw (the first one if it succeeded, else the
  -- @origin@ fallback; the same physical Git directory, not merely the same path):
  -- another attempt may have removed it, or something else replaced it, meanwhile.
  present <- liftIO (isProjectFolder path)
  current <- liftIO (gitIdentity path)
  let
    registrable = observedIdentity first <|> observedIdentity fallback
    replaced = isNothing current || (isJust registrable && current /= registrable)
  if not present || replaced
    then recordIn view SetupFailed (Just (T.pack "folder-not-offered")) Nothing (projectEngineer view) Nothing
    else do
      engineer <- ensureEngineerIn view slug
      case engineer of
        Left code -> recordIn view SetupFailed (Just code) Nothing (projectEngineer view) Nothing
        Right name -> do
          registered <- registerIn name path first fallback
          case registered of
            Left code -> recordIn view SetupFailed (Just code) Nothing (Just name) Nothing
            Right repository -> recordIn view Connected Nothing (Just (T.pack path)) (Just name) (Just (repositoryRecordId repository))

-- | Records the attempt at the revision it was read at; the new state.
recordIn :: ProjectView -> SetupState -> Maybe T.Text -> Maybe T.Text -> Maybe T.Text -> Maybe T.Text -> O.Orville (Either T.Text ProjectView)
recordIn view setup refusal folder engineer repository = do
  updated <- Store.updateProjectSetup (projectId view) (projectRevision view) (setupStateCode setup) refusal folder engineer repository
  if updated
    then maybe (Left (T.pack "unknown-project")) (Right . viewOf) <$> Store.findProjectById (projectId view)
    else pure (Left (T.pack "stale-revision"))

-- | The folder to connect: an offered one, or a new one this attempt made.
chooseFolder :: DatabaseRuntime -> ProjectFolders -> T.Text -> FolderChoice -> IO (Either T.Text FilePath)
chooseFolder runtime folders slug choice =
  case choice of
    DecideLater -> pure (Left (T.pack "folder-not-offered"))
    ExistingFolder path -> do
      offered <- offeredFolders runtime folders
      pure (if T.unpack path `L.elem` offered then Right (T.unpack path) else Left (T.pack "folder-not-offered"))
    NewFolder ->
      case foldersRoot folders of
        Nothing -> pure (Left (T.pack "no-projects-folder"))
        Just root -> do
          made <- makeProjectFolder root (fmap (slugCandidate slug) [1 .. 99])
          pure (either (const (Left (T.pack "folder-create-failed"))) Right made)

-- | The project's Engineer: the one it already has, else the first free @p-<slug>@, @p-<slug>-2@ ….
ensureEngineerIn :: ProjectView -> T.Text -> O.Orville (Either T.Text T.Text)
ensureEngineerIn view slug =
  case projectEngineer view of
    Just name -> pure (Right name)
    Nothing -> go (1 :: Int)
 where
  go n
    | n > 99 = pure (Left (T.pack "engineer-name-taken"))
    | otherwise = do
        let
          name = engineerNameFor (slugCandidate slug n)
        engineerId <- liftIO newEngineerId
        added <- addEngineerIn engineerId name
        case added of
          Right _ -> pure (Right name)
          Left refused
            | refusedCode refused == T.pack "engineer-name-taken" -> go (n + 1)
            | otherwise -> pure (Left (refusedCode refused))

{- | C-P2.1 registration; with several remotes and none chosen, @origin@ is tried
once. C-C.R1 R6-2: right before an observation that succeeded is registered,
the first one or the fallback, the folder's current identity must still be the
one that observation saw; otherwise @folder-not-offered@ and nothing is
registered. A refused observation registers nothing; its refusal is recorded
as before.
-}
registerIn :: T.Text -> FilePath -> Observed -> Observed -> O.Orville (Either T.Text RepositoryRecord)
registerIn engineer path first fallback = do
  registered <- registerSame first
  case registered of
    Left (Right refused)
      | refusedCode refused == T.pack "authoritative-remote-ambiguous" -> do
          second <- registerSame fallback
          pure $ case second of
            Left (Right again)
              | refusedCode again == T.pack "authoritative-remote-unknown" -> Left (refusedCode refused)
            other -> codeOf other
    other -> pure (codeOf other)
 where
  codeOf =
    either (Left . either id refusedCode) Right
  registerSame observed =
    case observedIdentity observed of
      Nothing -> either (Left . Right) Right <$> registerObservedIn engineer observed
      Just seen -> do
        current <- liftIO (gitIdentity path)
        if current == Just seen
          then either (Left . Right) Right <$> registerObservedIn engineer observed
          else pure (Left (Left (T.pack "folder-not-offered")))

listProjects :: DatabaseRuntime -> IO (Either NotReadyReason [ProjectView])
listProjects runtime =
  whenReady runtime (withDatabase runtime (fmap (fmap viewOf) Store.allProjects))

findProject :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Maybe ProjectView))
findProject runtime rawId =
  case parseUuid rawId of
    Left _ -> pure (Right Nothing)
    Right parsed -> whenReady runtime (withDatabase runtime (fmap (fmap viewOf) (Store.findProjectById (uuidText parsed))))

{- | Each direct child of the projects folder and each added folder that is a
real directory with a real @.git@ directory, and that no project has connected.
-}
offeredFolders :: DatabaseRuntime -> ProjectFolders -> IO [FilePath]
offeredFolders runtime folders = do
  children <- maybe (pure []) childFolders (foldersRoot folders)
  candidates <- filterM isProjectFolder (children <> foldersAdded folders)
  connected <- withDatabase runtime Store.connectedFolders
  let
    taken = either (const []) (fmap T.unpack) connected
  pure (L.sort (L.nub (L.filter (`L.notElem` taken) candidates)))
