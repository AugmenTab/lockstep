module Lockstep.Foundation.Cli
  ( Command (..)
  , BackupPolicy (..)
  , CliError (..)
  , RenameArgs (..)
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
  | OperatorSignIn Port
  | OperatorSignOutAll
  | WorkspaceShow
  | WorkspaceRename RenameArgs
  deriving (Eq, Show)

data RenameArgs
  = RenameArgs
  { renameExpected :: Integer
  , renameKey :: Maybe String
  , renameName :: String
  }
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
  | MissingOption String
  | InvalidRevision String
  | MissingArgument String
  deriving (Eq, Show)

parseArgs :: [String] -> Either CliError Command
parseArgs args =
  case args of
    [] -> Left NoCommand
    "serve" : options -> fmap Serve (parseServeOptions options)
    "db" : rest -> parseDbCommand rest
    "operator" : rest -> parseOperatorCommand rest
    "workspace" : rest -> parseWorkspaceCommand rest
    command : _ -> Left (UnknownCommand command)

-- | Contract C-P1.4 E8.
parseWorkspaceCommand :: [String] -> Either CliError Command
parseWorkspaceCommand args =
  case args of
    [] -> Left (MissingSubcommand "workspace")
    "show" : rest -> WorkspaceShow <$ noMoreArguments rest
    "rename" : options -> fmap WorkspaceRename (parseRenameOptions options)
    command : _ -> Left (UnknownCommand ("workspace " <> command))

expectedRevisionOption :: String
expectedRevisionOption =
  "--expected-revision"

idempotencyKeyOption :: String
idempotencyKeyOption =
  "--idempotency-key"

data RenameAcc
  = RenameAcc
  { accExpected :: Maybe Integer
  , accKey :: Maybe String
  , accName :: Maybe String
  }

parseRenameOptions :: [String] -> Either CliError RenameArgs
parseRenameOptions =
  let
    finish acc =
      case (accExpected acc, accName acc) of
        (Nothing, _) -> Left (MissingOption expectedRevisionOption)
        (_, Nothing) -> Left (MissingArgument "NAME")
        (Just expected, Just name) -> Right (RenameArgs expected (accKey acc) name)

    withValue option value acc rest
      | option == expectedRevisionOption =
          case accExpected acc of
            Just _ -> Left (DuplicateOption option)
            Nothing -> parseRevision value >>= \n -> go acc {accExpected = Just n} rest
      | otherwise =
          case accKey acc of
            Just _ -> Left (DuplicateOption option)
            Nothing -> go acc {accKey = Just value} rest

    go acc options =
      case options of
        [] ->
          finish acc
        option : rest
          | option `L.elem` [expectedRevisionOption, idempotencyKeyOption] ->
              case rest of
                [] -> Left (MissingOptionValue option)
                value : rest' -> withValue option value acc rest'
          | (name, '=' : value) <- L.break (== '=') option
          , name `L.elem` [expectedRevisionOption, idempotencyKeyOption] ->
              if L.null value
                then Left (MissingOptionValue name)
                else withValue name value acc rest
          | "-" `L.isPrefixOf` option ->
              Left (UnknownOption option)
          | otherwise ->
              case accName acc of
                Just _ -> Left (UnexpectedArgument option)
                Nothing -> go acc {accName = Just option} rest
  in
    go (RenameAcc Nothing Nothing Nothing)

parseRevision :: String -> Either CliError Integer
parseRevision value =
  if not (L.null value) && L.length value <= 18 && L.all Char.isDigit value
    then Right (L.foldl' (\acc c -> acc * 10 + toInteger (Char.ord c - Char.ord '0')) 0 value)
    else Left (InvalidRevision value)

-- | Contract C-P1.3 E2, E9. There is deliberately no option that takes a token.
parseOperatorCommand :: [String] -> Either CliError Command
parseOperatorCommand args =
  case args of
    [] -> Left (MissingSubcommand "operator")
    "sign-in" : options -> fmap OperatorSignIn (parsePortOptions options)
    "sign-out-all" : rest -> OperatorSignOutAll <$ noMoreArguments rest
    command : _ -> Left (UnknownCommand ("operator " <> command))

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
parseServeOptions options = do
  port <- parsePortOptions options
  pure
    ServeConfig
      { serveHost = Loopback
      , servePort = port
      }

-- | An optional @--port N@ / @--port=N@ and nothing else; default 8000.
parsePortOptions :: [String] -> Either CliError Port
parsePortOptions =
  let
    finish mbPort =
      Right (fromMaybe defaultPort mbPort)

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
    MissingOption option -> "option " <> option <> " is required"
    InvalidRevision value -> "--expected-revision: not a revision number: " <> value
    MissingArgument name -> "argument " <> name <> " is required"

usage :: String
usage =
  L.unlines
    [ "usage: lockstep serve [--port N]"
    , "       lockstep db migrate [--backup FILE | --no-backup]"
    , "       lockstep db status"
    , "       lockstep operator sign-in [--port N]"
    , "       lockstep operator sign-out-all"
    , "       lockstep workspace show"
    , "       lockstep workspace rename --expected-revision N [--idempotency-key K] NAME"
    , ""
    , "  serve        run the local service on 127.0.0.1 (default port 8000)"
    , "  --port N     listen on port N (1-65535)"
    , "  db migrate   apply pending database migrations (needs a backup once any are applied)"
    , "  db status    show the database schema revision and pending migrations"
    , "  operator sign-in      print a one-time browser sign-in link (valid 5 minutes)"
    , "                        for the service on port N (default 8000)"
    , "  operator sign-out-all revoke every operator browser session"
    , "  workspace show        print the workspace name and revision"
    , "  workspace rename      rename the workspace if it is still at revision N; a repeated"
    , "                        command with the same key returns the same receipt"
    , ""
    , "The database is configured by the file named in LOCKSTEP_CONFIG."
    ]
