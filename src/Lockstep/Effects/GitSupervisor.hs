{- | The Supervisor's Git boundary (contract C-P4.4 G2–G6; DG-17 D-17.2(a)).
Only the Supervisor touches the canonical repository, and only through Git's
plumbing with a private index: the person's working tree, index and checked
out branch are never changed. Every command runs with options that switch off
repository-configured programs (file-system monitor, hooks, credential
helpers, remote protocols), a fixed locale and a time limit.

* 'observeBasis': the repository is clean and @HEAD@ is a commit.
* 'createWorkBranch', 'advanceBranch': the Work Order's branch, created only
  if absent, moved only from the expected commit (compare-and-swap).
* 'writeSnapshot': the exact tree of a commit written into an empty directory,
  without @.git@.
* 'snapshotChanges': what changed in such a directory, refusing anything but
  regular files.
* 'commitChanges': a commit by the Supervisor's identity on top of a parent,
  deterministic for the same parent, changes, message and time.
-}
module Lockstep.Effects.GitSupervisor
  ( Basis (..)
  , observeBasis
  , createWorkBranch
  , branchHead
  , treeEntries
  , writeSnapshot
  , snapshotChanges
  , SnapshotLimits (..)
  , defaultSnapshotLimits
  , writeSnapshotWithin
  , snapshotChangesWithin
  , CommitMeta (..)
  , commitChanges
  , advanceBranch
  , blobId
  , commitTime
  ) where

import Control.Exception (IOException, finally, try)
import Crypto.Hash (SHA1 (SHA1), hashWith)
import Crypto.Random (getRandomBytes)
import Data.Bits ((.&.))
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Flipstone.Prelude
import System.Directory
  ( createDirectory
  , createDirectoryIfMissing
  , doesDirectoryExist
  , getTemporaryDirectory
  , listDirectory
  , pathIsSymbolicLink
  , removeDirectoryRecursive
  )
import System.Environment (lookupEnv)
import System.IO (FilePath)
import System.Posix.Files
  ( createSymbolicLink
  , fileMode
  , fileSize
  , getSymbolicLinkStatus
  , isDirectory
  , isRegularFile
  , isSymbolicLink
  , readSymbolicLink
  , setFileMode
  )
import Text.Show (Show, show)

import Lockstep.Effects.Process (RunResult (..), newCancel, runDirect)
import Lockstep.Kernel.GitBasis
  ( Change (..)
  , TreeEntry (..)
  , TreeMode (..)
  , checkChanges
  , isCommitId
  , parseTreeMode
  , supervisorEmail
  , supervisorName
  , treeModeText
  , treePathValid
  )
import Lockstep.Kernel.Runner (Limits (..), RunOutcome (..), RunSpec (..), outcomeName)

-- Running Git ------------------------------------------------------------------

{- | Options that make a repository's own configuration inert for these
commands: no file-system monitor, hooks, untracked cache, signing, line-ending
conversion, remote protocol, SSH command or credential helper.
-}
safety :: [String]
safety =
  L.concatMap
    (\o -> ["-c", o])
    [ "core.fsmonitor=false"
    , "core.hooksPath=/dev/null"
    , "core.untrackedCache=false"
    , "commit.gpgSign=false"
    , "core.autocrlf=false"
    , "core.safecrlf=false"
    , "protocol.allow=never"
    , "core.sshCommand=false"
    , "credential.helper="
    ]

{- | Runs @git -C repo@ with the safety options through the finite runner
(C-P4.2 R2): its own process group, no input, no inherited descriptors, 60 s,
at most 32 MiB of output (so no blob over the snapshot limit is ever held),
and only these variables: a fixed search path, the caller's home (for the
operator's own Git configuration), @LC_ALL=C@, no prompts or optional locks,
and the given extras. Stdout as bytes, or a refusal code.
-}
git :: [(T.Text, T.Text)] -> FilePath -> [String] -> IO (Either T.Text BS.ByteString)
git extra repo args = do
  home <- fromMaybe "/tmp" <$> lookupEnv "HOME"
  cancel <- newCancel
  let
    base =
      [ (T.pack "PATH", T.pack "/usr/local/bin:/usr/bin:/bin")
      , (T.pack "HOME", T.pack home)
      , (T.pack "LC_ALL", T.pack "C")
      , (T.pack "GIT_TERMINAL_PROMPT", T.pack "0")
      , (T.pack "GIT_OPTIONAL_LOCKS", T.pack "0")
      ]
    env = extra <> L.filter (\(k, _) -> k `L.notElem` fmap fst extra) base
  result <-
    runDirect
      cancel
      RunSpec
        { runArgv = fmap T.pack ("git" : "-C" : repo : safety <> args)
        , runDirectory = T.pack "/"
        , runEnvironment = env
        , runLimits = Limits {limitWallMillis = 60000, limitStdoutBytes = 33554432, limitStderrBytes = 65536}
        }
  pure $ case result of
    Left code -> Left (T.pack "git-unavailable " <> code)
    Right r ->
      case resultOutcome r of
        Exited 0 -> Right (resultStdout r)
        Exited _ -> Left (T.pack "git-failed: " <> T.take 200 (firstLine (resultStderr r)))
        TimedOut -> Left (T.pack "git-timed-out")
        OutputLimit _ -> Left (T.pack "git-output-limit")
        other -> Left (T.pack "git-" <> outcomeName other)
 where
  firstLine =
    T.strip . TE.decodeUtf8With lenientDecode . BS8.takeWhile (/= '\n')

gitText :: FilePath -> [String] -> IO (Either T.Text T.Text)
gitText repo args =
  fmap (T.strip . TE.decodeUtf8With lenientDecode) <$> git [] repo args

-- Basis -------------------------------------------------------------------------

data Basis
  = Basis
  { basisCommit :: T.Text
  , basisTree :: T.Text
  }
  deriving (Eq, Show)

{- | G2: @repository-missing@, @not-a-repository@, @repository-dirty@ (any
staged, changed or untracked file that is not ignored), @no-commit@ (an unborn
@HEAD@); otherwise the commit and tree of @HEAD@.
-}
observeBasis :: FilePath -> IO (Either T.Text Basis)
observeBasis repo = do
  exists <- doesDirectoryExist repo
  if not exists
    then pure (Left (T.pack "repository-missing"))
    else do
      inside <- gitText repo ["rev-parse", "--is-inside-work-tree"]
      case inside of
        Right t | t == T.pack "true" -> do
          status <- git [] repo ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none"]
          case status of
            Left code -> pure (Left code)
            Right bytes
              | not (BS.null bytes) -> pure (Left (T.pack "repository-dirty"))
              | otherwise -> do
                  commit <- gitText repo ["rev-parse", "--verify", "--quiet", "HEAD^{commit}"]
                  tree <- gitText repo ["rev-parse", "--verify", "--quiet", "HEAD^{tree}"]
                  pure $ case (commit, tree) of
                    (Right c, Right t') | isCommitId c && isCommitId t' -> Right (Basis c t')
                    _ -> Left (T.pack "no-commit")
        _ -> pure (Left (T.pack "not-a-repository"))

-- | The committer time of a commit, in seconds since the epoch (@commit-invalid@ otherwise).
commitTime :: FilePath -> T.Text -> IO (Either T.Text Integer)
commitTime repo commit
  | not (isCommitId commit) = pure (Left (T.pack "commit-invalid"))
  | otherwise = do
      shown <- gitText repo ["show", "-s", "--format=%ct", T.unpack commit]
      pure $ case shown of
        Right t | not (T.null t) && T.all Char.isDigit t && T.length t <= 18 -> Right (T.foldl' (\acc c -> acc * 10 + toInteger (Char.ord c - Char.ord '0')) 0 t)
        Right _ -> Left (T.pack "commit-invalid")
        Left code -> Left code

-- Branches ----------------------------------------------------------------------

zeroId :: String
zeroId =
  L.replicate 40 '0'

-- | The commit a local branch points at, if it exists.
branchHead :: FilePath -> T.Text -> IO (Either T.Text (Maybe T.Text))
branchHead repo branch = do
  valid <- git [] repo ["check-ref-format", "refs/heads/" <> T.unpack branch]
  case valid of
    Left _ -> pure (Left (T.pack "branch-invalid"))
    Right _ -> do
      head' <- gitText repo ["rev-parse", "--verify", "--quiet", "refs/heads/" <> T.unpack branch <> "^{commit}"]
      pure (Right (either (const Nothing) (\c -> if isCommitId c then Just c else Nothing) head'))

checkedOut :: FilePath -> T.Text -> IO Bool
checkedOut repo branch = do
  listing <- gitText repo ["worktree", "list", "--porcelain"]
  pure $ case listing of
    Right text -> T.pack ("branch refs/heads/" <> T.unpack branch) `L.elem` T.lines text
    Left _ -> True

{- | G3: creates the branch at the commit only if it does not exist
(@branch-exists@ if it points elsewhere; the same commit again is accepted).
-}
createWorkBranch :: FilePath -> T.Text -> T.Text -> IO (Either T.Text ())
createWorkBranch repo branch commit
  | not (isCommitId commit) = pure (Left (T.pack "commit-invalid"))
  | otherwise = do
      current <- branchHead repo branch
      case current of
        Left code -> pure (Left code)
        Right (Just c)
          | c == commit -> pure (Right ())
          | otherwise -> pure (Left (T.pack "branch-exists"))
        Right Nothing -> do
          made <- git [] repo ["update-ref", "-m", "lockstep: work branch", "refs/heads/" <> T.unpack branch, T.unpack commit, zeroId]
          case made of
            Right _ -> pure (Right ())
            Left _ -> pure (Left (T.pack "branch-exists"))

{- | G6: moves the branch from @old@ to @new@ only if it is still at @old@
(@branch-moved@ otherwise; already at @new@ is accepted), and never a branch
that a worktree has checked out (@branch-checked-out@).
-}
advanceBranch :: FilePath -> T.Text -> T.Text -> T.Text -> IO (Either T.Text ())
advanceBranch repo branch old new
  | not (isCommitId old && isCommitId new) = pure (Left (T.pack "commit-invalid"))
  | otherwise = do
      busy <- checkedOut repo branch
      if busy
        then pure (Left (T.pack "branch-checked-out"))
        else do
          moved <- git [] repo ["update-ref", "-m", "lockstep: accepted", "refs/heads/" <> T.unpack branch, T.unpack new, T.unpack old]
          case moved of
            Right _ -> pure (Right ())
            Left _ -> do
              current <- branchHead repo branch
              pure $ case current of
                Right (Just c) | c == new -> Right ()
                Right _ -> Left (T.pack "branch-moved")
                Left code -> Left code

-- Snapshots ---------------------------------------------------------------------

{- | The tree of a commit: regular files, executables and symbolic links, and
the paths of submodules (which a snapshot leaves out). @tree-path-invalid@ if
any path fails 'treePathValid'.
-}
treeEntries :: FilePath -> T.Text -> IO (Either T.Text ([TreeEntry], [T.Text]))
treeEntries repo commit
  | not (isCommitId commit) = pure (Left (T.pack "commit-invalid"))
  | otherwise = do
      listing <- git [] repo ["ls-tree", "-r", "-z", "--full-tree", T.unpack commit]
      pure (listing >>= parseListing)
 where
  parseListing bytes =
    fmap collect (traverse parseEntry (L.filter (not . BS.null) (BS.split 0 bytes)))
  collect parsed =
    (lefts parsed, rights parsed)
  parseEntry raw =
    let
      (meta, rest) = BS8.break (== '\t') raw
      path = TE.decodeUtf8With lenientDecode (BS.drop 1 rest)
    in
      if not (treePathValid path)
        then Left (T.pack "tree-path-invalid")
        else case BS8.words meta of
          [mode, kind, object]
            | kind == BS8.pack "commit" -> Right (Right path)
            | kind == BS8.pack "blob"
            , Just m <- parseTreeMode (TE.decodeLatin1 mode) ->
                Right (Left (TreeEntry path m (TE.decodeLatin1 object)))
          _ -> Left (T.pack "tree-entry-unsupported")

{- | G4: writes the commit's tree into an empty directory
(@snapshot-destination-invalid@ otherwise), without @.git@ and without
submodules; returns the entries written.
-}
writeSnapshot :: FilePath -> T.Text -> FilePath -> IO (Either T.Text [TreeEntry])
writeSnapshot repo commit dest = do
  usable <- emptyDirectory dest
  if not usable
    then pure (Left (T.pack "snapshot-destination-invalid"))
    else do
      listed <- treeEntries repo commit
      case listed of
        Left code -> pure (Left code)
        Right (entries, _) -> fmap (const entries) <$> writeAll entries
 where
  writeAll entries =
    case entries of
      [] -> pure (Right ())
      entry : rest -> do
        one <- writeEntry repo dest entry
        case one of
          Left code -> pure (Left code)
          Right () -> writeAll rest

emptyDirectory :: FilePath -> IO Bool
emptyDirectory dir = do
  listed <- try $ do
    status <- getSymbolicLinkStatus dir
    if isDirectory status then L.null <$> listDirectory dir else pure False
  pure (fromRight False (listed :: Either IOException Bool))

-- | One entry: its blob from Git, then the file or link, never through a link on the way.
writeEntry :: FilePath -> FilePath -> TreeEntry -> IO (Either T.Text ())
writeEntry repo dest entry = do
  content <- git [] repo ["cat-file", "blob", T.unpack (entryBlob entry)]
  case content of
    Left code -> pure (Left code)
    Right bytes
      | BS.length bytes > 16777216 -> pure (Left (T.pack "file-too-large"))
      | otherwise -> do
          let
            relative = T.unpack (entryPath entry)
            target = dest <> "/" <> relative
            parent = L.reverse (L.dropWhile (/= '/') (L.reverse target))
          safe <- safeParents dest relative
          if not safe
            then pure (Left (T.pack "tree-path-invalid"))
            else do
              written <- try $ do
                createDirectoryIfMissing True parent
                case entryMode entry of
                  ModeSymlink -> createSymbolicLink (T.unpack (TE.decodeUtf8With lenientDecode bytes)) target
                  mode -> do
                    BS.writeFile target bytes
                    setFileMode target (if mode == ModeExecutable then 0o755 else 0o644)
              pure $ case written of
                Right () -> Right ()
                Left (e :: IOException) -> Left (T.pack "snapshot-failed: " <> T.take 200 (T.pack (show e)))

-- | No existing segment on the way to a path may be a symbolic link.
safeParents :: FilePath -> FilePath -> IO Bool
safeParents dest relative = do
  let
    parts = splitPath relative
    segments = L.take (L.length parts - 1) parts
    prefixes = L.drop 1 (L.scanl (\acc s -> acc <> "/" <> s) dest segments)
  links <- traverse (\p -> fromRight False <$> (try (pathIsSymbolicLink p) :: IO (Either IOException Bool))) prefixes
  pure (not (L.or links))

splitPath :: FilePath -> [FilePath]
splitPath =
  fmap T.unpack . T.splitOn (T.pack "/") . T.pack

-- | Git's blob id of these bytes (SHA-1 of @blob <size>\\0@ and the bytes).
blobId :: BS.ByteString -> T.Text
blobId bytes =
  TE.decodeLatin1 (convertToBase Base16 (hashWith SHA1 (BS8.pack ("blob " <> show (BS.length bytes)) <> BS.singleton 0 <> bytes)))

{- | G5: the changes in a snapshot directory against the entries it was
written from: new, changed (bytes or executable bit) and removed regular
files. Refused: @git-directory@ (a @.git@ anywhere), @special-file@ (a new or
changed symbolic link, or anything but a file, directory or the original
links), @path-invalid@, @file-too-large@ (over 16 MiB).
-}
snapshotChanges :: [TreeEntry] -> FilePath -> IO (Either T.Text [Change])
snapshotChanges entries dest = do
  walked <- try (walk "") :: IO (Either IOException (Either T.Text [(T.Text, Either T.Text (TreeMode, BS.ByteString))]))
  pure $ case walked of
    Left e -> Left (T.pack "snapshot-unreadable: " <> T.take 200 (T.pack (show e)))
    Right (Left code) -> Left code
    Right (Right found) -> do
      let
        foundPaths = fmap fst found
        removed = [Change (entryPath e) Nothing | e <- entries, entryPath e `L.notElem` foundPaths]
      changed <- fmap L.concat (traverse compareFound found)
      Right (L.sortOn changePath (changed <> removed))
 where
  original path =
    L.find ((== path) . entryPath) entries
  compareFound (path, item) =
    case item of
      Left target ->
        case original path of
          Just e | entryMode e == ModeSymlink && entryBlob e == blobId (TE.encodeUtf8 target) -> Right []
          _ -> Left (T.pack "special-file")
      Right (mode, bytes) ->
        case original path of
          Just e | entryMode e == mode && entryBlob e == blobId bytes -> Right []
          Just e | entryMode e == ModeSymlink -> Left (T.pack "special-file")
          _ -> Right [Change path (Just (mode, bytes))]
  walk relative = do
    let
      here = if L.null relative then dest else dest <> "/" <> relative
    names <- L.sort <$> listDirectory here
    fmap L.concat . sequenceA <$> traverse (visit relative) names
  -- One directory entry, without following a link.
  visit relative name = do
    let
      rel = if L.null relative then name else relative <> "/" <> name
      path = dest <> "/" <> rel
      relText = T.pack rel
    status <- getSymbolicLinkStatus path
    case () of
      _
        | T.toLower (T.pack name) == T.pack ".git" -> pure (Left (T.pack "git-directory"))
        | not (treePathValid relText) -> pure (Left (T.pack "path-invalid"))
        | isDirectory status -> walk rel
        | isSymbolicLink status -> do
            target <- readSymbolicLink path
            pure (Right [(relText, Left (T.pack target))])
        | not (isRegularFile status) -> pure (Left (T.pack "special-file"))
        | fileSize status > 16777216 -> pure (Left (T.pack "file-too-large"))
        | otherwise -> do
            bytes <- BS.readFile path
            let
              mode = if fileMode status .&. 0o100 /= 0 then ModeExecutable else ModeFile
            pure (Right [(relText, Right (mode, bytes))])

-- | C-P4.R1 R-S2: the aggregate limits of a snapshot and its comparison.
data SnapshotLimits
  = SnapshotLimits
  { limitFiles :: Int
  , limitBytes :: Integer
  , limitChangedFiles :: Int
  , limitChangedBytes :: Integer
  }
  deriving (Eq, Show)

defaultSnapshotLimits :: SnapshotLimits
defaultSnapshotLimits =
  SnapshotLimits {limitFiles = 100000, limitBytes = 2147483648, limitChangedFiles = 1000, limitChangedBytes = 67108864}

-- | Stage-not-built: the limits are not applied yet.
writeSnapshotWithin :: SnapshotLimits -> FilePath -> T.Text -> FilePath -> IO (Either T.Text [TreeEntry])
writeSnapshotWithin _ =
  writeSnapshot

-- | Stage-not-built: the limits are not applied yet.
snapshotChangesWithin :: SnapshotLimits -> [TreeEntry] -> FilePath -> IO (Either T.Text [Change])
snapshotChangesWithin _ =
  snapshotChanges

-- Commits -----------------------------------------------------------------------

data CommitMeta
  = CommitMeta
  { metaMessage :: T.Text
  , metaEpoch :: Integer
  }
  deriving (Eq, Show)

{- | G5: a commit of the changes on top of the parent, by the Supervisor's
identity at the given time, through a private index (the repository's own
index is not used). Refused by 'checkChanges', @blob-mismatch@ if Git stores
other bytes than given, @parent-invalid@.
-}
commitChanges :: FilePath -> T.Text -> [Change] -> CommitMeta -> IO (Either T.Text T.Text)
commitChanges repo parent changes meta =
  case checkChanges changes of
    Left code -> pure (Left code)
    Right checked
      | not (isCommitId parent) -> pure (Left (T.pack "parent-invalid"))
      | otherwise -> do
          tmpRoot <- getTemporaryDirectory
          suffix <- TE.decodeLatin1 . convertToBase Base16 <$> (getRandomBytes 12 :: IO BS.ByteString)
          let
            scratch = tmpRoot <> "/lockstep-commit-" <> T.unpack suffix
          -- Any failure of the private index's files is a refusal; nothing reaches a branch here.
          made <-
            try (createDirectory scratch >> (commitIn scratch checked `finally` removeQuietly scratch))
          pure $ case made of
            Right result -> result
            Left (e :: IOException) -> Left (T.pack "commit-failed: " <> T.take 200 (T.pack (show e)))
 where
  removeQuietly dir =
    void (try (removeDirectoryRecursive dir) :: IO (Either IOException ()))
  stamp = T.pack (show (metaEpoch meta) <> " +0000")
  identity =
    [ (T.pack "GIT_AUTHOR_NAME", supervisorName)
    , (T.pack "GIT_AUTHOR_EMAIL", supervisorEmail)
    , (T.pack "GIT_AUTHOR_DATE", stamp)
    , (T.pack "GIT_COMMITTER_NAME", supervisorName)
    , (T.pack "GIT_COMMITTER_EMAIL", supervisorEmail)
    , (T.pack "GIT_COMMITTER_DATE", stamp)
    ]
  commitIn scratch checked = do
    let
      index = [(T.pack "GIT_INDEX_FILE", T.pack (scratch <> "/index"))]
      run = git (index <> identity) repo
    readTree <- run ["read-tree", T.unpack parent]
    case readTree of
      Left _ -> pure (Left (T.pack "parent-invalid"))
      Right _ -> do
        staged <- stageAll run scratch checked
        case staged of
          Left code -> pure (Left code)
          Right () -> do
            tree <- fmap (T.strip . TE.decodeLatin1) <$> run ["write-tree"]
            BS.writeFile (scratch <> "/message") (TE.encodeUtf8 (metaMessage meta))
            case tree of
              Left code -> pure (Left code)
              Right t -> do
                commit <- fmap (T.strip . TE.decodeLatin1) <$> run ["commit-tree", T.unpack t, "-p", T.unpack parent, "-F", scratch <> "/message"]
                pure $ case commit of
                  Right c | isCommitId c -> Right c
                  Right _ -> Left (T.pack "commit-failed")
                  Left code -> Left code
  stageAll run scratch checked =
    case checked of
      [] -> pure (Right ())
      change : rest -> do
        one <- stage run scratch change
        case one of
          Left code -> pure (Left code)
          Right () -> stageAll run scratch rest
  stage run scratch change =
    case changeContent change of
      Nothing -> fmap (const ()) <$> run ["update-index", "--force-remove", "--", T.unpack (changePath change)]
      Just (mode, bytes) -> do
        BS.writeFile (scratch <> "/blob") bytes
        stored <- fmap (T.strip . TE.decodeLatin1) <$> run ["hash-object", "-w", "--no-filters", "--", scratch <> "/blob"]
        case stored of
          Left code -> pure (Left code)
          Right sha
            | sha /= blobId bytes -> pure (Left (T.pack "blob-mismatch"))
            | otherwise ->
                fmap (const ())
                  <$> run ["update-index", "--add", "--cacheinfo", T.unpack (treeModeText mode) <> "," <> T.unpack sha <> "," <> T.unpack (changePath change)]
