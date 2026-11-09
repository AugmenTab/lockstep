{-# LANGUAGE TypeFamilies #-}

{- | Storage for background jobs (contract C-P1.5 E2–E5). Every update after
the claim is conditional on the claiming owner, so a process that lost its
lease cannot overwrite another's progress.
-}
module Lockstep.Persistence.Jobs
  ( JobState (..)
  , jobStateCode
  , parseJobState
  , JobEnd (..)
  , jobEndState
  , JobRow (..)
  , insertNoopJob
  , findJobById
  , findJobByReceipt
  , claimJob
  , recordStep
  , finishJob
  , releaseJob
  , jobTable
  , jobIdField
  , jobReceiptField
  , jobStateField
  , jobStepsDoneField
  , jobStepsTotalField
  , jobErrorField
  , jobOutcomeDigestField
  ) where

import Data.ByteString qualified as BS
import Data.List qualified as L
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Execution.SelectOptions qualified as SelectOptions
import Orville.PostgreSQL.Expr qualified as Expr
import Orville.PostgreSQL.Raw.SqlValue qualified as SqlValue
import Text.Show (Show)

import Lockstep.Kernel.Enum (parseEnumText)
import Lockstep.Kernel.Identity (JobId (..), ReceiptId)
import Lockstep.Persistence.Commands (receiptIdField, receiptTable)
import Lockstep.Persistence.Entity (EntityKey, foreignKeyTo, serialKeyField)
import Lockstep.Persistence.Fields (codeField, digestField, forUpdateSkipLocked, headMay, increment, setExpression, setNow, tableReference)

-- | Where a no-op job stands (C-P1.5 E2): its stored @state@.
data JobState
  = JobQueued
  | JobRunning
  | JobSucceeded
  | JobFailed
  deriving (Eq, Show, Enum, Bounded)

jobStateCode :: JobState -> T.Text
jobStateCode state =
  T.pack $
    case state of
      JobQueued -> "queued"
      JobRunning -> "running"
      JobSucceeded -> "succeeded"
      JobFailed -> "failed"

-- | The state of its code; derived from 'jobStateCode'.
parseJobState :: T.Text -> Maybe JobState
parseJobState =
  parseEnumText jobStateCode

data JobRow
  = JobRow
  { jobRowId :: JobId
  , jobRowReceipt :: ReceiptId
  , jobRowState :: JobState
  , jobRowStepsTotal :: Int32
  , jobRowStepMillis :: Int32
  , jobRowFailAt :: Maybe Int32
  , jobRowStepsDone :: Int32
  , jobRowAttempts :: Int32
  , jobRowRecovered :: Int32
  , jobRowError :: Maybe T.Text
  }

type instance EntityKey JobRow = JobId

-- | What a no-op job is queued with; its progress columns start at their defaults.
data NewJob
  = NewJob
  { newJobReceipt :: ReceiptId
  , newJobSteps :: Int32
  , newJobMillis :: Int32
  , newJobFailAt :: Maybe Int32
  }

-- | Its key is the database's (read only), so it is built with 'O.mkTableDefinition'; the key is 'JobRow''s.
jobTable :: O.TableDefinition (O.HasKey (EntityKey JobRow)) NewJob JobRow
jobTable =
  O.mkTableDefinition "lockstep_jobs" (O.primaryKey jobIdField) $
    (\jobId receipt _kind state total millis failAt done attempts recovered lastError -> JobRow jobId receipt state total millis failAt done attempts recovered lastError)
      <$> O.marshallReadOnlyField jobIdField
      <*> O.marshallField newJobReceipt jobReceiptField
      <*> O.marshallField (const (T.pack "noop")) (O.unboundedTextField "kind")
      <*> O.marshallField (const JobQueued) jobStateField
      <*> O.marshallField newJobSteps jobStepsTotalField
      <*> O.marshallField newJobMillis jobStepMillisField
      <*> O.marshallField newJobFailAt (O.nullableField (O.integerField "fail_at_step"))
      <*> O.marshallReadOnlyField jobStepsDoneField
      <*> O.marshallReadOnlyField jobAttemptsField
      <*> O.marshallReadOnlyField jobRecoveredField
      <*> O.marshallReadOnlyField jobErrorField

jobIdField :: O.FieldDefinition O.NotNull JobId
jobIdField =
  serialKeyField "id"

jobReceiptField :: O.FieldDefinition O.NotNull ReceiptId
jobReceiptField =
  foreignKeyTo receiptTable receiptIdField "receipt_id"

-- | The job's state; a code no state has fails the read.
jobStateField :: O.FieldDefinition O.NotNull JobState
jobStateField =
  codeField "job state" jobStateCode parseJobState "state"

jobStepsTotalField :: O.FieldDefinition O.NotNull Int32
jobStepsTotalField =
  O.integerField "steps_total"

jobStepMillisField :: O.FieldDefinition O.NotNull Int32
jobStepMillisField =
  O.integerField "step_millis"

jobStepsDoneField :: O.FieldDefinition O.NotNull Int32
jobStepsDoneField =
  O.integerField "steps_done"

jobAttemptsField :: O.FieldDefinition O.NotNull Int32
jobAttemptsField =
  O.integerField "attempts"

jobRecoveredField :: O.FieldDefinition O.NotNull Int32
jobRecoveredField =
  O.integerField "recovered_count"

jobErrorField :: O.FieldDefinition O.Nullable (Maybe T.Text)
jobErrorField =
  O.nullableField (O.unboundedTextField "last_error")

jobOwnerField :: O.FieldDefinition O.Nullable (Maybe T.Text)
jobOwnerField =
  O.nullableField (O.unboundedTextField "owner")

jobLeaseUntilField :: O.FieldDefinition O.Nullable (Maybe UTCTime)
jobLeaseUntilField =
  O.nullableField (O.utcTimestampField "lease_until")

jobStartedAtField :: O.FieldDefinition O.Nullable (Maybe UTCTime)
jobStartedAtField =
  O.nullableField (O.utcTimestampField "started_at")

jobFinishedAtField :: O.FieldDefinition O.Nullable (Maybe UTCTime)
jobFinishedAtField =
  O.nullableField (O.utcTimestampField "finished_at")

jobOutcomeDigestField :: O.FieldDefinition O.Nullable (Maybe BS.ByteString)
jobOutcomeDigestField =
  O.nullableField (digestField "outcome_digest")

-- | Queues a no-op job for an admitted receipt (inside the admission transaction).
insertNoopJob :: O.MonadOrville m => ReceiptId -> Int32 -> Int32 -> Maybe Int32 -> m ()
insertNoopJob receiptId steps millis failAt =
  O.insertEntity jobTable (NewJob receiptId steps millis failAt)

findJobById :: O.MonadOrville m => JobId -> m (Maybe JobRow)
findJobById =
  O.findEntity jobTable

findJobByReceipt :: O.MonadOrville m => ReceiptId -> m (Maybe JobRow)
findJobByReceipt receiptId =
  O.findFirstEntityBy jobTable (O.where_ (O.fieldEquals jobReceiptField receiptId))

{- | A text parameter, cast to @text@ so that @||@ between two parameters
resolves (PostgreSQL cannot choose an operator for two untyped values).
-}
textValue :: T.Text -> Expr.ValueExpression
textValue value =
  Expr.cast (Expr.valueExpression (SqlValue.fromText value)) Expr.text

{- | An integer parameter, cast to @integer@: untyped parameters in a @CASE@
would otherwise resolve to @text@.
-}
intValue :: Int32 -> Expr.ValueExpression
intValue value =
  Expr.cast (Expr.valueExpression (SqlValue.fromInt32 value)) Expr.int

-- | The job's lease: @now() + make_interval(secs => (step_millis + 5000) / 1000.0)@, the step's time plus five seconds.
lease :: Expr.ValueExpression
lease =
  Expr.plus
    Expr.now
    ( Expr.functionCall
        (Expr.functionName "make_interval")
        ( L.replicate 6 (intValue 0)
            <> [ Expr.divide
                   (Expr.plus (O.fieldColumnReference jobStepMillisField) (intValue 5000))
                   (Expr.cast (Expr.valueExpression (SqlValue.fromDouble 1000)) Expr.doublePrecision)
               ]
        )
    )

{- | Claims the oldest queued job, or a running one whose lease expired (its
owner crashed), for this owner. Skips rows another claimer holds. One
statement: the row is chosen (@FOR UPDATE SKIP LOCKED@) and claimed together.
-}
claimJob :: O.MonadOrville m => T.Text -> m (Maybe JobRow)
claimJob owner =
  let
    stateIs = O.fieldEquals jobStateField
    claimable =
      stateIs JobQueued
        `O.orExpr` Expr.parenthesized (stateIs JobRunning `O.andExpr` Expr.lessThan (O.fieldColumnReference jobLeaseUntilField) Expr.now)
    oldestClaimable =
      SelectOptions.selectOptionsQueryExpr
        (Expr.selectColumns [Expr.unqualified (O.fieldColumnName jobIdField)])
        (Expr.tableReferenceList [tableReference jobTable])
        (O.where_ claimable <> O.orderBy (O.orderByField jobIdField O.ascendingOrder) <> O.limit 1 <> forUpdateSkipLocked)
    wasRunning =
      Expr.caseExpr (Expr.whenExpr (stateIs JobRunning) (intValue 1) :| []) (Just (intValue 0))
  in
    headMay
      <$> O.updateFieldsAndReturnEntities
        jobTable
        ( O.setField jobStateField JobRunning
            :| [ O.setField jobOwnerField (Just owner)
               , setExpression jobLeaseUntilField lease
               , increment jobAttemptsField
               , setExpression jobStartedAtField (Expr.coalesce (O.fieldColumnReference jobStartedAtField :| [Expr.now]))
               , setExpression jobRecoveredField (Expr.plus (O.fieldColumnReference jobRecoveredField) wasRunning)
               ]
        )
        (Just (Expr.inSubquery (O.fieldColumnReference jobIdField) oldestClaimable))

-- | The job is still running and held by this owner.
ownedBy :: JobId -> T.Text -> Expr.BooleanExpr
ownedBy jobId owner =
  O.fieldEquals jobIdField jobId
    `O.andExpr` O.fieldEquals jobOwnerField (Just owner)
    `O.andExpr` O.fieldEquals jobStateField JobRunning

-- | Applies the changes if this owner still holds the running job; 'False' if the lease was lost.
whileOwned :: O.MonadOrville m => JobId -> T.Text -> NonEmpty Expr.SetClause -> m Bool
whileOwned jobId owner changes =
  not . null <$> O.updateFieldsAndReturnEntities jobTable changes (Just (ownedBy jobId owner))

-- | Records a completed step and renews the lease; 'False' if the lease was lost.
recordStep :: O.MonadOrville m => JobId -> T.Text -> Int32 -> m Bool
recordStep jobId owner step =
  whileOwned jobId owner (O.setField jobStepsDoneField step :| [setExpression jobLeaseUntilField lease])

-- | How a job ended: the terminal states only.
data JobEnd
  = EndSucceeded
  | EndFailed
  deriving (Eq, Show)

jobEndState :: JobEnd -> JobState
jobEndState end =
  case end of
    EndSucceeded -> JobSucceeded
    EndFailed -> JobFailed

-- | Sets the terminal state with an optional error.
finishJob :: O.MonadOrville m => JobId -> T.Text -> JobEnd -> Maybe T.Text -> m Bool
finishJob jobId owner end lastError =
  let
    state = jobEndState end
  in
    whileOwned
      jobId
      owner
      ( O.setField jobStateField state
          :| [ O.setField jobErrorField lastError
             , setNow jobFinishedAtField
             , O.setField jobOwnerField Nothing
             , O.setField jobLeaseUntilField Nothing
             , setExpression jobOutcomeDigestField (outcomeDigest state lastError)
             ]
      )

{- | C-P1.6 E3: SHA-256 of the canonical outcome text, computed in the same
update from the row's final values:
@sha256(convert_to('lockstep-job-outcome-v1' || E'\\n' || id::text || E'\\n' || state || E'\\n' || steps_done::text || '/' || steps_total::text || E'\\n' || last_error, 'UTF8'))@,
with an absent error as the empty text.
-}
outcomeDigest :: JobState -> Maybe T.Text -> Expr.ValueExpression
outcomeDigest state lastError =
  let
    newline = textValue (T.pack "\n")
    asText field = Expr.cast (O.fieldColumnReference field) Expr.text
    concatenated =
      L.foldl'
        (Expr.binaryOpExpression (Expr.binaryOperator "||"))
        (textValue (T.pack "lockstep-job-outcome-v1"))
        [ newline
        , asText jobIdField
        , newline
        , textValue (jobStateCode state)
        , newline
        , asText jobStepsDoneField
        , textValue (T.pack "/")
        , asText jobStepsTotalField
        , newline
        , textValue (fromMaybe T.empty lastError)
        ]
  in
    Expr.functionCall
      (Expr.functionName "sha256")
      [Expr.functionCall (Expr.functionName "convert_to") [concatenated, Expr.valueExpression (SqlValue.fromText (T.pack "UTF8"))]]

-- | Returns a running job to the queue (graceful shutdown).
releaseJob :: O.MonadOrville m => JobId -> T.Text -> m Bool
releaseJob jobId owner =
  whileOwned jobId owner (O.setField jobStateField JobQueued :| [O.setField jobOwnerField Nothing, O.setField jobLeaseUntilField Nothing])
