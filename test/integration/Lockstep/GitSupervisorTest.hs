{-# LANGUAGE OverloadedStrings #-}

{- | The Supervisor's Git boundary against real Git in disposable repositories
(contract C-P4.4 G2–G6): the basis, the work branch, exact snapshots without
@.git@, what changed in a snapshot, the Supervisor's commit through a private
index, the compare-and-swap branch move, and a repository's own configuration
kept from running anything.
-}
module Lockstep.GitSupervisorTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import System.Directory (createDirectory, createDirectoryIfMissing, doesFileExist, doesPathExist, listDirectory, removeFile)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath, writeFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (createNamedPipe, createSymbolicLink, fileMode, getFileStatus, readSymbolicLink, setFileMode)
import System.Process qualified as Process
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Effects.GitSupervisor
  ( Basis (..)
  , CommitMeta (..)
  , advanceBranch
  , blobId
  , branchHead
  , commitChanges
  , createWorkBranch
  , observeBasis
  , snapshotChanges
  , treeEntries
  , writeSnapshot
  )
import Lockstep.Kernel.GitBasis (Change (..), TreeEntry (..), TreeMode (..))

tests :: TestTree
tests =
  testGroup
    "C-P4.4 the Supervisor's Git boundary (real Git)"
    [ testCase "a clean repository's HEAD is the basis" cleanBasis
    , testCase "a changed, staged or untracked file makes it dirty; an ignored one does not" dirty
    , testCase "a missing folder, a plain folder and an unborn HEAD are refused" notUsable
    , testCase "the work branch is created once; elsewhere is branch-exists; a bad name is refused" workBranch
    , testCase "a snapshot is the commit's exact tree: modes and links, no .git, no submodule, not the working tree" snapshot
    , testCase "a snapshot needs an empty, real directory" snapshotDestination
    , testCase "changes in a snapshot: added, changed, made executable and removed files, in path order" changes
    , testCase "a new or changed link, a .git, a pipe or a link made a file is refused" specialFiles
    , testCase "the Supervisor's commit: its identity, parent and tree; the person's index and files untouched" supervisorCommit
    , testCase "the same parent, changes, message and time give the same commit" deterministic
    , testCase "an invalid change set is refused before anything is written" invalidChanges
    , testCase "the branch moves only from the expected commit, never while checked out" branchMove
    , testCase "a repository's configured file-system monitor never runs" inertConfiguration
    ]

-- Fixtures ------------------------------------------------------------------------

gitEnv :: [(String, String)]
gitEnv =
  [ ("GIT_AUTHOR_NAME", "Person")
  , ("GIT_AUTHOR_EMAIL", "person@example.invalid")
  , ("GIT_COMMITTER_NAME", "Person")
  , ("GIT_COMMITTER_EMAIL", "person@example.invalid")
  , ("HOME", "/tmp")
  , ("PATH", "/usr/local/bin:/usr/bin:/bin")
  , ("LC_ALL", "C")
  ]

-- | Runs git in the directory; its stdout, or the test fails.
gitIn :: FilePath -> [String] -> IO String
gitIn dir args = do
  (code, out, err) <- Process.readCreateProcessWithExitCode ((Process.proc "git" ("-C" : dir : args)) {Process.env = Just gitEnv}) ""
  if code == ExitSuccess then pure out else assertFailure ("git " <> L.unwords args <> ": " <> err)

line1 :: String -> T.Text
line1 =
  T.strip . T.pack . L.takeWhile (/= '\n')

-- | A repository with a file, an executable, a link and a nested file, committed.
withRepo :: (FilePath -> FilePath -> Assertion) -> Assertion
withRepo body =
  withSystemTempDirectory "lockstep-git" $ \tmp -> do
    let
      repo = tmp <> "/repo"
    createDirectory repo
    void (gitIn repo ["init", "-q", "-b", "main"])
    writeFile (repo <> "/a.txt") "alpha\n"
    createDirectoryIfMissing True (repo <> "/bin")
    writeFile (repo <> "/bin/run.sh") "#!/bin/sh\necho run\n"
    setFileMode (repo <> "/bin/run.sh") 0o755
    createSymbolicLink "a.txt" (repo <> "/link")
    createDirectoryIfMissing True (repo <> "/nested/dir")
    writeFile (repo <> "/nested/dir/c.txt") "gamma\n"
    writeFile (repo <> "/.gitignore") "ignored.log\n"
    void (gitIn repo ["add", "-A"])
    void (gitIn repo ["commit", "-q", "-m", "start"])
    body tmp repo

headOf :: FilePath -> IO T.Text
headOf repo =
  line1 <$> gitIn repo ["rev-parse", "HEAD"]

ready :: Show e => IO (Either e a) -> IO a
ready action = do
  result <- action
  either (\e -> assertFailure ("unexpected: " <> show e)) pure result

refusal :: IO (Either T.Text a) -> IO T.Text
refusal action =
  fromLeft "accepted" <$> action

digest :: FilePath -> IO BS.ByteString
digest =
  BS.readFile

meta :: CommitMeta
meta =
  CommitMeta {metaMessage = "Fix: the bug\n\nLockstep-Work-Order: test\n", metaEpoch = 1700000000}

-- Cases -----------------------------------------------------------------------------

cleanBasis :: Assertion
cleanBasis =
  withRepo $ \_ repo -> do
    basis <- ready (observeBasis repo)
    commit <- headOf repo
    tree <- line1 <$> gitIn repo ["rev-parse", "HEAD^{tree}"]
    basis @?= Basis commit tree

dirty :: Assertion
dirty =
  withRepo $ \_ repo -> do
    writeFile (repo <> "/ignored.log") "noise\n"
    ignored <- refusal (observeBasis repo)
    ignored @?= "accepted"
    writeFile (repo <> "/a.txt") "changed\n"
    changed <- refusal (observeBasis repo)
    changed @?= "repository-dirty"
    void (gitIn repo ["add", "a.txt"])
    staged <- refusal (observeBasis repo)
    staged @?= "repository-dirty"
    void (gitIn repo ["commit", "-q", "-m", "more"])
    writeFile (repo <> "/new.txt") "untracked\n"
    untracked <- refusal (observeBasis repo)
    untracked @?= "repository-dirty"

notUsable :: Assertion
notUsable =
  withSystemTempDirectory "lockstep-git-none" $ \tmp -> do
    missing <- refusal (observeBasis (tmp <> "/missing"))
    missing @?= "repository-missing"
    createDirectory (tmp <> "/plain")
    plain <- refusal (observeBasis (tmp <> "/plain"))
    plain @?= "not-a-repository"
    createDirectory (tmp <> "/unborn")
    void (gitIn (tmp <> "/unborn") ["init", "-q"])
    unborn <- refusal (observeBasis (tmp <> "/unborn"))
    unborn @?= "no-commit"

workBranch :: Assertion
workBranch =
  withRepo $ \_ repo -> do
    first <- headOf repo
    ready (createWorkBranch repo "lockstep/wo-1" first)
    ready (createWorkBranch repo "lockstep/wo-1" first)
    branchHead repo "lockstep/wo-1" >>= (@?= Right (Just first))
    writeFile (repo <> "/b.txt") "beta\n"
    void (gitIn repo ["add", "b.txt"])
    void (gitIn repo ["commit", "-q", "-m", "second"])
    second <- headOf repo
    elsewhere <- refusal (createWorkBranch repo "lockstep/wo-1" second)
    elsewhere @?= "branch-exists"
    bad <- refusal (createWorkBranch repo "lockstep/wo..1" first)
    bad @?= "branch-invalid"
    branchHead repo "lockstep/absent" >>= (@?= Right Nothing)
    current <- line1 <$> gitIn repo ["symbolic-ref", "HEAD"]
    current @?= "refs/heads/main"
    status <- gitIn repo ["status", "--porcelain"]
    status @?= ""

snapshot :: Assertion
snapshot =
  withRepo $ \tmp repo -> do
    let
      other = tmp <> "/other"
      dest = tmp <> "/snap"
    createDirectory other
    void (gitIn other ["init", "-q", "-b", "main"])
    writeFile (other <> "/o.txt") "other\n"
    void (gitIn other ["add", "-A"])
    void (gitIn other ["commit", "-q", "-m", "o"])
    void (gitIn repo ["-c", "protocol.file.allow=always", "submodule", "add", "-q", other, "sub"])
    void (gitIn repo ["commit", "-q", "-m", "with a submodule"])
    commit <- headOf repo
    writeFile (repo <> "/a.txt") "uncommitted\n"
    createDirectory dest
    entries <- ready (writeSnapshot repo commit dest)
    fmap entryPath entries @?= [".gitignore", ".gitmodules", "a.txt", "bin/run.sh", "link", "nested/dir/c.txt"]
    fmap entryMode entries @?= [ModeFile, ModeFile, ModeFile, ModeExecutable, ModeSymlink, ModeFile]
    a <- BS.readFile (dest <> "/a.txt")
    a @?= "alpha\n"
    BS.readFile (dest <> "/nested/dir/c.txt") >>= (@?= "gamma\n")
    target <- readSymbolicLink (dest <> "/link")
    target @?= "a.txt"
    runMode <- fileMode <$> getFileStatus (dest <> "/bin/run.sh")
    assertBool "the executable stays executable" (runMode `mod` 0o1000 == 0o755)
    top <- L.sort <$> listDirectory dest
    top @?= [".gitignore", ".gitmodules", "a.txt", "bin", "link", "nested"]
    listed <- ready (treeEntries repo commit)
    snd listed @?= ["sub"]
    fmap entryBlob entries @?= fmap entryBlob (fst listed)
    fmap entryBlob (L.find ((== "a.txt") . entryPath) entries) @?= Just (blobId "alpha\n")

snapshotDestination :: Assertion
snapshotDestination =
  withRepo $ \tmp repo -> do
    commit <- headOf repo
    createDirectory (tmp <> "/full")
    writeFile (tmp <> "/full/x") "x"
    full <- refusal (writeSnapshot repo commit (tmp <> "/full"))
    full @?= "snapshot-destination-invalid"
    createDirectory (tmp <> "/empty")
    createSymbolicLink (tmp <> "/empty") (tmp <> "/linked")
    linked <- refusal (writeSnapshot repo commit (tmp <> "/linked"))
    linked @?= "snapshot-destination-invalid"
    missing <- refusal (writeSnapshot repo commit (tmp <> "/missing"))
    missing @?= "snapshot-destination-invalid"
    stale <- refusal (writeSnapshot repo "0123456789012345678901234567890123456789" (tmp <> "/empty"))
    assertBool ("an unknown commit is refused: " <> T.unpack stale) (stale /= "accepted")

withSnapshot :: (FilePath -> FilePath -> T.Text -> [TreeEntry] -> FilePath -> Assertion) -> Assertion
withSnapshot body =
  withRepo $ \tmp repo -> do
    commit <- headOf repo
    let
      dest = tmp <> "/snap"
    createDirectory dest
    entries <- ready (writeSnapshot repo commit dest)
    body tmp repo commit entries dest

changes :: Assertion
changes =
  withSnapshot $ \_ _ _ entries dest -> do
    unchanged <- ready (snapshotChanges entries dest)
    unchanged @?= []
    writeFile (dest <> "/a.txt") "alpha fixed\n"
    createDirectoryIfMissing True (dest <> "/new")
    writeFile (dest <> "/new/file.txt") "new\n"
    setFileMode (dest <> "/nested/dir/c.txt") 0o755
    removeFile (dest <> "/bin/run.sh")
    createDirectoryIfMissing True (dest <> "/empty/dir")
    found <- ready (snapshotChanges entries dest)
    found
      @?= [ Change "a.txt" (Just (ModeFile, "alpha fixed\n"))
          , Change "bin/run.sh" Nothing
          , Change "nested/dir/c.txt" (Just (ModeExecutable, "gamma\n"))
          , Change "new/file.txt" (Just (ModeFile, "new\n"))
          ]

specialFiles :: Assertion
specialFiles = do
  withSnapshot $ \_ _ _ entries dest -> do
    createSymbolicLink "/etc/passwd" (dest <> "/escape")
    r <- refusal (snapshotChanges entries dest)
    r @?= "special-file"
  withSnapshot $ \_ _ _ entries dest -> do
    removeFile (dest <> "/link")
    createSymbolicLink "nested/dir/c.txt" (dest <> "/link")
    r <- refusal (snapshotChanges entries dest)
    r @?= "special-file"
  withSnapshot $ \_ _ _ entries dest -> do
    removeFile (dest <> "/link")
    writeFile (dest <> "/link") "now a file\n"
    r <- refusal (snapshotChanges entries dest)
    r @?= "special-file"
  withSnapshot $ \_ _ _ entries dest -> do
    createDirectoryIfMissing True (dest <> "/nested/.git")
    writeFile (dest <> "/nested/.git/HEAD") "ref: refs/heads/x\n"
    r <- refusal (snapshotChanges entries dest)
    r @?= "git-directory"
  withSnapshot $ \_ _ _ entries dest -> do
    createDirectoryIfMissing True (dest <> "/.GIT")
    r <- refusal (snapshotChanges entries dest)
    r @?= "git-directory"
  withSnapshot $ \_ _ _ entries dest -> do
    createNamedPipe (dest <> "/pipe") 0o600
    r <- refusal (snapshotChanges entries dest)
    r @?= "special-file"

supervisorCommit :: Assertion
supervisorCommit =
  withSnapshot $ \_ repo basis entries dest -> do
    indexBefore <- digest (repo <> "/.git/index")
    writeFile (dest <> "/a.txt") "alpha fixed\n"
    removeFile (dest <> "/nested/dir/c.txt")
    found <- ready (snapshotChanges entries dest)
    commit <- ready (commitChanges repo basis found meta)
    shown <- gitIn repo ["show", "-s", "--format=%an|%ae|%cn|%ce|%P|%at|%B", T.unpack commit]
    shown @?= "Lockstep Supervisor|supervisor@lockstep.invalid|Lockstep Supervisor|supervisor@lockstep.invalid|" <> T.unpack basis <> "|1700000000|Fix: the bug\n\nLockstep-Work-Order: test\n\n"
    files <- gitIn repo ["ls-tree", "-r", "--name-only", T.unpack commit]
    L.lines files @?= [".gitignore", "a.txt", "bin/run.sh", "link"]
    fixed <- gitIn repo ["show", T.unpack commit <> ":a.txt"]
    fixed @?= "alpha fixed\n"
    indexAfter <- digest (repo <> "/.git/index")
    indexAfter @?= indexBefore
    status <- gitIn repo ["status", "--porcelain"]
    status @?= ""
    head' <- headOf repo
    head' @?= basis
    BS.readFile (repo <> "/a.txt") >>= (@?= "alpha\n")
    branches <- gitIn repo ["branch", "--list"]
    branches @?= "* main\n"

deterministic :: Assertion
deterministic =
  withSnapshot $ \_ repo basis _ _ -> do
    let
      change = [Change "a.txt" (Just (ModeFile, "alpha fixed\n"))]
    c1 <- ready (commitChanges repo basis change meta)
    c2 <- ready (commitChanges repo basis change meta)
    c1 @?= c2
    c3 <- ready (commitChanges repo basis change meta {metaEpoch = 1700000001})
    assertBool "another time is another commit" (c3 /= c1)

invalidChanges :: Assertion
invalidChanges =
  withRepo $ \_ repo -> do
    basis <- headOf repo
    let
      file = Just (ModeFile, "x\n")
      attempt cs = refusal (commitChanges repo basis cs meta)
    before <- gitIn repo ["count-objects"]
    r1 <- attempt [Change "../outside" file]
    r1 @?= "change-path-invalid"
    r2 <- attempt [Change ".git/config" file]
    r2 @?= "change-path-invalid"
    r3 <- attempt [Change "/etc/passwd" file]
    r3 @?= "change-path-invalid"
    r4 <- attempt [Change "a.txt" file, Change "a.txt" Nothing]
    r4 @?= "change-duplicated"
    r5 <- attempt [Change "evil" (Just (ModeSymlink, "/etc/passwd"))]
    r5 @?= "change-symlink"
    r6 <- attempt []
    r6 @?= "change-empty"
    r7 <- refusal (commitChanges repo "not-a-commit" [Change "a.txt" file] meta)
    r7 @?= "parent-invalid"
    after <- gitIn repo ["count-objects"]
    after @?= before

branchMove :: Assertion
branchMove =
  withRepo $ \tmp repo -> do
    basis <- headOf repo
    ready (createWorkBranch repo "lockstep/wo-2" basis)
    c1 <- ready (commitChanges repo basis [Change "a.txt" (Just (ModeFile, "one\n"))] meta)
    c2 <- ready (commitChanges repo basis [Change "a.txt" (Just (ModeFile, "two\n"))] meta)
    ready (advanceBranch repo "lockstep/wo-2" basis c1)
    branchHead repo "lockstep/wo-2" >>= (@?= Right (Just c1))
    again <- refusal (advanceBranch repo "lockstep/wo-2" basis c1)
    again @?= "accepted"
    moved <- refusal (advanceBranch repo "lockstep/wo-2" basis c2)
    moved @?= "branch-moved"
    branchHead repo "lockstep/wo-2" >>= (@?= Right (Just c1))
    void (gitIn repo ["worktree", "add", "-q", tmp <> "/wt", "lockstep/wo-2"])
    busy <- refusal (advanceBranch repo "lockstep/wo-2" c1 c2)
    busy @?= "branch-checked-out"
    branchHead repo "lockstep/wo-2" >>= (@?= Right (Just c1))

inertConfiguration :: Assertion
inertConfiguration =
  withRepo $ \tmp repo -> do
    basis <- headOf repo
    let
      marker = tmp <> "/ran"
      monitor = tmp <> "/monitor.sh"
    writeFile monitor ("#!/bin/sh\ntouch " <> marker <> "\nexit 1\n")
    setFileMode monitor 0o755
    void (gitIn repo ["config", "core.fsmonitor", monitor])
    void (gitIn repo ["config", "core.hooksPath", tmp])
    _ <- observeBasis repo
    createDirectory (tmp <> "/snap")
    entries <- ready (writeSnapshot repo basis (tmp <> "/snap"))
    writeFile (tmp <> "/snap/a.txt") "changed\n"
    found <- ready (snapshotChanges entries (tmp <> "/snap"))
    commit <- ready (commitChanges repo basis found meta)
    ready (createWorkBranch repo "lockstep/wo-3" basis)
    ready (advanceBranch repo "lockstep/wo-3" basis commit)
    ran <- doesFileExist marker
    ran @?= False
    present <- doesPathExist (tmp <> "/snap/.git")
    present @?= False
