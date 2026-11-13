{- | What a coding transaction's records show a person (contract C-P4.16 U1):
each criterion, how it was checked, what the checks did, the findings and
how they were disposed of, the review, and anything Lockstep could not
tell. Read back from the records the engine wrote; a record that does not
read back is reported as unreadable, never guessed at.
-}
module Lockstep.Application.EngineEvidence
  ( Evidence (..)
  , CheckRun (..)
  , FindingTime (..)
  , FindingView (..)
  , ReviewView (..)
  , transactionEvidence
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Maybe (catMaybes, isNothing)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Fleece.Aeson qualified as FA
import Flipstone.Prelude

import Lockstep.Application.Engine (InvocationView (..), RecordView (..), TransactionView (..))
import Lockstep.Application.EngineCandidate (recordedCandidate)
import Lockstep.Application.EngineRecords
  ( FindingRecord (FindingRecord)
  , ReviewRecord (ReviewRecord)
  , VerificationRun (VerificationRun)
  , VerificationSummary (VerificationSummary)
  , findingSchema
  , reviewSchema
  , verificationSchema
  , verificationSummarySchema
  )
import Lockstep.Kernel.Candidate (MutantRun)
import Lockstep.Kernel.Roles (Candidate (..), CandidateTest (..), Criterion (..), Role (..), Verdict, roleName)
import Lockstep.Kernel.Runner (OutcomeKind, RoleEnding (..), roleEndingFromText)
import Lockstep.Kernel.Transaction (Disposition, RecordKind (..), recordKindText)

-- | One command the Supervisor ran on the candidate commit, and what it did.
data CheckRun
  = CheckRun
  { checkCommand :: [T.Text]
  , checkOutcome :: OutcomeKind
  , checkExit :: Maybe Integer
  , checkStdout :: T.Text
  , checkStderr :: T.Text
  }
  deriving (Eq)

-- | When a finding was made.
data FindingTime
  = -- | before the freeze (a @finding@ record)
    BeforeChange
  | -- | after the implementation (a @post-finding@ record)
    AfterChange
  deriving (Eq)

data FindingView
  = FindingView
  { findingWhen :: FindingTime
  , findingRequirementId :: T.Text
  , findingClaimText :: T.Text
  , findingMutant :: MutantRun
  , findingDisposition :: Disposition
  }
  deriving (Eq)

data ReviewView
  = ReviewView
  { reviewCommit :: T.Text
  , reviewVerdict :: Verdict
  , reviewReasons :: [T.Text]
  }
  deriving (Eq)

data Evidence
  = Evidence
  { evidenceCriteria :: [Criterion]
  -- ^ What the fix must do (the latest candidate's criteria).
  , evidenceTests :: [CandidateTest]
  -- ^ The tests that check it (frozen once the freeze happened).
  , evidenceCommands :: [[T.Text]]
  -- ^ The other verification commands.
  , evidenceRuns :: [CheckRun]
  -- ^ The latest verification's runs.
  , evidencePassed :: Maybe (T.Text, Bool)
  -- ^ The latest verification: its commit and whether everything passed; Nothing if none ran.
  , evidenceFindings :: [FindingView]
  , evidenceReview :: Maybe ReviewView
  , evidenceUncertain :: [InvocationView]
  -- ^ Role runs whose outcome is not known (cut short) or still running.
  , evidenceUnreadable :: [Int]
  -- ^ Records that did not read back (their sequence numbers).
  , evidenceAttempts :: Int
  {- ^ C-P4.R1 R-A1: how many changes the Implementer made; the runs, the
  findings after the change and the review are those of the latest one.
  -}
  }

-- Documents -----------------------------------------------------------------------------
--
-- Each record is read through the schema it is written with ("Lockstep.Application.EngineRecords").

decodeWith :: (LBS.ByteString -> Either String a) -> RecordView -> Either Int a
decodeWith decoder r =
  either (const (Left (recordSequence r))) Right (decoder (LBS.fromStrict (TE.encodeUtf8 (recordBody r))))

-- Reading ---------------------------------------------------------------------------------

transactionEvidence :: TransactionView -> Evidence
transactionEvidence view =
  Evidence
    { evidenceCriteria = maybe [] candidateCriteria candidate
    , evidenceTests = maybe [] candidateTests candidate
    , evidenceCommands = maybe [] candidateVerification candidate
    , evidenceRuns = [CheckRun c o x s e | Right (VerificationRun c o x s e) <- fmap snd runs]
    , evidencePassed = (\(VerificationSummary c p) -> (c, p)) <$> lastRight (current summaries)
    , evidenceFindings =
        [FindingView BeforeChange r c m d | Right (FindingRecord r c _ m d) <- fmap snd (decodedKind (FA.decode findingSchema) RecordFinding)]
          <> [FindingView AfterChange r c m d | Right (FindingRecord r c _ m d) <- current (decodedKind (FA.decode findingSchema) RecordPostFinding)]
    , evidenceReview = (\(ReviewRecord c v rs _) -> ReviewView c v rs) <$> lastRight (current reviews)
    , evidenceUncertain = L.filter unsettled (viewInvocations view)
    , evidenceUnreadable =
        L.sort
          ( lefts (fmap snd runs)
              <> lefts (fmap snd summaries)
              <> lefts (fmap snd reviews)
              <> [n | k <- [RecordFinding, RecordPostFinding], Left n <- fmap (decodeWith (FA.decode findingSchema)) (ofKind k)]
              <> [recordSequence r | r <- ofKind RecordCandidate, isNothing (recordedCandidate (recordBody r))]
          )
    , evidenceAttempts = L.length (ofKind RecordImplementation)
    }
 where
  records = viewRecords view
  -- The view keeps a record's kind as its stored text ('recordKindText').
  ofKind kind = L.filter ((== recordKindText kind) . recordKind) records
  -- Each decoded record of a kind with its sequence number.
  decodedKind :: (LBS.ByteString -> Either String a) -> RecordKind -> [(Int, Either Int a)]
  decodedKind decoder kind = [(recordSequence r, decodeWith decoder r) | r <- ofKind kind]
  candidate = lastJust (fmap (recordedCandidate . recordBody) (ofKind RecordCandidate))
  summaries = decodedKind (FA.decode verificationSummarySchema) RecordVerificationSummary
  reviews = decodedKind (FA.decode reviewSchema) RecordReview
  -- The latest attempt begins with the latest implementation record.
  attemptFrom = maybe 0 recordSequence (headOf (L.reverse (ofKind RecordImplementation)))
  current :: [(Int, b)] -> [b]
  current decoded = [d | (n, d) <- decoded, n > attemptFrom]
  -- The runs of the latest verification of this attempt: those after the summary before it.
  latestRuns =
    case L.reverse [r | r <- ofKind RecordVerificationSummary, recordSequence r > attemptFrom] of
      [] -> []
      lastSummary : _ ->
        let
          from = maybe attemptFrom recordSequence (headOf (L.reverse [r | r <- ofKind RecordVerificationSummary, recordSequence r < recordSequence lastSummary]))
        in
          [r | r <- ofKind RecordVerification, recordSequence r > max from attemptFrom, recordSequence r < recordSequence lastSummary]
  runs = [(recordSequence r, decodeWith (FA.decode verificationSchema) r) | r <- latestRuns]
  -- A role's run still going, or one whose ending is not known ('roleEndingFromText').
  unsettled i =
    invocationWhat i `L.elem` fmap roleName [Planner, Challenger, Implementer, Reviewer]
      && maybe True (unknownEnding . roleEndingFromText) (invocationOutcome i)
  unknownEnding ending =
    case ending of
      RoleEndedUnsettled -> True
      RoleEndedUncertain _ -> True
      RoleEndedAnswered -> False
      RoleEndedFailed _ -> False

lastRight :: [Either e a] -> Maybe a
lastRight xs =
  headOf (L.reverse (rights xs))

lastJust :: [Maybe a] -> Maybe a
lastJust xs =
  headOf (L.reverse (catMaybes xs))

headOf :: [a] -> Maybe a
headOf xs =
  case xs of
    x : _ -> Just x
    [] -> Nothing
