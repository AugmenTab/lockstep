{-# LANGUAGE OverloadedStrings #-}

-- | The Supervisor's pure Git rules (contract C-P4.4 G1, G4).
module Lockstep.Kernel.GitBasisTest
  ( tests
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Lockstep.Kernel.GitBasis
  ( Change (..)
  , TreeMode (..)
  , checkChanges
  , isCommitId
  , parseTreeMode
  , supervisorEmail
  , supervisorName
  , treeModeText
  , treePathValid
  , workBranch
  )

tests :: TestTree
tests =
  testGroup
    "C-P4.4 Git rules"
    [ testCase "tree paths: relative, no empty, . or .. segment, no .git in any case, no control or backslash" paths
    , testCase "modes are Git's three file modes and nothing else" modes
    , testCase "a commit id is 40 lower-case hex characters" commitIds
    , testCase "the work branch and the Supervisor's identity" names
    , testCase "a change set: valid paths, each once, no link, not empty, in that order" changeSets
    ]

paths :: IO ()
paths = do
  fmap treePathValid ["a.txt", "src/a/b.hs", ".gitignore", ".github/workflows/x.yml", "a.git/x", "x/.gitkeep", T.replicate 4096 "a"]
    @?= [True, True, True, True, True, True, True]
  fmap treePathValid ["", "/abs", "a//b", "a/", "./a", "a/../b", "..", ".git", ".git/config", "x/.GIT/y", "x/.Git", "a\nb", "a\\b", "a\tb", T.replicate 4097 "a"]
    @?= [False, False, False, False, False, False, False, False, False, False, False, False, False, False, False]

modes :: IO ()
modes = do
  fmap treeModeText [ModeFile, ModeExecutable, ModeSymlink] @?= ["100644", "100755", "120000"]
  fmap parseTreeMode ["100644", "100755", "120000", "160000", "040000", "100664", ""]
    @?= [Just ModeFile, Just ModeExecutable, Just ModeSymlink, Nothing, Nothing, Nothing, Nothing]

commitIds :: IO ()
commitIds =
  fmap isCommitId [T.replicate 40 "a", T.replicate 39 "a", T.replicate 41 "a", T.replicate 40 "A", T.replicate 40 "g", "0123456789abcdef0123456789abcdef01234567"]
    @?= [True, False, False, False, False, True]

names :: IO ()
names = do
  workBranch "5f0c" @?= "lockstep/5f0c"
  supervisorName @?= "Lockstep Supervisor"
  supervisorEmail @?= "supervisor@lockstep.invalid"

changeSets :: IO ()
changeSets = do
  let
    file = Just (ModeFile, "x")
    code cs = fromLeft "accepted" (checkChanges cs)
  code [Change "a.txt" file, Change "b.txt" Nothing, Change "bin/x" (Just (ModeExecutable, ""))] @?= "accepted"
  code [Change "../x" file] @?= "change-path-invalid"
  code [Change ".git/HEAD" Nothing] @?= "change-path-invalid"
  code [Change "a" file, Change "a" file] @?= "change-duplicated"
  code [Change "l" (Just (ModeSymlink, "a"))] @?= "change-symlink"
  code [] @?= "change-empty"
  code [Change "../x" file, Change "../x" (Just (ModeSymlink, "a"))] @?= "change-path-invalid"
  code [Change "a" (Just (ModeSymlink, "b")), Change "a" Nothing] @?= "change-duplicated"
