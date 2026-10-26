{- | Projects and their folders (contract C-P3.5 J1–J4, J7). A project is
created first, under the projects lock; connecting it to a folder is a separate
step that records each attempt as one revision, so a refused folder leaves an
organized project that says why, and Try again needs the current revision.
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
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason, Readiness (..), checkReadiness, withDatabase)
import Lockstep.Application.Identity (newUuid)
import Lockstep.Application.Repositories (Refused (..), RegisterRequest (..), RepositoryRecord (..), addEngineer, registerRepository)
import Lockstep.Effects.ProjectFolders (childFolders, isProjectFolder, makeProjectFolder)
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
              choice -> attempt runtime folders (viewOf row) choice

connectProject :: DatabaseRuntime -> ProjectFolders -> T.Text -> Int64 -> FolderChoice -> IO (Either NotReadyReason (Either T.Text ProjectView))
connectProject runtime folders rawId expected choice =
  whenReady runtime $
    case parseUuid rawId of
      Left _ -> pure (Right (Left (T.pack "unknown-project")))
      Right parsed -> do
        found <- withDatabase runtime (Store.findProjectById (uuidText parsed))
        case fmap (fmap viewOf) found of
          Left reason -> pure (Left reason)
          Right Nothing -> pure (Right (Left (T.pack "unknown-project")))
          Right (Just view)
            | projectSetup view == Connected -> pure (Right (Left (T.pack "already-connected")))
            | projectRevision view /= expected -> pure (Right (Left (T.pack "stale-revision")))
            | choice == DecideLater -> pure (Right (Right view))
            | otherwise -> attempt runtime folders view choice

-- | One connection attempt at the project's current revision.
attempt :: DatabaseRuntime -> ProjectFolders -> ProjectView -> FolderChoice -> IO (Either NotReadyReason (Either T.Text ProjectView))
attempt runtime folders view choice = do
  let
    slug = either (const (T.pack "project")) projectSlug (mkProjectName (projectName view))
    record = recordAttempt runtime view
  folder <- chooseFolder runtime folders slug choice
  case folder of
    Left code -> record SetupFailed (Just code) Nothing (projectEngineer view) Nothing
    Right path -> do
      engineer <- ensureEngineer runtime view slug
      case engineer of
        Left reason -> pure (Left reason)
        Right (Left code) -> record SetupFailed (Just code) Nothing (projectEngineer view) Nothing
        Right (Right name) -> do
          registered <- register runtime name path
          case registered of
            Left reason -> pure (Left reason)
            Right (Left code) -> record SetupFailed (Just code) Nothing (Just name) Nothing
            Right (Right repository) -> record Connected Nothing (Just (T.pack path)) (Just name) (Just (repositoryRecordId repository))

-- | Stores the attempt if the project is still at the revision it was read at; the new state, or stale-revision.
recordAttempt :: DatabaseRuntime -> ProjectView -> SetupState -> Maybe T.Text -> Maybe T.Text -> Maybe T.Text -> Maybe T.Text -> IO (Either NotReadyReason (Either T.Text ProjectView))
recordAttempt runtime view setup refusal folder engineer repository =
  withDatabase runtime . O.withTransaction $ do
    Store.lockProjects
    updated <- Store.updateProjectSetup (projectId view) (projectRevision view) (setupStateCode setup) refusal folder engineer repository
    if updated
      then maybe (Left (T.pack "unknown-project")) (Right . viewOf) <$> Store.findProjectById (projectId view)
      else pure (Left (T.pack "stale-revision"))

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
ensureEngineer :: DatabaseRuntime -> ProjectView -> T.Text -> IO (Either NotReadyReason (Either T.Text T.Text))
ensureEngineer runtime view slug =
  case projectEngineer view of
    Just name -> pure (Right (Right name))
    Nothing -> go (1 :: Int)
 where
  go n
    | n > 99 = pure (Right (Left (T.pack "engineer-name-taken")))
    | otherwise = do
        let
          name = engineerNameFor (slugCandidate slug n)
        added <- addEngineer runtime name
        case added of
          Left reason -> pure (Left reason)
          Right (Right _) -> pure (Right (Right name))
          Right (Left refused)
            | refusedCode refused == T.pack "engineer-name-taken" -> go (n + 1)
            | otherwise -> pure (Right (Left (refusedCode refused)))

-- | C-P2.1 registration; with several remotes and none chosen, @origin@ is tried once.
register :: DatabaseRuntime -> T.Text -> FilePath -> IO (Either NotReadyReason (Either T.Text RepositoryRecord))
register runtime engineer path = do
  first <- registerRepository runtime (RegisterRequest engineer path Nothing)
  case first of
    Right (Left refused)
      | refusedCode refused == T.pack "authoritative-remote-ambiguous" -> do
          second <- registerRepository runtime (RegisterRequest engineer path (Just (T.pack "origin")))
          pure $ case second of
            Right (Left again)
              | refusedCode again == T.pack "authoritative-remote-unknown" -> Right (Left (refusedCode refused))
            other -> fmap (either (Left . refusedCode) Right) other
    other -> pure (fmap (either (Left . refusedCode) Right) other)

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
