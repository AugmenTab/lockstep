{- | The filesystem side of project setup (contract C-P3.5 J3, J7, J8): making
a new project folder inside the projects folder, and finding the folders that
may be offered. Nothing here contacts a network or writes outside the new
folder and the attempt's own working directory beside it (C-C.R1 R5-3).
Nothing here removes a published folder, and nothing is exported that could
(C-C.R1 R6-1): only the attempt's private staging directory is ever removed.
-}
module Lockstep.Effects.ProjectFolders
  ( makeProjectFolder
  , makeProjectFolderWith
  , gitIdentity
  , isProjectFolder
  , childFolders
  ) where

import Control.Exception (IOException, onException, try)
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import System.Directory (createDirectory, doesDirectoryExist, listDirectory, pathIsSymbolicLink, removeDirectory, removeDirectoryRecursive, renameDirectory)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath)
import System.IO.Error (isAlreadyExistsError)
import System.Posix.Files (deviceID, fileID, getSymbolicLinkStatus, isDirectory)
import System.Posix.Temp (mkdtemp)
import System.Process qualified as Process
import System.Timeout (timeout)
import Text.Show (show)

import Lockstep.Effects.Git (gitEnvironment)
import Lockstep.Kernel.Repository (PhysicalId (..))

tryIO :: IO a -> IO (Either IOException a)
tryIO =
  try

-- | A real directory (not a symbolic link), or False if it cannot be read.
realDirectory :: FilePath -> IO Bool
realDirectory path = do
  checked <- tryIO $ do
    link <- pathIsSymbolicLink path
    isDir <- doesDirectoryExist path
    pure (not link && isDir)
  pure (fromRight False checked)

-- | A real directory holding a real @.git@ directory.
isProjectFolder :: FilePath -> IO Bool
isProjectFolder path = do
  top <- realDirectory path
  if top then realDirectory (path <> "/.git") else pure False

{- | The direct children of a folder, as paths, sorted; nothing if it cannot be
read. A folder still being made (C-C.R1 R5-3, 'unpublishedPrefix') is left out.
-}
childFolders :: FilePath -> IO [FilePath]
childFolders dir = do
  names <- tryIO (listDirectory dir)
  pure (either (const []) (fmap (\n -> dir <> "/" <> n) . L.sort . L.filter (not . L.isPrefixOf unpublishedPrefix)) names)

-- | The name prefix of a folder 'makeProjectFolder' is still initializing; never offered.
unpublishedPrefix :: FilePath
unpublishedPrefix =
  ".lockstep-new-"

{- | Makes a new project folder for the first candidate name that is free (C-C.R1
R5-3): @git init -q -b main@ (no commit, no remote) runs first in a directory of
this attempt's own, @<root>/.lockstep-new-XXXXXX@ made by @mkdtemp@, which is
never offered; only after it succeeds is @<root>/<name>@ claimed with @mkdir@
(which never replaces an existing file, folder or link: a taken name moves on to
the next candidate) and the new @.git@ moved into it. On any failure only that
directory, and a destination this attempt has just claimed while it is still
empty, are removed. Once the @.git@ is moved in, the folder is published and
nothing here or in its callers removes it (C-C.R1 R6-1). Returns the folder's
path, or the reason as text.
-}
makeProjectFolder :: FilePath -> [T.Text] -> IO (Either T.Text FilePath)
makeProjectFolder =
  makeProjectFolderWith (const (pure ()))

{- | Test-only (C-C.R1 §3d): 'makeProjectFolder' with a hook run once @git init@
has succeeded, with the directory it ran in. The service never calls it.
-}
makeProjectFolderWith :: (FilePath -> IO ()) -> FilePath -> [T.Text] -> IO (Either T.Text FilePath)
makeProjectFolderWith afterInit root candidates = do
  made <- tryIO (mkdtemp (root <> "/" <> unpublishedPrefix))
  case made of
    Left err -> pure (Left (couldNotMake err))
    Right workspace -> do
      result <-
        ( do
            initialized <- initialize workspace
            case initialized of
              Left reason -> pure (Left reason)
              Right _ -> afterInit workspace >> publish workspace candidates
        )
          `onException` removeStaging workspace
      case result of
        -- Published: the workspace is empty, so it goes with rmdir, which removes nothing inside.
        Right _ -> void (tryIO (removeDirectory workspace))
        -- Not published: the workspace still holds the new .git; it is this attempt's and was never offered.
        Left _ -> removeStaging workspace
      pure result
 where
  publish workspace names =
    case names of
      [] -> pure (Left (T.pack "no free folder name"))
      name : rest -> do
        let
          path = root <> "/" <> T.unpack name
        claimed <- tryIO (createDirectory path)
        case claimed of
          Left err
            | isAlreadyExistsError err -> publish workspace rest
            | otherwise -> pure (Left (couldNotMake err))
          Right () -> do
            moved <- tryIO (renameDirectory (workspace <> "/.git") (path <> "/.git"))
            case moved of
              Right () -> pure (Right path)
              Left err -> do
                -- Only the destination just claimed, and only while it is still empty.
                void (tryIO (removeDirectory path))
                pure (Left (couldNotMake err))
  couldNotMake err =
    T.take 200 (T.pack ("the folder could not be made: " <> show' err))

{- | The physical identity (device, inode) of a folder's Git common directory,
@<path>/.git@, when that is a real directory (C-C.R1 R5-1, R5-2): the identity
C-P2.1 registration records. Nothing when it cannot be read.
-}
gitIdentity :: FilePath -> IO (Maybe PhysicalId)
gitIdentity path = do
  status <- tryIO (getSymbolicLinkStatus (path <> "/.git"))
  pure $
    case status of
      Right s | isDirectory s -> Just (PhysicalId (toInteger (deviceID s)) (toInteger (fileID s)))
      _ -> Nothing

{- | Removes the attempt's private staging directory (@mkdtemp@, never offered,
never published; C-C.R1 R6-1). Only a real directory is removed, never a link;
one that cannot be removed is left as it is. Not exported: nothing else may be
removed this way.
-}
removeStaging :: FilePath -> IO ()
removeStaging path = do
  real <- realDirectory path
  when real (void (tryIO (removeDirectoryRecursive path)))

initialize :: FilePath -> IO (Either T.Text FilePath)
initialize path = do
  env <- gitEnvironment
  result <-
    timeout 10000000 . tryIO $
      Process.readCreateProcessWithExitCode
        ((Process.proc "git" ["-C", path, "init", "-q", "-b", "main"]) {Process.env = Just env})
        ""
  pure $
    case result of
      Just (Right (ExitSuccess, _, _)) -> Right path
      Just (Right (_, out, err)) -> Left (T.take 200 (T.pack ("git init failed: " <> out <> err)))
      Just (Left err) -> Left (T.take 200 (T.pack ("git init failed: " <> show' err)))
      Nothing -> Left (T.pack "git init did not finish within 10 s")

show' :: IOException -> String
show' =
  show
