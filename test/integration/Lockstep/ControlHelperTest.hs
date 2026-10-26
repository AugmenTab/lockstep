{-# LANGUAGE OverloadedStrings #-}

{- | The host helper, @scripts/control-helper@, against the channel protocol v1
(contract C-P3.1 §4, L8, L9). The helper and @scripts/service@ run from a
throwaway copy of the checkout in a temporary directory, with @docker@ replaced
by a stub on @PATH@, so nothing touches the operator's installation,
configuration or containers. The test plays the pane.
-}
module Lockstep.ControlHelperTest
  ( tests
  ) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Numeric (showHex)
import System.Directory (createDirectory, doesFileExist, listDirectory, removeDirectory, renameDirectory, renameFile)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath, readFile)
import System.Posix.Files (createSymbolicLink, setFileMode, setOwnerAndGroup)
import System.Posix.Signals (signalProcess)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Read (readMaybe)
import Text.Show (show)

import Lockstep.Foundation.ControlProtocol
  ( ControlOp (OpStatus)
  , ControlRequest (..)
  , ControlResult (..)
  , Expect (ExpectAny)
  , Outcome (..)
  , decodeResult
  , encodeRequest
  , hmacHex
  , parseChannelKey
  , parseRequestId
  )
import Lockstep.Support.Control
  ( Env (..)
  , currentSeconds
  , helperDir
  , helperEnvironment
  , paneDir
  , startHelper
  , withEnv
  , withHelper
  , writeFileText
  )
import Lockstep.Support.Control qualified as Control

setMode :: Env -> String -> IO ()
setMode =
  Control.setStubMode

-- | A fresh 32-hex-character id: the current time and a per-test number.
newId :: Integer -> IO T.Text
newId n = do
  now <- currentSeconds
  pure (T.justifyRight 16 '0' (T.pack (showHex now "")) <> T.justifyRight 16 '0' (T.pack (showHex n "")))

statusRequest :: T.Text -> Integer -> IO ControlRequest
statusRequest rid issued =
  case parseRequestId rid of
    Nothing -> assertFailure ("bad test id " <> show rid)
    Just r -> pure (ControlRequest r issued OpStatus ExpectAny)

-- | Writes a request the way the pane does: a temporary name, then a rename.
submitBytes :: Env -> String -> BS.ByteString -> IO ()
submitBytes env name bytes = do
  let
    tmp = paneDir env <> "/requests/." <> name <> ".tmp"
  BS.writeFile tmp bytes
  setFileMode tmp 0o600
  renameFile tmp (paneDir env <> "/requests/" <> name)

submit :: Env -> T.Text -> Integer -> IO ()
submit env rid issued = do
  request <- statusRequest rid issued
  submitBytes env (T.unpack rid <> ".req") (encodeRequest (envKey env) request)

-- | A request body with chosen lines, signed with the test key.
signedBody :: Env -> BS.ByteString -> BS.ByteString
signedBody env body =
  body <> "mac " <> BS8.pack (T.unpack (hmacHex (envKey env) body)) <> "\n"

resultPath :: Env -> T.Text -> FilePath
resultPath env rid =
  paneDir env <> "/results/" <> T.unpack rid <> ".res"

-- | Waits (at most @seconds@) for the result and decodes it with the test key.
awaitResult :: Env -> Int -> T.Text -> IO ControlResult
awaitResult env seconds rid =
  let
    attempt :: Int -> IO ControlResult
    attempt remaining = do
      present <- doesFileExist (resultPath env rid)
      if present
        then do
          bytes <- BS.readFile (resultPath env rid)
          case decodeResult (envKey env) bytes of
            Right r -> pure r
            Left err -> assertFailure ("the helper's result does not verify: " <> show err <> "\n" <> show bytes)
        else
          if remaining <= 0
            then do
              out <- readFile (envStub env <> "/helper.out")
              assertFailure ("no result for " <> T.unpack rid <> " within " <> show seconds <> " s; helper output:\n" <> out)
            else threadDelay 100000 >> attempt (remaining - 1)
  in
    attempt (seconds * 10)

assertRefused :: Env -> T.Text -> T.Text -> Assertion
assertRefused env rid reason = do
  r <- awaitResult env 10 rid
  resultOutcome r @?= OutcomeRefused
  resultReason r @?= Just reason

-- | Asserts that nothing appears for this id within the time.
assertNoResult :: Env -> Int -> T.Text -> Assertion
assertNoResult env seconds rid = do
  threadDelay (seconds * 1000000)
  present <- doesFileExist (resultPath env rid)
  assertBool ("a result appeared for " <> T.unpack rid) (not present)

journal :: Env -> IO [[String]]
journal env = do
  present <- doesFileExist (helperDir env <> "/journal")
  if present
    then fmap L.words . L.lines <$> readFile (helperDir env <> "/journal")
    else pure []

field :: T.Text -> ControlResult -> Maybe T.Text
field name =
  L.lookup name . resultFields

tests :: TestTree
tests =
  testGroup
    "control helper (C-P3.1 §4, L8, L9)"
    [ testCase "a valid status request gets a signed result with the status fields" $
        withEnv $ \env -> withHelper env [] $ do
          rid <- newId 1
          now <- currentSeconds
          submit env rid now
          r <- awaitResult env 20 rid
          resultOutcome r @?= OutcomeOk
          resultOp r @?= "status"
          field "install.present" r @?= Just "yes"
          field "install.commit" r @?= Just "0123456789abcdef0123456789abcdef01234567"
          field "install.dirty" r @?= Just "false"
          field "database.server" r @?= Just "running"
          field "database.readiness" r @?= Just "ready"
          field "database.revision" r @?= Just "5"
          field "database.pending" r @?= Just "0"
          field "helper.protocol" r @?= Just "1"
          assertBool "service.state is not a constrained word" (field "service.state" r `L.elem` fmap Just ["running", "unknown"])
          assertBool "started after issued" (resultStarted r >= now && resultFinished r >= resultStarted r)
          requests <- listDirectory (paneDir env <> "/requests")
          L.filter (not . ("." `L.isPrefixOf`)) requests @?= []
          pwned <- doesFileExist "/tmp/lockstep-helper-pwned"
          assertBool "docker output was executed as a command" (not pwned)
          entries <- journal env
          assertBool ("journal lacks start/end: " <> show entries) $
            L.any (\e -> L.take 3 (L.drop 1 e) == ["start", T.unpack rid, "status"]) entries
              && L.any (\e -> L.take 3 (L.drop 1 e) == ["end", T.unpack rid, "ok"]) entries
    , testCase "a forged MAC is refused and nothing runs" $
        withEnv $ \env -> withHelper env [] $ do
          rid <- newId 2
          now <- currentSeconds
          other <- maybe (assertFailure "key") pure (parseChannelKey "0000000000000000000000000000000000000000000000000000000000000001")
          request <- statusRequest rid now
          submitBytes env (T.unpack rid <> ".req") (encodeRequest other request)
          assertRefused env rid "bad-mac"
          logged <- readOrEmpty (envStub env <> "/log")
          assertBool ("docker ran for a forged request: " <> logged) (L.null logged)
    , testCase "a replayed request file is refused and the first result is kept" $
        withEnv $ \env -> withHelper env [] $ do
          rid <- newId 3
          now <- currentSeconds
          request <- statusRequest rid now
          let
            bytes = encodeRequest (envKey env) request
          submitBytes env (T.unpack rid <> ".req") bytes
          r <- awaitResult env 20 rid
          resultOutcome r @?= OutcomeOk
          before <- BS.readFile (resultPath env rid)
          submitBytes env (T.unpack rid <> ".req") bytes
          threadDelay 2000000
          after <- BS.readFile (resultPath env rid)
          after @?= before
          entries <- journal env
          assertBool ("no replay refusal journaled: " <> show entries) $
            L.any (\e -> L.take 3 (L.drop 1 e) == ["refused", T.unpack rid, "replayed"]) entries
          requests <- listDirectory (paneDir env <> "/requests")
          L.filter (not . ("." `L.isPrefixOf`)) requests @?= []
    , testCase "stale and future requests are refused" $
        withEnv $ \env -> withHelper env [] $ do
          old <- newId 4
          future <- newId 5
          now <- currentSeconds
          submit env old (now - 200)
          submit env future (now + 60)
          assertRefused env old "stale"
          assertRefused env future "stale"
    , testCase "unknown operations, bad expect and malformed lines are refused, even when signed" $
        withEnv $ \env -> withHelper env [] $ do
          now <- currentSeconds
          ids <- traverse newId [6, 7, 8, 9, 10]
          let
            line k v = k <> " " <> v <> "\n"
            body rid op expect =
              "lockstep-control-request 1\n"
                <> line "id" (BS8.pack (T.unpack rid))
                <> line "issued" (BS8.pack (show now))
                <> line "op" op
                <> line "expect" expect
          case ids of
            [a, b, c, d, e] -> do
              submitBytes env (T.unpack a <> ".req") (signedBody env (body a "start" "any"))
              submitBytes env (T.unpack b <> ".req") (signedBody env (body b "status" "running"))
              submitBytes env (T.unpack c <> ".req") (signedBody env (body c "$(touch /tmp/lockstep-helper-pwned)" "any"))
              submitBytes env (T.unpack d <> ".req") (signedBody env ("lockstep-control-request 2\n" <> BS.drop 27 (body d "status" "any")))
              submitBytes env (T.unpack e <> ".req") (signedBody env (body e "status" "any" <> "extra line\n"))
              assertRefused env a "unknown-op"
              assertRefused env b "bad-expect"
              r <- awaitResult env 10 c
              resultOutcome r @?= OutcomeRefused
              assertBool ("metacharacters: " <> show (resultReason r)) (resultReason r `L.elem` [Just "malformed", Just "unknown-op"])
              assertRefused env d "bad-version"
              assertRefused env e "malformed"
            _ -> assertFailure "ids"
          pwned <- doesFileExist "/tmp/lockstep-helper-pwned"
          assertBool "a field was executed as a command" (not pwned)
    , testCase "a request whose name does not match its id is refused; other names are ignored" $
        withEnv $ \env -> withHelper env [] $ do
          a <- newId 11
          b <- newId 12
          now <- currentSeconds
          request <- statusRequest a now
          submitBytes env (T.unpack b <> ".req") (encodeRequest (envKey env) request)
          assertRefused env b "malformed"
          submitBytes env "notes.txt" "hello"
          submitBytes env "x.req" "hello"
          assertNoResult env 2 a
          names <- listDirectory (paneDir env <> "/results")
          L.sort names @?= [T.unpack b <> ".res"]
    , testCase "an oversized request is refused" $
        withEnv $ \env -> withHelper env [] $ do
          rid <- newId 13
          submitBytes env (T.unpack rid <> ".req") (BS.replicate 2000 0x61)
          assertRefused env rid "too-large"
    , testCase "a symlinked request is refused without reading its target" $
        withEnv $ \env -> withHelper env [] $ do
          rid <- newId 14
          now <- currentSeconds
          request <- statusRequest rid now
          let
            target = envStub env <> "/elsewhere.req"
          BS.writeFile target (encodeRequest (envKey env) request)
          createSymbolicLink target (paneDir env <> "/requests/" <> T.unpack rid <> ".req")
          assertRefused env rid "not-regular-file"
          stillThere <- doesFileExist target
          assertBool "the symlink target was removed" stillThere
    , testCase "a request owned by another user or writable by others is refused" $
        withEnv $ \env -> withHelper env [] $ do
          a <- newId 15
          b <- newId 16
          now <- currentSeconds
          ra <- statusRequest a now
          rb <- statusRequest b now
          let
            pa = paneDir env <> "/requests/." <> T.unpack a <> ".tmp"
            pb = paneDir env <> "/requests/." <> T.unpack b <> ".tmp"
          BS.writeFile pa (encodeRequest (envKey env) ra)
          setFileMode pa 0o600
          setOwnerAndGroup pa 65534 65534
          renameFile pa (paneDir env <> "/requests/" <> T.unpack a <> ".req")
          BS.writeFile pb (encodeRequest (envKey env) rb)
          setFileMode pb 0o666
          renameFile pb (paneDir env <> "/requests/" <> T.unpack b <> ".req")
          assertRefused env a "not-owner"
          assertRefused env b "bad-permissions"
    , testCase "a requests directory replaced by a symlink is not read" $
        withEnv $ \env -> withHelper env [] $ do
          rid <- newId 17
          now <- currentSeconds
          request <- statusRequest rid now
          let
            real = paneDir env <> "/requests"
            aside = paneDir env <> "/requests-real"
            decoy = envStub env <> "/decoy"
          createDirectory decoy
          setFileMode decoy 0o700
          BS.writeFile (decoy <> "/" <> T.unpack rid <> ".req") (encodeRequest (envKey env) request)
          setFileMode (decoy <> "/" <> T.unpack rid <> ".req") 0o600
          renameDirectory real aside
          createSymbolicLink decoy real
          assertNoResult env 3 rid
          stillThere <- doesFileExist (decoy <> "/" <> T.unpack rid <> ".req")
          assertBool "the decoy request was consumed" stillThere
    , testCase "a symlink planted at the result path is not followed" $
        withEnv $ \env -> withHelper env [] $ do
          rid <- newId 18
          now <- currentSeconds
          let
            victim = envStub env <> "/victim"
            victimDir = envStub env <> "/victimdir"
          writeFileText victim "victim\n"
          createDirectory victimDir
          createSymbolicLink victim (resultPath env rid)
          submit env rid now
          threadDelay 3000000
          content <- readFile victim
          content @?= "victim\n"
          other <- newId 19
          createSymbolicLink victimDir (resultPath env other)
          submit env other now
          threadDelay 3000000
          inside <- listDirectory victimDir
          inside @?= []
    , testCase "two requests run one after the other" $
        withEnv $ \env -> withHelper env [] $ do
          setMode env "delay"
          a <- newId 20
          b <- newId 21
          now <- currentSeconds
          submit env a now
          submit env b now
          ra <- awaitResult env 30 a
          rb <- awaitResult env 30 b
          resultOutcome ra @?= OutcomeOk
          resultOutcome rb @?= OutcomeOk
          entries <- journal env
          let
            events = [L.drop 1 e | e <- entries, L.take 1 (L.drop 1 e) `L.elem` [["start"], ["end"]]]
            kinds = fmap (L.take 1) events
          kinds @?= [["start"], ["end"], ["start"], ["end"]]
          assertBool ("interleaved: " <> show events) (fmap (L.take 2) events `L.elem` [[["start", ta], ["end", ta], ["start", tb], ["end", tb]] | (ta, tb) <- [(T.unpack a, T.unpack b), (T.unpack b, T.unpack a)]])
    , testCase "an operation over its time limit is stopped and reported timed-out" $
        withEnv $ \env -> withHelper env [("LOCKSTEP_HELPER_TIMEOUT", "2")] $ do
          setMode env "slow"
          rid <- newId 22
          now <- currentSeconds
          submit env rid now
          r <- awaitResult env 15 rid
          resultOutcome r @?= OutcomeTimedOut
          threadDelay 1000000
          pidText <- readFile (envStub env <> "/pid")
          case readMaybe (L.filter (/= '\n') pidText) :: Maybe Integer of
            Nothing -> assertFailure ("stub pid unreadable: " <> pidText)
            Just pid -> do
              -- Linux (the dev container): gone, or a zombie whose parent died with it, is stopped.
              stat <- readOrEmpty ("/proc/" <> show pid <> "/stat")
              let
                state = L.take 1 (L.words (L.drop 1 (L.dropWhile (/= ')') stat)))
              assertBool ("the timed-out operation is still running: " <> stat) (L.null stat || state == ["Z"])
    , testCase "an operation interrupted by a helper crash is reported interrupted after restart" $
        withEnv $ \env -> do
          setMode env "slow"
          rid <- newId 23
          handle <- startHelper env []
          now <- currentSeconds
          submit env rid now
          waitFor 10 $ L.any (\e -> L.take 2 (L.drop 1 e) == ["start", T.unpack rid]) <$> journal env
          mPid <- Process.getPid handle
          traverse_ (signalProcess 9) mPid
          void (timeout 5000000 (Process.waitForProcess handle))
          setMode env "normal"
          withHelper env [] $ do
            r <- awaitResult env 10 rid
            resultOutcome r @?= OutcomeInterrupted
    , testCase "a second helper on the same state refuses to start" $
        withEnv $ \env -> withHelper env [] $ do
          threadDelay 1000000
          vars <- helperEnvironment env []
          result <-
            timeout 10000000 $
              Process.readCreateProcessWithExitCode
                ((Process.proc (envRoot env <> "/scripts/control-helper") ["--state", envState env]) {Process.env = Just vars})
                ""
          case result of
            Nothing -> assertFailure "the second helper kept running"
            Just (code, _, err) -> do
              assertBool "the second helper exited 0" (code /= ExitSuccess)
              assertBool ("no reason: " <> err) ("already running" `L.isInfixOf` err)
    , testCase "markup in docker output reaches the result only as constrained text" $
        withEnv $ \env -> withHelper env [] $ do
          setMode env "markup"
          rid <- newId 24
          now <- currentSeconds
          submit env rid now
          r <- awaitResult env 20 rid
          field "database.readiness" r @?= Just "unknown"
          assertBool ("markup not kept as text in detail: " <> show (resultDetail r)) ("<img src=x onerror=alert(1)>" `T.isInfixOf` resultDetail r)
    , testCase "missing containers and installation are reported, not invented" $
        withEnv $ \env -> withHelper env [] $ do
          setMode env "absent"
          rid <- newId 25
          now <- currentSeconds
          submit env rid now
          r <- awaitResult env 20 rid
          field "service.state" r @?= Just "absent"
          field "database.server" r @?= Just "absent"
    , testCase "the helper refuses a state directory others can write" $
        withEnv $ \env -> do
          setFileMode (envState env) 0o777
          vars <- helperEnvironment env []
          result <-
            timeout 10000000 $
              Process.readCreateProcessWithExitCode
                ((Process.proc (envRoot env <> "/scripts/control-helper") ["--state", envState env]) {Process.env = Just vars})
                ""
          case result of
            Nothing -> assertFailure "the helper ran with a world-writable state directory"
            Just (code, _, _) -> assertBool "exit 0" (code /= ExitSuccess)
          removeDirectoryIfEmpty (helperDir env <> "/lock")
    ]

readOrEmpty :: FilePath -> IO String
readOrEmpty path = do
  r <- try (readFile path) :: IO (Either SomeException String)
  pure (fromRight "" r)

waitFor :: Int -> IO Bool -> Assertion
waitFor seconds check =
  let
    attempt :: Int -> Assertion
    attempt remaining = do
      ok <- check
      if ok
        then pure ()
        else
          if remaining <= 0
            then assertFailure ("condition not reached within " <> show seconds <> " s")
            else threadDelay 100000 >> attempt (remaining - 1)
  in
    attempt (seconds * 10)

removeDirectoryIfEmpty :: FilePath -> IO ()
removeDirectoryIfEmpty dir =
  void (try (removeDirectory dir) :: IO (Either SomeException ()))
