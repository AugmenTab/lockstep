-- | @lockstep control serve@ (contract C-P3.1 L3, L10).
module Lockstep.Foundation.CliControlTest
  ( tests
  ) where

import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Foundation.Cli (CliError (..), Command (..), parseArgs)
import Lockstep.Foundation.Config (Port, defaultControlPort, mkPort, portNumber)

tests :: TestTree
tests =
  testGroup
    "Cli control (C-P3.1)"
    [ testCase "the default control-pane port is 8100" $
        portNumber defaultControlPort @?= 8100
    , testCase "control serve --state DIR uses the default port" $
        parseArgs ["control", "serve", "--state", "/state"] @?= Right (ControlServe defaultControlPort "/state")
    , testCase "--port N and --state=DIR in either order" $ do
        port <- expectPort 8105
        parseArgs ["control", "serve", "--port", "8105", "--state=/state"] @?= Right (ControlServe port "/state")
        parseArgs ["control", "serve", "--state", "/state", "--port=8105"] @?= Right (ControlServe port "/state")
    , testCase "--state is required" $
        parseArgs ["control", "serve"] @?= Left (MissingOption "--state")
    , testCase "an empty --state is a missing value" $
        parseArgs ["control", "serve", "--state="] @?= Left (MissingOptionValue "--state")
    , testCase "a repeated option is refused" $ do
        parseArgs ["control", "serve", "--state", "/a", "--state", "/b"] @?= Left (DuplicateOption "--state")
        parseArgs ["control", "serve", "--state", "/a", "--port", "1", "--port", "2"] @?= Left (DuplicateOption "--port")
    , testCase "a bad port is refused" $ do
        parseArgs ["control", "serve", "--state", "/a", "--port", "0"] @?= Left (PortOutOfRange 0)
        parseArgs ["control", "serve", "--state", "/a", "--port", "x"] @?= Left (InvalidPort "x")
    , testCase "there is no option to bind another interface or name a database" $ do
        parseArgs ["control", "serve", "--state", "/a", "--host", "0.0.0.0"] @?= Left (UnknownOption "--host")
        parseArgs ["control", "serve", "--state", "/a", "--config", "x"] @?= Left (UnknownOption "--config")
    , testCase "extra arguments and unknown subcommands are refused" $ do
        parseArgs ["control", "serve", "--state", "/a", "now"] @?= Left (UnexpectedArgument "now")
        parseArgs ["control"] @?= Left (MissingSubcommand "control")
        parseArgs ["control", "start"] @?= Left (UnknownCommand "control start")
    ]

expectPort :: Integer -> IO Port
expectPort n =
  maybe (assertFailure ("mkPort rejected " <> show n)) pure (mkPort n)
