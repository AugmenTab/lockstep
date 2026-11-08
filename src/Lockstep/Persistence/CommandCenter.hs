{- | Read-only queries for the command center (contract C-P1.6 E4–E6). Every
value shown comes from these canonical rows at render time.
-}
module Lockstep.Persistence.CommandCenter
  ( ActivityRow (..)
  , JobEvidenceRow (..)
  , jobCounts
  , receiptCounts
  , recentActivity
  , recentJobs
  ) where

import Data.Text qualified as T
import Data.Time qualified as Time
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql

data ActivityRow
  = ActivityRow
  { activityId :: Int64
  , activityKind :: T.Text
  , activityOutcome :: T.Text
  , activityActor :: T.Text
  , activityAcceptedAt :: Time.UTCTime
  , activityRevision :: Int64
  , activityJobState :: Maybe T.Text
  }

data JobEvidenceRow
  = JobEvidenceRow
  { evidenceJobId :: Int64
  , evidenceReceiptId :: Int64
  , evidenceState :: T.Text
  , evidenceStepsDone :: Int32
  , evidenceStepsTotal :: Int32
  , evidenceError :: Maybe T.Text
  , evidenceDigestHex :: Maybe T.Text
  }

counts :: O.MonadOrville m => String -> m [(T.Text, Int32)]
counts query =
  O.executeAndDecode
    O.SelectQuery
    (RawSql.fromString query)
    ( O.annotateSqlMarshallerEmptyAnnotation $
        (,)
          <$> O.marshallField fst (O.unboundedTextField "k")
          <*> O.marshallField snd (O.integerField "n")
    )

jobCounts :: O.MonadOrville m => m [(T.Text, Int32)]
jobCounts =
  counts "SELECT state AS k, count(*)::integer AS n FROM lockstep_jobs GROUP BY state"

receiptCounts :: O.MonadOrville m => m [(T.Text, Int32)]
receiptCounts =
  counts "SELECT outcome AS k, count(*)::integer AS n FROM lockstep_command_receipts GROUP BY outcome"

-- | The newest 20 receipts, with the state of their job if any.
recentActivity :: O.MonadOrville m => m [ActivityRow]
recentActivity =
  O.executeAndDecode
    O.SelectQuery
    ( RawSql.fromString
        "SELECT r.id, r.command_kind, r.outcome, r.actor, r.accepted_at, r.resulting_revision, j.state AS job_state FROM lockstep_command_receipts r LEFT JOIN lockstep_jobs j ON j.receipt_id = r.id ORDER BY r.id DESC LIMIT 20"
    )
    ( O.annotateSqlMarshallerEmptyAnnotation $
        ActivityRow
          <$> O.marshallField activityId (O.bigIntegerField "id")
          <*> O.marshallField activityKind (O.unboundedTextField "command_kind")
          <*> O.marshallField activityOutcome (O.unboundedTextField "outcome")
          <*> O.marshallField activityActor (O.unboundedTextField "actor")
          <*> O.marshallField activityAcceptedAt (O.utcTimestampField "accepted_at")
          <*> O.marshallField activityRevision (O.bigIntegerField "resulting_revision")
          <*> O.marshallField activityJobState (O.nullableField (O.unboundedTextField "job_state"))
    )

-- | The newest 20 jobs with their stored outcome digest (hex), if any.
recentJobs :: O.MonadOrville m => m [JobEvidenceRow]
recentJobs =
  O.executeAndDecode
    O.SelectQuery
    ( RawSql.fromString
        "SELECT id, receipt_id, state, steps_done, steps_total, last_error, encode(outcome_digest, 'hex') AS digest_hex FROM lockstep_jobs ORDER BY id DESC LIMIT 20"
    )
    ( O.annotateSqlMarshallerEmptyAnnotation $
        JobEvidenceRow
          <$> O.marshallField evidenceJobId (O.bigIntegerField "id")
          <*> O.marshallField evidenceReceiptId (O.bigIntegerField "receipt_id")
          <*> O.marshallField evidenceState (O.unboundedTextField "state")
          <*> O.marshallField evidenceStepsDone (O.integerField "steps_done")
          <*> O.marshallField evidenceStepsTotal (O.integerField "steps_total")
          <*> O.marshallField evidenceError (O.nullableField (O.unboundedTextField "last_error"))
          <*> O.marshallField evidenceDigestHex (O.nullableField (O.unboundedTextField "digest_hex"))
    )
