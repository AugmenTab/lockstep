{- | The command-center projection (contract C-P1.6): status counts, recent
activity and job evidence rows, all read from canonical rows at render time.
Job evidence is re-hashed here (VISUAL_EVIDENCE_CONTRACT §4 rule 3).
-}
module Lockstep.Application.CommandCenter
  ( CommandCenter (..)
  , CenterView (..)
  , SummaryRow (..)
  , Activity (..)
  , EvidenceRow (..)
  , loadCommandCenter
  , jobOutcomeCanonical
  ) where

import Crypto.Hash (SHA256 (SHA256), hashWith)
import Data.Bifunctor (bimap)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time qualified as Time
import Flipstone.Prelude
import Text.Show (show)

import Lockstep.Application.Database
  ( DatabaseRuntime
  , NotReadyReason
  , Readiness (..)
  , checkReadiness
  , revisionNumber
  , withDatabase
  )
import Lockstep.Foundation.EvidenceModel
  ( Disposition (..)
  , EvidenceItem (..)
  , RowInput (..)
  , TestedRevision (..)
  , aggregate
  , effectiveDisposition
  )
import Lockstep.Persistence.CommandCenter qualified as Store

data SummaryRow
  = SummaryRow
  { summarySection :: T.Text
  , summaryStatus :: T.Text
  , summaryCount :: Int
  , summaryDescription :: T.Text
  }

data Activity
  = Activity
  { activityReceipt :: Int64
  , activityKind :: T.Text
  , activityOutcome :: T.Text
  , activityActor :: T.Text
  , activityAcceptedAt :: Time.UTCTime
  , activityRevision :: Int64
  , activityJobState :: Maybe T.Text
  }

data EvidenceRow
  = EvidenceRow
  { evidenceInput :: RowInput
  , evidenceEffective :: Disposition
  }

data CommandCenter
  = CenterUnavailable NotReadyReason
  | CenterReady CenterView

data CenterView
  = CenterView
  { centerSchema :: T.Text
  , centerSummary :: [SummaryRow]
  , centerActivity :: [Activity]
  , centerEvidence :: [EvidenceRow]
  , centerAggregate :: Disposition
  }

jobStatuses :: [(T.Text, T.Text)]
jobStatuses =
  fmap
    (bimap T.pack T.pack)
    [ ("queued", "accepted and waiting for the service")
    , ("running", "being executed by the service now")
    , ("succeeded", "completed all of their steps")
    , ("failed", "stopped at a failure; not retried")
    ]

receiptStatuses :: [(T.Text, T.Text)]
receiptStatuses =
  fmap
    (bimap T.pack T.pack)
    [ ("applied", "commands applied to the workspace")
    , ("queued", "commands that queued a background job")
    , ("refused_stale", "commands refused: the workspace had moved on")
    ]

loadCommandCenter :: DatabaseRuntime -> IO CommandCenter
loadCommandCenter runtime = do
  readiness <- checkReadiness (Just runtime)
  case readiness of
    NotReady reason ->
      pure (CenterUnavailable reason)
    Ready revision -> do
      result <-
        withDatabase runtime $
          (,,,) <$> Store.jobCounts <*> Store.receiptCounts <*> Store.recentActivity <*> Store.recentJobs
      pure $
        case result of
          Left reason ->
            CenterUnavailable reason
          Right (jobs, receipts, activity, recent) ->
            let
              schema = T.pack ("schema " <> show (revisionNumber revision))
              rows = fmap (evidenceRow schema) recent
            in
              CenterReady
                CenterView
                  { centerSchema = schema
                  , centerSummary =
                      fmap (summary (T.pack "jobs") jobs) jobStatuses
                        <> fmap (summary (T.pack "receipts") receipts) receiptStatuses
                  , centerActivity = fmap toActivity activity
                  , centerEvidence = rows
                  , centerAggregate = aggregate (fmap (\r -> (rowRequired (evidenceInput r), evidenceEffective r)) rows)
                  }

summary :: T.Text -> [(T.Text, Int32)] -> (T.Text, T.Text) -> SummaryRow
summary section found (status, description) =
  SummaryRow section status (maybe 0 fromIntegral (L.lookup status found)) description

toActivity :: Store.ActivityRow -> Activity
toActivity row =
  Activity
    { activityReceipt = Store.activityId row
    , activityKind = Store.activityKind row
    , activityOutcome = Store.activityOutcome row
    , activityActor = Store.activityActor row
    , activityAcceptedAt = Store.activityAcceptedAt row
    , activityRevision = Store.activityRevision row
    , activityJobState = Store.activityJobState row
    }

-- | C-P1.6 E3: the canonical outcome text whose SHA-256 the dispatcher stores.
jobOutcomeCanonical :: Int64 -> T.Text -> Int -> Int -> Maybe T.Text -> T.Text
jobOutcomeCanonical ident state done total lastError =
  T.intercalate
    (T.pack "\n")
    [ T.pack "lockstep-job-outcome-v1"
    , T.pack (show ident)
    , state
    , T.pack (show done <> "/" <> show total)
    , fromMaybe T.empty lastError
    ]

sha256Hex :: T.Text -> T.Text
sha256Hex =
  TE.decodeLatin1 . convertToBase Base16 . hashWith SHA256 . TE.encodeUtf8

-- | C-P1.6 E4.
evidenceRow :: T.Text -> Store.JobEvidenceRow -> EvidenceRow
evidenceRow schema job =
  let
    ident = Store.evidenceJobId job
    done = fromIntegral (Store.evidenceStepsDone job)
    total = fromIntegral (Store.evidenceStepsTotal job)
    state = Store.evidenceState job
    locator = T.pack ("db:lockstep_jobs/" <> show ident)
    recomputed = sha256Hex (jobOutcomeCanonical ident state done total (Store.evidenceError job))
    claimed
      | state == T.pack "succeeded" = Passed
      | state == T.pack "failed" = Failed
      | state == T.pack "running" = NotRun (T.pack "in progress")
      | otherwise = NotRun (T.pack "queued")
    actual =
      state
        <> T.pack (", " <> show done <> "/" <> show total <> " steps")
        <> maybe T.empty (T.pack ", error: " <>) (Store.evidenceError job)
    input =
      RowInput
        { rowCriterion = T.pack ("AC-JOB-" <> show ident <> "@v1")
        , rowStatement =
            T.pack ("Job " <> show ident <> " (receipt " <> show (Store.evidenceReceiptId job) <> ") completes all " <> show total <> " steps")
        , rowSourceRefs = [T.pack "C-P1.5 E4", T.pack ("receipt " <> show (Store.evidenceReceiptId job))]
        , rowRequired = True
        , rowMethod = T.pack "background dispatcher (lockstep serve)"
        , rowExpected = T.pack ("succeeded, " <> show total <> "/" <> show total <> " steps")
        , rowActual = Just actual
        , rowClaimed = claimed
        , rowEvidence =
            [ EvidenceItem locator digest (T.pack "db-row") (T.pack "lockstep serve")
            | Just digest <- [Store.evidenceDigestHex job]
            ]
        , rowTestedRevision = Just (TestedRevision schema False)
        }
    resolve l = if l == locator then Just recomputed else Nothing
  in
    EvidenceRow input (effectiveDisposition schema resolve input)
