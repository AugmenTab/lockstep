module Lockstep.Foundation.Cli
  ( Command (..)
  , BackupPolicy (..)
  , CliError (..)
  , RenameArgs (..)
  , QueueArgs (..)
  , RegisterArgs (..)
  , ResolveArgs (..)
  , WorkOrderArgs (..)
  , EvidenceArgs (..)
  , ExecuteArgs (..)
  , EffectChoice (..)
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
  | JobQueue QueueArgs
  | JobShow Integer
  | EngineerAdd String
  | RepositoryRegister RegisterArgs
  | RepositoryList
  | ProfileAdd String
  | ProfileList
  | ProfileShow String (Maybe Integer)
  | RepositorySetProfile String String
  | ProfileResolve ResolveArgs
  | LedgerShow
  | TicketCreate String
  | TicketAccept String Integer
  | WorkOrderCreate WorkOrderArgs
  | WorkOrderEvidence EvidenceArgs
  | WorkOrderHalt String Integer String
  | WorkOrderRequeue String Integer
  | ScheduleRunOnce
  | SupervisorStart String Integer [String]
  | SupervisorExecuteOnce ExecuteArgs
  | SupervisorReconcileOnce
  | WorkUnitAdmit String (Maybe String)
  | EffectsResolve String Integer EffectChoice
  | EffectsAbandon String String
  | EffectsAbandonAcknowledged String String
  | EffectsCarry String Integer Integer Bool
  | SandboxShow
  deriving (Eq, Show)

-- | @work-order create@ options (contract C-P2.8 §5).
data WorkOrderArgs
  = WorkOrderArgs
  { orderTicket :: String
  , orderEngineer :: String
  , orderPriority :: Integer
  , orderKind :: String
  , orderClasses :: [String]
  , orderPathClasses :: [String]
  , orderNonBehavioural :: Maybe String
  }
  deriving (Eq, Show)

-- | @work-order evidence@ options (contract C-P2.8 §5).
data EvidenceArgs
  = EvidenceArgs
  { evidenceWorkOrder :: String
  , evidenceArtifactName :: String
  , evidenceDigestHex :: String
  , evidenceVerifiers :: [String]
  , evidenceApprovalName :: String
  }
  deriving (Eq, Show)

-- | @supervisor execute-once@ options (contract C-P2.8 §5).
data ExecuteArgs
  = ExecuteArgs
  { executeOwner :: String
  , executeLeaseSeconds :: Integer
  , executeTimeoutMs :: Integer
  }
  deriving (Eq, Show)

-- | The one choice of @effects resolve@ (contract C-P2.8 §5).
data EffectChoice
  = ChooseAttestApplied String
  | ChooseAttestNotApplied String
  | ChooseRetryAcknowledged
  deriving (Eq, Show)

-- | @profile resolve@ options (contract C-P2.3 F14).
data ResolveArgs
  = ResolveArgs
  { resolveEngineer :: String
  , resolveKind :: String
  , resolveClasses :: [String]
  , resolvePathClasses :: [String]
  , resolveNonBehavioural :: Maybe String
  }
  deriving (Eq, Show)

-- | @repository register@ options (contract C-P2.1 I10).
data RegisterArgs
  = RegisterArgs
  { registerEngineer :: String
  , registerRemote :: Maybe String
  , registerPath :: String
  }
  deriving (Eq, Show)

-- | @job queue@ options (contract C-P1.5 E6); ranges are checked by the application.
data QueueArgs
  = QueueArgs
  { queueExpected :: Integer
  , queueSteps :: Integer
  , queueStepMillis :: Integer
  , queueFailAt :: Maybe Integer
  , queueKey :: Maybe String
  }
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
  | InvalidNumber String String
  deriving (Eq, Show)

parseArgs :: [String] -> Either CliError Command
parseArgs args =
  case args of
    [] -> Left NoCommand
    "serve" : options -> fmap Serve (parseServeOptions options)
    "db" : rest -> parseDbCommand rest
    "operator" : rest -> parseOperatorCommand rest
    "workspace" : rest -> parseWorkspaceCommand rest
    "job" : rest -> parseJobCommand rest
    "engineer" : rest -> parseEngineerCommand rest
    "repository" : rest -> parseRepositoryCommand rest
    "profile" : rest -> parseProfileCommand rest
    "ledger" : rest -> parseLedgerCommand rest
    "ticket" : rest -> parseTicketCommand rest
    "work-order" : rest -> parseWorkOrderCommand rest
    "schedule" : rest -> parseScheduleCommand rest
    "supervisor" : rest -> parseSupervisorCommand rest
    "work-unit" : rest -> parseWorkUnitCommand rest
    "effects" : rest -> parseEffectsCommand rest
    "sandbox" : rest -> parseSandboxCommand rest
    command : _ -> Left (UnknownCommand command)

-- | Contract C-P2.1 I10.
parseEngineerCommand :: [String] -> Either CliError Command
parseEngineerCommand args =
  case args of
    [] -> Left (MissingSubcommand "engineer")
    ["add"] -> Left (MissingArgument "NAME")
    ["add", name] -> EngineerAdd name <$ noOption name
    "add" : _ : extra : _ -> Left (unexpected extra)
    command : _ -> Left (UnknownCommand ("engineer " <> command))

noOption :: String -> Either CliError ()
noOption arg =
  if "-" `L.isPrefixOf` arg
    then Left (UnknownOption arg)
    else Right ()

-- | Contract C-P2.1 I10.
parseRepositoryCommand :: [String] -> Either CliError Command
parseRepositoryCommand args =
  case args of
    [] -> Left (MissingSubcommand "repository")
    "register" : options -> fmap RepositoryRegister (parseRegisterOptions options)
    "list" : rest -> RepositoryList <$ noMoreArguments rest
    "set-profile" : options -> parseSetProfileOptions options
    command : _ -> Left (UnknownCommand ("repository " <> command))

engineerOption :: String
engineerOption =
  "--engineer"

authoritativeRemoteOption :: String
authoritativeRemoteOption =
  "--authoritative-remote"

parseRegisterOptions :: [String] -> Either CliError RegisterArgs
parseRegisterOptions =
  let
    names = [engineerOption, authoritativeRemoteOption]

    set option value acc =
      case L.lookup option acc of
        Just _ -> Left (DuplicateOption option)
        Nothing -> Right ((option, value) : acc)

    finish acc mbPath =
      case (L.lookup engineerOption acc, mbPath) of
        (Nothing, _) -> Left (MissingOption engineerOption)
        (_, Nothing) -> Left (MissingArgument "PATH")
        (Just engineer, Just path) -> Right (RegisterArgs engineer (L.lookup authoritativeRemoteOption acc) path)

    go acc mbPath options =
      case options of
        [] ->
          finish acc mbPath
        option : rest
          | option `L.elem` names ->
              case rest of
                [] -> Left (MissingOptionValue option)
                value : rest'
                  | L.null value -> Left (MissingOptionValue option)
                  | otherwise -> set option value acc >>= \acc' -> go acc' mbPath rest'
          | (name, '=' : value) <- L.break (== '=') option
          , name `L.elem` names ->
              if L.null value
                then Left (MissingOptionValue name)
                else set name value acc >>= \acc' -> go acc' mbPath rest
          | "-" `L.isPrefixOf` option ->
              Left (UnknownOption option)
          | otherwise ->
              case mbPath of
                Just _ -> Left (UnexpectedArgument option)
                Nothing -> go acc (Just option) rest
  in
    go [] Nothing

-- | Contract C-P2.3 F14.
parseProfileCommand :: [String] -> Either CliError Command
parseProfileCommand args =
  case args of
    [] -> Left (MissingSubcommand "profile")
    ["add"] -> Left (MissingArgument "FILE")
    ["add", file] -> ProfileAdd file <$ (if file == "-" then Right () else noOption file)
    "add" : _ : extra : _ -> Left (unexpected extra)
    "list" : rest -> ProfileList <$ noMoreArguments rest
    "show" : options -> parseShowOptions options
    "resolve" : options -> fmap ProfileResolve (parseResolveOptions options)
    command : _ -> Left (UnknownCommand ("profile " <> command))

{- | Options with values (@--name V@ or @--name=V@) and at most one positional
argument. Options in @repeatable@ may be given more than once; their values are
kept in order.
-}
parseOptionsAndArgument :: [String] -> [String] -> [String] -> Either CliError ([(String, String)], Maybe String)
parseOptionsAndArgument names repeatable =
  let
    set option value acc =
      if option `L.notElem` repeatable && option `L.elem` fmap fst acc
        then Left (DuplicateOption option)
        else Right (acc <> [(option, value)])

    go acc mbArgument options =
      case options of
        [] ->
          Right (acc, mbArgument)
        option : rest
          | option `L.elem` names ->
              case rest of
                [] -> Left (MissingOptionValue option)
                value : rest'
                  | L.null value -> Left (MissingOptionValue option)
                  | otherwise -> set option value acc >>= \acc' -> go acc' mbArgument rest'
          | (name, '=' : value) <- L.break (== '=') option
          , name `L.elem` names ->
              if L.null value
                then Left (MissingOptionValue name)
                else set name value acc >>= \acc' -> go acc' mbArgument rest
          | "-" `L.isPrefixOf` option ->
              Left (UnknownOption option)
          | otherwise ->
              case mbArgument of
                Just _ -> Left (UnexpectedArgument option)
                Nothing -> go acc (Just option) rest
  in
    go [] Nothing

parseShowOptions :: [String] -> Either CliError Command
parseShowOptions options = do
  (acc, mbId) <- parseOptionsAndArgument ["--version"] [] options
  profileId <- maybe (Left (MissingArgument "ID")) Right mbId
  version <- traverse (parseNumber "--version") (L.lookup "--version" acc)
  pure (ProfileShow profileId version)

parseSetProfileOptions :: [String] -> Either CliError Command
parseSetProfileOptions options = do
  (acc, mbProfile) <- parseOptionsAndArgument [engineerOption] [] options
  engineer <- maybe (Left (MissingOption engineerOption)) Right (L.lookup engineerOption acc)
  profile <- maybe (Left (MissingArgument "PROFILE")) Right mbProfile
  pure (RepositorySetProfile engineer profile)

parseResolveOptions :: [String] -> Either CliError ResolveArgs
parseResolveOptions options = do
  let
    repeatable = ["--class", "--path-class"]
  (acc, mbArgument) <- parseOptionsAndArgument ([engineerOption, "--kind", "--non-behavioural"] <> repeatable) repeatable options
  maybe (Right ()) (Left . UnexpectedArgument) mbArgument
  engineer <- maybe (Left (MissingOption engineerOption)) Right (L.lookup engineerOption acc)
  kind <- maybe (Left (MissingOption "--kind")) Right (L.lookup "--kind" acc)
  pure
    ResolveArgs
      { resolveEngineer = engineer
      , resolveKind = kind
      , resolveClasses = [value | ("--class", value) <- acc]
      , resolvePathClasses = [value | ("--path-class", value) <- acc]
      , resolveNonBehavioural = L.lookup "--non-behavioural" acc
      }

-- Ledger commands (contract C-P2.8 §5) -------------------------------------------

{- | Options with values, flags without, and at most one positional argument.
Options in @repeatable@ may be given more than once; their values are kept in
order. Returns the option values, the flags present and the argument.
-}
parseWithFlags :: [String] -> [String] -> [String] -> [String] -> Either CliError ([(String, String)], [String], Maybe String)
parseWithFlags names repeatable flags =
  let
    go acc seen mbArgument options =
      case options of
        [] -> Right (acc, L.reverse seen, mbArgument)
        option : rest
          | option `L.elem` flags ->
              if option `L.elem` seen
                then Left (DuplicateOption option)
                else go acc (option : seen) mbArgument rest
          | option `L.elem` names ->
              case rest of
                value : rest'
                  | not (L.null value) ->
                      if option `L.notElem` repeatable && option `L.elem` fmap fst acc
                        then Left (DuplicateOption option)
                        else go (acc <> [(option, value)]) seen mbArgument rest'
                _ -> Left (MissingOptionValue option)
          | "-" `L.isPrefixOf` option -> Left (UnknownOption option)
          | otherwise ->
              case mbArgument of
                Just _ -> Left (UnexpectedArgument option)
                Nothing -> go acc seen (Just option) rest
  in
    go [] [] Nothing

required :: String -> [(String, String)] -> Either CliError String
required option acc =
  maybe (Left (MissingOption option)) Right (L.lookup option acc)

argument :: String -> Maybe String -> Either CliError String
argument name =
  maybe (Left (MissingArgument name)) Right

noArgument :: Maybe String -> Either CliError ()
noArgument =
  maybe (Right ()) (Left . UnexpectedArgument)

expectedRevision :: [(String, String)] -> Either CliError Integer
expectedRevision acc =
  required expectedRevisionOption acc >>= parseNumber expectedRevisionOption

parseLedgerCommand :: [String] -> Either CliError Command
parseLedgerCommand args =
  case args of
    [] -> Left (MissingSubcommand "ledger")
    "show" : rest -> LedgerShow <$ noMoreArguments rest
    command : _ -> Left (UnknownCommand ("ledger " <> command))

parseTicketCommand :: [String] -> Either CliError Command
parseTicketCommand args =
  case args of
    [] -> Left (MissingSubcommand "ticket")
    "create" : options -> do
      (_, _, title) <- parseWithFlags [] [] [] options
      TicketCreate <$> argument "TITLE" title
    "accept" : options -> do
      (acc, _, ticket) <- parseWithFlags [expectedRevisionOption] [] [] options
      t <- argument "TICKET" ticket
      TicketAccept t <$> expectedRevision acc
    command : _ -> Left (UnknownCommand ("ticket " <> command))

parseWorkOrderCommand :: [String] -> Either CliError Command
parseWorkOrderCommand args =
  case args of
    [] -> Left (MissingSubcommand "work-order")
    "create" : options -> do
      let
        repeatable = ["--class", "--path-class"]
      (acc, _, extra) <- parseWithFlags (["--ticket", engineerOption, "--priority", "--kind", "--non-behavioural"] <> repeatable) repeatable [] options
      noArgument extra
      ticket <- required "--ticket" acc
      engineer <- required engineerOption acc
      priority <- required "--priority" acc >>= parseNumber "--priority"
      pure
        ( WorkOrderCreate
            WorkOrderArgs
              { orderTicket = ticket
              , orderEngineer = engineer
              , orderPriority = priority
              , orderKind = fromMaybe "engineering" (L.lookup "--kind" acc)
              , orderClasses = [value | ("--class", value) <- acc]
              , orderPathClasses = [value | ("--path-class", value) <- acc]
              , orderNonBehavioural = L.lookup "--non-behavioural" acc
              }
        )
    "evidence" : options -> do
      (acc, _, workOrder) <- parseWithFlags ["--artifact", "--digest", "--verifier", "--approval"] ["--verifier"] [] options
      w <- argument "WORK-ORDER" workOrder
      artifact <- required "--artifact" acc
      digest <- required "--digest" acc
      verifiers <- case [value | ("--verifier", value) <- acc] of
        [] -> Left (MissingOption "--verifier")
        vs -> Right vs
      approval <- required "--approval" acc
      pure (WorkOrderEvidence (EvidenceArgs w artifact digest verifiers approval))
    "halt" : options -> do
      (acc, _, workOrder) <- parseWithFlags [expectedRevisionOption, "--reason"] [] [] options
      w <- argument "WORK-ORDER" workOrder
      revision <- expectedRevision acc
      WorkOrderHalt w revision <$> required "--reason" acc
    "requeue" : options -> do
      (acc, _, workOrder) <- parseWithFlags [expectedRevisionOption] [] [] options
      w <- argument "WORK-ORDER" workOrder
      WorkOrderRequeue w <$> expectedRevision acc
    command : _ -> Left (UnknownCommand ("work-order " <> command))

parseScheduleCommand :: [String] -> Either CliError Command
parseScheduleCommand args =
  case args of
    [] -> Left (MissingSubcommand "schedule")
    "run-once" : rest -> ScheduleRunOnce <$ noMoreArguments rest
    command : _ -> Left (UnknownCommand ("schedule " <> command))

parseSupervisorCommand :: [String] -> Either CliError Command
parseSupervisorCommand args =
  case args of
    [] -> Left (MissingSubcommand "supervisor")
    "start" : options -> do
      (acc, _, workOrder) <- parseWithFlags [expectedRevisionOption, "--effect"] ["--effect"] [] options
      w <- argument "WORK-ORDER" workOrder
      revision <- expectedRevision acc
      pure (SupervisorStart w revision [value | ("--effect", value) <- acc])
    "execute-once" : options -> do
      (acc, _, extra) <- parseWithFlags ["--owner", "--lease-seconds", "--timeout-ms"] [] [] options
      noArgument extra
      lease <- maybe (Right 60) (parseNumber "--lease-seconds") (L.lookup "--lease-seconds" acc)
      timeoutMs <- maybe (Right 30000) (parseNumber "--timeout-ms") (L.lookup "--timeout-ms" acc)
      pure (SupervisorExecuteOnce (ExecuteArgs (fromMaybe "supervisor" (L.lookup "--owner" acc)) lease timeoutMs))
    "reconcile-once" : rest -> SupervisorReconcileOnce <$ noMoreArguments rest
    command : _ -> Left (UnknownCommand ("supervisor " <> command))

parseWorkUnitCommand :: [String] -> Either CliError Command
parseWorkUnitCommand args =
  case args of
    [] -> Left (MissingSubcommand "work-unit")
    "admit" : options -> do
      (acc, _, workOrder) <- parseWithFlags ["--plan-ref"] [] [] options
      w <- argument "WORK-ORDER" workOrder
      pure (WorkUnitAdmit w (L.lookup "--plan-ref" acc))
    command : _ -> Left (UnknownCommand ("work-unit " <> command))

acknowledgeOption :: String
acknowledgeOption =
  "--acknowledge-duplication-risk"

parseEffectsCommand :: [String] -> Either CliError Command
parseEffectsCommand args =
  case args of
    [] -> Left (MissingSubcommand "effects")
    "resolve" : options -> do
      (acc, flags, operation) <- parseWithFlags ["--generation", "--attest-applied", "--attest-not-applied"] [] ["--retry", acknowledgeOption] options
      o <- argument "OPERATION" operation
      generation <- required "--generation" acc >>= parseNumber "--generation"
      let
        chosen =
          [c | c <- ["--attest-applied", "--attest-not-applied"], c `L.elem` fmap fst acc]
            <> ["--retry" | "--retry" `L.elem` flags]
        acknowledged = acknowledgeOption `L.elem` flags
      choice <-
        case chosen of
          [] -> Left (MissingOption "--attest-applied")
          first : second : _ -> Left (ConflictingOptions first second)
          ["--retry"]
            | acknowledged -> Right ChooseRetryAcknowledged
            | otherwise -> Left (MissingOption acknowledgeOption)
          [option]
            | acknowledged -> Left (UnexpectedArgument acknowledgeOption)
            | option == "--attest-applied" -> ChooseAttestApplied <$> required option acc
            | otherwise -> ChooseAttestNotApplied <$> required option acc
      pure (EffectsResolve o generation choice)
    "abandon" : options -> do
      (acc, flags, operation) <- parseWithFlags ["--reason"] [] [acknowledgeOption] options
      o <- argument "OPERATION" operation
      reason <- required "--reason" acc
      pure $
        if acknowledgeOption `L.elem` flags
          then EffectsAbandonAcknowledged o reason
          else EffectsAbandon o reason
    "carry" : options -> do
      (acc, flags, operation) <- parseWithFlags ["--from-activation", "--to-activation"] [] [acknowledgeOption] options
      o <- argument "OPERATION" operation
      from <- required "--from-activation" acc >>= parseNumber "--from-activation"
      to <- required "--to-activation" acc >>= parseNumber "--to-activation"
      pure (EffectsCarry o from to (acknowledgeOption `L.elem` flags))
    command : _ -> Left (UnknownCommand ("effects " <> command))

parseSandboxCommand :: [String] -> Either CliError Command
parseSandboxCommand args =
  case args of
    [] -> Left (MissingSubcommand "sandbox")
    "show" : rest -> SandboxShow <$ noMoreArguments rest
    command : _ -> Left (UnknownCommand ("sandbox " <> command))

-- | Contract C-P1.5 E6.
parseJobCommand :: [String] -> Either CliError Command
parseJobCommand args =
  case args of
    [] -> Left (MissingSubcommand "job")
    "queue" : options -> fmap JobQueue (parseQueueOptions options)
    ["show"] -> Left (MissingArgument "JOB")
    ["show", job] -> JobShow <$> parseNumber "JOB" job
    "show" : _ : extra : _ -> Left (unexpected extra)
    command : _ -> Left (UnknownCommand ("job " <> command))

parseNumber :: String -> String -> Either CliError Integer
parseNumber name value =
  if not (L.null value) && L.length value <= 18 && L.all Char.isDigit value
    then Right (L.foldl' (\acc c -> acc * 10 + toInteger (Char.ord c - Char.ord '0')) 0 value)
    else Left (InvalidNumber name value)

parseQueueOptions :: [String] -> Either CliError QueueArgs
parseQueueOptions =
  let
    names = [expectedRevisionOption, "--steps", "--step-ms", "--fail-at-step", idempotencyKeyOption]

    set option value acc =
      case L.lookup option acc of
        Just _ -> Left (DuplicateOption option)
        Nothing -> Right ((option, value) : acc)

    finish acc = do
      expected <-
        maybe (Left (MissingOption expectedRevisionOption)) parseRevision (L.lookup expectedRevisionOption acc)
      steps <- maybe (Right 3) (parseNumber "--steps") (L.lookup "--steps" acc)
      millis <- maybe (Right 100) (parseNumber "--step-ms") (L.lookup "--step-ms" acc)
      failAt <- traverse (parseNumber "--fail-at-step") (L.lookup "--fail-at-step" acc)
      pure (QueueArgs expected steps millis failAt (L.lookup idempotencyKeyOption acc))

    go acc options =
      case options of
        [] ->
          finish acc
        option : rest
          | option `L.elem` names ->
              case rest of
                [] -> Left (MissingOptionValue option)
                value : rest'
                  | L.null value -> Left (MissingOptionValue option)
                  | otherwise -> set option value acc >>= \acc' -> go acc' rest'
          | (name, '=' : value) <- L.break (== '=') option
          , name `L.elem` names ->
              if L.null value
                then Left (MissingOptionValue name)
                else set name value acc >>= \acc' -> go acc' rest
          | otherwise ->
              Left (unexpected option)
  in
    go []

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
    InvalidNumber name value -> name <> ": not a valid number: " <> value

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
    , "       lockstep job queue --expected-revision N [--steps S] [--step-ms M] [--fail-at-step K] [--idempotency-key K]"
    , "       lockstep job show JOB"
    , "       lockstep engineer add NAME"
    , "       lockstep repository register --engineer NAME [--authoritative-remote REMOTE] PATH"
    , "       lockstep repository list"
    , "       lockstep repository set-profile --engineer NAME PROFILE"
    , "       lockstep profile add FILE|-"
    , "       lockstep profile list"
    , "       lockstep profile show ID [--version N]"
    , "       lockstep profile resolve --engineer NAME --kind KIND [--class TAG]... [--path-class CLASS]... [--non-behavioural RATIONALE]"
    , "       lockstep ledger show"
    , "       lockstep ticket create TITLE"
    , "       lockstep ticket accept TICKET --expected-revision N"
    , "       lockstep work-order create --ticket TICKET --engineer NAME --priority N [--kind KIND] [--class TAG]... [--path-class CLASS]... [--non-behavioural RATIONALE]"
    , "       lockstep work-order evidence WORK-ORDER --artifact A --digest HEX --verifier V... --approval none|supervisor|human"
    , "       lockstep work-order halt WORK-ORDER --expected-revision N --reason TEXT"
    , "       lockstep work-order requeue WORK-ORDER --expected-revision N"
    , "       lockstep schedule run-once"
    , "       lockstep supervisor start WORK-ORDER --expected-revision N [--effect NAME[:MODE]]..."
    , "       lockstep supervisor execute-once [--owner O] [--lease-seconds N] [--timeout-ms N]"
    , "       lockstep supervisor reconcile-once"
    , "       lockstep work-unit admit WORK-ORDER [--plan-ref REF]"
    , "       lockstep effects resolve OPERATION --generation G (--attest-applied E | --attest-not-applied E | --retry --acknowledge-duplication-risk)"
    , "       lockstep effects abandon OPERATION --reason TEXT [--acknowledge-duplication-risk]"
    , "       lockstep effects carry OPERATION --from-activation S --to-activation T [--acknowledge-duplication-risk]"
    , "       lockstep sandbox show"
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
    , "  job queue             queue a model-free no-op job; lockstep serve runs it"
    , "  job show              print a job's state and progress"
    , "  engineer add          add an Engineer (name: a-z, 0-9 and -, up to 40 characters)"
    , "  repository register   give an Engineer exclusive ownership of the Git repository whose"
    , "                        main worktree is PATH; with several remotes, name the"
    , "                        repository's own with --authoritative-remote"
    , "  repository list       print every owned repository"
    , "  repository set-profile  make PROFILE the default SDLC Profile of the Engineer's repository"
    , "  profile add           register a versioned SDLC Profile document (JSON; - reads standard input)"
    , "  profile list          print every registered Profile version and its digest"
    , "  profile show          print a Profile's canonical rendering and digest (default: the latest version)"
    , "  profile resolve       print the effective Profile the Engineer's repository would bind for this work"
    , "  ledger show           print the durable ledger: tickets, work orders, effects with their status, refusals"
    , "  ticket, work-order, work-unit, effects   the operator's (Human) decisions on the ledger"
    , "  schedule run-once     run the deterministic scheduler once"
    , "  supervisor            run Lockstep's own deterministic supervisor steps once: start a"
    , "                        claimed work order with sandbox effects, execute or recover one"
    , "                        effect, reconcile one uncertain effect (model-free; no daemon)"
    , "  sandbox show          print the sandbox destination's applications per operation"
    , ""
    , "The database is configured by the file named in LOCKSTEP_CONFIG."
    ]
