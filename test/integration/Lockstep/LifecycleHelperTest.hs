{-# LANGUAGE OverloadedStrings #-}

{- | The helper's lifecycle operations (contract C-P3.2 M1–M5, §3): the real
@scripts/control-helper@ with stateful @docker@ and @curl@ stubs in a throwaway
checkout. The test plays the pane and observes the stub state afterwards.
-}
module Lockstep.LifecycleHelperTest
  ( tests
  ) where

import Control.Concurrent (threadDelay)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Text qualified as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Flipstone.Prelude
import Numeric (showHex)
import System.Directory (doesFileExist, renameFile)
import System.IO (FilePath, readFile)
import System.Posix.Files (setFileMode)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
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
import Lockstep.Foundation.LifecycleProtocol
  ( LifecycleOp (..)
  , LifecycleRequest (..)
  , encodeLifecycleRequest
  , expectedFor
  )
import Lockstep.Support.Lifecycle
  ( LEnv (..)
  , lHelper
  , lPane
  , readStub
  , servicePort
  , setStub
  , stubLog
  , withLifecycleEnv
  , withLifecycleHelper
  )

now' :: IO Integer
now' =
  floor <$> getPOSIXTime

newId :: Integer -> IO T.Text
newId n = do
  t <- now'
  pure (T.justifyRight 16 '0' (T.pack (showHex t "")) <> T.justifyRight 16 '0' (T.pack (showHex (n + 4096) "")))

place :: LEnv -> String -> BS.ByteString -> IO ()
place env name bytes = do
  let
    tmp = lPane env <> "/requests/." <> name <> ".tmp"
  BS.writeFile tmp bytes
  setFileMode tmp 0o600
  renameFile tmp (lPane env <> "/requests/" <> name)

-- | Submits a lifecycle request with the operation's own expected state.
lifecycle :: LEnv -> T.Text -> LifecycleOp -> IO ()
lifecycle env rid op = do
  t <- now'
  r <- maybe (assertFailure "id") pure (parseRequestId rid)
  place env (T.unpack rid <> ".lreq") (encodeLifecycleRequest (lKey env) (LifecycleRequest r t op (expectedFor op)))

resultFile :: LEnv -> T.Text -> FilePath
resultFile env rid =
  lPane env <> "/results/" <> T.unpack rid <> ".res"

await :: LEnv -> Int -> T.Text -> IO ControlResult
await env seconds rid =
  let
    attempt :: Int -> IO ControlResult
    attempt remaining = do
      present <- doesFileExist (resultFile env rid)
      if present
        then do
          bytes <- BS.readFile (resultFile env rid)
          either (\e -> assertFailure ("result does not verify: " <> show e)) pure (decodeResult (lKey env) bytes)
        else
          if remaining <= 0
            then do
              out <- readFile (lStub env <> "/helper.out")
              assertFailure ("no result for " <> T.unpack rid <> " within " <> show seconds <> " s:\n" <> out)
            else threadDelay 100000 >> attempt (remaining - 1)
  in
    attempt (seconds * 10)

expectOutcome :: LEnv -> Int -> T.Text -> Outcome -> Maybe T.Text -> Assertion
expectOutcome env seconds rid outcome reason = do
  r <- await env seconds rid
  (resultOutcome r, resultReason r) @?= (outcome, reason)

logHas :: LEnv -> String -> IO Bool
logHas env needle =
  L.any (needle `L.isInfixOf`) <$> stubLog env

journalEvents :: LEnv -> IO [[String]]
journalEvents env = do
  present <- doesFileExist (lHelper env <> "/journal")
  if present then fmap (L.drop 1 . L.words) . L.lines <$> readFile (lHelper env <> "/journal") else pure []

withRunning :: (LEnv -> IO a) -> IO a
withRunning action =
  withLifecycleEnv Nothing $ \env -> withLifecycleHelper env [] (action env)

tests :: TestTree
tests =
  testGroup
    "helper lifecycle operations (C-P3.2)"
    [ testCase "service-stop on a running service stops it and says ok" $
        withRunning $ \env -> do
          rid <- newId 1
          lifecycle env rid ServiceStop
          expectOutcome env 30 rid OutcomeOk Nothing
          svc <- readStub env "svc"
          assertBool ("service still " <> svc) (svc `L.elem` ["stopped", "absent"])
          entries <- journalEvents env
          assertBool ("journal: " <> show entries) (["start", T.unpack rid, "service-stop"] `L.elem` entries && ["end", T.unpack rid, "ok"] `L.elem` entries)
    , testCase "service-start on an absent, compatible service starts it on the fixed port and observes it answer" $
        withRunning $ \env -> do
          setStub env "svc" "absent"
          rid <- newId 2
          lifecycle env rid ServiceStart
          expectOutcome env 30 rid OutcomeOk Nothing
          readStub env "svc" >>= (@?= "running")
          started <- logHas env ("serve --port " <> show servicePort)
          assertBool "the service was not started on the helper's fixed port" started
    , testCase "service-start on a stopped container restarts it" $
        withRunning $ \env -> do
          setStub env "svc" "stopped"
          rid <- newId 3
          lifecycle env rid ServiceStart
          expectOutcome env 30 rid OutcomeOk Nothing
          readStub env "svc" >>= (@?= "running")
    , testCase "service-restart on a running service stops and starts it" $
        withRunning $ \env -> do
          rid <- newId 4
          lifecycle env rid ServiceRestart
          expectOutcome env 30 rid OutcomeOk Nothing
          readStub env "svc" >>= (@?= "running")
          stopped <- logHas env "docker stop"
          served <- logHas env "serve --port"
          assertBool "restart did not stop and start" (stopped && served)
    , testCase "database-stop with the service stopped, then database-start" $
        withRunning $ \env -> do
          setStub env "svc" "absent"
          a <- newId 5
          lifecycle env a DatabaseStop
          expectOutcome env 30 a OutcomeOk Nothing
          readStub env "db" >>= (@?= "stopped")
          b <- newId 6
          lifecycle env b DatabaseStart
          expectOutcome env 60 b OutcomeOk Nothing
          readStub env "db" >>= (@?= "running")
    , testCase "an expected state that no longer holds is refused and nothing runs" $
        withRunning $ \env -> do
          setStub env "svc" "absent"
          rid <- newId 7
          lifecycle env rid ServiceStop
          expectOutcome env 20 rid OutcomeRefused (Just "state-changed")
          stopped <- logHas env "docker stop"
          assertBool "docker stop ran" (not stopped)
          b <- newId 8
          setStub env "svc" "running"
          lifecycle env b ServiceStart
          expectOutcome env 20 b OutcomeRefused (Just "state-changed")
    , testCase "an incompatible installation is not started (upgrades are P3.3)" $
        withRunning $ \env -> do
          setStub env "svc" "absent"
          setStub env "ready" "no"
          rid <- newId 9
          lifecycle env rid ServiceStart
          expectOutcome env 20 rid OutcomeRefused (Just "not-compatible")
          served <- logHas env "serve --port"
          assertBool "the service was started anyway" (not served)
          readStub env "svc" >>= (@?= "absent")
    , testCase "the database is not stopped under a running service" $
        withRunning $ \env -> do
          rid <- newId 10
          lifecycle env rid DatabaseStop
          expectOutcome env 20 rid OutcomeRefused (Just "state-changed")
          readStub env "db" >>= (@?= "running")
    , testCase "an instance's database is not managed by its control pane" $
        withLifecycleEnv (Just "lct") $ \env -> withLifecycleHelper env [] $ do
          setStub env "svc" "absent"
          rid <- newId 11
          lifecycle env rid DatabaseStop
          expectOutcome env 20 rid OutcomeRefused (Just "not-managed")
          b <- newId 12
          lifecycle env b ServiceStart
          expectOutcome env 30 b OutcomeOk Nothing
          started <- logHas env "--name lockstep-lct "
          assertBool "the instance's service was not the one started" started
    , testCase "a start that fails is failed, with the error as detail" $
        withRunning $ \env -> do
          setStub env "svc" "absent"
          setStub env "mode" "fail-start"
          rid <- newId 13
          lifecycle env rid ServiceStart
          r <- await env 30 rid
          resultOutcome r @?= OutcomeFailed
          assertBool ("no error detail: " <> show (resultDetail r)) (not (T.null (resultDetail r)))
    , testCase "a start that never answers is failed, not ok" $
        withRunning $ \env -> do
          setStub env "svc" "absent"
          setStub env "mode" "no-answer"
          rid <- newId 14
          lifecycle env rid ServiceStart
          r <- await env 60 rid
          resultOutcome r @?= OutcomeFailed
    , testCase "two stops sent together: one runs, the other is refused, never overlapping" $
        withRunning $ \env -> do
          a <- newId 15
          b <- newId 16
          lifecycle env a ServiceStop
          lifecycle env b ServiceStop
          ra <- await env 30 a
          rb <- await env 30 b
          L.sortOn show [(resultOutcome ra, resultReason ra), (resultOutcome rb, resultReason rb)]
            @?= L.sortOn show [(OutcomeOk, Nothing), (OutcomeRefused, Just "state-changed")]
          stops <- L.length . L.filter ("docker stop" `L.isInfixOf`) <$> stubLog env
          stops @?= 1
    , testCase "forged, replayed, stale and wrongly expected lifecycle requests are refused" $
        withRunning $ \env -> do
          t <- now'
          other <- maybe (assertFailure "key") pure (parseChannelKey "0000000000000000000000000000000000000000000000000000000000000002")
          f <- newId 17
          fr <- maybe (assertFailure "id") pure (parseRequestId f)
          place env (T.unpack f <> ".lreq") (encodeLifecycleRequest other (LifecycleRequest fr t ServiceStop (expectedFor ServiceStop)))
          expectOutcome env 20 f OutcomeRefused (Just "bad-mac")
          s <- newId 18
          sr <- maybe (assertFailure "id") pure (parseRequestId s)
          place env (T.unpack s <> ".lreq") (encodeLifecycleRequest (lKey env) (LifecycleRequest sr (t - 500) ServiceStop (expectedFor ServiceStop)))
          expectOutcome env 20 s OutcomeRefused (Just "stale")
          w <- newId 19
          let
            body =
              "lockstep-lifecycle-request 1\nid "
                <> BS8.pack (T.unpack w)
                <> "\nissued "
                <> BS8.pack (show t)
                <> "\nop service-stop\nexpect not-running\n"
          place env (T.unpack w <> ".lreq") (body <> "mac " <> BS8.pack (T.unpack (hmacHex (lKey env) body)) <> "\n")
          expectOutcome env 20 w OutcomeRefused (Just "bad-expect")
          u <- newId 20
          let
            ubody =
              "lockstep-lifecycle-request 1\nid "
                <> BS8.pack (T.unpack u)
                <> "\nissued "
                <> BS8.pack (show t)
                <> "\nop reboot\nexpect running\n"
          place env (T.unpack u <> ".lreq") (ubody <> "mac " <> BS8.pack (T.unpack (hmacHex (lKey env) ubody)) <> "\n")
          expectOutcome env 20 u OutcomeRefused (Just "unknown-op")
          readStub env "svc" >>= (@?= "running")
          setStub env "svc" "running"
          ok <- newId 21
          okr <- maybe (assertFailure "id") pure (parseRequestId ok)
          let
            bytes = encodeLifecycleRequest (lKey env) (LifecycleRequest okr t ServiceRestart (expectedFor ServiceRestart))
          place env (T.unpack ok <> ".lreq") bytes
          expectOutcome env 30 ok OutcomeOk Nothing
          before <- BS.readFile (resultFile env ok)
          restarts <- L.length . L.filter ("docker stop" `L.isInfixOf`) <$> stubLog env
          place env (T.unpack ok <> ".lreq") bytes
          threadDelay 2000000
          after <- BS.readFile (resultFile env ok)
          after @?= before
          restarts' <- L.length . L.filter ("docker stop" `L.isInfixOf`) <$> stubLog env
          restarts' @?= restarts
    , testCase "a lifecycle operation over its time limit is timed-out" $
        withLifecycleEnv Nothing $ \env -> withLifecycleHelper env [("LOCKSTEP_HELPER_TIMEOUT", "3")] $ do
          setStub env "svc" "absent"
          setStub env "mode" "slow"
          rid <- newId 22
          lifecycle env rid ServiceStart
          r <- await env 20 rid
          resultOutcome r @?= OutcomeTimedOut
    , testCase "lifecycle content in a status-kind file is refused as malformed" $
        withRunning $ \env -> do
          rid <- newId 23
          t <- now'
          r <- maybe (assertFailure "id") pure (parseRequestId rid)
          place env (T.unpack rid <> ".req") (encodeLifecycleRequest (lKey env) (LifecycleRequest r t ServiceStop (expectedFor ServiceStop)))
          expectOutcome env 20 rid OutcomeRefused (Just "malformed")
          readStub env "svc" >>= (@?= "running")
    , testCase "status still works and now reports health, Docker and Git" $
        withRunning $ \env -> do
          rid <- newId 24
          t <- now'
          r <- maybe (assertFailure "id") pure (parseRequestId rid)
          place env (T.unpack rid <> ".req") (encodeRequest (lKey env) (ControlRequest r t OpStatus ExpectAny))
          res <- await env 30 rid
          resultOutcome res @?= OutcomeOk
          let
            field n = L.lookup n (resultFields res)
          field "service.state" @?= Just "running"
          field "service.health" @?= Just "answers"
          field "docker.server" @?= Just "29.4.0"
          assertBool "git.present missing" (field "git.present" `L.elem` [Just "yes", Just "no"])
          field "database.readiness" @?= Just "ready"
    ]
