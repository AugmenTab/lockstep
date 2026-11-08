-- | C-P2.3 F14: the Profile commands.
module Lockstep.Foundation.CliProfileTest
  ( tests
  ) where

import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Lockstep.Foundation.Cli (CliError (..), Command (..), RegisterArgs (..), ResolveArgs (..), parseArgs)

tests :: TestTree
tests =
  testGroup
    "Cli Profile commands (C-P2.3 F14)"
    [ testCase "profile add FILE and profile add -" $ do
        parseArgs ["profile", "add", "team.json"] @?= Right (ProfileAdd "team.json")
        parseArgs ["profile", "add", "-"] @?= Right (ProfileAdd "-")
    , testCase "profile add needs exactly one file" $ do
        parseArgs ["profile", "add"] @?= Left (MissingArgument "FILE")
        parseArgs ["profile", "add", "a", "b"] @?= Left (UnexpectedArgument "b")
        parseArgs ["profile", "add", "--force"] @?= Left (UnknownOption "--force")
    , testCase "profile list takes no arguments" $ do
        parseArgs ["profile", "list"] @?= Right ProfileList
        parseArgs ["profile", "list", "x"] @?= Left (UnexpectedArgument "x")
    , testCase "profile show ID [--version N]" $ do
        parseArgs ["profile", "show", "team"] @?= Right (ProfileShow "team" Nothing)
        parseArgs ["profile", "show", "team", "--version", "2"] @?= Right (ProfileShow "team" (Just 2))
        parseArgs ["profile", "show", "--version=3", "team"] @?= Right (ProfileShow "team" (Just 3))
    , testCase "profile show refusals" $ do
        parseArgs ["profile", "show"] @?= Left (MissingArgument "ID")
        parseArgs ["profile", "show", "a", "b"] @?= Left (UnexpectedArgument "b")
        parseArgs ["profile", "show", "a", "--version"] @?= Left (MissingOptionValue "--version")
        parseArgs ["profile", "show", "a", "--version", "x"] @?= Left (InvalidNumber "--version" "x")
        parseArgs ["profile", "show", "a", "--version", "1", "--version", "2"] @?= Left (DuplicateOption "--version")
        parseArgs ["profile", "show", "a", "--latest"] @?= Left (UnknownOption "--latest")
    , testCase "repository set-profile --engineer NAME PROFILE" $ do
        parseArgs ["repository", "set-profile", "--engineer", "alice", "team"] @?= Right (RepositorySetProfile "alice" "team")
        parseArgs ["repository", "set-profile", "team", "--engineer=alice"] @?= Right (RepositorySetProfile "alice" "team")
    , testCase "repository set-profile refusals" $ do
        parseArgs ["repository", "set-profile", "team"] @?= Left (MissingOption "--engineer")
        parseArgs ["repository", "set-profile", "--engineer", "alice"] @?= Left (MissingArgument "PROFILE")
        parseArgs ["repository", "set-profile", "--engineer", "a", "p", "q"] @?= Left (UnexpectedArgument "q")
        parseArgs ["repository", "set-profile", "--engineer", "a", "--engineer", "b", "p"] @?= Left (DuplicateOption "--engineer")
        parseArgs ["repository", "set-profile", "--engineer", "a", "--force", "p"] @?= Left (UnknownOption "--force")
    , testCase "profile resolve with every option" $
        parseArgs
          [ "profile"
          , "resolve"
          , "--engineer"
          , "alice"
          , "--kind=engineering"
          , "--class"
          , "security"
          , "--class=bug-fix"
          , "--path-class"
          , "docs"
          , "--non-behavioural"
          , "typo only"
          ]
          @?= Right
            ( ProfileResolve
                ResolveArgs
                  { resolveEngineer = "alice"
                  , resolveKind = "engineering"
                  , resolveClasses = ["security", "bug-fix"]
                  , resolvePathClasses = ["docs"]
                  , resolveNonBehavioural = Just "typo only"
                  }
            )
    , testCase "profile resolve with the minimum" $
        parseArgs ["profile", "resolve", "--kind", "investigate", "--engineer", "bob"]
          @?= Right (ProfileResolve (ResolveArgs "bob" "investigate" [] [] Nothing))
    , testCase "profile resolve refusals" $ do
        parseArgs ["profile", "resolve", "--kind", "plan"] @?= Left (MissingOption "--engineer")
        parseArgs ["profile", "resolve", "--engineer", "a"] @?= Left (MissingOption "--kind")
        parseArgs ["profile", "resolve", "--engineer", "a", "--kind", "plan", "--kind", "plan"] @?= Left (DuplicateOption "--kind")
        parseArgs ["profile", "resolve", "--engineer", "a", "--kind", "plan", "--non-behavioural", "x", "--non-behavioural", "y"]
          @?= Left (DuplicateOption "--non-behavioural")
        parseArgs ["profile", "resolve", "--engineer", "a", "--kind", "plan", "--class"] @?= Left (MissingOptionValue "--class")
        parseArgs ["profile", "resolve", "--engineer", "a", "--kind", "plan", "extra"] @?= Left (UnexpectedArgument "extra")
        parseArgs ["profile", "resolve", "--engineer", "a", "--kind", "plan", "--force"] @?= Left (UnknownOption "--force")
    , testCase "profile alone or unknown" $ do
        parseArgs ["profile"] @?= Left (MissingSubcommand "profile")
        parseArgs ["profile", "delete", "x"] @?= Left (UnknownCommand "profile delete")
    , testCase "earlier commands are unchanged" $ do
        parseArgs ["repository", "list"] @?= Right RepositoryList
        parseArgs ["repository", "register", "--engineer", "a", "p"] @?= Right (RepositoryRegister (RegisterArgs "a" Nothing "p"))
        parseArgs ["engineer", "add", "a"] @?= Right (EngineerAdd "a")
    ]
