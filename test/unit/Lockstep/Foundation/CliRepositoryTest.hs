module Lockstep.Foundation.CliRepositoryTest
  ( tests
  ) where

import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Lockstep.Foundation.Cli (CliError (..), Command (..), RegisterArgs (..), parseArgs)

tests :: TestTree
tests =
  testGroup
    "Cli engineer and repository (C-P2.1 I10)"
    [ testCase "engineer add NAME" $
        parseArgs ["engineer", "add", "alice"] @?= Right (EngineerAdd "alice")
    , testCase "engineer add needs exactly one name" $ do
        parseArgs ["engineer", "add"] @?= Left (MissingArgument "NAME")
        parseArgs ["engineer", "add", "a", "b"] @?= Left (UnexpectedArgument "b")
        parseArgs ["engineer", "add", "--x"] @?= Left (UnknownOption "--x")
    , testCase "engineer alone or unknown" $ do
        parseArgs ["engineer"] @?= Left (MissingSubcommand "engineer")
        parseArgs ["engineer", "remove", "a"] @?= Left (UnknownCommand "engineer remove")
    , testCase "repository register --engineer E PATH" $
        parseArgs ["repository", "register", "--engineer", "alice", "/w/orig"]
          @?= Right (RepositoryRegister (RegisterArgs "alice" Nothing "/w/orig"))
    , testCase "the = forms, an option after the path, and --authoritative-remote" $
        parseArgs ["repository", "register", "/w/fork", "--engineer=bob", "--authoritative-remote=origin"]
          @?= Right (RepositoryRegister (RegisterArgs "bob" (Just "origin") "/w/fork"))
    , testCase "--authoritative-remote R as two words" $
        parseArgs ["repository", "register", "--authoritative-remote", "origin", "--engineer", "bob", "p"]
          @?= Right (RepositoryRegister (RegisterArgs "bob" (Just "origin") "p"))
    , testCase "a path that looks like a relative path is kept as given" $
        parseArgs ["repository", "register", "--engineer", "a", "../orig/"]
          @?= Right (RepositoryRegister (RegisterArgs "a" Nothing "../orig/"))
    , testCase "a missing --engineer is refused" $
        parseArgs ["repository", "register", "/w/orig"] @?= Left (MissingOption "--engineer")
    , testCase "a missing path is refused" $
        parseArgs ["repository", "register", "--engineer", "a"] @?= Left (MissingArgument "PATH")
    , testCase "two paths are refused" $
        parseArgs ["repository", "register", "--engineer", "a", "p", "q"] @?= Left (UnexpectedArgument "q")
    , testCase "a duplicate option is refused" $ do
        parseArgs ["repository", "register", "--engineer", "a", "--engineer", "b", "p"]
          @?= Left (DuplicateOption "--engineer")
        parseArgs ["repository", "register", "--engineer", "a", "--authoritative-remote=o", "--authoritative-remote", "u", "p"]
          @?= Left (DuplicateOption "--authoritative-remote")
    , testCase "an option without its value is refused" $ do
        parseArgs ["repository", "register", "p", "--engineer"] @?= Left (MissingOptionValue "--engineer")
        parseArgs ["repository", "register", "p", "--engineer="] @?= Left (MissingOptionValue "--engineer")
    , testCase "an unknown option is refused" $
        parseArgs ["repository", "register", "--engineer", "a", "--force", "p"] @?= Left (UnknownOption "--force")
    , testCase "repository list takes no arguments" $ do
        parseArgs ["repository", "list"] @?= Right RepositoryList
        parseArgs ["repository", "list", "x"] @?= Left (UnexpectedArgument "x")
    , testCase "repository alone or unknown" $ do
        parseArgs ["repository"] @?= Left (MissingSubcommand "repository")
        parseArgs ["repository", "release", "p"] @?= Left (UnknownCommand "repository release")
    , testCase "earlier commands are unchanged" $ do
        parseArgs ["workspace", "show"] @?= Right WorkspaceShow
        parseArgs ["db", "status"] @?= Right DbStatus
        parseArgs ["job", "show", "3"] @?= Right (JobShow 3)
    ]
