{-# LANGUAGE OverloadedStrings #-}

{- | The independent review of C-P6.6 (R-P6.6), pure: what a documentation
change may touch. Files that hold dependencies, instructions for later model
roles, embedded sources or programs are never documentation, whatever their
extension; a documentation name is a whole name, not a prefix.
-}
module Lockstep.Kernel.WorkPolicyReviewTest
  ( tests
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Lockstep.Kernel.Profile (PathClass (..))
import Lockstep.Kernel.WorkPolicy (documentationOnly, pathClassOf)

classes :: [T.Text] -> [PathClass]
classes =
  fmap pathClassOf

tests :: TestTree
tests =
  testGroup
    "R-P6.6 what documentation may touch (pure)"
    [ testCase "dependency pins in text files are dependencies (R-P6.6-2)" $
        classes ["requirements-dev.txt", "requirements/base.txt", "constraints.txt", "runtime.txt"]
          @?= [PathDependencies, PathDependencies, PathDependencies, PathDependencies]
    , testCase "instructions for model roles and agents are configuration, never documentation (R-P6.6-2)" $
        classes ["CLAUDE.md", "AGENTS.md", ".claude/agents/reviewer.md", ".github/copilot-instructions.md"]
          @?= [PathConfiguration, PathConfiguration, PathConfiguration, PathConfiguration]
    , testCase "anything under a source folder is source, whatever its extension (R-P6.6-2)" $
        classes ["src/help.md", "src/templates/page.txt", "lib/notes.rst"]
          @?= [PathSource, PathSource, PathSource]
    , testCase "a documentation name is a whole name: programs that start with one are not documentation (R-P6.6-3)" $
        classes ["bin/license-check", "scripts/readme-render", "authors-sync", "noticeboard"]
          @?= [PathSource, PathSource, PathSource, PathSource]
    , testCase "documentation stays documentation" $
        classes ["README", "LICENSE", "license.txt", "docs/notes.txt", "notes.txt", "guide/intro.md", "CONTRIBUTING.md"]
          @?= [PathDocs, PathDocs, PathDocs, PathDocs, PathDocs, PathDocs, PathDocs]
    , testCase "a documentation change touching any of these is not documentation only" $ do
        documentationOnly ["README.md", "requirements-dev.txt"] @?= False
        documentationOnly ["README.md", "CLAUDE.md"] @?= False
        documentationOnly ["README.md", "src/help.md"] @?= False
        documentationOnly ["README.md", "docs/notes.txt"] @?= True
    ]
