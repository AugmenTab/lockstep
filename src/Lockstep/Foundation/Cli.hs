module Lockstep.Foundation.Cli
  ( Command (..)
  , CliError (..)
  , parseArgs
  , renderCliError
  , usage
  ) where

import Data.Char qualified as Char
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Flipstone.Prelude
import Text.Show (Show, show)

import Lockstep.Foundation.Config
  ( BindHost (Loopback)
  , Port
  , ServeConfig (..)
  , defaultPort
  , mkPort
  )

{- HLINT ignore Command "Use newtype instead of data" -}
-- A sum type: P1.4 adds operator-command constructors.
data Command
  = Serve ServeConfig
  deriving (Eq, Show)

-- | Every way the command line can be refused. Usage errors exit 64.
data CliError
  = NoCommand
  | UnknownCommand String
  | UnknownOption String
  | MissingOptionValue String
  | DuplicateOption String
  | InvalidPort String
  | PortOutOfRange Integer
  | UnexpectedArgument String
  deriving (Eq, Show)

parseArgs :: [String] -> Either CliError Command
parseArgs args =
  case args of
    [] -> Left NoCommand
    "serve" : options -> fmap Serve (parseServeOptions options)
    command : _ -> Left (UnknownCommand command)

portOption :: String
portOption =
  "--port"

parseServeOptions :: [String] -> Either CliError ServeConfig
parseServeOptions =
  let
    finish mbPort =
      Right
        ServeConfig
          { serveHost = Loopback
          , servePort = fromMaybe defaultPort mbPort
          }

    withPort mbPort value rest =
      case mbPort of
        Just _ -> Left (DuplicateOption portOption)
        Nothing -> parsePort value >>= \port -> go (Just port) rest

    go mbPort options =
      case options of
        [] ->
          finish mbPort
        option : rest
          | option == portOption ->
              case rest of
                [] -> Left (MissingOptionValue portOption)
                value : rest' -> withPort mbPort value rest'
          | Just value <- L.stripPrefix (portOption <> "=") option ->
              if L.null value
                then Left (MissingOptionValue portOption)
                else withPort mbPort value rest
          | "-" `L.isPrefixOf` option ->
              Left (UnknownOption option)
          | otherwise ->
              Left (UnexpectedArgument option)
  in
    go Nothing

parsePort :: String -> Either CliError Port
parsePort value =
  if not (L.null value) && L.all Char.isDigit value
    then
      let
        n = L.foldl' (\acc c -> acc * 10 + toInteger (Char.ord c - Char.ord '0')) 0 value
      in
        maybe (Left (PortOutOfRange n)) Right (mkPort n)
    else Left (InvalidPort value)

renderCliError :: CliError -> String
renderCliError err =
  case err of
    NoCommand -> "no command given"
    UnknownCommand command -> "unknown command: " <> command
    UnknownOption option -> "unknown option: " <> option
    MissingOptionValue option -> "option " <> option <> " requires a value"
    DuplicateOption option -> "option " <> option <> " given more than once"
    InvalidPort value -> "--port: not a port number: " <> value
    PortOutOfRange n -> "--port: " <> show n <> " is outside 1-65535"
    UnexpectedArgument arg -> "unexpected argument: " <> arg

usage :: String
usage =
  L.unlines
    [ "usage: lockstep serve [--port N]"
    , ""
    , "  serve       run the local service on 127.0.0.1 (default port 8000)"
    , "  --port N    listen on port N (1-65535)"
    ]
