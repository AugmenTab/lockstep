module Lockstep.Foundation.Cli
  ( Command (..)
  , BackupPolicy (..)
  , CliError (..)
  , parseArgs
  , renderCliError
  , usage
  ) where

import Data.Char qualified as Char
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Flipstone.Prelude
import System.IO (FilePath)
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
  | DbMigrate BackupPolicy
  | DbStatus
  deriving (Eq, Show)

{- | What @db migrate@ requires before applying migrations to a database that
already has some (contract C-P1.2 E6).
-}
data BackupPolicy
  = BackupRequiredIfApplied
  | BackupFile FilePath
  | NoBackup
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
  | MissingSubcommand String
  | ConflictingOptions String String
  deriving (Eq, Show)

parseArgs :: [String] -> Either CliError Command
parseArgs args =
  case args of
    [] -> Left NoCommand
    "serve" : options -> fmap Serve (parseServeOptions options)
    "db" : rest -> parseDbCommand rest
    command : _ -> Left (UnknownCommand command)

parseDbCommand :: [String] -> Either CliError Command
parseDbCommand args =
  case args of
    [] -> Left (MissingSubcommand "db")
    "migrate" : options -> fmap DbMigrate (parseMigrateOptions options)
    "status" : rest -> DbStatus <$ noMoreArguments rest
    command : _ -> Left (UnknownCommand ("db " <> command))

noMoreArguments :: [String] -> Either CliError ()
noMoreArguments args =
  case args of
    [] -> Right ()
    arg : _ -> Left (unexpected arg)

unexpected :: String -> CliError
unexpected arg =
  if "-" `L.isPrefixOf` arg
    then UnknownOption arg
    else UnexpectedArgument arg

backupOption :: String
backupOption =
  "--backup"

noBackupOption :: String
noBackupOption =
  "--no-backup"

parseMigrateOptions :: [String] -> Either CliError BackupPolicy
parseMigrateOptions =
  let
    conflict =
      Left (ConflictingOptions backupOption noBackupOption)

    withFile mbPolicy file rest =
      case mbPolicy of
        Nothing -> go (Just (BackupFile file)) rest
        Just (BackupFile _) -> Left (DuplicateOption backupOption)
        Just _ -> conflict

    go mbPolicy options =
      case options of
        [] ->
          Right (fromMaybe BackupRequiredIfApplied mbPolicy)
        option : rest
          | option == backupOption ->
              case rest of
                [] -> Left (MissingOptionValue backupOption)
                file : rest' -> withFile mbPolicy file rest'
          | Just file <- L.stripPrefix (backupOption <> "=") option ->
              if L.null file
                then Left (MissingOptionValue backupOption)
                else withFile mbPolicy file rest
          | option == noBackupOption ->
              case mbPolicy of
                Nothing -> go (Just NoBackup) rest
                Just NoBackup -> Left (DuplicateOption noBackupOption)
                Just _ -> conflict
          | otherwise ->
              Left (unexpected option)
  in
    go Nothing

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
          | otherwise ->
              Left (unexpected option)
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
    MissingSubcommand command -> command <> ": a subcommand is required"
    ConflictingOptions a b -> "options " <> a <> " and " <> b <> " cannot be combined"

usage :: String
usage =
  L.unlines
    [ "usage: lockstep serve [--port N]"
    , "       lockstep db migrate [--backup FILE | --no-backup]"
    , "       lockstep db status"
    , ""
    , "  serve        run the local service on 127.0.0.1 (default port 8000)"
    , "  --port N     listen on port N (1-65535)"
    , "  db migrate   apply pending database migrations (needs a backup once any are applied)"
    , "  db status    show the database schema revision and pending migrations"
    , ""
    , "The database is configured by the file named in LOCKSTEP_CONFIG."
    ]
