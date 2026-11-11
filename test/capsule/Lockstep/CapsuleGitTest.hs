{- | P5.8: the Supervisor's Git against content a Dev Capsule returns (contract
C-P5.8 G1-G6; Phase 5 update 1 §5). A capsule's tree comes back to the
Supervisor as regular files and directories only, with the guest's @.git@ left
in the guest (@check-capsule-runner@ E4, E5). These tests take such a tree,
made as hostile as a guest can make it, through the Supervisor's real path
(@writeSnapshot@, @snapshotChanges@, @commitChanges@, @advanceBranch@) on a
real repository, with real Git, an operator configuration and a repository
configuration that both try to run programs (content filters, a text
converter, a file-system monitor, hooks), and checks that nothing runs, the
bytes committed are the bytes returned, and only the work branch moves, by
compare-and-swap.
-}
module Lockstep.CapsuleGitTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import System.Directory (createDirectory, createDirectoryIfMissing, listDirectory)
import System.Environment (setEnv)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath, writeFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (createSymbolicLink, setFileMode)
import System.Process qualified as Process
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

import Lockstep.Effects.GitSupervisor (CommitMeta (..), advanceBranch, branchHead, commitChanges, createWorkBranch, snapshotChanges, writeSnapshot)
import Lockstep.Kernel.GitBasis (Change (..), TreeMode (..), checkChanges)

tests :: TestTree
tests =
  testGroup
    "C-P5.8 the Supervisor's Git against a capsule's returned tree"
    [ testCase "control: the same hostile configuration does run its programs under ordinary Git" controlTrapsFire
    , testCase "G1-G5 a hostile tree is committed as bytes: no filter, converter, monitor or hook runs; only the work branch moves" hostileTree
    , testCase "G2 a .git anywhere in the returned tree, in any letter case, is refused before any commit" gitDirectoryRefused
    , testCase "G2 a symbolic link in the returned tree is refused" symlinkRefused
    , testCase "G3 change paths that escape or name .git are refused by the Kernel's rule" pathsRefused
    , testCase "G6 a stale basis cannot move the work branch (compare-and-swap)" staleBasisRefused
    ]

-- A program that records that it ran.
trap :: FilePath -> FilePath -> String -> IO ()
trap dir pwned name = do
  let
    path = dir <> "/" <> name
  writeFile path ("#!/bin/sh\ntouch " <> pwned <> "/" <> name <> "\ncat\n")
  setFileMode path 0o755

-- A hostile world: the operator's ~/.gitconfig and the repository's own .git/config and hooks.
withHostileRepo :: (FilePath -> FilePath -> T.Text -> Assertion) -> Assertion
withHostileRepo =
  withHostileRepoExpecting []

withHostileRepoExpecting :: [FilePath] -> (FilePath -> FilePath -> T.Text -> Assertion) -> Assertion
withHostileRepoExpecting expected body =
  withSystemTempDirectory "lockstep-p58" $ \tmp -> do
    let
      home = tmp <> "/home"
      repo = tmp <> "/repo"
      pwned = tmp <> "/pwned"
      traps = tmp <> "/traps"
    traverse_ createDirectory [home, repo, pwned, traps]
    traverse_ (trap traps pwned) ["clean", "smudge", "textconv", "fsmonitor", "pre-commit", "post-commit", "commit-msg", "reference-transaction", "post-checkout"]
    writeFile (home <> "/.gitconfig") . L.unlines $
      [ "[user]"
      , "  name = Operator"
      , "  email = operator@example.invalid"
      , "[filter \"evil\"]"
      , "  clean = " <> traps <> "/clean"
      , "  smudge = " <> traps <> "/smudge"
      , "  required = true"
      , "[diff \"evil\"]"
      , "  textconv = " <> traps <> "/textconv"
      , "[core]"
      , "  hooksPath = " <> traps
      , "  fsmonitor = " <> traps <> "/fsmonitor"
      , "[safe]"
      , "  directory = *"
      ]
    setEnv "HOME" home
    -- The canonical repository, made by the test itself with every program switched off.
    git repo ["init", "-q", "-b", "main"]
    createDirectoryIfMissing True (repo <> "/src")
    writeFile (repo <> "/src/a.c") "int add(int a, int b) { return a - b; }\n"
    git repo ["add", "src/a.c"]
    git repo ["commit", "-q", "-m", "basis"]
    -- The repository's own configuration and hooks try too.
    traverse_ (trap (repo <> "/.git/hooks") pwned) ["pre-commit", "post-commit", "reference-transaction"]
    git repo ["config", "filter.evil.clean", traps <> "/clean"]
    git repo ["config", "core.fsmonitor", traps <> "/fsmonitor"]
    parent <- T.strip . T.pack <$> gitOut repo ["rev-parse", "HEAD"]
    body tmp repo parent
    ran <- listDirectory pwned
    L.sort ran @?= L.sort expected

git :: FilePath -> [String] -> Assertion
git repo args = do
  (code, _, err) <- Process.readProcessWithExitCode "git" (["-C", repo, "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] <> args) ""
  unless' (code == ExitSuccess) ("git " <> L.unwords args <> ": " <> err)

gitOut :: FilePath -> [String] -> IO String
gitOut repo args = do
  (code, out, err) <- Process.readProcessWithExitCode "git" (["-C", repo, "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"] <> args) ""
  unless' (code == ExitSuccess) ("git " <> L.unwords args <> ": " <> err)
  pure out

unless' :: Bool -> String -> Assertion
unless' ok message =
  if ok then pure () else assertFailure message

right :: String -> Either T.Text a -> IO a
right what =
  either (\code -> assertFailure (what <> ": " <> T.unpack code)) pure

meta :: CommitMeta
meta =
  CommitMeta {metaMessage = T.pack "lockstep: accepted implementation", metaEpoch = 1762800000}

-- The returned tree: the basis written out, then changed the way a hostile guest would.
returnedTree :: FilePath -> FilePath -> T.Text -> IO (FilePath, [Change])
returnedTree tmp repo parent = do
  let
    tree = tmp <> "/tree"
  createDirectory tree
  entries <- writeSnapshot repo parent tree >>= right "writeSnapshot"
  writeFile (tree <> "/src/a.c") "int add(int a, int b) { return a + b; }\n"
  writeFile (tree <> "/.gitattributes") "* filter=evil diff=evil\n"
  writeFile (tree <> "/.gitmodules") "[submodule \"x\"]\n\tpath = x\n\turl = /tmp/evil\n"
  writeFile (tree <> "/notes.txt") "a new file\n"
  changes <- snapshotChanges entries tree >>= right "snapshotChanges"
  pure (tree, changes)

hostileTree :: Assertion
hostileTree =
  withHostileRepo $ \tmp repo parent -> do
    (_, changes) <- returnedTree tmp repo parent
    L.sort (fmap changePath changes) @?= fmap T.pack [".gitattributes", ".gitmodules", "notes.txt", "src/a.c"]
    commit <- commitChanges repo parent changes meta >>= right "commitChanges"
    createWorkBranch repo (T.pack "lockstep/p58") parent >>= right "createWorkBranch"
    advanceBranch repo (T.pack "lockstep/p58") parent commit >>= right "advanceBranch"
    -- The committed bytes are the returned bytes (no clean filter applied).
    stored <- gitOut repo ["cat-file", "blob", T.unpack commit <> ":src/a.c"]
    stored @?= "int add(int a, int b) { return a + b; }\n"
    attributes <- gitOut repo ["cat-file", "blob", T.unpack commit <> ":.gitattributes"]
    attributes @?= "* filter=evil diff=evil\n"
    -- Only the work branch moved; main and the person's checkout are where they were.
    branchHead repo (T.pack "lockstep/p58") >>= right "branchHead" >>= (@?= Just commit)
    branchHead repo (T.pack "main") >>= right "branchHead" >>= (@?= Just parent)
    checkedOut <- readFileStrict (repo <> "/src/a.c")
    checkedOut @?= "int add(int a, int b) { return a - b; }\n"

-- Without the Supervisor's options, plain `git add` and `git commit` in this world run the clean filter
-- and the hooks: the traps are live, so their silence above means something.
controlTrapsFire :: Assertion
controlTrapsFire =
  withHostileRepoExpecting ["clean", "commit-msg", "fsmonitor", "post-commit", "pre-commit", "reference-transaction"] $ \_ repo _ -> do
    writeFile (repo <> "/.gitattributes") "* filter=evil\n"
    writeFile (repo <> "/x.txt") "x\n"
    _ <- Process.readProcessWithExitCode "git" ["-C", repo, "add", ".gitattributes", "x.txt"] ""
    _ <- Process.readProcessWithExitCode "git" ["-C", repo, "-c", "core.fsmonitor=false", "commit", "-q", "-m", "plain"] ""
    pure ()

gitDirectoryRefused :: Assertion
gitDirectoryRefused =
  withHostileRepo $ \tmp repo parent -> do
    let
      tree = tmp <> "/tree"
    createDirectory tree
    entries <- writeSnapshot repo parent tree >>= right "writeSnapshot"
    createDirectoryIfMissing True (tree <> "/sub/.GiT/hooks")
    writeFile (tree <> "/sub/.GiT/hooks/pre-commit") "#!/bin/sh\necho pwned\n"
    result <- snapshotChanges entries tree
    assertBool ("refused: " <> show' result) (either (const True) (const False) result)

symlinkRefused :: Assertion
symlinkRefused =
  withHostileRepo $ \tmp repo parent -> do
    let
      tree = tmp <> "/tree"
    createDirectory tree
    entries <- writeSnapshot repo parent tree >>= right "writeSnapshot"
    createSymbolicLink "/etc/passwd" (tree <> "/src/passwd")
    result <- snapshotChanges entries tree
    assertBool ("refused: " <> show' result) (either (const True) (const False) result)

pathsRefused :: Assertion
pathsRefused =
  fmap
    (either Just (const Nothing) . checkChanges . pure)
    [ Change (T.pack ".GIT/config") (Just (ModeFile, BS.empty))
    , Change (T.pack "a/.git/hooks/pre-commit") (Just (ModeExecutable, BS.empty))
    , Change (T.pack "../outside") (Just (ModeFile, BS.empty))
    , Change (T.pack "/etc/passwd") (Just (ModeFile, BS.empty))
    , Change (T.pack "a\\b") (Just (ModeFile, BS.empty))
    , Change (T.pack "link") (Just (ModeSymlink, TE.encodeUtf8 (T.pack "/etc/passwd")))
    ]
    @?= fmap (Just . T.pack) ["change-path-invalid", "change-path-invalid", "change-path-invalid", "change-path-invalid", "change-path-invalid", "change-symlink"]

staleBasisRefused :: Assertion
staleBasisRefused =
  withHostileRepo $ \tmp repo parent -> do
    (_, changes) <- returnedTree tmp repo parent
    first <- commitChanges repo parent changes meta >>= right "commitChanges"
    second <- commitChanges repo parent changes meta {metaEpoch = 1762800100} >>= right "commitChanges"
    createWorkBranch repo (T.pack "lockstep/p58") parent >>= right "createWorkBranch"
    advanceBranch repo (T.pack "lockstep/p58") parent first >>= right "advanceBranch"
    -- A second acceptance computed from the same, now stale, basis.
    stale <- advanceBranch repo (T.pack "lockstep/p58") parent second
    stale @?= Left (T.pack "branch-moved")
    branchHead repo (T.pack "lockstep/p58") >>= right "branchHead" >>= (@?= Just first)

readFileStrict :: FilePath -> IO String
readFileStrict path =
  T.unpack . TE.decodeUtf8 <$> BS.readFile path

show' :: Either T.Text [Change] -> String
show' result =
  case result of
    Left code -> T.unpack code
    Right cs -> "accepted " <> L.unwords (fmap (T.unpack . changePath) cs)
