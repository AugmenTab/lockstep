module Lockstep.ProcessTest
  ( tests
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, try)
import Data.ByteString.Lazy.Char8 qualified as LBS8
import Data.List qualified as L
import Flipstone.Prelude
import Network.HTTP.Client qualified as HTTP
import Network.HTTP.Types qualified as HTTPTypes
import Network.Socket qualified as Socket
import System.Environment (lookupEnv)
import System.Exit (ExitCode (ExitFailure, ExitSuccess))
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

tests :: TestTree
tests =
  testGroup
    "Process"
    [ testCase "serve with no --port answers health on 127.0.0.1:8000" $
        withServer [] 8000 $ do
          status <- getStatus 8000 "/api/health_check"
          status @?= 204
    , testCase "serve --port P answers health and the liveness page on 127.0.0.1:P" $ do
        port <- freePort
        withServer ["--port", show port] port $ do
          health <- getStatus port "/api/health_check"
          health @?= 204
          (status, body) <- getPage port "/"
          status @?= 200
          assertBool "liveness page does not say liveness" ("liveness" `L.isInfixOf` body)
    , testCase "serve is not reachable on a non-loopback interface" $ do
        address <- requireNonLoopbackAddress
        port <- freePort
        withServer ["--port", show port] port $ do
          loopback <- canConnect "127.0.0.1" port
          assertBool "control: loopback connection failed" loopback
          external <- canConnect address port
          assertBool
            ("server accepted a connection on non-loopback " <> address)
            (not external)
    , testCase "serve --port without a value exits 64 with a typed error" $ do
        (code, _out, err) <- Process.readProcessWithExitCode "lockstep" ["serve", "--port"] ""
        code @?= ExitFailure 64
        assertBool ("stderr does not name --port: " <> err) ("--port" `L.isInfixOf` err)
    , testCase "SIGTERM stops the server with exit 0 within 5 seconds" $ do
        port <- freePort
        handle <- startServer ["--port", show port]
        waitReady handle port
        Process.terminateProcess handle
        result <- timeout 5000000 (Process.waitForProcess handle)
        result @?= Just ExitSuccess
    ]

startServer :: [String] -> IO Process.ProcessHandle
startServer args = do
  (_, _, _, handle) <-
    Process.createProcess (Process.proc "lockstep" ("serve" : args))
  pure handle

stopServer :: Process.ProcessHandle -> IO ()
stopServer handle = do
  Process.terminateProcess handle
  void (timeout 5000000 (Process.waitForProcess handle))

withServer :: [String] -> Int -> Assertion -> Assertion
withServer args port action =
  bracket (startServer args) stopServer $ \handle -> do
    waitReady handle port
    action

waitReady :: Process.ProcessHandle -> Int -> Assertion
waitReady handle port =
  let
    attempt :: Int -> Assertion
    attempt remaining = do
      exited <- Process.getProcessExitCode handle
      case exited of
        Just code ->
          assertFailure ("server exited before becoming ready: " <> show code)
        Nothing -> do
          result <- try (getStatus port "/api/health_check")
          case result of
            Right _ ->
              pure ()
            Left err ->
              if remaining <= 0
                then assertFailure ("server not ready: " <> show (err :: HTTP.HttpException))
                else threadDelay 100000 >> attempt (remaining - 1)
  in
    attempt 100

getStatus :: Int -> String -> IO Int
getStatus port path =
  fmap fst (getPage port path)

getPage :: Int -> String -> IO (Int, String)
getPage port path = do
  manager <- HTTP.newManager HTTP.defaultManagerSettings
  request <- HTTP.parseRequest ("http://127.0.0.1:" <> show port <> path)
  response <- HTTP.httpLbs request manager
  pure
    ( HTTPTypes.statusCode (HTTP.responseStatus response)
    , LBS8.unpack (HTTP.responseBody response)
    )

canConnect :: String -> Int -> IO Bool
canConnect host port = do
  let
    hints =
      Socket.defaultHints
        { Socket.addrSocketType = Socket.Stream
        , Socket.addrFlags = [Socket.AI_NUMERICHOST]
        }
  addresses <- Socket.getAddrInfo (Just hints) (Just host) (Just (show port))
  case addresses of
    [] ->
      assertFailure ("no address for " <> host)
    address : _ -> do
      result <-
        try $
          bracket
            (Socket.openSocket address)
            Socket.close
            (\sock -> timeout 2000000 (Socket.connect sock (Socket.addrAddress address)))
      case result of
        Left err ->
          let
            _ = err :: IOException
          in
            pure False
        Right Nothing ->
          assertFailure ("connection attempt to " <> host <> " timed out (inconclusive)")
        Right (Just ()) ->
          pure True

freePort :: IO Int
freePort =
  bracket
    (Socket.socket Socket.AF_INET Socket.Stream Socket.defaultProtocol)
    Socket.close
    ( \sock -> do
        Socket.bind sock (Socket.SockAddrInet 0 (Socket.tupleToHostAddress (127, 0, 0, 1)))
        fmap fromIntegral (Socket.socketPort sock)
    )

{- | The non-loopback IPv4 address of this host, supplied by scripts/check. A
missing or loopback address fails the test: it must never pass vacuously.
-}
requireNonLoopbackAddress :: IO String
requireNonLoopbackAddress = do
  mbAddress <- lookupEnv "LOCKSTEP_TEST_NONLOOPBACK_ADDR"
  case mbAddress of
    Nothing ->
      assertFailure "precondition missing: LOCKSTEP_TEST_NONLOOPBACK_ADDR is not set (NOT_RUN)"
    Just address ->
      if L.null address || "127." `L.isPrefixOf` address
        then
          assertFailure ("precondition invalid: " <> address <> " is not a non-loopback address")
        else pure address
