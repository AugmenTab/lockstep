{- | The Supervisor's Git boundary (contract C-P4.4 G2–G6; DG-17 D-17.2(a)).
Only the Supervisor touches the canonical repository, and only through Git's
plumbing with a private index: the person's working tree, index and checked
out branch are never changed. Every command runs with options that switch off
repository-configured programs (file-system monitor, hooks, credential
helpers, remote protocols, line-ending conversion), a fixed locale and a time
limit; 'observeBasis' also switches off every content filter the
repository's configuration names (C-P4.R1 R-G1), the one command that reads
the person's working tree.

* 'observeBasis': the repository is clean and @HEAD@ is a commit.
* 'createWorkBranch', 'advanceBranch': the Work Order's branch, created only
  if absent, moved only from the expected commit (compare-and-swap).
* 'writeSnapshot': the exact tree of a commit written into an empty directory,
  without @.git@, never through a link, within aggregate limits.
* 'snapshotChanges': what changed in such a directory, refusing anything but
  regular files, read in chunks and within aggregate limits (C-P4.R1 R-S1,
  R-S2).
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
import Crypto.Hash (Context, SHA1 (SHA1), hashFinalize, hashInit, hashUpdate, hashWith)
import Crypto.Random (getRandomBytes)
import Data.Bits ((.&.))
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set qualified as Set
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
import System.IO (FilePath, IOMode (ReadMode), hClose, withBinaryFile)
import System.Posix.Files
  ( createSymbolicLink
  , fileMode
  , fileSize
  , getSymbolicLinkStatus
  , isDirectory
  , isRegularFile
  , isSymbolicLink
  , readSymbolicLink
  , setFdMode
  )
import System.Posix.IO (OpenFileFlags (creat, exclusive, nofollow), OpenMode (WriteOnly), defaultFileFlags, fdToHandle, openFd)
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
          neutral <- filtersOff repo
          status <- either (pure . Left) (\off -> git [] repo (off <> ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none"])) neutral
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

{- | C-P4.R1 R-G1: options that switch off every content filter driver named
in the repository's configuration (any scope), so @git status@ compares the
raw bytes and runs no configured program. A driver name Git could not take
back in an option is refused (@repository-filter-unsupported@).
-}
filtersOff :: FilePath -> IO (Either T.Text [String])
filtersOff repo = do
  listed <- git [] repo ["config", "--list", "--name-only", "-z"]
  pure $ do
    bytes <- listed
    let
      keys = fmap (TE.decodeUtf8With lenientDecode) (L.filter (not . BS.null) (BS.split 0 bytes))
      drivers =
        L.nub
          [ d
          | k <- keys
          , Just rest <- [T.stripPrefix (T.pack "filter.") k]
          , let
              d = T.dropWhileEnd (/= '.') rest
          , not (T.null d)
          ]
      names = fmap (T.dropEnd 1) drivers
    if L.any (\n -> T.null n || T.any (\c -> c == '=' || Char.isControl c) n) names
      then Left (T.pack "repository-filter-unsupported")
      else Right (L.concat [["-c", "filter." <> T.unpack n <> "." <> o] | n <- names, o <- ["clean=", "smudge=", "process=", "required=false"]])

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
submodules, within the default limits; returns the entries written.
-}
writeSnapshot :: FilePath -> T.Text -> FilePath -> IO (Either T.Text [TreeEntry])
writeSnapshot =
  writeSnapshotWithin defaultSnapshotLimits

{- | 'writeSnapshot' within these limits (C-P4.R1 R-S2): more entries than
'limitFiles' is @snapshot-too-many-files@ before anything is written; an entry
that would take the bytes written past 'limitBytes' is @snapshot-too-large@
and is not written.
-}
writeSnapshotWithin :: SnapshotLimits -> FilePath -> T.Text -> FilePath -> IO (Either T.Text [TreeEntry])
writeSnapshotWithin limits repo commit dest = do
  usable <- emptyDirectory dest
  if not usable
    then pure (Left (T.pack "snapshot-destination-invalid"))
    else do
      listed <- treeEntries repo commit
      case listed of
        Left code -> pure (Left code)
        Right (entries, _)
          | L.length entries > limitFiles limits -> pure (Left (T.pack "snapshot-too-many-files"))
          | otherwise -> fmap (const entries) <$> writeAll 0 entries
 where
  writeAll written entries =
    case entries of
      [] -> pure (Right ())
      entry : rest -> do
        one <- writeEntry repo dest (limitBytes limits - written) entry
        case one of
          Left code -> pure (Left code)
          Right n -> writeAll (written + n) rest

emptyDirectory :: FilePath -> IO Bool
emptyDirectory dir = do
  listed <- try $ do
    status <- getSymbolicLinkStatus dir
    if isDirectory status then L.null <$> listDirectory dir else pure False
  pure (fromRight False (listed :: Either IOException Bool))

{- | One entry: its blob from Git, then the file or link, never through a link
on the way and never onto anything already there (C-P4.R1 R-C1: on a
case-insensitive disk two names that differ only in letter case are one
file, @tree-path-collision@). A file is created exclusively, without following
a link. Its size, or @snapshot-too-large@ when it is over what may still be
written.
-}
writeEntry :: FilePath -> FilePath -> Integer -> TreeEntry -> IO (Either T.Text Integer)
writeEntry repo dest room entry = do
  content <- git [] repo ["cat-file", "blob", T.unpack (entryBlob entry)]
  case content of
    Left code -> pure (Left code)
    Right bytes
      | BS.length bytes > 16777216 -> pure (Left (T.pack "file-too-large"))
      | toInteger (BS.length bytes) > room -> pure (Left (T.pack "snapshot-too-large"))
      | otherwise -> do
          let
            relative = T.unpack (entryPath entry)
            target = dest <> "/" <> relative
            parent = L.reverse (L.dropWhile (/= '/') (L.reverse target))
          safe <- safeParents dest relative
          present <- either (\(_ :: IOException) -> False) (const True) <$> try (getSymbolicLinkStatus target)
          case () of
            _
              | not safe -> pure (Left (T.pack "tree-path-invalid"))
              | present -> pure (Left (T.pack "tree-path-collision"))
              | otherwise -> do
                  written <- try $ do
                    createDirectoryIfMissing True parent
                    case entryMode entry of
                      ModeSymlink -> createSymbolicLink (T.unpack (TE.decodeUtf8With lenientDecode bytes)) target
                      mode -> do
                        let
                          bits = if mode == ModeExecutable then 0o755 else 0o644
                        fd <- openFd target WriteOnly defaultFileFlags {creat = Just bits, exclusive = True, nofollow = True}
                        setFdMode fd bits
                        h <- fdToHandle fd
                        BS.hPut h bytes `finally` hClose h
                  pure $ case written of
                    Right () -> Right (toInteger (BS.length bytes))
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
snapshotChanges =
  snapshotChangesWithin defaultSnapshotLimits

-- | What the walk has seen so far.
data Walked
  = Walked
  { walkedCount :: Int
  , walkedPaths :: Set.Set T.Text
  , walkedChanges :: [Change]
  , walkedBytes :: Integer
  }

{- | 'snapshotChanges' within these limits (C-P4.R1 R-S1, R-S2): a file is
compared with its entry by its blob id, read in chunks; only a changed file's
bytes are kept. @snapshot-too-many-files@ past 'limitFiles' files and links;
@changes-too-many@ past 'limitChangedFiles' changed or removed paths;
@changes-too-large@ past 'limitChangedBytes' bytes of changed files.
-}
snapshotChangesWithin :: SnapshotLimits -> [TreeEntry] -> FilePath -> IO (Either T.Text [Change])
snapshotChangesWithin limits entries dest = do
  walked <- try (walk "" (Walked 0 Set.empty [] 0)) :: IO (Either IOException (Either T.Text Walked))
  pure $ case walked of
    Left e -> Left (T.pack "snapshot-unreadable: " <> T.take 200 (T.pack (show e)))
    Right (Left code) -> Left code
    Right (Right w) -> do
      let
        removed = [Change (entryPath e) Nothing | e <- entries, not (Set.member (entryPath e) (walkedPaths w))]
        changes = walkedChanges w <> removed
      if L.length changes > limitChangedFiles limits
        then Left (T.pack "changes-too-many")
        else Right (L.sortOn changePath changes)
 where
  original =
    Map.fromList [(entryPath e, e) | e <- entries]
  walk relative w = do
    let
      here = if L.null relative then dest else dest <> "/" <> relative
    names <- L.sort <$> listDirectory here
    visitAll relative names w
  visitAll relative names w =
    case names of
      [] -> pure (Right w)
      name : rest -> do
        one <- visit relative name w
        case one of
          Left code -> pure (Left code)
          Right w' -> visitAll relative rest w'
  -- One directory entry, without following a link.
  visit relative name w = do
    let
      rel = if L.null relative then name else relative <> "/" <> name
      path = dest <> "/" <> rel
      relText = T.pack rel
      seen = w {walkedCount = walkedCount w + 1, walkedPaths = Set.insert relText (walkedPaths w)}
    status <- getSymbolicLinkStatus path
    case () of
      _
        | T.toLower (T.pack name) == T.pack ".git" -> pure (Left (T.pack "git-directory"))
        | not (treePathValid relText) -> pure (Left (T.pack "path-invalid"))
        | isDirectory status -> walk rel w
        | walkedCount w >= limitFiles limits -> pure (Left (T.pack "snapshot-too-many-files"))
        | isSymbolicLink status -> do
            target <- readSymbolicLink path
            pure $ case Map.lookup relText original of
              Just e | entryMode e == ModeSymlink && entryBlob e == blobId (TE.encodeUtf8 (T.pack target)) -> Right seen
              _ -> Left (T.pack "special-file")
        | not (isRegularFile status) -> pure (Left (T.pack "special-file"))
        | fileSize status > 16777216 -> pure (Left (T.pack "file-too-large"))
        | otherwise -> do
            let
              mode = if fileMode status .&. 0o100 /= 0 then ModeExecutable else ModeFile
            case Map.lookup relText original of
              Just e | entryMode e == ModeSymlink -> pure (Left (T.pack "special-file"))
              Just e
                | entryMode e == mode -> do
                    same <- (== entryBlob e) <$> fileBlobId path (toInteger (fileSize status))
                    if same then pure (Right seen) else changed seen relText mode path
              _ -> changed seen relText mode path
  changed w relText mode path
    | L.length (walkedChanges w) >= limitChangedFiles limits = pure (Left (T.pack "changes-too-many"))
    | otherwise = do
        bytes <- withBinaryFile path ReadMode (`BS.hGet` 16777217)
        let
          total = walkedBytes w + toInteger (BS.length bytes)
        pure $ case () of
          _
            | BS.length bytes > 16777216 -> Left (T.pack "file-too-large")
            | total > limitChangedBytes limits -> Left (T.pack "changes-too-large")
            | otherwise -> Right w {walkedChanges = Change relText (Just (mode, bytes)) : walkedChanges w, walkedBytes = total}

-- | Git's blob id of a file of this size, read in 64 KiB chunks (a file whose size changed gets another id).
fileBlobId :: FilePath -> Integer -> IO T.Text
fileBlobId path size =
  withBinaryFile path ReadMode $ \h ->
    let
      start = hashUpdate (hashInit :: Context SHA1) (BS8.pack ("blob " <> show size) <> BS.singleton 0)
      loop context = do
        chunk <- BS.hGetSome h 65536
        if BS.null chunk
          then pure (TE.decodeLatin1 (convertToBase Base16 (hashFinalize context)))
          else loop (hashUpdate context chunk)
    in
      loop start

-- | C-P4.R1 R-S2: the aggregate limits of a snapshot and its comparison.
data SnapshotLimits
  = SnapshotLimits
  { limitFiles :: Int
  , limitBytes :: Integer
  , limitChangedFiles :: Int
  , limitChangedBytes :: Integer
  }
  deriving (Eq, Show)

-- | 100 000 files, 2 GiB written, 1 000 changed paths, 64 MiB of changed bytes.
defaultSnapshotLimits :: SnapshotLimits
defaultSnapshotLimits =
  SnapshotLimits {limitFiles = 100000, limitBytes = 2147483648, limitChangedFiles = 1000, limitChangedBytes = 67108864}

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
