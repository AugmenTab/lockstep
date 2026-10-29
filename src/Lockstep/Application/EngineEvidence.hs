{- | What a coding transaction's records show a person (contract C-P4.16 U1):
each criterion, how it was checked, what the checks did, the findings and
how they were disposed of, the review, and anything Lockstep could not
tell. Read back from the records the engine wrote; a record that does not
read back is reported as unreadable, never guessed at.
-}
module Lockstep.Application.EngineEvidence
  ( Evidence (..)
  , CheckRun (..)
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
import Fleece.Core ((#+))
import Fleece.Core qualified as FC
import Flipstone.Prelude

import Lockstep.Application.Engine (InvocationView (..), RecordView (..), TransactionView (..))
import Lockstep.Application.EngineCandidate (recordedCandidate)
import Lockstep.Kernel.Roles (Candidate (..), CandidateTest (..), Criterion (..))

-- | One command the Supervisor ran on the candidate commit, and what it did.
data CheckRun
  = CheckRun
  { checkCommand :: [T.Text]
  , checkOutcome :: T.Text
  , checkExit :: Maybe Integer
  , checkStdout :: T.Text
  , checkStderr :: T.Text
  }
  deriving (Eq)

-- | A finding: before the freeze (@before@) or after the implementation (@after@).
data FindingView
  = FindingView
  { findingWhen :: T.Text
  , findingRequirementId :: T.Text
  , findingClaimText :: T.Text
  , findingMutant :: T.Text
  , findingDisposition :: T.Text
  }
  deriving (Eq)

data ReviewView
  = ReviewView
  { reviewCommit :: T.Text
  , reviewVerdict :: T.Text
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

data DocRun
  = DocRun [T.Text] T.Text (Maybe Integer) T.Text T.Text

runSchema :: FC.Fleece t => FC.Schema t DocRun
runSchema =
  FC.object $
    FC.constructor DocRun
      #+ FC.required "command" (\(DocRun c _ _ _ _) -> c) (FC.list FC.text)
      #+ FC.required "outcome" (\(DocRun _ o _ _ _) -> o) FC.text
      #+ FC.optional "exit" (\(DocRun _ _ x _ _) -> x) FC.integer
      #+ FC.required "stdout_tail" (\(DocRun _ _ _ s _) -> s) FC.text
      #+ FC.required "stderr_tail" (\(DocRun _ _ _ _ e) -> e) FC.text

data DocSummary
  = DocSummary T.Text Bool

summarySchema :: FC.Fleece t => FC.Schema t DocSummary
summarySchema =
  FC.object $
    FC.constructor DocSummary
      #+ FC.required "commit" (\(DocSummary c _) -> c) FC.text
      #+ FC.required "passed" (\(DocSummary _ p) -> p) FC.boolean

data DocFinding
  = DocFinding T.Text T.Text T.Text T.Text

findingSchema :: FC.Fleece t => FC.Schema t DocFinding
findingSchema =
  FC.object $
    FC.constructor DocFinding
      #+ FC.required "requirement" (\(DocFinding r _ _ _) -> r) FC.text
      #+ FC.required "claim" (\(DocFinding _ c _ _) -> c) FC.text
      #+ FC.required "mutant" (\(DocFinding _ _ m _) -> m) FC.text
      #+ FC.required "disposition" (\(DocFinding _ _ _ d) -> d) FC.text

data DocReview
  = DocReview T.Text T.Text [T.Text]

reviewSchema :: FC.Fleece t => FC.Schema t DocReview
reviewSchema =
  FC.object $
    FC.constructor DocReview
      #+ FC.required "commit" (\(DocReview c _ _) -> c) FC.text
      #+ FC.required "verdict" (\(DocReview _ v _) -> v) FC.text
      #+ FC.required "reasons" (\(DocReview _ _ r) -> r) (FC.list FC.text)

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
    , evidenceRuns = [CheckRun c o x s e | Right (DocRun c o x s e) <- fmap snd runs]
    , evidencePassed = (\(DocSummary c p) -> (c, p)) <$> lastRight (current summaries)
    , evidenceFindings =
        [FindingView (T.pack "before") r c m d | Right (DocFinding r c m d) <- fmap snd (decodedKind (FA.decode findingSchema) (T.pack "finding"))]
          <> [FindingView (T.pack "after") r c m d | Right (DocFinding r c m d) <- current (decodedKind (FA.decode findingSchema) (T.pack "post-finding"))]
    , evidenceReview = (\(DocReview c v rs) -> ReviewView c v rs) <$> lastRight (current reviews)
    , evidenceUncertain = L.filter unsettled (viewInvocations view)
    , evidenceUnreadable =
        L.sort
          ( lefts (fmap snd runs)
              <> lefts (fmap snd summaries)
              <> lefts (fmap snd reviews)
              <> [n | k <- [T.pack "finding", T.pack "post-finding"], Left n <- fmap (decodeWith (FA.decode findingSchema)) (ofKind k)]
              <> [recordSequence r | r <- ofKind (T.pack "candidate"), isNothing (recordedCandidate (recordBody r))]
          )
    , evidenceAttempts = L.length (ofKind (T.pack "implementation"))
    }
 where
  records = viewRecords view
  ofKind kind = L.filter ((== kind) . recordKind) records
  -- Each decoded record of a kind with its sequence number.
  decodedKind :: (LBS.ByteString -> Either String a) -> T.Text -> [(Int, Either Int a)]
  decodedKind decoder kind = [(recordSequence r, decodeWith decoder r) | r <- ofKind kind]
  candidate = lastJust (fmap (recordedCandidate . recordBody) (ofKind (T.pack "candidate")))
  summaries = decodedKind (FA.decode summarySchema) (T.pack "verification-summary")
  reviews = decodedKind (FA.decode reviewSchema) (T.pack "review")
  -- The latest attempt begins with the latest implementation record.
  attemptFrom = maybe 0 recordSequence (headOf (L.reverse (ofKind (T.pack "implementation"))))
  current :: [(Int, b)] -> [b]
  current decoded = [d | (n, d) <- decoded, n > attemptFrom]
  -- The runs of the latest verification of this attempt: those after the summary before it.
  latestRuns =
    case L.reverse [r | r <- ofKind (T.pack "verification-summary"), recordSequence r > attemptFrom] of
      [] -> []
      lastSummary : _ ->
        let
          from = maybe attemptFrom recordSequence (headOf (L.reverse [r | r <- ofKind (T.pack "verification-summary"), recordSequence r < recordSequence lastSummary]))
        in
          [r | r <- ofKind (T.pack "verification"), recordSequence r > max from attemptFrom, recordSequence r < recordSequence lastSummary]
  runs = [(recordSequence r, decodeWith (FA.decode runSchema) r) | r <- latestRuns]
  unsettled i =
    invocationWhat i `L.elem` fmap T.pack ["planner", "challenger", "implementer", "reviewer"]
      && maybe True (T.isPrefixOf (T.pack "uncertain")) (invocationOutcome i)

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
