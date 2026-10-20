{- | Composition root (ARCHITECTURE §2): parses the command line, loads the
operator configuration, builds the runtime resources and runs the subcommand.
-}
module Main
  ( main
  ) where

import Control.Exception.Safe (finally)
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Network.Wai.Handler.Warp qualified as Warp
import System.Environment (getArgs, lookupEnv)
import System.Exit (ExitCode (ExitFailure), exitWith)
import System.IO (hPutStr, hPutStrLn, putStr, putStrLn, stderr)
import System.Log.FastLogger qualified as FL
import Text.Show (show)

import Lockstep.Application.Command
  ( Actor (ActorCli)
  , CommandEnvelope
  , CommandRefusal (..)
  , Outcome (..)
  , Receipt (..)
  , WorkspaceState (..)
  , buildQueue
  , buildRename
  , generateIdempotencyKey
  , idempotencyKeyText
  , outcomeCode
  , readWorkspace
  , renderInvalidReason
  , revisionInt
  , submitCommand
  )
import Lockstep.Application.Database
  ( DatabaseRuntime
  , MigrateError (..)
  , NotReadyReason
  , Readiness (..)
  , SchemaStatus (..)
  , checkReadiness
  , closeDatabase
  , migrateWithPolicy
  , openDatabase
  , readinessCode
  , recordServiceStart
  , renderMigrateError
  , revisionNumber
  , schemaStatus
  )
import Lockstep.Application.Dispatcher (Job (..), findJob, findJobForReceipt, jobStateCode, requestStop, startDispatcher, stopDispatcher)
import Lockstep.Application.Executor (Executor (..), RunOutcome (..), executeOnce, noExecutorFaults)
import Lockstep.Application.Ledger
  ( LedgerFailure (..)
  , NewWorkOrder (..)
  , ScheduleReceipt (..)
  , WorkOrderView (..)
  , abandonIntentAcknowledged
  , admitWorkUnit
  , carryIntentChecked
  , createTicket
  , createWorkOrder
  , decideTicket
  , decideWorkOrder
  , gateEvidenceNamed
  , intentActivation
  , noFaults
  , recordGateEvidence
  , resolveOutcome
  , scheduleOnce
  , showWorkOrder
  )
import Lockstep.Application.Ledger qualified as Ledger
import Lockstep.Application.LedgerView (projectLedger, projectionTimeText, renderProjection)
import Lockstep.Application.OperatorTrust (issueSignIn, revokeAllSessions, signInUrl)
import Lockstep.Application.Profiles
  ( AddOutcome (..)
  , ProfileFailure (..)
  , ResolveRequest (..)
  , StoredProfile (..)
  , addProfile
  , listProfiles
  , readProfileDocument
  , resolveForEngineer
  , setRepositoryProfile
  , showProfile
  )
import Lockstep.Application.Reconciler (ReconcileOutcome (..), Reconciliation (..), reconcileOnce)
import Lockstep.Application.Repositories
  ( EngineerRecord (..)
  , Refused (..)
  , RegisterRequest (..)
  , RepositoryRecord (..)
  , addEngineer
  , listRepositories
  , registerRepository
  )
import Lockstep.Application.Sandbox (sandboxAdapters, sandboxApplications, sandboxReconcilers, sandboxRequest)
import Lockstep.Foundation.Cli
  ( BackupPolicy
  , Command (..)
  , EffectChoice (..)
  , EvidenceArgs (..)
  , ExecuteArgs (..)
  , QueueArgs (..)
  , RegisterArgs (..)
  , RenameArgs (..)
  , ResolveArgs (..)
  , WorkOrderArgs (..)
  , parseArgs
  , renderCliError
  , usage
  )
import Lockstep.Foundation.Config (Port, ServeConfig (..), bindHostAddress, portNumber)
import Lockstep.Foundation.SystemConfig
  ( SystemConfig (..)
  , loadSystemConfig
  , renderConfigError
  )
import Lockstep.Kernel.Effect (Intent (..), IntentRequest (..), OperationId (..), effectKeyText, intentStateName)
import Lockstep.Kernel.Identity (EngineerId (..), TicketId (..), Uuid, WorkOrderId (..), WorkUnitId (..), parseUuid, uuidText)
import Lockstep.Kernel.Reconciliation (Resolution (..))
import Lockstep.Kernel.Ticket qualified as Ticket
import Lockstep.Kernel.Transition qualified as K
import Lockstep.Kernel.WorkOrder (Claim (..), WorkOrderInput (..), WorkOrderState (..), parseWorkOrderKind)
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Web.Application (applicationWith)
import Lockstep.Web.Server (serverSettingsWith)

main :: IO ()
main = do
  refuseFaultPlan
  args <- getArgs
  case parseArgs args of
    Left err -> do
      hPutStrLn stderr ("lockstep: " <> renderCliError err)
      hPutStr stderr usage
      exitWith (ExitFailure 64)
    Right (Serve serveConfig) ->
      serve serveConfig
    Right (DbMigrate policy) ->
      withRequiredDatabase (dbMigrate policy)
    Right DbStatus ->
      withRequiredDatabase dbStatus
    Right (OperatorSignIn port) ->
      withRequiredDatabase (operatorSignIn port)
    Right OperatorSignOutAll ->
      withRequiredDatabase operatorSignOutAll
    Right WorkspaceShow ->
      withRequiredDatabase workspaceShow
    Right (WorkspaceRename renameArgs) ->
      withRequiredDatabase (workspaceRename renameArgs)
    Right (JobQueue queueArgs) ->
      withRequiredDatabase (jobQueue queueArgs)
    Right (JobShow job) ->
      withRequiredDatabase (jobShow job)
    Right (EngineerAdd name) ->
      withRequiredDatabase (engineerAdd name)
    Right (RepositoryRegister registerArgs) ->
      withRequiredDatabase (repositoryRegister registerArgs)
    Right RepositoryList ->
      withRequiredDatabase repositoryList
    Right (ProfileAdd file) ->
      withRequiredDatabase (profileAdd file)
    Right ProfileList ->
      withRequiredDatabase profileList
    Right (ProfileShow profileId version) ->
      withRequiredDatabase (profileShow profileId version)
    Right (RepositorySetProfile engineer profileId) ->
      withRequiredDatabase (repositorySetProfile engineer profileId)
    Right (ProfileResolve resolveArgs) ->
      withRequiredDatabase (profileResolve resolveArgs)
    Right command ->
      -- C-P2.8 §5: the ledger commands (every other command is matched above).
      withRequiredDatabase (ledgerCommand command)

{- | C-P1.7 E4: this build has no fault-injection flag, so a fault plan is
refused before arguments, configuration or the database are read.
-}
refuseFaultPlan :: IO ()
refuseFaultPlan = do
  plan <- lookupEnv "LOCKSTEP_FAULT_PLAN"
  case plan of
    Nothing -> pure ()
    Just _ -> do
      hPutStrLn stderr "lockstep: fault plans are not accepted by this build (no fault-injection flag)"
      exitWith (ExitFailure 78)

configVariable :: String
configVariable =
  "LOCKSTEP_CONFIG"

-- | Nothing when LOCKSTEP_CONFIG is unset; exits 66 when it names a bad file.
loadOptionalDatabase :: IO (Maybe DatabaseRuntime)
loadOptionalDatabase = do
  mbPath <- lookupEnv configVariable
  case mbPath of
    Nothing ->
      pure Nothing
    Just path -> do
      loaded <- loadSystemConfig path
      case loaded of
        Left err -> do
          hPutStrLn stderr ("lockstep: " <> renderConfigError err)
          exitWith (ExitFailure 66)
        Right config ->
          Just <$> openDatabase (databaseConfig config)

withRequiredDatabase :: (DatabaseRuntime -> IO ()) -> IO ()
withRequiredDatabase action = do
  mbRuntime <- loadOptionalDatabase
  case mbRuntime of
    Nothing -> do
      hPutStrLn stderr ("lockstep: " <> configVariable <> " is not set; it must name the database configuration file")
      exitWith (ExitFailure 66)
    Just runtime ->
      action runtime `finally` closeDatabase runtime

serve :: ServeConfig -> IO ()
serve serveConfig = do
  mbRuntime <- loadOptionalDatabase
  (appLogger, finishLogger) <- FL.newFastLogger (FL.LogStdout FL.defaultBufSize)
  let
    logLine message =
      appLogger (FL.toLogStr (message <> "\n"))
  readiness <- checkReadiness mbRuntime
  logLine ("Database readiness: " <> T.unpack (readinessCode readiness))
  dispatcher <-
    case (readiness, mbRuntime) of
      (Ready _, Just runtime) -> do
        recorded <- recordServiceStart runtime
        case recorded of
          Right () -> logLine "Service start recorded"
          Left reason -> logLine ("Service start not recorded: " <> show reason)
        -- C-P1.5 E4: background execution of queued jobs.
        Just <$> startDispatcher runtime logLine
      _ ->
        pure Nothing
  let
    address =
      bindHostAddress (serveHost serveConfig)
        <> ":"
        <> show (portNumber (servePort serveConfig))
    -- C-P1.3 E11: Warp's default handler can print a malformed request line
    -- (and so a query string); log a fixed line instead.
    onException _ err =
      when (Warp.defaultShouldDisplayException err) $
        logLine "EXCEPTION warp: a request failed in the HTTP layer"
    settings =
      Warp.setOnException onException
        . Warp.setBeforeMainLoop (logLine ("Listening on " <> address))
        $ serverSettingsWith (traverse_ requestStop dispatcher) serveConfig
  Warp.runSettings settings (applicationWith serveConfig mbRuntime appLogger)
    `finally` (traverse_ stopDispatcher dispatcher >> traverse_ closeDatabase mbRuntime >> finishLogger)

dbMigrate :: BackupPolicy -> DatabaseRuntime -> IO ()
dbMigrate policy runtime = do
  result <- migrateWithPolicy policy migrations runtime
  case result of
    Right [] ->
      putStrLn "nothing to apply: the database is at this binary's schema revision"
    Right applied ->
      putStrLn ("applied migrations: " <> L.intercalate ", " (fmap (show . revisionNumber) applied))
    Left err -> do
      hPutStrLn stderr ("lockstep: " <> renderMigrateError err)
      exitWith (ExitFailure (migrateExitCode err))

-- | sysexits-style codes for the db migrate refusals.
migrateExitCode :: MigrateError -> Int
migrateExitCode err =
  case err of
    MigrateRefused _ -> 65
    MigrateFailed _ _ -> 70
    BackupRequired -> 75
    BackupMissing _ -> 75
    BackupStale _ -> 75
    MigrateNotReady _ -> 69

dbStatus :: DatabaseRuntime -> IO ()
dbStatus runtime = do
  readiness <- checkReadiness (Just runtime)
  putStrLn ("readiness " <> T.unpack (readinessCode readiness))
  status <- schemaStatus runtime
  case status of
    Left _ ->
      exitWith (ExitFailure 69)
    Right (SchemaStatus applied pending) -> do
      putStrLn ("revision " <> maybe "none" (show . revisionNumber) applied)
      putStrLn ("pending " <> show pending)

-- | C-P1.3 E2: prints exactly one line, the sign-in URL. Not ready: exit 69.
operatorSignIn :: Port -> DatabaseRuntime -> IO ()
operatorSignIn port runtime = do
  result <- issueSignIn runtime
  case result of
    Left reason ->
      notReady reason
    Right token ->
      putStrLn (T.unpack (signInUrl port token))

-- | C-P1.3 E9.
operatorSignOutAll :: DatabaseRuntime -> IO ()
operatorSignOutAll runtime = do
  result <- revokeAllSessions runtime
  case result of
    Left reason ->
      notReady reason
    Right n ->
      putStrLn ("revoked sessions: " <> show n)

notReady :: NotReadyReason -> IO ()
notReady reason = do
  hPutStrLn stderr ("lockstep: " <> T.unpack (readinessCode (NotReady reason)))
  exitWith (ExitFailure 69)

-- | C-P1.4 E8.
workspaceShow :: DatabaseRuntime -> IO ()
workspaceShow runtime = do
  result <- readWorkspace runtime
  case result of
    Left reason ->
      notReady reason
    Right workspace -> do
      putStrLn ("name: " <> T.unpack (workspaceName workspace))
      putStrLn ("revision: " <> show (revisionInt (workspaceRevision workspace)))

-- | C-P1.4 E8: builds the envelope and calls the shared operation.
workspaceRename :: RenameArgs -> DatabaseRuntime -> IO ()
workspaceRename args runtime = do
  key <- maybe (idempotencyKeyText <$> generateIdempotencyKey) (pure . T.pack) (renameKey args)
  case buildRename ActorCli key (renameExpected args) (T.pack (renameName args)) of
    Left reason ->
      refuse ("invalid command: " <> renderInvalidReason reason)
    Right envelope ->
      submitAndReport runtime envelope (renameExpected args)

-- | C-P1.5 E6: queues a no-op job; @lockstep serve@ runs it.
jobQueue :: QueueArgs -> DatabaseRuntime -> IO ()
jobQueue args runtime = do
  key <- maybe (idempotencyKeyText <$> generateIdempotencyKey) (pure . T.pack) (queueKey args)
  case buildQueue ActorCli key (queueExpected args) (queueSteps args) (queueStepMillis args) (queueFailAt args) of
    Left reason ->
      refuse ("invalid command: " <> renderInvalidReason reason)
    Right envelope ->
      submitAndReport runtime envelope (queueExpected args)

jobShow :: Integer -> DatabaseRuntime -> IO ()
jobShow ident runtime = do
  found <- findJob runtime (fromInteger ident)
  case found of
    Nothing ->
      refuse ("no job " <> show ident)
    Just job -> do
      putStrLn
        ( "job "
            <> show (jobId job)
            <> " "
            <> T.unpack (jobStateCode (jobState job))
            <> " steps "
            <> show (jobStepsDone job)
            <> "/"
            <> show (jobStepsTotal job)
            <> " attempts "
            <> show (jobAttempts job)
        )
      traverse_ (\err -> putStrLn ("error: " <> T.unpack err)) (jobError job)

-- | Submits through the shared operation and prints the receipt (C-P1.4 E8).
submitAndReport :: DatabaseRuntime -> CommandEnvelope -> Integer -> IO ()
submitAndReport runtime envelope expected = do
  result <- submitCommand runtime envelope
  case result of
    Right receipt -> do
      suffix <-
        case receiptOutcome receipt of
          Queued -> maybe "" (\job -> " job " <> show (jobId job)) <$> findJobForReceipt runtime (receiptId receipt)
          _ -> pure ""
      putStrLn (receiptLine receipt suffix)
      case receiptOutcome receipt of
        Applied -> pure ()
        Queued -> pure ()
        RefusedStale ->
          refuse
            ( "refused: stale revision (expected "
                <> show expected
                <> ", current "
                <> show (revisionInt (receiptRevision receipt))
                <> ")"
            )
    Left CommandKeyConflict ->
      refuse "refused: this idempotency key was already used for a different command"
    Left (CommandInvalid reason) ->
      refuse ("invalid command: " <> renderInvalidReason reason)
    Left (CommandNotReady reason) ->
      notReady reason

receiptLine :: Receipt -> String -> String
receiptLine receipt suffix =
  "receipt "
    <> show (receiptId receipt)
    <> " "
    <> T.unpack (outcomeCode (receiptOutcome receipt))
    <> " revision "
    <> show (revisionInt (receiptRevision receipt))
    <> " key "
    <> T.unpack (receiptKey receipt)
    <> suffix
    <> (if receiptReplayed receipt then " (replayed)" else "")

refuse :: String -> IO ()
refuse message = do
  hPutStrLn stderr ("lockstep: " <> message)
  exitWith (ExitFailure 65)

-- | C-P2.1 I10.
engineerAdd :: String -> DatabaseRuntime -> IO ()
engineerAdd name runtime = do
  result <- addEngineer runtime (T.pack name)
  case result of
    Left reason -> notReady reason
    Right (Left refused) -> refusal refused
    Right (Right engineer) ->
      let
        EngineerId uuid = engineerRecordId engineer
      in
        putStrLn ("engineer " <> T.unpack (uuidText uuid) <> " " <> T.unpack (engineerRecordName engineer))

-- | C-P2.1 I10: observes in this process's filesystem view, then decides.
repositoryRegister :: RegisterArgs -> DatabaseRuntime -> IO ()
repositoryRegister args runtime = do
  result <-
    registerRepository
      runtime
      RegisterRequest
        { registrationEngineer = T.pack (registerEngineer args)
        , registrationPath = registerPath args
        , registrationRemote = fmap T.pack (registerRemote args)
        }
  case result of
    Left reason -> notReady reason
    Right (Left refused) -> refusal refused
    Right (Right repository) -> putStrLn (repositoryLine repository)

repositoryList :: DatabaseRuntime -> IO ()
repositoryList runtime = do
  result <- listRepositories runtime
  case result of
    Left reason -> notReady reason
    Right repositories -> traverse_ (putStrLn . repositoryLine) repositories

repositoryLine :: RepositoryRecord -> String
repositoryLine repository =
  "repository "
    <> T.unpack (repositoryRecordId repository)
    <> " owner "
    <> T.unpack (repositoryRecordOwner repository)
    <> " authoritative "
    <> maybe "none" (\(name, identity) -> T.unpack name <> "=" <> T.unpack identity) (repositoryRecordAuthoritative repository)
    <> " common-dir "
    <> T.unpack (repositoryRecordCommonDir repository)

-- | A recorded refusal: the code and decision on stdout, the reason on stderr; exit 65.
refusal :: Refused -> IO ()
refusal refused = do
  putStrLn ("refused " <> T.unpack (refusedCode refused) <> " decision " <> show (refusedDecision refused))
  refuse ("refused (" <> T.unpack (refusedCode refused) <> "): " <> T.unpack (refusedMessage refused))

-- | C-P2.3 F14: a refusal (exit 65, with its decision when one was recorded) or an integrity failure (exit 70).
profileFailure :: ProfileFailure -> IO ()
profileFailure failure =
  case failure of
    ProfileRefused code message decision -> do
      putStrLn ("refused " <> T.unpack code <> maybe "" (\n -> " decision " <> show n) decision)
      refuse ("refused (" <> T.unpack code <> "): " <> T.unpack message)
    ProfileIntegrity message -> do
      hPutStrLn stderr ("lockstep: integrity failure: " <> T.unpack message)
      exitWith (ExitFailure 70)

storedLine :: StoredProfile -> String
storedLine stored =
  "profile " <> T.unpack (storedId stored) <> " version " <> show (storedVersion stored) <> " digest " <> T.unpack (storedDigest stored)

profileAdd :: String -> DatabaseRuntime -> IO ()
profileAdd file runtime = do
  bytes <- readProfileDocument file
  case bytes of
    Left err -> do
      hPutStrLn stderr ("lockstep: cannot read " <> file <> ": " <> err)
      exitWith (ExitFailure 66)
    Right document -> do
      result <- addProfile runtime document
      case result of
        Left reason -> notReady reason
        Right (Left failure) -> profileFailure failure
        Right (Right (stored, outcome)) ->
          putStrLn (storedLine stored <> (case outcome of Added -> " added"; Unchanged -> " unchanged"))

profileList :: DatabaseRuntime -> IO ()
profileList runtime = do
  result <- listProfiles runtime
  case result of
    Left reason -> notReady reason
    Right stored -> traverse_ (putStrLn . storedLine) stored

-- | A rendering followed by its digest line.
rendered :: (T.Text, T.Text) -> IO ()
rendered (rendering, digest) = do
  putStr (T.unpack rendering)
  putStrLn ("digest " <> T.unpack digest)

profileShow :: String -> Maybe Integer -> DatabaseRuntime -> IO ()
profileShow profileId version runtime = do
  result <- showProfile runtime (T.pack profileId) version
  case result of
    Left reason -> notReady reason
    Right (Left failure) -> profileFailure failure
    Right (Right shown) -> rendered shown

repositorySetProfile :: String -> String -> DatabaseRuntime -> IO ()
repositorySetProfile engineer profileId runtime = do
  result <- setRepositoryProfile runtime (T.pack engineer) (T.pack profileId)
  case result of
    Left reason -> notReady reason
    Right (Left failure) -> profileFailure failure
    Right (Right repositoryId) -> putStrLn ("repository " <> T.unpack repositoryId <> " default-profile " <> profileId)

profileResolve :: ResolveArgs -> DatabaseRuntime -> IO ()
profileResolve args runtime = do
  result <-
    resolveForEngineer
      runtime
      ResolveRequest
        { resolveRequestEngineer = T.pack (resolveEngineer args)
        , resolveRequestKind = T.pack (resolveKind args)
        , resolveRequestClasses = fmap T.pack (resolveClasses args)
        , resolveRequestPathClasses = fmap T.pack (resolvePathClasses args)
        , resolveRequestNonBehavioural = fmap T.pack (resolveNonBehavioural args)
        }
  case result of
    Left reason -> notReady reason
    Right (Left failure) -> profileFailure failure
    Right (Right effective) -> rendered effective

-- Ledger commands (C-P2.8 §5) -------------------------------------------------------

-- | Prints the lines, or reports the failure: a refusal exits 65, an integrity failure 70, an unavailable database 69.
ledgerOutcome :: Either LedgerFailure [String] -> IO ()
ledgerOutcome result =
  case result of
    Right ls -> traverse_ putStrLn ls
    Left (LedgerRefused code message) -> do
      putStrLn ("refused " <> T.unpack code)
      refuse ("refused (" <> T.unpack code <> "): " <> T.unpack message)
    Left (LedgerIntegrity message) -> do
      hPutStrLn stderr ("lockstep: integrity failure: " <> T.unpack message)
      exitWith (ExitFailure 70)
    Left (LedgerUnavailable code) -> do
      hPutStrLn stderr ("lockstep: " <> T.unpack code)
      exitWith (ExitFailure 69)

-- | An id argument; one that is not a UUID is a usage error (exit 64).
uuidArgument :: String -> IO Uuid
uuidArgument text =
  case parseUuid (T.pack text) of
    Right u -> pure u
    Left _ -> do
      hPutStrLn stderr ("lockstep: not an id (a UUID): " <> text)
      hPutStr stderr usage
      exitWith (ExitFailure 64)

ledgerCommand :: Command -> DatabaseRuntime -> IO ()
ledgerCommand command runtime =
  case command of
    LedgerShow -> do
      projected <- projectLedger runtime
      ledgerOutcome $
        fmap
          ( \p ->
              ("as of " <> T.unpack (projectionTimeText p))
                : fmap T.unpack (T.lines (renderProjection p))
          )
          projected
    TicketCreate title -> do
      created <- createTicket runtime (T.pack title)
      ledgerOutcome (fmap (\(TicketId u) -> ["ticket " <> uuidString u]) created)
    TicketAccept ticket expected -> do
      u <- uuidArgument ticket
      receipt <- decideTicket runtime noFaults (TicketId u) (fromInteger expected) (K.Command K.Human Ticket.TicketAccept)
      ledgerOutcome (fmap (\r -> ["ticket " <> uuidString u <> receiptText r]) receipt)
    WorkOrderCreate args -> do
      u <- uuidArgument (orderTicket args)
      case parseWorkOrderKind (T.pack (orderKind args)) of
        Nothing -> ledgerOutcome (Left (LedgerRefused (T.pack "invalid-kind") (T.pack ("no work order kind " <> orderKind args))))
        Just kind -> do
          created <-
            createWorkOrder
              runtime
              NewWorkOrder
                { newTicket = TicketId u
                , newEngineer = T.pack (orderEngineer args)
                , newKind = kind
                , newPriority = fromInteger (orderPriority args)
                , newDependencies = []
                , newClasses = fmap T.pack (orderClasses args)
                , newPathClasses = fmap T.pack (orderPathClasses args)
                , newNonBehavioural = fmap T.pack (orderNonBehavioural args)
                }
          ledgerOutcome (fmap (\(WorkOrderId w) -> ["work-order " <> uuidString w]) created)
    WorkOrderEvidence args -> do
      w <- uuidArgument (evidenceWorkOrder args)
      case gateEvidenceNamed (T.pack (evidenceArtifactName args)) (T.pack (evidenceDigestHex args)) (fmap T.pack (evidenceVerifiers args)) (T.pack (evidenceApprovalName args)) of
        Left failure -> ledgerOutcome (Left failure)
        Right gate -> do
          recorded <- recordGateEvidence runtime K.Human (WorkOrderId w) gate
          ledgerOutcome (fmap (const ["evidence " <> uuidString w <> " " <> evidenceArtifactName args]) recorded)
    WorkOrderHalt workOrder expected reason ->
      orderDecision workOrder expected (K.Command K.Human (WoHalt (T.pack reason)))
    WorkOrderRequeue workOrder expected ->
      orderDecision workOrder expected (K.Command K.Human WoRequeue)
    ScheduleRunOnce -> do
      scheduled <- scheduleOnce runtime
      ledgerOutcome $
        fmap
          ( \r ->
              fmap T.unpack (T.lines (scheduleRendering r))
                <> ["digest " <> T.unpack (scheduleDigestText r)]
                <> [ case scheduleClaimed r of
                       Just (WorkOrderId w, c) -> "selected " <> uuidString w <> " generation " <> show (claimGeneration c)
                       Nothing -> "selected none"
                   ]
          )
          scheduled
    SupervisorStart workOrder expected effects -> do
      w <- uuidArgument workOrder
      case traverse (sandboxRequest . T.pack) effects of
        Left failure -> ledgerOutcome (Left failure)
        Right requests -> do
          shown <- showWorkOrder runtime (WorkOrderId w)
          case fmap woState shown of
            Left failure -> ledgerOutcome (Left failure)
            Right (Claimed c) -> do
              receipt <- decideWorkOrder runtime noFaults (WorkOrderId w) (fromInteger expected) (K.Command K.Supervisor (WoStart c)) requests
              ledgerOutcome $
                fmap
                  ( \r ->
                      ("work-order " <> uuidString w <> receiptText r)
                        : L.zipWith (\(OperationId o) request -> "intent " <> uuidString o <> " effect " <> T.unpack (effectKeyText (requestKey request))) (Ledger.receiptOperations r) requests
                  )
                  receipt
            Right _ -> ledgerOutcome (Left (LedgerRefused (T.pack "work-order-not-claimed") (T.pack "only a claimed work order can be started")))
    SupervisorExecuteOnce args -> do
      adapters <- sandboxAdapters runtime
      let
        executor = Executor (T.pack (executeOwner args)) (fromInteger (executeLeaseSeconds args)) (fromInteger (executeTimeoutMs args)) adapters
      executed <- executeOnce runtime executor noExecutorFaults
      ledgerOutcome $
        fmap
          ( \r -> case r of
              Nothing -> ["idle"]
              Just (OperationId o, outcome) -> ["executed " <> uuidString o <> " " <> runText outcome]
          )
          executed
    SupervisorReconcileOnce -> do
      reconcilers <- sandboxReconcilers runtime
      reconciled <- reconcileOnce runtime (Reconciliation 5000 reconcilers)
      ledgerOutcome $
        fmap
          ( \r -> case r of
              Nothing -> ["idle"]
              Just (OperationId o, outcome) -> ["reconciled " <> uuidString o <> " " <> reconcileText outcome]
          )
          reconciled
    WorkUnitAdmit workOrder planRef -> do
      w <- uuidArgument workOrder
      admitted <- admitWorkUnit runtime (WorkOrderId w) (fmap T.pack planRef)
      ledgerOutcome (fmap (\(WorkUnitId u) -> ["work-unit " <> uuidString u]) admitted)
    EffectsResolve operation generation choice -> do
      o <- uuidArgument operation
      let
        resolution =
          case choice of
            ChooseAttestApplied e -> AttestApplied (T.pack e)
            ChooseAttestNotApplied e -> AttestNotApplied (T.pack e)
            ChooseRetryAcknowledged -> RetryAcknowledgingDuplication True
      resolved <- resolveOutcome runtime (OperationId o) (fromInteger generation) resolution
      ledgerOutcome (fmap (\i -> ["intent " <> uuidString o <> " state " <> T.unpack (intentStateName (intentState i)) <> " generation " <> show (intentGeneration i)]) resolved)
    EffectsAbandon operation reason -> abandon operation reason False
    EffectsAbandonAcknowledged operation reason -> abandon operation reason True
    EffectsCarry operation from to acknowledged -> do
      o <- uuidArgument operation
      carried <- carryIntentChecked runtime K.Human (OperationId o) (Just (fromInteger from, fromInteger to)) acknowledged
      case carried of
        Left failure -> ledgerOutcome (Left failure)
        Right _ -> do
          activation <- intentActivation runtime (OperationId o)
          ledgerOutcome (fmap (\g -> ["intent " <> uuidString o <> " carried to activation " <> show g]) activation)
    SandboxShow -> do
      applications <- sandboxApplications runtime
      ledgerOutcome (fmap (fmap (\(OperationId o, effect, n) -> "application " <> uuidString o <> " effect " <> T.unpack effect <> " count " <> show n)) applications)
    _ -> do
      hPutStr stderr usage
      exitWith (ExitFailure 64)
 where
  abandon operation reason acknowledged = do
    o <- uuidArgument operation
    abandoned <- abandonIntentAcknowledged runtime (OperationId o) (T.pack reason) acknowledged
    ledgerOutcome (fmap (\i -> ["intent " <> uuidString o <> " state " <> T.unpack (intentStateName (intentState i))]) abandoned)
  orderDecision workOrder expected decision = do
    w <- uuidArgument workOrder
    receipt <- decideWorkOrder runtime noFaults (WorkOrderId w) (fromInteger expected) decision []
    ledgerOutcome (fmap (\r -> ["work-order " <> uuidString w <> receiptText r]) receipt)

uuidString :: Uuid -> String
uuidString =
  T.unpack . uuidText

receiptText :: Ledger.Receipt -> String
receiptText r =
  " revision " <> show (Ledger.receiptRevision r) <> " state " <> T.unpack (Ledger.receiptState r)

runText :: RunOutcome -> String
runText outcome =
  case outcome of
    RanApplied r -> "applied " <> T.unpack r
    RanNotApplied r -> "not-applied " <> T.unpack r
    RanExhausted r -> "exhausted " <> T.unpack r
    RanUnknown r -> "unknown " <> T.unpack r

reconcileText :: ReconcileOutcome -> String
reconcileText outcome =
  case outcome of
    ReconciledApplied r -> "applied " <> T.unpack r
    ReconciledNotApplied r -> "not-applied " <> T.unpack r
    ReconciledExhausted r -> "exhausted " <> T.unpack r
    StillUnknown r -> "unknown " <> T.unpack r
