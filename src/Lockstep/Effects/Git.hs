{- | The Git observation boundary (contract C-P2.1 I3, I4; DG-03 D-3.2a
amended, D-3.7). Runs read-only @git@ commands in this process's filesystem
view and turns the answers into a validated 'RepositoryObservation' or a typed
refusal. Paths are never case-folded: aliases are detected by the physical
identity (device, inode) of the directories, so one directory with two
spellings on a case-insensitive filesystem is one repository, and two
directories on a case-sensitive one are two.
-}
module Lockstep.Effects.Git
  ( observeRepository
  ) where

import Control.Exception (IOException, try)
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import System.Directory (canonicalizePath, doesDirectoryExist, doesPathExist)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath)
import System.Posix.Files (deviceID, fileID, getFileStatus, getSymbolicLinkStatus, isDirectory)
import System.Process qualified as Process
import System.Timeout (timeout)
import Text.Show (show)

import Lockstep.Kernel.Repository
  ( AuthoritativeRemote (..)
  , PhysicalId (..)
  , RegistrationRefusal (..)
  , RemoteConfig (..)
  , RemoteIdentity (..)
  , RemoteLocator (..)
  , RepositoryObservation (..)
  , selectAuthoritative
  , settleAuthoritative
  )

-- | One step of the observation; a refusal stops it.
type Observe a = IO (Either RegistrationRefusal a)

{- | Observes the main worktree at the path. The optional remote name is the
operator's choice of authoritative remote (I4).
-}
observeRepository :: FilePath -> Maybe T.Text -> IO (Either RegistrationRefusal RepositoryObservation)
observeRepository path choice = do
  env <- gitEnvironment
  exists <- doesPathExist path
  isDir <- doesDirectoryExist path
  if not exists
    then pure (Left PathNotFound)
    else
      if not isDir
        then pure (Left NotADirectory)
        else do
          -- A directory that changes while it is observed is a refusal, not a crash.
          observed <- tryIO (observeDirectory env path choice)
          pure $
            case observed of
              Right result -> result
              Left err -> Left (GitFailed (T.take 200 (T.pack ("filesystem: " <> show err))))

tryIO :: IO a -> IO (Either IOException a)
tryIO =
  try

observeDirectory :: [(String, String)] -> FilePath -> Maybe T.Text -> Observe RepositoryObservation
observeDirectory env path choice =
  chain (git env path ["rev-parse", "--is-bare-repository", "--is-inside-git-dir", "--is-shallow-repository"]) $ \flags ->
    case flags of
      [bare, insideGitDir, shallow]
        | bare == "true" -> pure (Left BareRepository)
        | insideGitDir == "true" -> pure (Left NotTopLevel)
        | otherwise -> observeWorktree env path choice (shallow == "true")
      _ -> pure (Left (GitFailed (T.pack "unexpected rev-parse output")))

observeWorktree :: [(String, String)] -> FilePath -> Maybe T.Text -> Bool -> Observe RepositoryObservation
observeWorktree env path choice shallow =
  chain (git env path ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-dir", "--git-common-dir"]) $ \dirs ->
    case dirs of
      [top, gitDir, commonDir] -> do
        pathId <- physicalOf path
        topId <- physicalOf top
        gitDirId <- physicalOf gitDir
        commonId <- physicalOf commonDir
        if pathId /= topId
          then pure (Left NotTopLevel)
          else
            if gitDirId /= commonId
              then pure (Left LinkedWorktree)
              else chain (git env path ["rev-parse", "--show-superproject-working-tree"]) $ \super ->
                if not (L.null (L.filter (not . L.null) super))
                  then pure (Left Submodule)
                  else do
                    ownGitDir <- ownGitDirectory (top <> "/.git") commonId
                    if not ownGitDir
                      then pure (Left UnsupportedGitLayout)
                      else
                        if shallow
                          then pure (Left ShallowRepository)
                          else do
                            canonical <- canonicalizePath commonDir
                            observeRemotes env top choice canonical commonId
      _ -> pure (Left (GitFailed (T.pack "unexpected rev-parse output")))

-- | @<top>/.git@ must be a real directory (not a file or symlink) that is the common directory.
ownGitDirectory :: FilePath -> PhysicalId -> IO Bool
ownGitDirectory dotGit commonId = do
  status <- tryIO (getSymbolicLinkStatus dotGit)
  case status of
    Right s | isDirectory s -> (== commonId) <$> physicalOf dotGit
    _ -> pure False

observeRemotes :: [(String, String)] -> FilePath -> Maybe T.Text -> FilePath -> PhysicalId -> Observe RepositoryObservation
observeRemotes env top choice canonical commonId =
  chain (git env top ["remote"]) $ \names ->
    chain (fmap sequenceA (traverse (remoteConfig env top) (L.filter (not . L.null) names))) $ \configs ->
      case selectAuthoritative choice configs of
        Left refusal ->
          pure (Left refusal)
        Right selection -> do
          settled <-
            case selection of
              Nothing -> pure (Right Nothing)
              Just (name, locators) -> do
                identities <- traverse (resolveLocator env top name) locators
                pure (fmap Just (sequenceA identities >>= settleAuthoritative name))
          pure $ do
            authoritative <- settled
            let
              others = L.sort (L.filter (\n -> Just n /= fmap authoritativeName authoritative) (fmap remoteName configs))
            pure
              RepositoryObservation
                { observedCommonDir = T.pack canonical
                , observedPhysical = commonId
                , observedAuthoritative = authoritative
                , observedOtherRemotes = others
                }

remoteConfig :: [(String, String)] -> FilePath -> String -> Observe RemoteConfig
remoteConfig env top name =
  chain (git env top ["remote", "get-url", "--all", name]) $ \fetch ->
    chain (git env top ["remote", "get-url", "--push", "--all", name]) $ \push ->
      pure
        ( Right
            RemoteConfig
              { remoteName = T.pack name
              , remoteFetchUrls = fmap T.pack (L.filter (not . L.null) fetch)
              , remotePushUrls = fmap T.pack (L.filter (not . L.null) push)
              }
        )

{- | A network locator is already an identity. A local one is resolved relative
to the top level and identified by its Git common directory, which must be
the named directory itself (a bare repository or a .git directory) or a main
worktree's top level: a plain directory inside some other repository does not
count.
-}
resolveLocator :: [(String, String)] -> FilePath -> T.Text -> RemoteLocator -> Observe RemoteIdentity
resolveLocator env top name locator =
  case locator of
    NetworkLocator host path ->
      pure (Right (NetworkIdentity host path))
    LocalLocator raw -> do
      let
        unresolvable = Left (RemoteUnresolvable name)
        target = if T.pack "/" `T.isPrefixOf` raw then T.unpack raw else top <> "/" <> T.unpack raw
      isDir <- doesDirectoryExist target
      if not isDir
        then pure unresolvable
        else do
          answer <- git env target ["rev-parse", "--path-format=absolute", "--git-common-dir", "--show-toplevel"]
          targetId <- physicalOf target
          case answer of
            Right (commonDir : rest) -> do
              commonId <- physicalOf commonDir
              topIds <- traverse physicalOf (L.take 1 (L.filter (not . L.null) rest))
              if targetId == commonId || targetId `L.elem` topIds
                then do
                  canonical <- canonicalizePath commonDir
                  pure (Right (LocalIdentity commonId (T.pack canonical)))
                else pure unresolvable
            _ -> pure unresolvable

physicalOf :: FilePath -> IO PhysicalId
physicalOf path = do
  status <- getFileStatus path
  pure (PhysicalId (toInteger (deviceID status)) (toInteger (fileID status)))

-- | Runs the next step only when the previous one succeeded.
chain :: Observe a -> (a -> Observe b) -> Observe b
chain step next = do
  result <- step
  case result of
    Left refusal -> pure (Left refusal)
    Right value -> next value

{- | Runs @git -C dir args@ with a 10 s limit and returns its stdout lines. A
missing git, a timeout, "not a git repository" and other failures are
distinct refusals.
-}
git :: [(String, String)] -> FilePath -> [String] -> Observe [String]
git env dir args = do
  result <-
    try
      ( timeout 10000000 $
          Process.readCreateProcessWithExitCode
            ((Process.proc "git" ("-C" : dir : args)) {Process.env = Just env})
            ""
      )
  pure $
    case result of
      Left (_ :: IOException) -> Left GitUnavailable
      Right Nothing -> Left GitTimedOut
      Right (Just (ExitSuccess, out, _)) -> Right (L.lines out)
      Right (Just (_, _, err))
        | "not a git repository" `L.isInfixOf` err -> Left NotAGitRepository
        | otherwise -> Left (GitFailed (failureLine err))

failureLine :: String -> T.Text
failureLine err =
  let
    line = T.strip (T.pack (L.takeWhile (/= '\n') err))
  in
    T.take 200 (fromMaybe line (T.stripPrefix (T.pack "fatal: ") line))

{- | The caller's environment without the variables that select a repository,
with a fixed locale and no prompts or optional locks. The operator's Git
configuration (including GIT_CONFIG_* and insteadOf rules) is kept.
-}
gitEnvironment :: IO [(String, String)]
gitEnvironment = do
  base <- getEnvironment
  let
    removed =
      [ "GIT_DIR"
      , "GIT_WORK_TREE"
      , "GIT_COMMON_DIR"
      , "GIT_INDEX_FILE"
      , "GIT_OBJECT_DIRECTORY"
      , "GIT_ALTERNATE_OBJECT_DIRECTORIES"
      , "GIT_NAMESPACE"
      , "LC_ALL"
      , "LANGUAGE"
      , "GIT_TERMINAL_PROMPT"
      , "GIT_OPTIONAL_LOCKS"
      ]
  pure
    ( [("LC_ALL", "C"), ("GIT_TERMINAL_PROMPT", "0"), ("GIT_OPTIONAL_LOCKS", "0")]
        <> L.filter (\(k, _) -> k `L.notElem` removed) base
    )
