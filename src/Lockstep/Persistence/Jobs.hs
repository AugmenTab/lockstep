{- | Storage for background jobs (contract C-P1.5 E2–E5). Every update after
the claim is conditional on the claiming owner, so a process that lost its
lease cannot overwrite another's progress.
-}
module Lockstep.Persistence.Jobs
  ( JobRow (..)
  , insertNoopJob
  , findJobById
  , findJobByReceipt
  , claimJob
  , recordStep
  , finishJob
  , releaseJob
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql
import Orville.PostgreSQL.Raw.SqlValue qualified as SqlValue

data JobRow
  = JobRow
  { jobRowId :: Int64
  , jobRowReceipt :: Int64
  , jobRowState :: T.Text
  , jobRowStepsTotal :: Int32
  , jobRowStepMillis :: Int32
  , jobRowFailAt :: Maybe Int32
  , jobRowStepsDone :: Int32
  , jobRowAttempts :: Int32
  , jobRowRecovered :: Int32
  , jobRowError :: Maybe T.Text
  }

sql :: String -> RawSql.RawSql
sql =
  RawSql.fromString

text :: T.Text -> RawSql.RawSql
text =
  RawSql.parameter . SqlValue.fromText

int32 :: Int32 -> RawSql.RawSql
int32 =
  RawSql.parameter . SqlValue.fromInt32

int64 :: Int64 -> RawSql.RawSql
int64 =
  RawSql.parameter . SqlValue.fromInt64

columns :: String
columns =
  "id, receipt_id, state, steps_total, step_millis, fail_at_step, steps_done, attempts, recovered_count, last_error"

jobMarshaller :: O.AnnotatedSqlMarshaller JobRow JobRow
jobMarshaller =
  O.annotateSqlMarshallerEmptyAnnotation $
    JobRow
      <$> O.marshallField jobRowId (O.bigIntegerField "id")
      <*> O.marshallField jobRowReceipt (O.bigIntegerField "receipt_id")
      <*> O.marshallField jobRowState (O.unboundedTextField "state")
      <*> O.marshallField jobRowStepsTotal (O.integerField "steps_total")
      <*> O.marshallField jobRowStepMillis (O.integerField "step_millis")
      <*> O.marshallField jobRowFailAt (O.nullableField (O.integerField "fail_at_step"))
      <*> O.marshallField jobRowStepsDone (O.integerField "steps_done")
      <*> O.marshallField jobRowAttempts (O.integerField "attempts")
      <*> O.marshallField jobRowRecovered (O.integerField "recovered_count")
      <*> O.marshallField jobRowError (O.nullableField (O.unboundedTextField "last_error"))

oneRow :: O.MonadOrville m => O.QueryType -> RawSql.RawSql -> m (Maybe JobRow)
oneRow queryType query =
  headMay <$> O.executeAndDecode queryType query jobMarshaller

-- | Queues a no-op job for an admitted receipt (inside the admission transaction).
insertNoopJob :: O.MonadOrville m => Int64 -> Int32 -> Int32 -> Maybe Int32 -> m ()
insertNoopJob receiptId steps millis failAt =
  O.executeVoid O.InsertQuery $
    sql "INSERT INTO lockstep_jobs (receipt_id, kind, state, steps_total, step_millis, fail_at_step) VALUES ("
      <> int64 receiptId
      <> sql ", 'noop', 'queued', "
      <> int32 steps
      <> sql ", "
      <> int32 millis
      <> sql ", "
      <> maybe (sql "NULL") int32 failAt
      <> sql ")"

findJobById :: O.MonadOrville m => Int64 -> m (Maybe JobRow)
findJobById jobId =
  oneRow O.SelectQuery (sql ("SELECT " <> columns <> " FROM lockstep_jobs WHERE id = ") <> int64 jobId)

findJobByReceipt :: O.MonadOrville m => Int64 -> m (Maybe JobRow)
findJobByReceipt receiptId =
  oneRow O.SelectQuery (sql ("SELECT " <> columns <> " FROM lockstep_jobs WHERE receipt_id = ") <> int64 receiptId)

lease :: String
lease =
  "now() + make_interval(secs => (step_millis + 5000) / 1000.0)"

{- | Claims the oldest queued job, or a running one whose lease expired (its
owner crashed), for this owner. Skips rows another claimer holds.
-}
claimJob :: O.MonadOrville m => T.Text -> m (Maybe JobRow)
claimJob owner =
  oneRow O.UpdateQuery $
    sql "UPDATE lockstep_jobs SET state = 'running', owner = "
      <> text owner
      <> sql
        ( ", lease_until = "
            <> lease
            <> ", attempts = attempts + 1, started_at = coalesce(started_at, now()), recovered_count = recovered_count + (CASE WHEN state = 'running' THEN 1 ELSE 0 END) WHERE id = (SELECT id FROM lockstep_jobs WHERE state = 'queued' OR (state = 'running' AND lease_until < now()) ORDER BY id LIMIT 1 FOR UPDATE SKIP LOCKED) RETURNING "
            <> columns
        )

ownedBy :: Int64 -> T.Text -> RawSql.RawSql
ownedBy jobId owner =
  sql " WHERE id = " <> int64 jobId <> sql " AND owner = " <> text owner <> sql " AND state = 'running' RETURNING id"

idMarshaller :: O.AnnotatedSqlMarshaller Int64 Int64
idMarshaller =
  O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.bigIntegerField "id"))

owned :: O.MonadOrville m => RawSql.RawSql -> m Bool
owned query =
  not . null <$> O.executeAndDecode O.UpdateQuery query idMarshaller

-- | Records a completed step and renews the lease; 'False' if the lease was lost.
recordStep :: O.MonadOrville m => Int64 -> T.Text -> Int32 -> m Bool
recordStep jobId owner step =
  owned $
    sql "UPDATE lockstep_jobs SET steps_done = "
      <> int32 step
      <> sql (", lease_until = " <> lease)
      <> ownedBy jobId owner

-- | Sets a terminal state ('succeeded' or 'failed') with an optional error.
finishJob :: O.MonadOrville m => Int64 -> T.Text -> T.Text -> Maybe T.Text -> m Bool
finishJob jobId owner state lastError =
  owned $
    sql "UPDATE lockstep_jobs SET state = "
      <> text state
      <> sql ", last_error = "
      <> maybe (sql "NULL") text lastError
      <> sql ", finished_at = now(), owner = NULL, lease_until = NULL"
      <> ownedBy jobId owner

-- | Returns a running job to the queue (graceful shutdown).
releaseJob :: O.MonadOrville m => Int64 -> T.Text -> m Bool
releaseJob jobId owner =
  owned $
    sql "UPDATE lockstep_jobs SET state = 'queued', owner = NULL, lease_until = NULL"
      <> ownedBy jobId owner

headMay :: [a] -> Maybe a
headMay xs =
  case xs of
    [] -> Nothing
    x : _ -> Just x
