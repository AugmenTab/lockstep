{-# LANGUAGE OverloadedStrings #-}

{- | The snapshot's memory bound (contract C-P4.R1 R-S3), run on its own
(@stack test lockstep:lockstep-stress@) because it writes a large tree: a
384 MiB repository (48 files of 8 MiB) is written into a snapshot and compared
with its tree inside a 96 MiB heap (this suite runs with @-M96m@). Holding the
whole tree, as the comparison once did, exhausts that heap.
-}
module Main
  ( main
  ) where

import Data.ByteString qualified as BS
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import System.Directory (createDirectory)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath)
import System.IO.Temp (withSystemTempDirectory)
import System.Process qualified as Process
import Test.Tasty (defaultMain, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Effects.GitSupervisor (snapshotChanges, writeSnapshot)
import Lockstep.Kernel.GitBasis (Change (..), TreeMode (..))

main :: IO ()
main =
  defaultMain $
    testGroup
      "C-P4.R1 R-S3 the snapshot's memory does not grow with the tree"
      [testCase "a 384 MiB tree is written and compared within a 96 MiB heap; the one changed file is found" bounded]

gitIn :: FilePath -> [String] -> IO String
gitIn dir args = do
  base <- getEnvironment
  let
    identity = ["-c", "user.name=Person", "-c", "user.email=person@example.invalid", "-c", "init.defaultBranch=main"]
    env = ("GIT_CONFIG_NOSYSTEM", "1") : L.filter ((/= "GIT_CONFIG_NOSYSTEM") . fst) base
  (code, out, err) <- Process.readCreateProcessWithExitCode ((Process.proc "git" (identity <> args)) {Process.cwd = Just dir, Process.env = Just env}) ""
  if code == ExitSuccess then pure out else assertFailure ("git " <> show args <> ": " <> err)

bounded :: IO ()
bounded =
  withSystemTempDirectory "lockstep-stress" $ \tmp -> do
    let
      repo = tmp <> "/repo"
      dest = tmp <> "/snapshot"
      names = [T.unpack ("part-" <> T.pack (show n) <> ".bin") | n <- [1 .. 48 :: Int]]
    createDirectory repo
    _ <- gitIn repo ["init", "-q"]
    traverse_ (\(n, name) -> BS.writeFile (repo <> "/" <> name) (BS.replicate 8388608 (fromIntegral (n :: Int)))) (L.zip [1 ..] names)
    _ <- gitIn repo ["add", "-A"]
    _ <- gitIn repo ["commit", "-q", "-m", "a large tree"]
    commit <- T.strip . T.pack <$> gitIn repo ["rev-parse", "HEAD"]
    createDirectory dest
    written <- writeSnapshot repo commit dest
    entries <- either (assertFailure . T.unpack) pure written
    L.length entries @?= 48
    BS.writeFile (dest <> "/part-7.bin") "changed\n"
    changes <- snapshotChanges entries dest
    changes @?= Right [Change "part-7.bin" (Just (ModeFile, "changed\n"))]
