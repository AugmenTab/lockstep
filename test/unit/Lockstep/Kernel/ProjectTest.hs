{-# LANGUAGE OverloadedStrings #-}

{- | The pure project rules (contract C-P3.5 J1, J3, J4, J10): names, outcomes,
folder names, folder choices, and plain words for every refusal.
-}
module Lockstep.Kernel.ProjectTest
  ( tests
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

import Lockstep.Kernel.Project
  ( FolderChoice (..)
  , ProjectRuleError (..)
  , SetupState (..)
  , engineerNameFor
  , mkProjectName
  , mkProjectOutcome
  , parseFolderChoice
  , parseSetupState
  , projectNameText
  , projectOutcomeText
  , projectRefusalCodes
  , projectSlug
  , refusalWords
  , ruleErrorCode
  , setupStateCode
  , slugCandidate
  )

-- | Every DG-03 registration refusal code (C-P2.1 'refusalCode').
registrationCodes :: [T.Text]
registrationCodes =
  [ "path-not-found"
  , "not-a-directory"
  , "not-a-git-repository"
  , "bare-repository"
  , "not-top-level"
  , "linked-worktree"
  , "submodule"
  , "unsupported-git-layout"
  , "shallow-repository"
  , "git-unavailable"
  , "git-timed-out"
  , "git-failed"
  , "authoritative-remote-ambiguous"
  , "authoritative-remote-unknown"
  , "authoritative-remote-inconsistent"
  , "remote-url-unsupported"
  , "remote-unresolvable"
  , "repository-already-owned"
  , "authoritative-remote-owned"
  , "remote-is-owned-repository"
  , "owned-repository-pushes-here"
  , "engineer-already-owns-repository"
  , "repository-id-in-use"
  ]

slugOf :: T.Text -> T.Text
slugOf name =
  either (const "<refused>") projectSlug (mkProjectName name)

tests :: TestTree
tests =
  testGroup
    "Project rules (C-P3.5)"
    [ testCase "a name is 1 to 80 characters after trimming, without control characters" $ do
        fmap projectNameText (mkProjectName "  Family recipes  ") @?= Right "Family recipes"
        fmap projectNameText (mkProjectName (T.replicate 80 "a")) @?= Right (T.replicate 80 "a")
        fmap projectNameText (mkProjectName "Caf\233 <menu> & \"more\"") @?= Right "Caf\233 <menu> & \"more\""
        mkProjectName "" @?= Left NameEmpty
        mkProjectName "   " @?= Left NameEmpty
        mkProjectName (T.replicate 81 "a") @?= Left NameTooLong
        mkProjectName "two\nlines" @?= Left NameHasControl
        mkProjectName "tab\there" @?= Left NameHasControl
    , testCase "an outcome is at most 2000 characters; new lines and tabs are kept, other control characters are not" $ do
        fmap projectOutcomeText (mkProjectOutcome "") @?= Right ""
        fmap projectOutcomeText (mkProjectOutcome "  Publish it.\r\nThen share it.\t(soon)  ") @?= Right "Publish it.\nThen share it.\t(soon)"
        fmap projectOutcomeText (mkProjectOutcome (T.replicate 2000 "x")) @?= Right (T.replicate 2000 "x")
        mkProjectOutcome (T.replicate 2001 "x") @?= Left OutcomeTooLong
        mkProjectOutcome "bell\a" @?= Left OutcomeHasControl
    , testCase "rule errors have stable codes" $
        fmap ruleErrorCode [NameEmpty, NameTooLong, NameHasControl, OutcomeTooLong, OutcomeHasControl]
          @?= ["name-empty", "name-too-long", "name-control", "outcome-too-long", "outcome-control"]
    , testCase "the folder name comes from the project name: a-z, 0-9 and -, at most 36" $ do
        slugOf "My Website!" @?= "my-website"
        slugOf "  Caf\233  Menu " @?= "caf-menu"
        slugOf "2026 Plans" @?= "2026-plans"
        slugOf "!!!" @?= "project"
        slugOf "\26085\26412" @?= "project"
        slugOf (T.replicate 50 "a") @?= T.replicate 36 "a"
        slugOf (T.replicate 35 "a" <> " b") @?= T.replicate 35 "a"
    , testCase "taken folder names get -2, -3 … and stay within 36" $ do
        slugCandidate "my-website" 1 @?= "my-website"
        slugCandidate "my-website" 2 @?= "my-website-2"
        slugCandidate (T.replicate 36 "a") 12 @?= T.replicate 33 "a" <> "-12"
        slugCandidate (T.replicate 33 "a" <> "-bc") 2 @?= T.replicate 33 "a" <> "-2"
    , testCase "the project's Engineer is p- and the folder name, a valid C-P2.1 name" $ do
        engineerNameFor "my-website" @?= "p-my-website"
        engineerNameFor "2026-plans" @?= "p-2026-plans"
        assertBool "longer than 40" (T.length (engineerNameFor (slugCandidate (T.replicate 36 "a") 99)) <= 40)
    , testCase "folder choices are new, existing with a path, or later" $ do
        parseFolderChoice "new" Nothing @?= Just NewFolder
        parseFolderChoice "new" (Just "/ignored") @?= Just NewFolder
        parseFolderChoice "existing" (Just "/home/a/code") @?= Just (ExistingFolder "/home/a/code")
        parseFolderChoice "existing" (Just "") @?= Nothing
        parseFolderChoice "existing" Nothing @?= Nothing
        parseFolderChoice "later" Nothing @?= Just DecideLater
        parseFolderChoice "elsewhere" (Just "/x") @?= Nothing
    , testCase "setup states have stable codes" $ do
        fmap setupStateCode [Organized, Connected, SetupFailed] @?= ["organized", "connected", "setup-failed"]
        traverse_ (\s -> parseSetupState (setupStateCode s) @?= Just s) [Organized, Connected, SetupFailed]
        parseSetupState "ready" @?= Nothing
    , testCase "every refusal has its own plain words, with no Git vocabulary" $ do
        let
          fallback = refusalWords "no-such-code"
          codes = registrationCodes <> projectRefusalCodes
          jargon = ["git", "repositor", "remote", "worktree", "submodule", "bare", "shallow", "commit", "engineer"]
        assertBool "no project codes" (not (L.null projectRefusalCodes))
        traverse_
          ( \code -> do
              let
                words' = refusalWords code
              assertBool (T.unpack code <> " has no words of its own") (words' /= fallback && not (T.null words'))
              traverse_
                (\j -> assertBool (T.unpack code <> " says " <> T.unpack j <> ": " <> T.unpack words') (not (j `T.isInfixOf` T.toLower words')))
                jargon
          )
          codes
    , testCase "the project codes include every P3.5 refusal" $
        traverse_
          (\c -> assertBool (T.unpack c <> " missing") (c `L.elem` projectRefusalCodes))
          ["folder-not-offered", "no-projects-folder", "folder-exists", "folder-create-failed", "project-name-taken", "stale-revision", "already-connected"]
    , testCase "rule errors refuse rather than truncate" $
        assertBool "a long name was accepted" (isLeft (mkProjectName (T.replicate 200 "b")))
    ]
