{-# LANGUAGE OverloadedStrings #-}

{- | Behaviour-preservation checks for the Orville conversion of the
persistence layer (stack-compliance pass, 2026-11-07), on a real PostgreSQL
with the production migrations. Each check pins one thing the hand-written
SQL used to do explicitly and the typed definitions now do: uuid text in and
out, bytea digests as lowercase hex, ON CONFLICT inserts, server-clock
expiries, optimistic concurrency, and the job outcome digest computed in the
update. The independent oracle in each case is the server itself, asked with
plain SQL.

Settings come from LOCKSTEP_TEST_PG_*, as for the integration suite; missing
settings fail the test.
-}
module Lockstep.Compliance.PersistenceTest
  ( tests
  ) where

import Control.Exception (SomeException, bracket, try)
import Crypto.Hash (SHA256 (SHA256), hashWith)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString qualified as BS
import Data.List qualified as L
import Data.Maybe (isJust)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Unique (hashUnique, newUnique)
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql
import System.Environment (lookupEnv)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Read (readMaybe)
import Text.Show (show)

import Lockstep.Application.Database (closeDatabase, openDatabase, runMigrations)
import Lockstep.Foundation.Config (mkPort)
import Lockstep.Foundation.SystemConfig (DatabaseConfig (..), mkSecret)
import Lockstep.Persistence.CommandCenter (JobEvidenceRow (..), recentJobs)
import Lockstep.Persistence.Commands (NewReceipt (..), ReceiptRow (rowDigestHex), findReceiptByKey, insertReceipt)
import Lockstep.Persistence.Connection (poolOptions)
import Lockstep.Persistence.Jobs (JobRow (..), claimJob, finishJob, insertNoopJob)
import Lockstep.Persistence.Ledger (SubjectRow (..), insertSubject, subjectRow)
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Persistence.OperatorSessions (insertSession, liveSessionExpiry, revokeLiveSessions)
import Lockstep.Persistence.Projects (ProjectRow (..), findProjectById, insertProject, updateProjectSetup)
import Lockstep.Persistence.Repositories (insertEngineer)

tests :: TestTree
tests =
  testGroup
    "Orville persistence behaviour (stack compliance; real PostgreSQL)"
    [ testCase "uuid columns: canonical text in and out; upper case accepted and read back lower case; malformed text refused by the server" $
        withMigrated $ \run -> do
          run (insertSubject "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D" "ticket" "draft")
          found <- run (subjectRow "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d")
          fmap subjectRowId found @?= Just "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
          refused <- try (run (insertSubject "not-a-uuid" "ticket" "draft")) :: IO (Either SomeException ())
          assertBool "a malformed uuid is refused" (isLeft refused)
    , testCase "bytea digests: every byte value survives, read back as the hex encode(..., 'hex') gives" $
        withMigrated $ \run -> do
          let
            digest = BS.pack ([0, 1, 15, 16, 127, 128, 254, 255] <> L.replicate 24 171)
          inserted <- run (insertReceipt (NewReceipt "compliance-key-0001" 1 "noop" digest "operator" 0 "applied" 1))
          assertBool "the insert returned the row" (isJust inserted)
          row <- run (findReceiptByKey "compliance-key-0001")
          oracle <- run (textQuery "SELECT encode(payload_digest, 'hex') AS v FROM lockstep_command_receipts")
          fmap rowDigestHex row @?= Just (hex digest)
          oracle @?= [hex digest]
    , testCase "ON CONFLICT (name) DO NOTHING: a taken name inserts nothing and says so" $
        withMigrated $ \run -> do
          first <- run (insertEngineer "11111111-1111-4111-8111-111111111111" "ada")
          second <- run (insertEngineer "22222222-2222-4222-8222-222222222222" "ada")
          other <- run (insertEngineer "33333333-3333-4333-8333-333333333333" "grace")
          (first, second, other) @?= (True, False, True)
          names <- run (textQuery "SELECT name AS v FROM lockstep_engineers ORDER BY name")
          names @?= ["ada", "grace"]
    , testCase "a session's expiry is the database clock plus 12 hours, and revocation counts what it revoked" $
        withMigrated $ \run -> do
          let
            digest = BS.replicate 32 7
          expiry <- run (insertSession digest)
          live <- run (liveSessionExpiry digest)
          assertBool "the inserted expiry is the live one" (isJust expiry && expiry == live)
          exact <- run (textQuery "SELECT ((expires_at - created_at) = interval '12 hours')::text AS v FROM lockstep_operator_sessions")
          exact @?= ["true"]
          revoked <- run revokeLiveSessions
          revokedAgain <- run revokeLiveSessions
          (revoked, revokedAgain) @?= (1, 0)
    , testCase "optimistic concurrency: a stale revision changes nothing; the expected one changes the row and adds one" $
        withMigrated $ \run -> do
          let
            projectId = "44444444-4444-4444-8444-444444444444"
          run (insertProject projectId "compliance-project-0001" "Compliance" "outcome" (T.replicate 64 "a"))
          stale <- run (updateProjectSetup projectId 2 "setup-failed" (Just "refused-x") Nothing Nothing Nothing)
          current <- run (updateProjectSetup projectId 1 "setup-failed" (Just "refused-x") Nothing Nothing Nothing)
          row <- run (findProjectById projectId)
          (stale, current) @?= (False, True)
          fmap (\r -> (rowSetup r, rowRefusal r, rowRevision r)) row @?= Just ("setup-failed", Just "refused-x", 2)
    , testCase "a job's outcome digest is SHA-256 of the canonical outcome text (C-P1.6 E3), computed in the finishing update" $
        withMigrated $ \run -> do
          receipt <- run (insertReceipt (NewReceipt "compliance-key-0002" 1 "noop" (BS.replicate 32 1) "operator" 0 "queued" 1))
          receiptId <- maybe (assertFailure "no receipt id") (pure . fst) receipt
          run (insertNoopJob receiptId 3 0 Nothing)
          claimed <- run (claimJob "compliance-owner")
          job <- maybe (assertFailure "nothing claimed") pure claimed
          finished <- run (finishJob (jobRowId job) "compliance-owner" "failed" (Just "boom"))
          assertBool "the owner finished its job" finished
          evidence <- run recentJobs
          let
            canonical = "lockstep-job-outcome-v1\n" <> show (jobRowId job) <> "\nfailed\n0/3\nboom"
          fmap evidenceDigestHex evidence @?= [Just (sha256Hex (T.pack canonical))]
    ]

-- | SHA-256 of a text's UTF-8 bytes, as lowercase hex.
sha256Hex :: T.Text -> T.Text
sha256Hex text =
  TE.decodeLatin1 (convertToBase Base16 (hashWith SHA256 (TE.encodeUtf8 text)))

hex :: BS.ByteString -> T.Text
hex =
  TE.decodeLatin1 . convertToBase Base16

-- | A query whose single column @v@ is text.
textQuery :: O.MonadOrville m => String -> m [T.Text]
textQuery sql =
  O.executeAndDecode
    O.SelectQuery
    (RawSql.fromString sql)
    (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.unboundedTextField "v")))

-- | A fresh database with the production migrations; the action runs Orville statements in it.
withMigrated :: ((forall a. O.Orville a -> IO a) -> IO ()) -> IO ()
withMigrated action = do
  host <- requireEnv "LOCKSTEP_TEST_PG_HOST"
  portText <- requireEnv "LOCKSTEP_TEST_PG_PORT"
  user <- requireEnv "LOCKSTEP_TEST_PG_USER"
  password <- requireEnv "LOCKSTEP_TEST_PG_PASSWORD"
  port <- maybe (assertFailure ("precondition invalid: LOCKSTEP_TEST_PG_PORT=" <> portText)) pure (readMaybe portText >>= mkPort)
  n <- fmap hashUnique newUnique
  now <- getPOSIXTime
  let
    name = "lockstep_c_" <> show (truncate (now * 1000000) :: Integer) <> "_" <> show n
    config database = DatabaseConfig (T.pack host) port (T.pack database) (T.pack user) (mkSecret (T.pack password))
    admin = executeIn (config "postgres")
  bracket
    (admin ("CREATE DATABASE " <> name))
    (\_ -> admin ("DROP DATABASE IF EXISTS " <> name <> " WITH (FORCE)"))
    ( \_ ->
        bracket (openDatabase (config name)) closeDatabase $ \runtime -> do
          migrated <- runMigrations migrations runtime
          either (const (assertFailure "the production migrations did not apply")) (const (pure ())) migrated
          pool <- O.createConnectionPool (poolOptions (config name))
          action (O.runOrville pool)
    )

-- | Runs one statement; a refusal propagates with PostgreSQL's message.
executeIn :: DatabaseConfig -> String -> IO ()
executeIn config sql = do
  pool <- O.createConnectionPool (poolOptions config)
  O.runOrville pool (O.executeVoid O.OtherQuery (RawSql.fromString sql))

requireEnv :: String -> IO String
requireEnv name = do
  value <- lookupEnv name
  maybe (assertFailure ("precondition missing: " <> name <> " is not set (NOT_RUN)")) pure value
