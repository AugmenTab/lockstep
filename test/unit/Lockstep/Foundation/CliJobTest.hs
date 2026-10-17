module Lockstep.Foundation.CliJobTest
  ( tests
  ) where

import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Lockstep.Foundation.Cli (CliError (..), Command (..), QueueArgs (..), RenameArgs (..), parseArgs)

tests :: TestTree
tests =
  testGroup
    "Cli job"
    [ testCase "job queue with defaults: 3 steps, 100 ms, no failure" $
        parseArgs ["job", "queue", "--expected-revision", "0"]
          @?= Right (JobQueue (QueueArgs 0 3 100 Nothing Nothing))
    , testCase "job queue with every option, = forms mixed" $
        parseArgs ["job", "queue", "--steps=5", "--step-ms", "250", "--fail-at-step=2", "--idempotency-key", "k", "--expected-revision=4"]
          @?= Right (JobQueue (QueueArgs 4 5 250 (Just 2) (Just "k")))
    , testCase "a missing expected revision is refused" $
        parseArgs ["job", "queue", "--steps", "2"] @?= Left (MissingOption "--expected-revision")
    , testCase "non-numeric values are refused" $ do
        parseArgs ["job", "queue", "--expected-revision", "0", "--steps", "x"] @?= Left (InvalidNumber "--steps" "x")
        parseArgs ["job", "queue", "--expected-revision", "0", "--step-ms", "-1"] @?= Left (InvalidNumber "--step-ms" "-1")
        parseArgs ["job", "queue", "--expected-revision", "0", "--fail-at-step", ""] @?= Left (MissingOptionValue "--fail-at-step")
    , testCase "a repeated option is refused" $
        parseArgs ["job", "queue", "--expected-revision", "0", "--steps", "1", "--steps", "2"] @?= Left (DuplicateOption "--steps")
    , testCase "job queue takes no positional argument" $
        parseArgs ["job", "queue", "--expected-revision", "0", "extra"] @?= Left (UnexpectedArgument "extra")
    , testCase "an unknown option is refused" $
        parseArgs ["job", "queue", "--expected-revision", "0", "--now"] @?= Left (UnknownOption "--now")
    , testCase "job show J" $
        parseArgs ["job", "show", "12"] @?= Right (JobShow 12)
    , testCase "job show needs exactly one numeric id" $ do
        parseArgs ["job", "show"] @?= Left (MissingArgument "JOB")
        parseArgs ["job", "show", "x"] @?= Left (InvalidNumber "JOB" "x")
        parseArgs ["job", "show", "1", "2"] @?= Left (UnexpectedArgument "2")
    , testCase "job without a subcommand is refused" $
        parseArgs ["job"] @?= Left (MissingSubcommand "job")
    , testCase "an unknown job subcommand is refused" $
        parseArgs ["job", "run"] @?= Left (UnknownCommand "job run")
    , testCase "workspace rename is unchanged" $
        parseArgs ["workspace", "rename", "--expected-revision", "1", "N"]
          @?= Right (WorkspaceRename (RenameArgs 1 Nothing "N"))
    ]
