{-# LANGUAGE OverloadedStrings #-}

{- | Behaviour-preservation checks for the Orville conversion of the
persistence layer (stack-compliance pass, 2026-11-07), on a real PostgreSQL
with the production migrations. Each check pins one thing the hand-written
SQL used to do explicitly and the typed definitions now do: native uuid in and
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

import Control.Exception (SomeException, try)
import Crypto.Hash (SHA256 (SHA256), hashWith)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString qualified as BS
import Data.List qualified as L
import Data.Maybe (isJust)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Compliance.Support (executeSql, identity, textQuery, withMigrated)
import Lockstep.Kernel.Identity (EngineerId (..), ProjectId (..), parseUuid, uuidText)
import Lockstep.Kernel.Project (SetupState (..))
import Lockstep.Persistence.CommandCenter (JobEvidenceRow (..), recentJobs)
import Lockstep.Persistence.Commands (NewReceipt (..), ReceiptRow (rowDigestHex), findReceiptByKey, insertReceipt)
import Lockstep.Persistence.Jobs (JobEnd (..), JobRow (..), claimJob, finishJob, insertNoopJob)
import Lockstep.Persistence.Ledger (SubjectKind (..), SubjectRow (..), insertSubject, subjectRow)
import Lockstep.Persistence.OperatorSessions (insertSession, liveSessionExpiry, revokeLiveSessions)
import Lockstep.Persistence.Projects (ProjectRow (..), findProjectById, insertProject, updateProjectSetup)
import Lockstep.Persistence.Repositories (insertEngineer)

tests :: TestTree
tests =
  testGroup
    "Orville persistence behaviour (stack compliance; real PostgreSQL)"
    [ testCase "uuid columns: the library UUID in and out, stored as the server's own uuid; malformed text has no UUID to send" $
        withMigrated $ \run -> do
          subject <- identity "0a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
          run (insertSubject subject TicketSubject "draft")
          found <- run (subjectRow subject)
          fmap subjectRowId found @?= Just subject
          oracle <- run (textQuery "SELECT id::text AS v FROM lockstep_subjects")
          oracle @?= [uuidText subject]
          -- A row written by the server from upper-case text is the same UUID.
          run (executeSql "INSERT INTO lockstep_subjects (id, kind, revision, state) VALUES ('1A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D', 'ticket', 1, 'draft')")
          upper <- identity "1a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
          foundUpper <- run (subjectRow upper)
          fmap subjectRowId foundUpper @?= Just upper
          assertBool "malformed text is no UUID" (isLeft (parseUuid "not-a-uuid"))
          refused <- try (run (executeSql "INSERT INTO lockstep_subjects (id, kind, revision, state) VALUES ('not-a-uuid', 'ticket', 1, 'draft')")) :: IO (Either SomeException ())
          assertBool "the server refuses it too" (isLeft refused)
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
          ada <- identity "11111111-1111-4111-8111-111111111111"
          ada2 <- identity "22222222-2222-4222-8222-222222222222"
          grace <- identity "33333333-3333-4333-8333-333333333333"
          first <- run (insertEngineer ada "ada")
          second <- run (insertEngineer ada2 "ada")
          other <- run (insertEngineer grace "grace")
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
          projectId <- identity "44444444-4444-4444-8444-444444444444"
          run (insertProject projectId "compliance-project-0001" "Compliance" "outcome" (T.replicate 64 "a"))
          stale <- run (updateProjectSetup projectId 2 SetupFailed (Just "refused-x") Nothing Nothing Nothing)
          current <- run (updateProjectSetup projectId 1 SetupFailed (Just "refused-x") Nothing Nothing Nothing)
          row <- run (findProjectById projectId)
          (stale, current) @?= (False, True)
          fmap (\r -> (rowSetup r, rowRefusal r, rowRevision r)) row @?= Just (SetupFailed, Just "refused-x", 2)
    , testCase "a job's outcome digest is SHA-256 of the canonical outcome text (C-P1.6 E3), computed in the finishing update" $
        withMigrated $ \run -> do
          receipt <- run (insertReceipt (NewReceipt "compliance-key-0002" 1 "noop" (BS.replicate 32 1) "operator" 0 "queued" 1))
          receiptId <- maybe (assertFailure "no receipt id") (pure . fst) receipt
          run (insertNoopJob receiptId 3 0 Nothing)
          claimed <- run (claimJob "compliance-owner")
          job <- maybe (assertFailure "nothing claimed") pure claimed
          finished <- run (finishJob (jobRowId job) "compliance-owner" EndFailed (Just "boom"))
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
