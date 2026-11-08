{-# LANGUAGE OverloadedStrings #-}

{- | Increment A of the type-discipline remediation (2026-11-08): one check per
correctness defect in @docs/reviews/type-discipline-audit-2026-11-08.md@ §4.
Each pins the corrected behaviour and, where bytes are stored, that the
stored bytes do not change. The pure checks need nothing; the database checks
need LOCKSTEP_TEST_PG_*.
-}
module Lockstep.Compliance.DefectsTest
  ( tests
  ) where

import Control.Exception (SomeException, try)
import Crypto.Hash (SHA256 (SHA256), hashWith)
import Data.List qualified as L
import Data.Maybe (isNothing)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.SqlValue qualified as SqlValue
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Command (Actor (..), InvalidReason (..), Revision (..), buildRename, mkRevision)
import Lockstep.Application.Database (MigrateError (..), MigrateReport (..), openDatabase, runMigrationsReporting)
import Lockstep.Application.Ledger (LedgerFailure (..), createTicket, decideTicket, noFaults)
import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Compliance.Support (executeSql, textQuery, withFreshDatabase, withMigrated, withMigratedRuntime)
import Lockstep.Kernel.Conversation (HumanRequest, RequestInput (..), RequestKind (..), newHumanRequest, stepRequest, stepRequestChecked)
import Lockstep.Kernel.Effect (ClassTerms (..), IdempotencyTerms (..), mkEffectSpec)
import Lockstep.Kernel.EventCodec (WorkOrderEvent (..), decodeWorkOrderEvent, encodeWorkOrderEvent, workOrderCreatedText)
import Lockstep.Kernel.Profile (Hasher (..), contentDigestText, mkContentDigest)
import Lockstep.Kernel.Project (SetupState (..), parseSetupState, setupStateCode)
import Lockstep.Kernel.Ticket (TicketInput (..))
import Lockstep.Kernel.Transition (Command (..), Principal (..))
import Lockstep.Persistence.Fields (codeField)
import Lockstep.Persistence.Integrity (IntegrityViolation (..), integrityViolation)
import Lockstep.Persistence.Ledger (insertSubject, subjectRow)
import Lockstep.Persistence.Migration (Migration (..), checksumText, migrationChecksum, mkMigrationId)
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Persistence.Projects (ProjectRow (..), findProjectById, insertProject)

tests :: TestTree
tests =
  testGroup
    "type-discipline Increment A: the nine correctness defects"
    [ testCase "1. sha256Hasher is SHA-256 in lowercase hex through the explicit encoding, the same bytes the Show-based digest gave" $ do
        digestOf "" @?= "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        digestOf "abc" @?= "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        traverse_ (\t -> digestOf t @?= showDigest t) samples
        traverse_ (\t -> fmap contentDigestText (mkContentDigest (digestOf t)) @?= Just (digestOf t)) samples
    , testCase "2. an expected revision is range-checked before it is narrowed to Int64" $ do
        mkRevision (toInteger (maxBound :: Int64)) @?= Right (Revision maxBound)
        mkRevision 0 @?= Right (Revision 0)
        mkRevision (toInteger (maxBound :: Int64) + 1) @?= Left RevisionTooLarge
        -- 2^64 wrapped to revision 0 before the correction.
        mkRevision 18446744073709551616 @?= Left RevisionTooLarge
        mkRevision (-1) @?= Left RevisionNegative
        void (buildRename ActorCli "compliance-key-000001" 18446744073709551616 "a name") @?= Left RevisionTooLarge
    , testCase "3. every production migration's checksum is unchanged: explicit hex equals the Show-encoded value stored in ledgers" $ do
        assertBool "there are migrations" (not (L.null migrations))
        traverse_ (\m -> checksumText (migrationChecksum m) @?= showDigest (migrationSql m)) migrations
    , testCase "4. a message's stored text is the text H1 checked (trimmed, CRLF as LF), and the plain step agrees" $ do
        let
          input = HumanSays 1 "  first\r\nsecond  "
        fmap snd (stepRequestChecked clarification (Command Human input)) @?= Right "first\nsecond"
        fmap fst (stepRequestChecked clarification (Command Human input)) @?= stepRequest clarification (Command Human input)
        fmap snd (stepRequestChecked clarification (Command Human (HumanSays 1 "   "))) @?= Left "text-empty"
    , testCase "5. the creation event's text needs no fallback, and replays as a creation" $ do
        encodeWorkOrderEvent WorkOrderCreated @?= Right workOrderCreatedText
        decodeWorkOrderEvent workOrderCreatedText @?= Just WorkOrderCreated
    , testCase "6. an integrity violation inside a transaction rolls the transaction back" $
        withMigrated $ \run -> do
          let
            subject = "5a5a5a5a-5a5a-4a5a-8a5a-5a5a5a5a5a5a"
          result <- try (run (O.withTransaction (insertSubject subject "ticket" "draft" >> integrityViolation "compliance: a required row is missing"))) :: IO (Either IntegrityViolation ())
          result @?= Left (IntegrityViolation "compliance: a required row is missing")
          found <- run (subjectRow subject)
          assertBool "the subject written before the violation was rolled back" (isNothing found)
    , testCase "7a. a typed code column decodes the codes it knows and refuses any other" $ do
        let
          field = codeField "project setup state" setupStateCode parseSetupState "setup"
          decode = O.sqlTypeFromSql (O.fieldType field) . SqlValue.fromText
        traverse_ (\s -> decode (setupStateCode s) @?= Right s) [minBound .. maxBound :: SetupState]
        assertBool "an unknown code is a decoding failure" (isLeft (decode "ready"))
    , testCase "7b. a project row whose setup state is corrupt fails to read; it is not shown as organized" $
        withMigrated $ \run -> do
          let
            projectId = "66666666-6666-4666-8666-666666666666"
          run (insertProject projectId "compliance-project-0007" "Compliance" "outcome" (T.replicate 64 "a"))
          run (executeSql "ALTER TABLE lockstep_projects DROP CONSTRAINT lockstep_projects_setup_check")
          run (executeSql ("UPDATE lockstep_projects SET setup = 'bogus' WHERE id = '" <> T.unpack projectId <> "'"))
          stored <- run (textQuery "SELECT setup AS v FROM lockstep_projects")
          stored @?= ["bogus"]
          read' <- try (run (fmap (fmap rowSetup) (findProjectById projectId))) :: IO (Either SomeException (Maybe SetupState))
          assertBool "the corrupt row did not read as a project" (isLeft read')
    , testCase "8. a failed migration reports PostgreSQL's error with the frozen classification" $
        withFreshDatabase $ \config -> do
          runtime <- openDatabase config
          one <- maybe (assertFailure "id") pure (mkMigrationId 1)
          two <- maybe (assertFailure "id") pure (mkMigrationId 2)
          result <- runMigrationsReporting [Migration one "create a" "CREATE TABLE a (id integer);", Migration two "broken" "SELECT * FROM does_not_exist;"] runtime
          case result of
            Left report -> do
              reportError report @?= MigrateFailed two [one]
              assertBool ("PostgreSQL's message is kept: " <> show (reportCause report)) (maybe False ("does_not_exist" `L.isInfixOf`) (reportCause report))
            Right applied -> assertFailure ("the broken migration applied: " <> show (L.length applied))
    , testCase "9a. a caller's revision outside the integer range is refused before anything is written" $
        withMigratedRuntime $ \runtime run -> do
          created <- createTicket runtime "Compliance ticket"
          ticket <- either (assertFailure . show) pure created
          -- 2^32 + 1 narrowed to 1 before the correction, the ticket's real revision.
          decided <- decideTicket runtime noFaults ticket 4294967297 (Command Human TicketAccept)
          decided @?= Left (LedgerRefused "revision-out-of-range" "a revision or generation is outside the range of a stored integer")
          refusals <- run (textQuery "SELECT count(*)::text AS v FROM lockstep_decision_refusals")
          refusals @?= ["0"]
    , testCase "9b. an effect key lifetime a bigint cannot hold is refused by the Kernel" $ do
        let
          terms seconds = TermsIdempotent (IdempotencyTerms seconds True)
        assertBool "the largest bigint lifetime is accepted" (isRight (mkEffectSpec "deploy" (terms (toInteger (maxBound :: Int64))) 0))
        assertBool "one more second is refused" (isLeft (mkEffectSpec "deploy" (terms (toInteger (maxBound :: Int64) + 1)) 0))
    ]

samples :: [T.Text]
samples =
  ["", "a", "abc", "lockstep", "π ≠ 3", T.replicate 1000 "x", "line\nbreak\r\n", "\0"]

digestOf :: T.Text -> T.Text
digestOf text =
  case sha256Hasher of
    Hasher f -> contentDigestText (f text)

-- | The former encoding, as the oracle: crypton's 'show' of the digest.
showDigest :: T.Text -> T.Text
showDigest =
  T.pack . show . hashWith SHA256 . TE.encodeUtf8

clarification :: HumanRequest
clarification =
  newHumanRequest ClarificationRequest
