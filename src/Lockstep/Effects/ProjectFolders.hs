{- | The filesystem side of project setup (contract C-P3.5 J3, J7, J8): making
a new project folder inside the projects folder, and finding the folders that
may be offered. Nothing here contacts a network or writes outside the new
folder.
-}
module Lockstep.Effects.ProjectFolders
  ( makeProjectFolder
  , removeProjectFolder
  , isProjectFolder
  , childFolders
  ) where

import Control.Exception (IOException, try)
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import System.Directory (createDirectory, doesDirectoryExist, doesPathExist, listDirectory, pathIsSymbolicLink, removeDirectoryRecursive)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath)
import System.Process qualified as Process
import System.Timeout (timeout)
import Text.Show (show)

import Lockstep.Effects.Git (gitEnvironment)

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

-- | The direct children of a folder, as paths, sorted; nothing if it cannot be read.
childFolders :: FilePath -> IO [FilePath]
childFolders dir = do
  names <- tryIO (listDirectory dir)
  pure (either (const []) (fmap (\n -> dir <> "/" <> n) . L.sort) names)

{- | Makes @<root>/<name>@ for the first candidate name that is not taken by
any file, folder or link, and runs @git init -q -b main@ in it (no commit, no
remote). Returns the folder's path, or the reason as text.
-}
makeProjectFolder :: FilePath -> [T.Text] -> IO (Either T.Text FilePath)
makeProjectFolder root candidates =
  case candidates of
    [] -> pure (Left (T.pack "no free folder name"))
    name : rest -> do
      let
        path = root <> "/" <> T.unpack name
      present <- doesPathExist path
      -- A dangling symbolic link does not "exist" but still takes the name.
      link <- fromRight False <$> tryIO (pathIsSymbolicLink path)
      if present || link
        then makeProjectFolder root rest
        else do
          made <- tryIO (createDirectory path)
          case made of
            Left err -> pure (Left (T.take 200 (T.pack ("the folder could not be made: " <> show' err))))
            Right () -> do
              initialized <- initialize path
              when (isLeft initialized) (removeProjectFolder path)
              pure initialized

{- | Removes a folder 'makeProjectFolder' made for an attempt that did not end
connected (C-C.R1 R5). Only a real directory is removed, never a link; a
folder that cannot be removed is left as it is.
-}
removeProjectFolder :: FilePath -> IO ()
removeProjectFolder path = do
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
