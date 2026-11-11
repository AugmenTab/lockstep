{- | The helper's capsule status, as the service sees it (Phase 5, P5.10;
@docs/architecture/dev-capsules.md@). When its capsule mode is on, the host
helper keeps @DIR/runner/capsule-status@ current: which Dev Capsule and
verification capsule, whether the VM is ready and its configuration audited,
the run under way, the last run's outcome and the last failure. The operator's
pages show it; nothing here decides anything.

The file is the helper's (trusted), never a guest's. Every value is checked:
printable ASCII, bounded; a malformed file reads as unavailable, never as a
partly understood status.
-}
module Lockstep.Application.CapsuleStatus
  ( CapsuleStatus (..)
  , parseCapsuleStatus
  , readCapsuleStatus
  , capsuleStatusPath
  , capsuleStatusFromEnvironment
  , StopOutcome (..)
  , stopCapsuleRun
  ) where

import Control.Exception (IOException, try)
import Data.ByteString qualified as BS
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)
import System.IO (FilePath)
import Text.Show (Show)

import Lockstep.Effects.HelperRunner (RunnerChannel, openRunnerChannel, requestCancel, runnerDirectory)
import Lockstep.Foundation.RunnerProtocol (isRunName)

data CapsuleStatus
  = CapsuleStatus
  { statusCapsule :: T.Text
  , statusProject :: Maybe T.Text
  {- ^ the Lockstep project the capsule serves (its id, from the helper's capsule config); the status
  and its stop control belong to that project's page only
  -}
  , statusVerify :: Maybe T.Text
  , statusVm :: T.Text
  -- ^ the VM's state as the runtime read it: Running, Stopped, absent, Broken
  , statusAudit :: T.Text
  -- ^ @ok@, or the reason the configuration is refused
  , statusTemplate :: T.Text
  -- ^ @current@ or @stale@
  , statusActiveRun :: Maybe T.Text
  -- ^ the run under way (32 hexadecimal characters)
  , statusActiveOp :: Maybe T.Text
  , statusLastRun :: Maybe T.Text
  -- ^ @OP OUTCOME exit N@ of the last run that ended
  , statusLastFailure :: Maybe T.Text
  , statusUpdated :: T.Text
  }
  deriving (Eq, Show)

capsuleStatusPath :: RunnerChannel -> FilePath
capsuleStatusPath channel =
  runnerDirectory channel <> "/capsule-status"

{- | Reads @lockstep-capsule-status 1@ and exactly the eleven keyed lines, in
order; @-@ is none. Nothing for anything else.
-}
parseCapsuleStatus :: BS.ByteString -> Maybe CapsuleStatus
parseCapsuleStatus bytes = do
  text <- either (const Nothing) Just (TE.decodeUtf8' bytes)
  body <- T.stripSuffix (T.pack "\n") text
  case T.splitOn (T.pack "\n") body of
    header : rest
      | header == T.pack "lockstep-capsule-status 1"
      , L.length rest == 11
      , L.all printable rest -> do
          vals <- traverse value (L.zip keys rest)
          case vals of
            [cap, project, verify, vm, audit, template, run, op, lastRun, lastFailure, updated]
              | not (T.null cap)
              , maybe True isRunName (optional run) ->
                  Just
                    CapsuleStatus
                      { statusCapsule = cap
                      , statusProject = optional project
                      , statusVerify = optional verify
                      , statusVm = vm
                      , statusAudit = audit
                      , statusTemplate = template
                      , statusActiveRun = optional run
                      , statusActiveOp = optional op
                      , statusLastRun = optional lastRun
                      , statusLastFailure = optional lastFailure
                      , statusUpdated = updated
                      }
            _ -> Nothing
    _ -> Nothing
 where
  keys =
    fmap T.pack ["capsule", "project", "verify", "vm", "audit", "template", "active-run", "active-op", "last-run", "last-failure", "updated"]
  value (key, line) =
    case T.stripPrefix (key <> T.pack " ") line of
      Just v | not (T.null v) -> Just v
      _ -> Nothing
  printable line =
    T.length line <= 400 && T.all (\c -> Char.isAscii c && Char.isPrint c) line
  optional v =
    if v == T.pack "-" then Nothing else Just v

-- | The runner channel the service was started with (@LOCKSTEP_RUNNER_DIR@), if any.
runnerChannelFromEnvironment :: IO (Maybe RunnerChannel)
runnerChannelFromEnvironment = do
  dir <- lookupEnv "LOCKSTEP_RUNNER_DIR"
  case dir of
    Nothing -> pure Nothing
    Just d -> either (const Nothing) Just <$> openRunnerChannel d

{- | The helper's capsule status for this project (its id): only when the
service has the runner channel, the helper is in capsule mode and its capsule
serves this project (P5.5 review 3, finding M5).
-}
capsuleStatusFromEnvironment :: T.Text -> IO (Maybe CapsuleStatus)
capsuleStatusFromEnvironment project = do
  status <- runnerChannelFromEnvironment >>= maybe (pure Nothing) readCapsuleStatus
  pure $ case status of
    Just s | statusProject s == Just project -> Just s
    _ -> Nothing

data StopOutcome
  = StopRequested
  | StopNotRunning
  | StopNoHelper
  deriving (Eq, Show)

{- | P5.10: asks the helper to stop the run under way in this project's capsule,
only if that run is the one named (a stale page stops nothing) and the capsule
serves this project. The helper ends it; the engine treats it as a cancelled
step and the bug waits for the person. A request the helper did not receive is
reported as such.
-}
stopCapsuleRun :: T.Text -> T.Text -> IO StopOutcome
stopCapsuleRun project run = do
  channel <- runnerChannelFromEnvironment
  case channel of
    Nothing -> pure StopNoHelper
    Just c -> do
      status <- readCapsuleStatus c
      case status of
        Just s
          | statusProject s == Just project
          , isRunName run
          , statusActiveRun s == Just run -> do
              sent <- requestCancel c run
              pure (either (const StopNoHelper) (const StopRequested) sent)
        _ -> pure StopNotRunning

-- | The status, if the helper is in capsule mode and its file reads.
readCapsuleStatus :: RunnerChannel -> IO (Maybe CapsuleStatus)
readCapsuleStatus channel = do
  let
    path = capsuleStatusPath channel
  present <- doesFileExist path
  if not present
    then pure Nothing
    else do
      bytes <- try (BS.readFile path) :: IO (Either IOException BS.ByteString)
      pure $ case bytes of
        Right b | BS.length b <= 8192 -> parseCapsuleStatus b
        _ -> Nothing
