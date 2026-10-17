module Lockstep.Foundation.CliDbTest
  ( tests
  ) where

import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Lockstep.Foundation.Cli (BackupPolicy (..), CliError (..), Command (..), parseArgs)

tests :: TestTree
tests =
  testGroup
    "Cli db"
    [ testCase "db migrate defaults to requiring a backup when migrations are applied" $
        parseArgs ["db", "migrate"] @?= Right (DbMigrate BackupRequiredIfApplied)
    , testCase "db migrate --backup FILE" $
        parseArgs ["db", "migrate", "--backup", "b.dump"] @?= Right (DbMigrate (BackupFile "b.dump"))
    , testCase "db migrate --backup=FILE" $
        parseArgs ["db", "migrate", "--backup=b.dump"] @?= Right (DbMigrate (BackupFile "b.dump"))
    , testCase "db migrate --no-backup" $
        parseArgs ["db", "migrate", "--no-backup"] @?= Right (DbMigrate NoBackup)
    , testCase "db migrate --backup without a value is a typed error" $
        parseArgs ["db", "migrate", "--backup"] @?= Left (MissingOptionValue "--backup")
    , testCase "--backup and --no-backup conflict" $
        parseArgs ["db", "migrate", "--backup", "b.dump", "--no-backup"]
          @?= Left (ConflictingOptions "--backup" "--no-backup")
    , testCase "a repeated --backup is refused" $
        parseArgs ["db", "migrate", "--backup", "a", "--backup", "b"]
          @?= Left (DuplicateOption "--backup")
    , testCase "an unknown db migrate option is refused" $
        parseArgs ["db", "migrate", "--force"] @?= Left (UnknownOption "--force")
    , testCase "db status" $
        parseArgs ["db", "status"] @?= Right DbStatus
    , testCase "db status takes no arguments" $
        parseArgs ["db", "status", "now"] @?= Left (UnexpectedArgument "now")
    , testCase "db without a subcommand is refused" $
        parseArgs ["db"] @?= Left (MissingSubcommand "db")
    , testCase "an unknown db subcommand is refused" $
        parseArgs ["db", "frob"] @?= Left (UnknownCommand "db frob")
    ]
