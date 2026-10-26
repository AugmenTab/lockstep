{-# LANGUAGE OverloadedStrings #-}

{- | Prepare, upgrade, first installation and recovery in the helper (contract
C-P3.3 U1–U9), with the real @scripts/control-helper@, @scripts/service@ and
@scripts/db@ in a throwaway Git checkout and stateful stubs. Every failure the
Phase 3 handoff names for P3.3 is a case here: backup cannot be created,
backup corrupt, migration fails, database ahead of the binary, service start
fails, upgrade interrupted, two upgrades race, an instance beside the
operator's installation.
-}
module Lockstep.InstallHelperTest
  ( tests
  ) where

import Control.Concurrent (threadDelay)
import Data.ByteString qualified as BS
import Data.List qualified as L
import Data.Maybe (fromMaybe, isJust, isNothing)
import Data.Text qualified as T
import Data.Time.Clock.POSIX (getPOSIXTime)
import Flipstone.Prelude
import Numeric (showHex)
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, renameFile)
import System.IO (FilePath, readFile, writeFile)
import System.Posix.Files (setFileMode)
import System.Posix.Signals (signalProcess)
import System.Process qualified as Process
import System.Timeout (timeout)
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
  , parseRequestId
  )
import Lockstep.Foundation.InstallProtocol (InstallExpect (..), InstallOp (..), InstallRequest (..), encodeInstallRequest)
import Lockstep.Support.Install
  ( IEnv (..)
  , fakeBinary
  , iInstall
  , iPane
  , iStaging
  , readFileTrim
  , setFile
  , startInstallHelper
  , stubCalls
  , withInstallEnv
  , withInstallHelper
  )

now' :: IO Integer
now' =
  floor <$> getPOSIXTime

counter :: IO Integer
counter = do
  t <- getPOSIXTime
  pure (floor (t * 1000000))

newId :: IO T.Text
newId = do
  n <- counter
  pure (T.justifyRight 32 '0' (T.pack (showHex n "")))

place :: IEnv -> String -> BS.ByteString -> IO ()
place env name bytes = do
  let
    tmp = iPane env <> "/requests/." <> name <> ".tmp"
  BS.writeFile tmp bytes
  setFileMode tmp 0o600
  renameFile tmp (iPane env <> "/requests/" <> name)

install :: IEnv -> InstallOp -> InstallExpect -> IO T.Text
install env op expect = do
  rid <- newId
  t <- now'
  r <- maybe (assertFailure "id") pure (parseRequestId rid)
  place env (T.unpack rid <> ".ireq") (encodeInstallRequest (iKey env) (InstallRequest r t op expect))
  pure rid

statusOf :: IEnv -> IO ControlResult
statusOf env = do
  rid <- newId
  t <- now'
  r <- maybe (assertFailure "id") pure (parseRequestId rid)
  place env (T.unpack rid <> ".req") (encodeRequest (iKey env) (ControlRequest r t OpStatus ExpectAny))
  await env 60 rid

field :: T.Text -> ControlResult -> T.Text
field name r =
  fromMaybe "<absent>" (L.lookup name (resultFields r))

await :: IEnv -> Int -> T.Text -> IO ControlResult
await env seconds rid =
  let
    path = iPane env <> "/results/" <> T.unpack rid <> ".res"
    attempt :: Int -> IO ControlResult
    attempt remaining = do
      present <- doesFileExist path
      if present
        then BS.readFile path >>= either (\e -> assertFailure ("result does not verify: " <> show e)) pure . decodeResult (iKey env)
        else
          if remaining <= 0
            then do
              out <- readFile (iStub env <> "/helper.out")
              assertFailure ("no result for " <> T.unpack rid <> " within " <> show seconds <> " s:\n" <> out)
            else threadDelay 100000 >> attempt (remaining - 1)
  in
    attempt (seconds * 10)

outcome :: IEnv -> Int -> T.Text -> IO (Outcome, Maybe T.Text)
outcome env seconds rid = do
  r <- await env seconds rid
  pure (resultOutcome r, resultReason r)

-- | Prepares a candidate and returns its expectation (from status, as the page would).
prepared :: IEnv -> IO InstallExpect
prepared env = do
  p <- install env PrepareCandidate CandidateNone
  outcome env 60 p >>= (@?= (OutcomeOk, Nothing))
  s <- statusOf env
  field "candidate.present" s @?= "yes"
  let
    digest = field "candidate.digest" s
  assertBool ("candidate.digest is not 16 hex: " <> show digest) (T.length digest == 16)
  pure (CandidateDigest digest)

revisionKnownBy :: FilePath -> IO String
revisionKnownBy dir =
  L.concat . L.take 1 . L.filter ("# rev " `L.isPrefixOf`) . L.lines <$> readFile (dir <> "/bin/lockstep")

indexOf :: [String] -> String -> Maybe Int
indexOf calls needle =
  L.findIndex (needle `L.isInfixOf`) calls

operator :: (IEnv -> IO a) -> IO a
operator action =
  withInstallEnv Nothing (Just 5) 5 $ \env -> withInstallHelper env [] (action env)

tests :: TestTree
tests =
  testGroup
    "helper install and upgrade (C-P3.3)"
    [ testCase "prepare builds the clean checkout into staging; status shows the candidate" $
        operator $ \env -> do
          _ <- prepared env
          revisionKnownBy (iStaging env) >>= (@?= "# rev 6")
          s <- statusOf env
          field "candidate.pending" s @?= "1"
          head' <- Process.readProcess "git" ["-C", iRoot env, "rev-parse", "HEAD"] ""
          field "candidate.commit" s @?= T.pack (L.filter (/= '\n') head')
          revisionKnownBy (iInstall env) >>= (@?= "# rev 5")
    , testCase "prepare refuses a checkout with uncommitted changes and builds nothing" $
        operator $ \env -> do
          writeFile (iRoot env <> "/README") "changed\n"
          p <- install env PrepareCandidate CandidateNone
          outcome env 30 p >>= (@?= (OutcomeRefused, Just "dirty-checkout"))
          calls <- stubCalls env
          assertBool "a build ran" (isNothingIndex (indexOf calls "docker build"))
          doesDirectoryExist (iStaging env) >>= assertBool "staging exists" . not
    , testCase "prepare with an expectation that does not match the staging is refused" $
        operator $ \env -> do
          p <- install env PrepareCandidate (CandidateDigest "0011223344556677")
          outcome env 30 p >>= (@?= (OutcomeRefused, Just "state-changed"))
    , testCase "a failing build is failed and leaves no candidate" $
        operator $ \env -> do
          setFile env "flags" "build-fail"
          p <- install env PrepareCandidate CandidateNone
          (o, _) <- outcome env 60 p
          o @?= OutcomeFailed
          s <- statusOf env
          field "candidate.present" s @?= "no"
    , testCase "upgrade: back up and verify, stop, migrate with the backup, activate, start, verify" $
        operator $ \env -> do
          expect <- prepared env
          a <- install env ApplyCandidate expect
          outcome env 120 a >>= (@?= (OutcomeOk, Nothing))
          readFileTrim (iStub env <> "/applied") >>= (@?= "6")
          readFileTrim (iStub env <> "/serving") >>= (@?= "6")
          readFileTrim (iStub env <> "/svc") >>= (@?= "running")
          revisionKnownBy (iInstall env) >>= (@?= "# rev 6")
          revisionKnownBy (iInstall env <> ".previous") >>= (@?= "# rev 5")
          backups <- L.filter (".dump" `L.isSuffixOf`) <$> listDirectory (iRoot env <> "/.local/backups")
          L.length backups @?= 1
          traverse_ (\b -> doesFileExist (iRoot env <> "/.local/backups/" <> b <> ".sha256") >>= assertBool "no digest file") backups
          calls <- stubCalls env
          let
            order = fmap (indexOf calls) ["pg_dump", "pg_restore --list", "docker stop", "db migrate", " serve "]
          assertBool ("steps out of order: " <> show order) (L.all isJust' order && L.sort order == order)
          assertBool "migrate did not name the backup" (L.any (\c -> "db migrate" `L.isInfixOf` c && "--backup" `L.isInfixOf` c) calls)
          s <- statusOf env
          field "database.readiness" s @?= "ready"
          field "upgrade.state" s @?= "none"
          field "candidate.present" s @?= "no"
    , testCase "a candidate other than the one the page showed is not applied" $
        operator $ \env -> do
          _ <- prepared env
          a <- install env ApplyCandidate (CandidateDigest "0011223344556677")
          outcome env 30 a >>= (@?= (OutcomeRefused, Just "state-changed"))
          readFileTrim (iStub env <> "/applied") >>= (@?= "5")
          revisionKnownBy (iInstall env) >>= (@?= "# rev 5")
    , testCase "a backup that cannot be created stops the upgrade before anything changes" $
        operator $ \env -> do
          expect <- prepared env
          setFile env "flags" "backup-empty"
          a <- install env ApplyCandidate expect
          (o, _) <- outcome env 60 a
          o @?= OutcomeFailed
          calls <- stubCalls env
          assertBool "the service was stopped" (isNothingIndex (indexOf calls "docker stop"))
          assertBool "a migration ran" (isNothingIndex (indexOf calls "db migrate"))
          readFileTrim (iStub env <> "/svc") >>= (@?= "running")
          revisionKnownBy (iInstall env) >>= (@?= "# rev 5")
          s <- statusOf env
          field "upgrade.state" s @?= "none"
    , testCase "a corrupt backup stops the upgrade before anything changes" $
        operator $ \env -> do
          expect <- prepared env
          setFile env "flags" "backup-corrupt"
          a <- install env ApplyCandidate expect
          (o, _) <- outcome env 60 a
          o @?= OutcomeFailed
          calls <- stubCalls env
          assertBool "a migration ran" (isNothingIndex (indexOf calls "db migrate"))
          readFileTrim (iStub env <> "/applied") >>= (@?= "5")
          readFileTrim (iStub env <> "/svc") >>= (@?= "running")
    , testCase "a failed migration needs recovery; restore-previous restores the backup and the previous version" $
        operator $ \env -> do
          expect <- prepared env
          setFile env "flags" "migrate-fail"
          a <- install env ApplyCandidate expect
          (o, _) <- outcome env 120 a
          o @?= OutcomeFailed
          s <- statusOf env
          field "upgrade.state" s @?= "recovery-needed"
          field "upgrade.id" s @?= a
          field "upgrade.step" s @?= "migrate"
          setFile env "flags" ""
          r <- install env RestorePrevious (RecoveryOf a)
          outcome env 120 r >>= (@?= (OutcomeOk, Nothing))
          readFileTrim (iStub env <> "/applied") >>= (@?= "5")
          revisionKnownBy (iInstall env) >>= (@?= "# rev 5")
          readFileTrim (iStub env <> "/serving") >>= (@?= "5")
          s' <- statusOf env
          field "upgrade.state" s' @?= "none"
          field "database.readiness" s' @?= "ready"
    , testCase "a service that does not start after the migration needs recovery, and recovers" $
        operator $ \env -> do
          expect <- prepared env
          setFile env "flags" "start-fail"
          a <- install env ApplyCandidate expect
          (o, _) <- outcome env 120 a
          o @?= OutcomeFailed
          s <- statusOf env
          field "upgrade.state" s @?= "recovery-needed"
          field "upgrade.step" s @?= "start"
          setFile env "flags" ""
          r <- install env RestorePrevious (RecoveryOf a)
          outcome env 120 r >>= (@?= (OutcomeOk, Nothing))
          readFileTrim (iStub env <> "/applied") >>= (@?= "5")
          readFileTrim (iStub env <> "/serving") >>= (@?= "5")
    , testCase "recovery names the exact failed upgrade" $
        operator $ \env -> do
          expect <- prepared env
          setFile env "flags" "migrate-fail"
          a <- install env ApplyCandidate expect
          _ <- outcome env 120 a
          other <- newId
          r <- install env RestorePrevious (RecoveryOf other)
          outcome env 30 r >>= (@?= (OutcomeRefused, Just "state-changed"))
    , testCase "a database ahead of the candidate is not downgraded; a newer candidate upgrades it" $
        withInstallEnv Nothing (Just 5) 7 $ \env -> withInstallHelper env [] $ do
          s <- statusOf env
          field "database.readiness" s @?= "not-ready"
          field "database.reason" s @?= "schema_invalid"
          expect <- prepared env
          a <- install env ApplyCandidate expect
          outcome env 60 a >>= (@?= (OutcomeRefused, Just "database-ahead"))
          readFileTrim (iStub env <> "/applied") >>= (@?= "7")
          setFile env "next" "8"
          p <- install env PrepareCandidate expect
          outcome env 60 p >>= (@?= (OutcomeOk, Nothing))
          s2 <- statusOf env
          b <- install env ApplyCandidate (CandidateDigest (field "candidate.digest" s2))
          outcome env 120 b >>= (@?= (OutcomeOk, Nothing))
          readFileTrim (iStub env <> "/applied") >>= (@?= "8")
    , testCase "an upgrade interrupted by a helper crash is reported, and can be recovered" $
        withInstallEnv Nothing (Just 5) 5 $ \env -> do
          handle <- startInstallHelper env []
          expect <- prepared env
          setFile env "flags" "slow-migrate"
          a <- install env ApplyCandidate expect
          waitUntil 60 (L.any ("db migrate" `L.isInfixOf`) <$> stubCalls env)
          threadDelay 500000
          Process.getPid handle >>= traverse_ (signalProcess 9)
          void (timeout 5000000 (Process.waitForProcess handle))
          setFile env "flags" ""
          withInstallHelper env [] $ do
            outcome env 30 a >>= (@?= (OutcomeInterrupted, Nothing))
            s <- statusOf env
            field "upgrade.state" s @?= "interrupted"
            field "upgrade.step" s @?= "migrate"
            r <- install env RestorePrevious (RecoveryOf a)
            outcome env 120 r >>= (@?= (OutcomeOk, Nothing))
            revisionKnownBy (iInstall env) >>= (@?= "# rev 5")
            readFileTrim (iStub env <> "/applied") >>= (@?= "5")
    , testCase "two upgrade requests for one candidate: one applies it, the other is refused" $
        operator $ \env -> do
          expect <- prepared env
          a <- install env ApplyCandidate expect
          b <- install env ApplyCandidate expect
          ra <- outcome env 120 a
          rb <- outcome env 120 b
          L.sortOn show [ra, rb] @?= L.sortOn show [(OutcomeOk, Nothing), (OutcomeRefused, Just "state-changed")]
          migrations <- L.length . L.filter ("db migrate" `L.isInfixOf`) <$> stubCalls env
          migrations @?= 1
    , testCase "a first installation needs no backup of an empty database" $
        withInstallEnv Nothing Nothing 0 $ \env -> withInstallHelper env [] $ do
          s <- statusOf env
          field "install.present" s @?= "no"
          expect <- prepared env
          a <- install env ApplyCandidate expect
          outcome env 120 a >>= (@?= (OutcomeOk, Nothing))
          revisionKnownBy (iInstall env) >>= (@?= "# rev 6")
          readFileTrim (iStub env <> "/applied") >>= (@?= "6")
          calls <- stubCalls env
          assertBool "a backup was taken of an empty database" (isNothingIndex (indexOf calls "pg_dump"))
    , testCase "an instance upgrades only its own installation, staging and database" $
        withInstallEnv (Just "q") (Just 5) 5 $ \env -> do
          let
            operatorInstall = iRoot env <> "/.local/install"
          createDirectoryIfMissing True (operatorInstall <> "/bin")
          writeFile (operatorInstall <> "/bin/lockstep") (fakeBinary 4)
          writeFile (iRoot env <> "/.local/config/lockstep-q.json") "{\"database\":{\"host\":\"lockstep-postgres\",\"port\":5432,\"name\":\"lockstep_q\",\"username\":\"lockstep\",\"password\":\"x\"}}\n"
          withInstallHelper env [] $ do
            expect <- prepared env
            a <- install env ApplyCandidate expect
            outcome env 120 a >>= (@?= (OutcomeOk, Nothing))
            revisionKnownBy (iInstall env) >>= (@?= "# rev 6")
            revisionKnownBy operatorInstall >>= (@?= "# rev 4")
            doesDirectoryExist (iRoot env <> "/.local/staging-install") >>= assertBool "the operator's staging was used" . not
            calls <- stubCalls env
            assertBool "the backup was not of the instance's database" (L.any (\c -> "pg_dump" `L.isInfixOf` c && "lockstep_q" `L.isInfixOf` c) calls)
            assertBool "the operator's service was touched" (not (L.any ("lockstep-service" `L.isInfixOf`) calls))
    , testCase "install requests are refused in the other kinds' files and unknown ones are refused" $
        operator $ \env -> do
          rid <- newId
          t <- now'
          r <- maybe (assertFailure "id") pure (parseRequestId rid)
          place env (T.unpack rid <> ".lreq") (encodeInstallRequest (iKey env) (InstallRequest r t PrepareCandidate CandidateNone))
          outcome env 30 rid >>= (@?= (OutcomeRefused, Just "malformed"))
          dirExists <- doesDirectoryExist (iStaging env)
          assertBool "a candidate was built" (not dirExists)
    ]
 where
  isNothingIndex = isNothing
  isJust' = isJust

waitUntil :: Int -> IO Bool -> Assertion
waitUntil seconds check =
  let
    attempt :: Int -> Assertion
    attempt remaining = do
      ok <- check
      unless' ok $
        if remaining <= 0
          then assertFailure ("condition not reached within " <> show seconds <> " s")
          else threadDelay 100000 >> attempt (remaining - 1)
  in
    attempt (seconds * 10)
 where
  unless' ok act = if ok then pure () else act
