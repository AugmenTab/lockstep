module Lockstep.Foundation.CliTest
  ( tests
  ) where

import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Foundation.Cli (CliError (..), Command (..), parseArgs)
import Lockstep.Foundation.Config
  ( BindHost (Loopback)
  , Port
  , ServeConfig (..)
  , defaultPort
  , mkPort
  , portNumber
  )

tests :: TestTree
tests =
  testGroup
    "Cli"
    [ testCase "serve with no options binds loopback on the documented default port" $
        parseArgs ["serve"] @?= Right (Serve (ServeConfig Loopback defaultPort))
    , testCase "the documented default port is 8000" $
        portNumber defaultPort @?= 8000
    , testCase "--port N sets the port" $ do
        port <- expectPort 9001
        parseArgs ["serve", "--port", "9001"] @?= Right (Serve (ServeConfig Loopback port))
    , testCase "--port=N sets the port" $ do
        port <- expectPort 9001
        parseArgs ["serve", "--port=9001"] @?= Right (Serve (ServeConfig Loopback port))
    , testCase "port bounds 1 and 65535 are accepted" $ do
        low <- expectPort 1
        high <- expectPort 65535
        parseArgs ["serve", "--port", "1"] @?= Right (Serve (ServeConfig Loopback low))
        parseArgs ["serve", "--port", "65535"] @?= Right (Serve (ServeConfig Loopback high))
    , testCase "--port with no value is a typed error, not the default" $
        parseArgs ["serve", "--port"] @?= Left (MissingOptionValue "--port")
    , testCase "--port= with an empty value is a typed error" $
        parseArgs ["serve", "--port="] @?= Left (MissingOptionValue "--port")
    , testCase "a non-numeric port is rejected" $
        parseArgs ["serve", "--port", "http"] @?= Left (InvalidPort "http")
    , testCase "a negative port is rejected" $
        parseArgs ["serve", "--port", "-1"] @?= Left (InvalidPort "-1")
    , testCase "port 0 is out of range" $
        parseArgs ["serve", "--port", "0"] @?= Left (PortOutOfRange 0)
    , testCase "port 65536 is out of range" $
        parseArgs ["serve", "--port", "65536"] @?= Left (PortOutOfRange 65536)
    , testCase "a repeated --port is refused" $
        parseArgs ["serve", "--port", "9001", "--port", "9002"]
          @?= Left (DuplicateOption "--port")
    , testCase "there is no option to bind a public interface" $
        parseArgs ["serve", "--host", "0.0.0.0"] @?= Left (UnknownOption "--host")
    , testCase "an unknown option is refused" $
        parseArgs ["serve", "--rollbar-token", "x"] @?= Left (UnknownOption "--rollbar-token")
    , testCase "an extra positional argument is refused" $
        parseArgs ["serve", "now"] @?= Left (UnexpectedArgument "now")
    , testCase "an unknown subcommand is refused" $
        parseArgs ["migrate"] @?= Left (UnknownCommand "migrate")
    , testCase "no subcommand is refused" $
        parseArgs [] @?= Left NoCommand
    , testCase "mkPort rejects 0 and 65536 and accepts 8000" $ do
        fmap portNumber (mkPort 0) @?= Nothing
        fmap portNumber (mkPort 65536) @?= Nothing
        fmap portNumber (mkPort 8000) @?= Just 8000
    ]

expectPort :: Integer -> IO Port
expectPort n =
  maybe (assertFailure ("mkPort rejected " <> show n)) pure (mkPort n)
