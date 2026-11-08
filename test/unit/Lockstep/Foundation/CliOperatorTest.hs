module Lockstep.Foundation.CliOperatorTest
  ( tests
  ) where

import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Foundation.Cli (BackupPolicy (..), CliError (..), Command (..), parseArgs)
import Lockstep.Foundation.Config (BindHost (Loopback), Port, ServeConfig (..), defaultPort, mkPort)

tests :: TestTree
tests =
  testGroup
    "Cli operator"
    [ testCase "operator sign-in defaults to the serve default port" $
        parseArgs ["operator", "sign-in"] @?= Right (OperatorSignIn defaultPort)
    , testCase "operator sign-in --port N" $ do
        port <- expectPort 9001
        parseArgs ["operator", "sign-in", "--port", "9001"] @?= Right (OperatorSignIn port)
    , testCase "operator sign-in --port=N" $ do
        port <- expectPort 9001
        parseArgs ["operator", "sign-in", "--port=9001"] @?= Right (OperatorSignIn port)
    , testCase "operator sign-in validates the port like serve" $ do
        parseArgs ["operator", "sign-in", "--port", "0"] @?= Left (PortOutOfRange 0)
        parseArgs ["operator", "sign-in", "--port", "x"] @?= Left (InvalidPort "x")
        parseArgs ["operator", "sign-in", "--port"] @?= Left (MissingOptionValue "--port")
        parseArgs ["operator", "sign-in", "--port", "1", "--port", "2"] @?= Left (DuplicateOption "--port")
    , testCase "there is no option that takes a token" $
        parseArgs ["operator", "sign-in", "--token", "x"] @?= Left (UnknownOption "--token")
    , testCase "operator sign-in takes no positional argument" $
        parseArgs ["operator", "sign-in", "now"] @?= Left (UnexpectedArgument "now")
    , testCase "operator sign-out-all" $
        parseArgs ["operator", "sign-out-all"] @?= Right OperatorSignOutAll
    , testCase "operator sign-out-all takes no arguments" $ do
        parseArgs ["operator", "sign-out-all", "now"] @?= Left (UnexpectedArgument "now")
        parseArgs ["operator", "sign-out-all", "--port", "1"] @?= Left (UnknownOption "--port")
    , testCase "operator without a subcommand is refused" $
        parseArgs ["operator"] @?= Left (MissingSubcommand "operator")
    , testCase "an unknown operator subcommand is refused" $
        parseArgs ["operator", "frob"] @?= Left (UnknownCommand "operator frob")
    , testCase "the P1.1 and P1.2 commands are unchanged" $ do
        parseArgs ["serve"] @?= Right (Serve (ServeConfig Loopback defaultPort))
        parseArgs ["db", "migrate"] @?= Right (DbMigrate BackupRequiredIfApplied)
        parseArgs ["db", "status"] @?= Right DbStatus
    ]

expectPort :: Integer -> IO Port
expectPort n =
  maybe (assertFailure ("mkPort rejected " <> show n)) pure (mkPort n)
