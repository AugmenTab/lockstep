module Lockstep.Foundation.CliWorkspaceTest
  ( tests
  ) where

import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Lockstep.Foundation.Cli (BackupPolicy (..), CliError (..), Command (..), RenameArgs (..), parseArgs)
import Lockstep.Foundation.Config (defaultPort)

tests :: TestTree
tests =
  testGroup
    "Cli workspace"
    [ testCase "workspace show" $
        parseArgs ["workspace", "show"] @?= Right WorkspaceShow
    , testCase "workspace show takes no arguments" $
        parseArgs ["workspace", "show", "x"] @?= Left (UnexpectedArgument "x")
    , testCase "workspace rename --expected-revision N NAME" $
        parseArgs ["workspace", "rename", "--expected-revision", "3", "Lockstep Two"]
          @?= Right (WorkspaceRename (RenameArgs 3 Nothing "Lockstep Two"))
    , testCase "the = forms and an option after the name" $
        parseArgs ["workspace", "rename", "Lockstep Two", "--expected-revision=0", "--idempotency-key=abcdefghijklmnop"]
          @?= Right (WorkspaceRename (RenameArgs 0 (Just "abcdefghijklmnop") "Lockstep Two"))
    , testCase "--idempotency-key K" $
        parseArgs ["workspace", "rename", "--idempotency-key", "k", "--expected-revision", "1", "N"]
          @?= Right (WorkspaceRename (RenameArgs 1 (Just "k") "N"))
    , testCase "a missing expected revision is refused" $
        parseArgs ["workspace", "rename", "N"] @?= Left (MissingOption "--expected-revision")
    , testCase "a non-numeric expected revision is refused" $
        parseArgs ["workspace", "rename", "--expected-revision", "two", "N"] @?= Left (InvalidRevision "two")
    , testCase "a negative expected revision is refused by the parser" $
        parseArgs ["workspace", "rename", "--expected-revision", "-1", "N"] @?= Left (InvalidRevision "-1")
    , testCase "an option without its value is refused" $
        parseArgs ["workspace", "rename", "N", "--expected-revision"] @?= Left (MissingOptionValue "--expected-revision")
    , testCase "a missing name is refused" $
        parseArgs ["workspace", "rename", "--expected-revision", "1"] @?= Left (MissingArgument "NAME")
    , testCase "two names are refused" $
        parseArgs ["workspace", "rename", "--expected-revision", "1", "a", "b"] @?= Left (UnexpectedArgument "b")
    , testCase "a repeated option is refused" $
        parseArgs ["workspace", "rename", "--expected-revision", "1", "--expected-revision", "2", "a"]
          @?= Left (DuplicateOption "--expected-revision")
    , testCase "an unknown option is refused" $
        parseArgs ["workspace", "rename", "--expected-revision", "1", "--force", "a"] @?= Left (UnknownOption "--force")
    , testCase "workspace without a subcommand is refused" $
        parseArgs ["workspace"] @?= Left (MissingSubcommand "workspace")
    , testCase "an unknown workspace subcommand is refused" $
        parseArgs ["workspace", "delete"] @?= Left (UnknownCommand "workspace delete")
    , testCase "earlier commands are unchanged" $ do
        parseArgs ["db", "migrate", "--no-backup"] @?= Right (DbMigrate NoBackup)
        parseArgs ["operator", "sign-in"] @?= Right (OperatorSignIn defaultPort)
    ]
