{- | The container runner's client in the service (contract C-P4.2 R4; DG-17
D-17.1(a)). It prepares a run directory under the helper's runner channel,
writes the argument vector and the protected paths, signs a request, and
waits for the helper's signed result. The container, its image, mounts,
options, network and limits are the helper's; nothing here can choose them.

A run with no result in time, or one the helper reports interrupted, has an
unknown outcome ('HelperNoResult', 'HelperInterrupted'); the caller must not
run it again by itself.
-}
module Lockstep.Effects.HelperRunner
  ( RunnerChannel
  , openRunnerChannel
  , runnerDirectory
  , PreparedRun (..)
  , prepareRun
  , HelperFailure (..)
  , helperFailureCode
  , submitRun
  , requestCancel
  , interpretResult
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, finally, try)
import Control.Monad (unless)
import Crypto.Hash (SHA256 (SHA256), hashWith)
import Crypto.Random (getRandomBytes)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Flipstone.Prelude
import System.Directory (createDirectory, doesFileExist, renameFile)
import System.IO (FilePath, hClose)
import System.Posix.IO (OpenFileFlags (creat, exclusive), OpenMode (WriteOnly), defaultFileFlags, fdToHandle, openFd)
import Text.Read (readMaybe)
import Text.Show (Show)

import Lockstep.Effects.Process (RunResult (..))
import Lockstep.Foundation.ControlProtocol (ChannelKey, parseChannelKey, parseRequestId)
import Lockstep.Foundation.RunnerProtocol
  ( RunProfile
  , RunnerOp (..)
  , RunnerRequest (..)
  , RunnerResult (..)
  , decodeRunnerResult
  , encodeRunnerRequest
  , isRunName
  , resultField
  )
import Lockstep.Kernel.GitBasis (protectedPathValid)
import Lockstep.Kernel.Runner (RoleKind (RoleCommand), RunOutcome (..), RunSpec (..), Stream (..), checkSpec, roleLimits)

data RunnerChannel
  = RunnerChannel FilePath ChannelKey

runnerDirectory :: RunnerChannel -> FilePath
runnerDirectory (RunnerChannel dir _) =
  dir

-- | The channel at the directory the helper made (@LOCKSTEP_RUNNER_DIR@).
openRunnerChannel :: FilePath -> IO (Either T.Text RunnerChannel)
openRunnerChannel dir = do
  bytes <- try (BS.readFile (dir <> "/channel.key")) :: IO (Either IOException BS.ByteString)
  pure $
    case either (const Nothing) parseChannelKey bytes of
      Just key -> Right (RunnerChannel dir key)
      Nothing -> Left (T.pack "runner-unavailable")

data PreparedRun
  = PreparedRun
  { preparedName :: T.Text
  , preparedTree :: FilePath
  , preparedInput :: FilePath
  , preparedOutput :: FilePath
  }
  deriving (Eq, Show)

-- | A new run directory with empty @tree@, @input@ and @output@.
prepareRun :: RunnerChannel -> IO PreparedRun
prepareRun channel = do
  name <- randomHex
  let
    dir = runnerDirectory channel <> "/work/" <> T.unpack name
  createDirectory dir
  traverse_ (\d -> createDirectory (dir <> "/" <> d)) ["tree", "input", "output"]
  pure (PreparedRun name (dir <> "/tree") (dir <> "/input") (dir <> "/output"))

data HelperFailure
  = HelperRefused T.Text
  | HelperInterrupted
  | HelperNoResult
  | HelperResultInvalid T.Text
  | HelperRequestInvalid T.Text
  deriving (Eq, Show)

helperFailureCode :: HelperFailure -> T.Text
helperFailureCode failure =
  case failure of
    HelperRefused reason -> T.pack "helper-refused " <> reason
    HelperInterrupted -> T.pack "helper-interrupted"
    HelperNoResult -> T.pack "helper-no-result"
    HelperResultInvalid code -> T.pack "helper-result-invalid " <> code
    HelperRequestInvalid code -> T.pack "helper-request-invalid " <> code

{- | Submits a prepared run and waits up to the given seconds for its result.
Protected paths are relative to the tree; the helper mounts each read-only.
-}
submitRun :: RunnerChannel -> PreparedRun -> RunProfile -> [T.Text] -> [T.Text] -> Int -> IO (Either HelperFailure RunResult)
submitRun channel prepared profile argv protected waitSeconds =
  case checkSpec (RunSpec argv (T.pack "/work/tree") [] (roleLimits RoleCommand)) of
    Left code -> pure (Left (HelperRequestInvalid code))
    Right _
      | not (L.all validProtected protected) -> pure (Left (HelperRequestInvalid (T.pack "protected-invalid")))
      | otherwise -> do
          let
            dir = runnerDirectory channel <> "/work/" <> T.unpack (preparedName prepared)
            argvBytes = BS.concat [TE.encodeUtf8 a <> BS8.pack "\NUL" | a <- argv]
          -- Nothing is sent yet: a failure here is a refusal, not an unknown outcome.
          written <-
            try $ do
              BS.writeFile (dir <> "/argv") argvBytes
              unless (L.null protected) (BS.writeFile (dir <> "/protected") (TE.encodeUtf8 (T.unlines protected)))
          sent <-
            case written of
              Left (_ :: IOException) -> pure (Left (HelperRequestInvalid (T.pack "run-files-unwritable")))
              Right () -> send channel (RunOp profile) (preparedName prepared) (Just (sha256Hex argvBytes))
          case sent of
            Left failure -> pure (Left failure)
            Right rid -> do
              result <- awaitResult channel rid (waitSeconds * 10)
              case result of
                Left failure -> pure (Left failure)
                Right r -> do
                  out <- readOrEmpty (dir <> "/stdout")
                  err <- readOrEmpty (dir <> "/stderr")
                  pure (interpretResult r out err)

-- | Asks the helper to stop the run; its own result then reports @cancelled@.
requestCancel :: RunnerChannel -> T.Text -> IO (Either HelperFailure ())
requestCancel channel name = do
  sent <- send channel CancelOp name Nothing
  case sent of
    Left failure -> pure (Left failure)
    Right rid -> do
      result <- awaitResult channel rid 100
      pure $ case result of
        Left failure -> Left failure
        Right r
          | runnerOutcome r == T.pack "ok" -> Right ()
          | otherwise -> Left (HelperRefused (runnerReason r))

send :: RunnerChannel -> RunnerOp -> T.Text -> Maybe T.Text -> IO (Either HelperFailure T.Text)
send (RunnerChannel dir key) op name digest = do
  ridText <- randomHex
  now <- getPOSIXTime
  case parseRequestId ridText of
    Nothing -> pure (Left (HelperRequestInvalid (T.pack "request-id")))
    Just rid
      | not (isRunName name) -> pure (Left (HelperRequestInvalid (T.pack "run-name")))
      | otherwise -> do
          let
            bytes = encodeRunnerRequest key (RunnerRequest rid (floor now) op name digest)
            temporary = dir <> "/requests/." <> T.unpack ridText
          -- Made 0600 from the start; the request exists for the helper only once renamed.
          placed <-
            try $ do
              fd <- openFd temporary WriteOnly defaultFileFlags {creat = Just 0o600, exclusive = True}
              h <- fdToHandle fd
              BS.hPut h bytes `finally` hClose h
              renameFile temporary (dir <> "/requests/" <> T.unpack ridText <> ".rreq")
          pure $ case placed of
            Left (_ :: IOException) -> Left (HelperRequestInvalid (T.pack "request-unwritable"))
            Right () -> Right ridText

awaitResult :: RunnerChannel -> T.Text -> Int -> IO (Either HelperFailure RunnerResult)
awaitResult (RunnerChannel dir key) rid ticks = do
  let
    path = dir <> "/results/" <> T.unpack rid <> ".res"
    loop n = do
      -- The helper places a result whole (rename); a read that fails is retried until the time is up.
      read' <- try (doesFileExist path >>= \present -> if present then Just <$> BS.readFile path else pure Nothing)
      case read' of
        Right (Just bytes) ->
          pure $ case decodeRunnerResult key bytes of
            Left _ -> Left (HelperResultInvalid (T.pack "unsigned"))
            Right r
              | runnerResultId r /= rid -> Left (HelperResultInvalid (T.pack "wrong-id"))
              | otherwise -> Right r
        Right Nothing -> next n
        Left (_ :: IOException) -> next n
    next n =
      if n <= 0
        then pure (Left HelperNoResult)
        else threadDelay 100000 >> loop (n - 1 :: Int)
  loop ticks

{- | The run's result from the signed result and the two captured streams,
whose digests must match the signed ones.
-}
interpretResult :: RunnerResult -> BS.ByteString -> BS.ByteString -> Either HelperFailure RunResult
interpretResult result out err =
  case runnerOutcome result of
    o | o == T.pack "refused" -> Left (HelperRefused (runnerReason result))
    o | o == T.pack "interrupted" -> Left HelperInterrupted
    o -> do
      outcome <- outcomeOf o
      outBytes <- number "stdout-bytes"
      errBytes <- number "stderr-bytes"
      if resultField (T.pack "stdout-sha256") result /= Just (sha256Hex out)
        || resultField (T.pack "stderr-sha256") result /= Just (sha256Hex err)
        then Left (HelperResultInvalid (T.pack "output-digest"))
        else
          Right
            RunResult
              { resultOutcome = outcome
              , resultStdout = out
              , resultStderr = err
              , resultStdoutBytes = outBytes
              , resultStderrBytes = errBytes
              , resultMillis = fromIntegral (max 0 (runnerFinished result - runnerStarted result) * 1000)
              , resultDescendantsKilled = False
              }
 where
  number :: String -> Either HelperFailure Int
  number name =
    maybe (Left (HelperResultInvalid (T.pack name))) Right (resultField (T.pack name) result >>= readMaybe . T.unpack)
  limits :: Maybe (Int, Int)
  limits =
    case fmap T.words (resultField (T.pack "limits") result) of
      Just [_, o, e] -> (,) <$> readMaybe (T.unpack o) <*> readMaybe (T.unpack e)
      _ -> Nothing
  outcomeOf o
    | o == T.pack "exited" = Exited <$> number "exit"
    | o == T.pack "timed-out" = Right TimedOut
    | o == T.pack "cancelled" = Right Cancelled
    | o == T.pack "launch-failed" = Right (LaunchFailed (T.pack "container"))
    | o == T.pack "output-limit" = do
        outBytes <- number "stdout-bytes"
        case limits of
          Just (outLimit, _) | outBytes > (outLimit :: Int) -> Right (OutputLimit Stdout)
          Just _ -> Right (OutputLimit Stderr)
          Nothing -> Left (HelperResultInvalid (T.pack "limits"))
    | otherwise = Left (HelperResultInvalid (T.pack "outcome"))

-- | C-P4.R1 R-P1: the Kernel's one rule for protected paths.
validProtected :: T.Text -> Bool
validProtected =
  protectedPathValid

readOrEmpty :: FilePath -> IO BS.ByteString
readOrEmpty path =
  fromRight BS.empty <$> (try (BS.readFile path) :: IO (Either IOException BS.ByteString))

sha256Hex :: BS.ByteString -> T.Text
sha256Hex bytes =
  TE.decodeLatin1 (convertToBase Base16 (hashWith SHA256 bytes))

randomHex :: IO T.Text
randomHex = do
  bytes <- getRandomBytes 16 :: IO BS.ByteString
  pure (TE.decodeLatin1 (convertToBase Base16 bytes))
