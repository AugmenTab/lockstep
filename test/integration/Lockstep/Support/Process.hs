-- | Running the real lockstep binary with a chosen environment.
module Lockstep.Support.Process
  ( runLockstep
  , withService
  , httpGet
  , freePort
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket, try)
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.List qualified as L
import Flipstone.Prelude
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types qualified as HTTPTypes
import Network.Socket qualified as Socket
import System.Environment (getEnvironment)
import System.Exit (ExitCode)
import System.IO (FilePath, IOMode (WriteMode), openFile, readFile)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty.HUnit (Assertion, assertFailure)
import Text.Show (show)

environmentWith :: [(String, String)] -> IO [(String, String)]
environmentWith extra = do
  base <- getEnvironment
  pure (extra <> L.filter (\(k, _) -> k `L.notElem` fmap fst extra) base)

{- | Runs @lockstep args@ to completion (at most 20 s; a hang is a failure) and
returns the exit code, stdout and stderr.
-}
runLockstep :: [(String, String)] -> [String] -> IO (ExitCode, String, String)
runLockstep extra args = do
  env <- environmentWith extra
  result <-
    timeout 20000000 $
      Process.readCreateProcessWithExitCode ((Process.proc "lockstep" args) {Process.env = Just env}) ""
  case result of
    Nothing -> assertFailure ("lockstep " <> show args <> " did not finish within 20 s")
    Just r -> pure r

{- | Starts @lockstep serve --port P@, waits for liveness, runs the action, then
stops it with SIGTERM. Returns the action's result and the combined output.
-}
withService :: [(String, String)] -> Int -> FilePath -> IO a -> IO (a, String)
withService extra port logPath action = do
  env <- environmentWith extra
  result <-
    bracket
      ( do
          logHandle <- openFile logPath WriteMode
          (_, _, _, handle) <-
            Process.createProcess
              (Process.proc "lockstep" ["serve", "--port", show port])
                { Process.env = Just env
                , Process.std_out = Process.UseHandle logHandle
                , Process.std_err = Process.UseHandle logHandle
                }
          pure handle
      )
      ( \handle -> do
          Process.terminateProcess handle
          void (timeout 5000000 (Process.waitForProcess handle))
      )
      (\handle -> waitReady handle port >> action)
  output <- readFile logPath
  pure (result, output)

waitReady :: Process.ProcessHandle -> Int -> Assertion
waitReady handle port =
  let
    attempt :: Int -> Assertion
    attempt remaining = do
      exited <- Process.getProcessExitCode handle
      case exited of
        Just code -> assertFailure ("server exited before becoming ready: " <> show code)
        Nothing -> do
          r <- try (httpGet port "/api/health_check")
          case r of
            Right _ -> pure ()
            Left err ->
              if remaining <= 0
                then assertFailure ("server not ready: " <> show (err :: HTTP.HttpException))
                else threadDelay 100000 >> attempt (remaining - 1)
  in
    attempt 100

httpGet :: Int -> String -> IO (Int, String)
httpGet port path = do
  manager <- HTTP.newManager HTTP.defaultManagerSettings
  request <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> path)
  response <- HTTP.httpLbs request manager
  pure
    ( HTTPTypes.statusCode (HTTP.responseStatus response)
    , LBS8.unpack (HTTP.responseBody response)
    )

freePort :: IO Int
freePort =
  bracket
    (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol)
    Socket.close
    ( \sock -> do
        Socket.bind sock (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
        fmap fromIntegral (Socket.socketPort sock)
    )
