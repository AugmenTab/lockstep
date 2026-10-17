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
import System.IO (hPutStr, hPutStrLn, putStrLn, stderr)
import System.Log.FastLogger qualified as FL
import Text.Show (show)

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
import Lockstep.Application.OperatorTrust (issueSignIn, revokeAllSessions, signInUrl)
import Lockstep.Foundation.Cli (BackupPolicy, Command (..), parseArgs, renderCliError, usage)
import Lockstep.Foundation.Config (Port, ServeConfig (..), bindHostAddress, portNumber)
import Lockstep.Foundation.SystemConfig
  ( SystemConfig (..)
  , loadSystemConfig
  , renderConfigError
  )
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Web.Application (applicationWith)
import Lockstep.Web.Server (serverSettings)

main :: IO ()
main = do
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
  case (readiness, mbRuntime) of
    (Ready _, Just runtime) -> do
      recorded <- recordServiceStart runtime
      case recorded of
        Right () -> logLine "Service start recorded"
        Left reason -> logLine ("Service start not recorded: " <> show reason)
    _ ->
      pure ()
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
        $ serverSettings serveConfig
  Warp.runSettings settings (applicationWith serveConfig mbRuntime appLogger)
    `finally` (traverse_ closeDatabase mbRuntime >> finishLogger)

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
