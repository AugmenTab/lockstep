{-# LANGUAGE OverloadedStrings #-}

{- | The Supervisor's snapshots within bounds (contract C-P4.R1 R-S1, R-S2,
R-G1, R-C1), against real Git: aggregate limits are typed refusals; the
comparison still finds every changed byte and executable bit; a filter the
person's repository configures is never run when Lockstep observes it, and a
file it would have cleaned is not taken as clean; a snapshot never writes
through a link, which on a case-insensitive disk (@LOCKSTEP_TEST_CASE_DIR@,
the host's behaviour) is what two names that differ only in letter case would
do.
-}
module Lockstep.SnapshotBoundsTest
  ( tests
  ) where

import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Time.Clock (addUTCTime, getCurrentTime)
import Flipstone.Prelude
import System.Directory (createDirectory, createDirectoryIfMissing, doesFileExist, getPermissions, removeFile, setModificationTime, setOwnerExecutable, setPermissions)
import System.Environment (getEnvironment, lookupEnv)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath, writeFile)
import System.IO.Temp (withSystemTempDirectory, withTempDirectory)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, testCaseInfo, (@?=))
import Text.Show (show)

import Lockstep.Effects.GitSupervisor
  ( Basis (..)
  , SnapshotLimits (..)
  , defaultSnapshotLimits
  , observeBasis
  , snapshotChanges
  , snapshotChangesWithin
  , writeSnapshot
  , writeSnapshotWithin
  )
import Lockstep.Kernel.GitBasis (Change (..), TreeMode (..))

tests :: TestTree
tests =
  testGroup
    "C-P4.R1 snapshots within bounds: limits, exact bytes, no configured filter, never through a link (real Git)"
    [ testCase "R-S2 too many files, too many bytes written, too many or too large changes are typed refusals; within them the exact changes are found" limits
    , testCase "R-G1 a clean filter the repository configures is not run when the basis is observed; a file it would clean is a change" filters
    , testCaseInfo "R-C1 a link and a file whose names differ only in letter case: nothing is written through the link" folded
    ]

gitIn :: FilePath -> [String] -> IO String
gitIn dir args = do
  base <- getEnvironment
  let
    identity = ["-c", "user.name=Person", "-c", "user.email=person@example.invalid", "-c", "init.defaultBranch=main"]
    env = ("GIT_CONFIG_NOSYSTEM", "1") : L.filter ((/= "GIT_CONFIG_NOSYSTEM") . fst) base
  finished <-
    timeout 30000000 $
      Process.readCreateProcessWithExitCode ((Process.proc "git" (identity <> args)) {Process.cwd = Just dir, Process.env = Just env}) ""
  case finished of
    Just (ExitSuccess, out, _) -> pure out
    other -> assertFailure ("git " <> show args <> ": " <> show other)

gitLine :: FilePath -> [String] -> IO T.Text
gitLine dir args =
  T.strip . T.pack <$> gitIn dir args

-- | A repository with these files committed; its HEAD.
repoWith :: FilePath -> [(FilePath, String)] -> IO T.Text
repoWith repo files = do
  createDirectory repo
  _ <- gitIn repo ["init", "-q"]
  traverse_ (\(p, content) -> writeFile (repo <> "/" <> p) content) files
  _ <- gitIn repo ["add", "-A"]
  _ <- gitIn repo ["commit", "-q", "-m", "files"]
  gitLine repo ["rev-parse", "HEAD"]

limits :: Assertion
limits =
  withSystemTempDirectory "lockstep-p4r1-limits" $ \tmp -> do
    let
      repo = tmp <> "/repo"
      small = defaultSnapshotLimits
    commit <- repoWith repo [(n, "eight b\n") | n <- ["a.txt", "b.txt", "c.txt", "d.txt", "e.txt"]]
    createDirectory (tmp <> "/few")
    tooMany <- writeSnapshotWithin small {limitFiles = 3} repo commit (tmp <> "/few")
    fmap L.length tooMany @?= Left "snapshot-too-many-files"
    createDirectory (tmp <> "/small")
    tooLarge <- writeSnapshotWithin small {limitBytes = 20} repo commit (tmp <> "/small")
    fmap L.length tooLarge @?= Left "snapshot-too-large"
    createDirectory (tmp <> "/tree")
    written <- writeSnapshot repo commit (tmp <> "/tree")
    entries <- either (assertFailure . T.unpack) pure written
    L.length entries @?= 5
    let
      tree = tmp <> "/tree"
    walked <- snapshotChangesWithin small {limitFiles = 3} entries tree
    walked @?= Left "snapshot-too-many-files"
    traverse_ (\n -> writeFile (tree <> "/" <> n) "new\n") ["f.txt", "g.txt", "h.txt"]
    many <- snapshotChangesWithin small {limitChangedFiles = 2} entries tree
    many @?= Left "changes-too-many"
    big <- snapshotChangesWithin small {limitChangedBytes = 10} entries tree
    big @?= Left "changes-too-large"
    -- Within the limits: a one-byte change of the same size, an executable bit, a removal and the new files.
    traverse_ (\n -> removeFile (tree <> "/" <> n)) ["f.txt", "g.txt", "h.txt"]
    writeFile (tree <> "/a.txt") "eight c\n"
    perms <- getPermissions (tree <> "/b.txt")
    setPermissions (tree <> "/b.txt") (setOwnerExecutable True perms)
    removeFile (tree <> "/c.txt")
    writeFile (tree <> "/n.txt") "new\n"
    changes <- snapshotChanges entries tree
    changes
      @?= Right
        [ Change "a.txt" (Just (ModeFile, "eight c\n"))
        , Change "b.txt" (Just (ModeExecutable, "eight b\n"))
        , Change "c.txt" Nothing
        , Change "n.txt" (Just (ModeFile, "new\n"))
        ]

filters :: Assertion
filters =
  withSystemTempDirectory "lockstep-p4r1-filters" $ \tmp -> do
    let
      repo = tmp <> "/repo"
      marker = tmp <> "/filter-ran"
    commit <- repoWith repo [("a.txt", "plain text\n"), (".gitattributes", "*.txt filter=probe\n")]
    _ <- gitIn repo ["config", "filter.probe.clean", "touch " <> marker <> "; cat"]
    _ <- gitIn repo ["config", "filter.probe.smudge", "touch " <> marker <> "; cat"]
    -- The file's time changes, so Git must read it again to know it is clean.
    later <- addUTCTime 30 <$> getCurrentTime
    setModificationTime (repo <> "/a.txt") later
    observed <- observeBasis repo
    ran <- doesFileExist marker
    assertBool "the repository's clean filter was run by Lockstep" (not ran)
    fmap basisCommit observed @?= Right commit
    -- A file the filter would have cleaned into its committed bytes is a change, never clean.
    let
      repo2 = tmp <> "/repo2"
    createDirectory repo2
    _ <- gitIn repo2 ["init", "-q"]
    _ <- gitIn repo2 ["config", "filter.upper.clean", "tr a-z A-Z"]
    writeFile (repo2 <> "/.gitattributes") "*.txt filter=upper\n"
    writeFile (repo2 <> "/b.txt") "lower case\n"
    _ <- gitIn repo2 ["add", "-A"]
    _ <- gitIn repo2 ["commit", "-q", "-m", "through the filter"]
    stored <- gitIn repo2 ["show", "HEAD:b.txt"]
    stored @?= "LOWER CASE\n"
    later2 <- addUTCTime 30 <$> getCurrentTime
    setModificationTime (repo2 <> "/b.txt") later2
    observed2 <- observeBasis repo2
    fmap basisCommit observed2 @?= Left "repository-dirty"

folded :: IO String
folded = do
  caseDir <- lookupEnv "LOCKSTEP_TEST_CASE_DIR"
  withSystemTempDirectory "lockstep-p4r1-fold" $ \tmp -> do
    let
      repo = tmp <> "/repo"
      outside = tmp <> "/outside"
      base = fromMaybe tmp caseDir
    createDirectory outside
    createDirectoryIfMissing True base
    _ <- repoWith repo [("keep.txt", "keep\n")]
    -- Through Git's plumbing: a link `Foo` to a file outside, and a file `foo`.
    writeFile (tmp <> "/target") (outside <> "/written-through")
    writeFile (tmp <> "/content") "written through the link\n"
    link <- gitLine repo ["hash-object", "-w", tmp <> "/target"]
    file <- gitLine repo ["hash-object", "-w", tmp <> "/content"]
    _ <- gitIn repo ["update-index", "--add", "--cacheinfo", "120000," <> T.unpack link <> ",Foo"]
    _ <- gitIn repo ["update-index", "--add", "--cacheinfo", "100644," <> T.unpack file <> ",foo"]
    treeId <- gitLine repo ["write-tree"]
    commit <- gitLine repo ["commit-tree", T.unpack treeId, "-m", "folded names"]
    withTempDirectory base "lockstep-p4r1-dest" $ \dest -> do
      writeFile (dest <> "/Probe") "x"
      insensitive <- doesFileExist (dest <> "/probe")
      removeFile (dest <> "/Probe")
      written <- writeSnapshot repo commit dest
      through <- doesFileExist (outside <> "/written-through")
      assertBool "a file was written through the link, outside the snapshot" (not through)
      when insensitive (fmap L.length written @?= Left "tree-path-collision")
      unless insensitive $ do
        fmap L.length written @?= Right 3
        bytes <- BS.readFile (dest <> "/foo")
        bytes @?= "written through the link\n"
      pure (if insensitive then "case-insensitive: refused tree-path-collision" else "case-sensitive: both names written, nothing through the link")
