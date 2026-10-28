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
    , evidenceRuns = [CheckRun c o x s e | Right (DocRun c o x s e) <- runs]
    , evidencePassed = (\(DocSummary c p) -> (c, p)) <$> lastRight summaries
    , evidenceFindings =
        [ FindingView w r c m d
        | (w, kind) <- [(T.pack "before", T.pack "finding"), (T.pack "after", T.pack "post-finding")]
        , Right (DocFinding r c m d) <- fmap (decodeWith (FA.decode findingSchema)) (ofKind kind)
        ]
    , evidenceReview = (\(DocReview c v rs) -> ReviewView c v rs) <$> lastRight reviews
    , evidenceUncertain = L.filter unsettled (viewInvocations view)
    , evidenceUnreadable =
        L.sort
          ( lefts runs
              <> lefts summaries
              <> lefts reviews
              <> [n | k <- [T.pack "finding", T.pack "post-finding"], Left n <- fmap (decodeWith (FA.decode findingSchema)) (ofKind k)]
              <> [recordSequence r | r <- ofKind (T.pack "candidate"), isNothing (recordedCandidate (recordBody r))]
          )
    }
 where
  records = viewRecords view
  ofKind kind = L.filter ((== kind) . recordKind) records
  candidate = lastJust (fmap (recordedCandidate . recordBody) (ofKind (T.pack "candidate")))
  summaries = fmap (decodeWith (FA.decode summarySchema)) (ofKind (T.pack "verification-summary"))
  reviews = fmap (decodeWith (FA.decode reviewSchema)) (ofKind (T.pack "review"))
  -- The runs of the latest verification: those after the summary before it.
  latestRuns =
    case L.reverse (ofKind (T.pack "verification-summary")) of
      [] -> []
      lastSummary : earlier ->
        let
          from = maybe 0 recordSequence (headOf earlier)
        in
          [r | r <- ofKind (T.pack "verification"), recordSequence r > from, recordSequence r < recordSequence lastSummary]
  runs = fmap (decodeWith (FA.decode runSchema)) latestRuns
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
