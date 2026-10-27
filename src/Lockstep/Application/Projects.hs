{- | Projects and their folders (contract C-P3.5 J1–J4, J7). A project is
created first, under the projects lock; connecting it to a folder is a separate
step that records each attempt as one revision, so a refused folder leaves an
organized project that says why, and Try again needs the current revision.
Attempts are serialized per project, and each one's database writes are one
transaction (C-C.R1 R5).
-}
module Lockstep.Application.Projects
  ( ProjectFolders (..)
  , parseProjectFolders
  , projectFoldersFromEnvironment
  , NewProject (..)
  , ProjectView (..)
  , createProject
  , connectProject
  , listProjects
  , findProject
  , offeredFolders
  ) where

import Control.Exception (onException)
import Control.Monad (filterM)
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import System.Environment (lookupEnv)
import System.IO (FilePath)
import Text.Show (Show)

import Lockstep.Application.Command (IdempotencyKey, idempotencyKeyText)
import Lockstep.Application.Database (DatabaseRuntime, LockFailure (..), NotReadyReason, Readiness (..), SessionLock (..), checkReadiness, withDatabase, withSessionLock)
import Lockstep.Application.Identity (newEngineerId, newUuid)
import Lockstep.Application.Repositories (Observed, Refused (..), RepositoryRecord (..), addEngineerIn, observeRegistration, registerObservedIn)
import Lockstep.Effects.ProjectFolders (childFolders, isProjectFolder, makeProjectFolder, removeProjectFolder)
import Lockstep.Foundation.FolderProtocol (validFolderPath)
import Lockstep.Kernel.Identity (parseUuid, uuidText)
import Lockstep.Kernel.Project
  ( FolderChoice (..)
  , SetupState (..)
  , engineerNameFor
  , mkProjectName
  , mkProjectOutcome
  , parseSetupState
  , projectNameText
  , projectOutcomeText
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
        created <- withDatabase runtime . O.withTransaction $ do
          Store.lockProjects
          existing <- Store.findProjectByKey (idempotencyKeyText (newProjectKey request))
          case existing of
            Just row -> pure (Right (row, False))
            Nothing -> do
              taken <- Store.projectNameTaken (projectNameText name)
              if taken
                then pure (Left (T.pack "project-name-taken"))
                else do
                  let
                    newId = uuidText projectUuid
                  Store.insertProject newId (idempotencyKeyText (newProjectKey request)) (projectNameText name) (projectOutcomeText outcome)
                  row <- Store.findProjectById newId
                  pure (maybe (Left (T.pack "unknown-project")) (\r -> Right (r, True)) row)
        case created of
          Left reason -> pure (Left reason)
          Right (Left code) -> pure (Right (Left code))
          Right (Right (row, False)) -> pure (Right (Right (viewOf row)))
          Right (Right (row, True)) ->
            case newProjectFolder request of
              DecideLater -> pure (Right (Right (viewOf row)))
              choice -> connectLocked runtime folders (Store.rowId row) (Store.rowRevision row) choice

connectProject :: DatabaseRuntime -> ProjectFolders -> T.Text -> Int64 -> FolderChoice -> IO (Either NotReadyReason (Either T.Text ProjectView))
connectProject runtime folders rawId expected choice =
  whenReady runtime $
    case parseUuid rawId of
      Left _ -> pure (Right (Left (T.pack "unknown-project")))
      Right parsed -> connectLocked runtime folders (uuidText parsed) expected choice

{- | C-C.R1 R5: one connection attempt at a time per project, under the session
lock for the project; the project is read again under it, so a stale or
already-connected request is answered before any side effect.
-}
connectLocked :: DatabaseRuntime -> ProjectFolders -> T.Text -> Int64 -> FolderChoice -> IO (Either NotReadyReason (Either T.Text ProjectView))
connectLocked runtime folders pid expected choice = do
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
          | otherwise -> attempt runtime folders view choice
  pure $
    case locked of
      Right result -> result
      Left LockBusy -> Right (Left (T.pack "project-busy"))
      Left (LockUnavailable reason) -> Left reason

{- | One connection attempt at the project's current revision: the folder and
the read-only Git observations first, then one transaction that adds the
Engineer, registers the repository and records the attempt, so a failure
leaves none of them. A folder this attempt made is removed unless the project
ends connected.
-}
attempt :: DatabaseRuntime -> ProjectFolders -> ProjectView -> FolderChoice -> IO (Either NotReadyReason (Either T.Text ProjectView))
attempt runtime folders view choice = do
  let
    slug = either (const (T.pack "project")) projectSlug (mkProjectName (projectName view))
  folder <- chooseFolder runtime folders slug choice
  case folder of
    Left code -> settle Nothing (recordIn view SetupFailed (Just code) Nothing (projectEngineer view) Nothing)
    Right (path, made) ->
      -- A folder this attempt made goes again if anything throws before the attempt settles.
      ( do
          first <- observeRegistration path Nothing
          fallback <- observeRegistration path (Just (T.pack "origin"))
          settle (if made then Just path else Nothing) (connectIn view slug path first fallback)
      )
        `onException` when made (removeProjectFolder path)
 where
  settle made action = do
    result <-
      withDatabase runtime . O.withTransaction $ do
        Store.lockProjects
        current <- Store.findProjectById (projectId view)
        case current of
          Nothing -> pure (Left (T.pack "unknown-project"))
          Just row
            | Store.rowRevision row /= projectRevision view -> pure (Left (T.pack "stale-revision"))
            | otherwise -> action
    case made of
      Just path | not (endsConnected result) -> removeProjectFolder path
      _ -> pure ()
    pure result
  endsConnected result =
    case result of
      Right (Right v) -> projectSetup v == Connected
      _ -> False

-- | The Engineer, the registration and the recorded attempt, inside the attempt's transaction.
connectIn :: ProjectView -> T.Text -> FilePath -> Observed -> Observed -> O.Orville (Either T.Text ProjectView)
connectIn view slug path first fallback = do
  engineer <- ensureEngineerIn view slug
  case engineer of
    Left code -> recordIn view SetupFailed (Just code) Nothing (projectEngineer view) Nothing
    Right name -> do
      registered <- registerIn name first fallback
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

-- | The folder to connect, and whether this attempt made it.
chooseFolder :: DatabaseRuntime -> ProjectFolders -> T.Text -> FolderChoice -> IO (Either T.Text (FilePath, Bool))
chooseFolder runtime folders slug choice =
  case choice of
    DecideLater -> pure (Left (T.pack "folder-not-offered"))
    ExistingFolder path -> do
      offered <- offeredFolders runtime folders
      pure (if T.unpack path `L.elem` offered then Right (T.unpack path, False) else Left (T.pack "folder-not-offered"))
    NewFolder ->
      case foldersRoot folders of
        Nothing -> pure (Left (T.pack "no-projects-folder"))
        Just root -> do
          made <- makeProjectFolder root (fmap (slugCandidate slug) [1 .. 99])
          pure (either (const (Left (T.pack "folder-create-failed"))) (\p -> Right (p, True)) made)

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

-- | C-P2.1 registration; with several remotes and none chosen, @origin@ is tried once.
registerIn :: T.Text -> Observed -> Observed -> O.Orville (Either T.Text RepositoryRecord)
registerIn engineer first fallback = do
  registered <- registerObservedIn engineer first
  case registered of
    Left refused
      | refusedCode refused == T.pack "authoritative-remote-ambiguous" -> do
          second <- registerObservedIn engineer fallback
          pure $ case second of
            Left again
              | refusedCode again == T.pack "authoritative-remote-unknown" -> Left (refusedCode refused)
            other -> either (Left . refusedCode) Right other
    other -> pure (either (Left . refusedCode) Right other)

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
