{- | Storage for coding transactions (contract C-P4.6 T5): the transaction's
head row, its immutable records, and its invocations (recorded before they
start, finished exactly once; the migration's triggers refuse anything else).
The head row changes only under 'lockTransaction', together with the record
that explains the change. Callers run these inside one transaction.
-}
module Lockstep.Persistence.Transactions
  ( TransactionRow (..)
  , RecordRow (..)
  , InvocationRow (..)
  , Finish (..)
  , insertTransaction
  , findTransaction
  , lockTransaction
  , findTransactionByWorkOrder
  , busyTransactions
  , runningTransactions
  , activeTransactions
  , updateTransaction
  , appendRecord
  , transactionRecords
  , insertInvocation
  , finishInvocation
  , unfinishedInvocations
  , transactionInvocations
  , AdmissionFacts (..)
  , admissionFacts
  , pendingAdmissions
  , projectStarted
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql
import Orville.PostgreSQL.Raw.SqlValue qualified as SqlValue

data TransactionRow
  = TransactionRow
  { txRowId :: T.Text
  , txRowWorkOrder :: T.Text
  , txRowTask :: T.Text
  , txRowEngineer :: T.Text
  , txRowFolder :: T.Text
  , txRowState :: T.Text
  , txRowStage :: T.Text
  , txRowHaltCode :: Maybe T.Text
  , txRowCandidates :: Int32
  , txRowAttempts :: Int32
  , txRowBasis :: Maybe T.Text
  , txRowBranch :: Maybe T.Text
  , txRowFreeze :: Maybe T.Text
  , txRowCandidate :: Maybe T.Text
  , txRowAccepted :: Maybe T.Text
  , txRowContract :: Maybe T.Text
  , txRowRevision :: Int32
  }
  deriving (Eq)

data RecordRow
  = RecordRow
  { recordRowTransaction :: T.Text
  , recordRowSequence :: Int32
  , recordRowKind :: T.Text
  , recordRowPrincipal :: T.Text
  , recordRowStage :: T.Text
  , recordRowBody :: T.Text
  , recordRowDigest :: T.Text
  }
  deriving (Eq)

data InvocationRow
  = InvocationRow
  { invocationRowId :: T.Text
  , invocationRowTransaction :: T.Text
  , invocationRowStage :: T.Text
  , invocationRowWhat :: T.Text
  , invocationRowRunner :: T.Text
  , invocationRowAdapter :: T.Text
  , invocationRowArgv :: T.Text
  , invocationRowOutcome :: Maybe T.Text
  , invocationRowExit :: Maybe Int32
  , invocationRowMillis :: Maybe Int32
  , invocationRowStdoutBytes :: Maybe Int32
  , invocationRowStderrBytes :: Maybe Int32
  , invocationRowStdoutDigest :: Maybe T.Text
  , invocationRowStderrDigest :: Maybe T.Text
  , invocationRowStdoutTail :: Maybe T.Text
  , invocationRowStderrTail :: Maybe T.Text
  }
  deriving (Eq)

-- | How an invocation ended; written once.
data Finish
  = Finish
  { finishOutcome :: T.Text
  , finishExit :: Maybe Int32
  , finishMillis :: Maybe Int32
  , finishStdoutBytes :: Maybe Int32
  , finishStderrBytes :: Maybe Int32
  , finishStdoutDigest :: Maybe T.Text
  , finishStderrDigest :: Maybe T.Text
  , finishStdoutTail :: Maybe T.Text
  , finishStderrTail :: Maybe T.Text
  }
  deriving (Eq)

sql :: String -> RawSql.RawSql
sql =
  RawSql.fromString

text :: T.Text -> RawSql.RawSql
text =
  RawSql.parameter . SqlValue.fromText

maybeText :: Maybe T.Text -> RawSql.RawSql
maybeText =
  maybe (sql "NULL") text

int :: Int32 -> RawSql.RawSql
int =
  RawSql.parameter . SqlValue.fromInt32

maybeInt :: Maybe Int32 -> RawSql.RawSql
maybeInt =
  maybe (sql "NULL") int

uuid :: T.Text -> RawSql.RawSql
uuid value =
  sql "CAST(" <> text value <> sql " AS uuid)"

headMay :: [a] -> Maybe a
headMay xs =
  case xs of
    [] -> Nothing
    x : _ -> Just x

commaSeparated :: [RawSql.RawSql] -> RawSql.RawSql
commaSeparated parts =
  case parts of
    [] -> sql ""
    p : rest -> p <> mconcat [sql ", " <> r | r <- rest]

-- Transactions ---------------------------------------------------------------------

transactionMarshaller :: O.AnnotatedSqlMarshaller TransactionRow TransactionRow
transactionMarshaller =
  O.annotateSqlMarshallerEmptyAnnotation $
    TransactionRow
      <$> O.marshallField txRowId (O.unboundedTextField "id")
      <*> O.marshallField txRowWorkOrder (O.unboundedTextField "work_order_id")
      <*> O.marshallField txRowTask (O.unboundedTextField "task_id")
      <*> O.marshallField txRowEngineer (O.unboundedTextField "engineer_name")
      <*> O.marshallField txRowFolder (O.unboundedTextField "folder")
      <*> O.marshallField txRowState (O.unboundedTextField "state")
      <*> O.marshallField txRowStage (O.unboundedTextField "stage")
      <*> O.marshallField txRowHaltCode (O.nullableField (O.unboundedTextField "halt_code"))
      <*> O.marshallField txRowCandidates (O.integerField "candidates_made")
      <*> O.marshallField txRowAttempts (O.integerField "attempts_made")
      <*> O.marshallField txRowBasis (O.nullableField (O.unboundedTextField "basis_commit"))
      <*> O.marshallField txRowBranch (O.nullableField (O.unboundedTextField "branch"))
      <*> O.marshallField txRowFreeze (O.nullableField (O.unboundedTextField "freeze_commit"))
      <*> O.marshallField txRowCandidate (O.nullableField (O.unboundedTextField "candidate_commit"))
      <*> O.marshallField txRowAccepted (O.nullableField (O.unboundedTextField "accepted_commit"))
      <*> O.marshallField txRowContract (O.nullableField (O.unboundedTextField "contract_digest"))
      <*> O.marshallField txRowRevision (O.integerField "revision")

selectTransactions :: O.MonadOrville m => RawSql.RawSql -> m [TransactionRow]
selectTransactions rest =
  O.executeAndDecode
    O.SelectQuery
    ( sql "SELECT id::text AS id, work_order_id::text AS work_order_id, task_id::text AS task_id, engineer_name, folder, state, stage, halt_code, candidates_made, attempts_made, basis_commit, branch, freeze_commit, candidate_commit, accepted_commit, contract_digest, revision FROM lockstep_transactions "
        <> rest
    )
    transactionMarshaller

insertTransaction :: O.MonadOrville m => TransactionRow -> m ()
insertTransaction row =
  O.executeVoid O.InsertQuery $
    sql "INSERT INTO lockstep_transactions (id, work_order_id, task_id, engineer_name, folder, state, stage, halt_code, candidates_made, attempts_made, basis_commit, branch, freeze_commit, candidate_commit, accepted_commit, contract_digest, revision) VALUES ("
      <> commaSeparated
        [ uuid (txRowId row)
        , uuid (txRowWorkOrder row)
        , uuid (txRowTask row)
        , text (txRowEngineer row)
        , text (txRowFolder row)
        , text (txRowState row)
        , text (txRowStage row)
        , maybeText (txRowHaltCode row)
        , int (txRowCandidates row)
        , int (txRowAttempts row)
        , maybeText (txRowBasis row)
        , maybeText (txRowBranch row)
        , maybeText (txRowFreeze row)
        , maybeText (txRowCandidate row)
        , maybeText (txRowAccepted row)
        , maybeText (txRowContract row)
        , int (txRowRevision row)
        ]
      <> sql ")"

findTransaction :: O.MonadOrville m => T.Text -> m (Maybe TransactionRow)
findTransaction txId =
  headMay <$> selectTransactions (sql "WHERE id = " <> uuid txId)

-- | The transaction row, locked until the database transaction ends.
lockTransaction :: O.MonadOrville m => T.Text -> m (Maybe TransactionRow)
lockTransaction txId =
  headMay <$> selectTransactions (sql "WHERE id = " <> uuid txId <> sql " FOR UPDATE")

findTransactionByWorkOrder :: O.MonadOrville m => T.Text -> m (Maybe TransactionRow)
findTransactionByWorkOrder workOrder =
  headMay <$> selectTransactions (sql "WHERE work_order_id = " <> uuid workOrder)

-- | The Engineer's transactions that still hold its one writer: running or halted.
busyTransactions :: O.MonadOrville m => T.Text -> m [TransactionRow]
busyTransactions engineer =
  selectTransactions (sql "WHERE engineer_name = " <> text engineer <> sql " AND state IN ('running', 'halted') ORDER BY created_at, id")

runningTransactions :: O.MonadOrville m => m [TransactionRow]
runningTransactions =
  selectTransactions (sql "WHERE state = 'running' ORDER BY created_at, id")

-- | Every running or halted transaction, in start order (C-P4.15 W1).
activeTransactions :: O.MonadOrville m => m [TransactionRow]
activeTransactions =
  selectTransactions (sql "WHERE state IN ('running', 'halted') ORDER BY created_at, id")

-- | Rewrites the head row (call under 'lockTransaction').
updateTransaction :: O.MonadOrville m => TransactionRow -> m ()
updateTransaction row =
  O.executeVoid O.UpdateQuery $
    sql "UPDATE lockstep_transactions SET state = "
      <> text (txRowState row)
      <> sql ", stage = "
      <> text (txRowStage row)
      <> sql ", halt_code = "
      <> maybeText (txRowHaltCode row)
      <> sql ", candidates_made = "
      <> int (txRowCandidates row)
      <> sql ", attempts_made = "
      <> int (txRowAttempts row)
      <> sql ", basis_commit = "
      <> maybeText (txRowBasis row)
      <> sql ", branch = "
      <> maybeText (txRowBranch row)
      <> sql ", freeze_commit = "
      <> maybeText (txRowFreeze row)
      <> sql ", candidate_commit = "
      <> maybeText (txRowCandidate row)
      <> sql ", accepted_commit = "
      <> maybeText (txRowAccepted row)
      <> sql ", contract_digest = "
      <> maybeText (txRowContract row)
      <> sql ", revision = "
      <> int (txRowRevision row)
      <> sql ", updated_at = now() WHERE id = "
      <> uuid (txRowId row)

-- Records --------------------------------------------------------------------------

recordMarshaller :: O.AnnotatedSqlMarshaller RecordRow RecordRow
recordMarshaller =
  O.annotateSqlMarshallerEmptyAnnotation $
    RecordRow
      <$> O.marshallField recordRowTransaction (O.unboundedTextField "transaction_id")
      <*> O.marshallField recordRowSequence (O.integerField "sequence")
      <*> O.marshallField recordRowKind (O.unboundedTextField "kind")
      <*> O.marshallField recordRowPrincipal (O.unboundedTextField "principal")
      <*> O.marshallField recordRowStage (O.unboundedTextField "stage")
      <*> O.marshallField recordRowBody (O.unboundedTextField "body")
      <*> O.marshallField recordRowDigest (O.unboundedTextField "body_digest")

transactionRecords :: O.MonadOrville m => T.Text -> m [RecordRow]
transactionRecords txId =
  O.executeAndDecode
    O.SelectQuery
    (sql "SELECT transaction_id::text AS transaction_id, sequence, kind, principal, stage, body, body_digest FROM lockstep_transaction_records WHERE transaction_id = " <> uuid txId <> sql " ORDER BY sequence")
    recordMarshaller

-- | Appends the next record (call under 'lockTransaction', so the sequence is the next one).
appendRecord :: O.MonadOrville m => RecordRow -> m ()
appendRecord row =
  O.executeVoid O.InsertQuery $
    sql "INSERT INTO lockstep_transaction_records (transaction_id, sequence, kind, principal, stage, body, body_digest) VALUES ("
      <> commaSeparated
        [ uuid (recordRowTransaction row)
        , int (recordRowSequence row)
        , text (recordRowKind row)
        , text (recordRowPrincipal row)
        , text (recordRowStage row)
        , text (recordRowBody row)
        , text (recordRowDigest row)
        ]
      <> sql ")"

-- Invocations ----------------------------------------------------------------------

invocationMarshaller :: O.AnnotatedSqlMarshaller InvocationRow InvocationRow
invocationMarshaller =
  O.annotateSqlMarshallerEmptyAnnotation $
    InvocationRow
      <$> O.marshallField invocationRowId (O.unboundedTextField "id")
      <*> O.marshallField invocationRowTransaction (O.unboundedTextField "transaction_id")
      <*> O.marshallField invocationRowStage (O.unboundedTextField "stage")
      <*> O.marshallField invocationRowWhat (O.unboundedTextField "what")
      <*> O.marshallField invocationRowRunner (O.unboundedTextField "runner")
      <*> O.marshallField invocationRowAdapter (O.unboundedTextField "adapter")
      <*> O.marshallField invocationRowArgv (O.unboundedTextField "argv")
      <*> O.marshallField invocationRowOutcome (O.nullableField (O.unboundedTextField "outcome"))
      <*> O.marshallField invocationRowExit (O.nullableField (O.integerField "exit_code"))
      <*> O.marshallField invocationRowMillis (O.nullableField (O.integerField "millis"))
      <*> O.marshallField invocationRowStdoutBytes (O.nullableField (O.integerField "stdout_bytes"))
      <*> O.marshallField invocationRowStderrBytes (O.nullableField (O.integerField "stderr_bytes"))
      <*> O.marshallField invocationRowStdoutDigest (O.nullableField (O.unboundedTextField "stdout_digest"))
      <*> O.marshallField invocationRowStderrDigest (O.nullableField (O.unboundedTextField "stderr_digest"))
      <*> O.marshallField invocationRowStdoutTail (O.nullableField (O.unboundedTextField "stdout_tail"))
      <*> O.marshallField invocationRowStderrTail (O.nullableField (O.unboundedTextField "stderr_tail"))

selectInvocations :: O.MonadOrville m => RawSql.RawSql -> m [InvocationRow]
selectInvocations rest =
  O.executeAndDecode
    O.SelectQuery
    ( sql "SELECT id::text AS id, transaction_id::text AS transaction_id, stage, what, runner, adapter, argv, outcome, exit_code, millis, stdout_bytes, stderr_bytes, stdout_digest, stderr_digest, stdout_tail, stderr_tail FROM lockstep_invocations "
        <> rest
    )
    invocationMarshaller

-- | Recorded before the run starts: the run has not ended until 'finishInvocation'.
insertInvocation :: O.MonadOrville m => InvocationRow -> m ()
insertInvocation row =
  O.executeVoid O.InsertQuery $
    sql "INSERT INTO lockstep_invocations (id, transaction_id, stage, what, runner, adapter, argv) VALUES ("
      <> commaSeparated
        [ uuid (invocationRowId row)
        , uuid (invocationRowTransaction row)
        , text (invocationRowStage row)
        , text (invocationRowWhat row)
        , text (invocationRowRunner row)
        , text (invocationRowAdapter row)
        , text (invocationRowArgv row)
        ]
      <> sql ")"

-- | Writes how the invocation ended; a second finish is refused by the trigger.
finishInvocation :: O.MonadOrville m => T.Text -> Finish -> m ()
finishInvocation invocationId f =
  O.executeVoid O.UpdateQuery $
    sql "UPDATE lockstep_invocations SET finished_at = clock_timestamp(), outcome = "
      <> text (finishOutcome f)
      <> sql ", exit_code = "
      <> maybeInt (finishExit f)
      <> sql ", millis = "
      <> maybeInt (finishMillis f)
      <> sql ", stdout_bytes = "
      <> maybeInt (finishStdoutBytes f)
      <> sql ", stderr_bytes = "
      <> maybeInt (finishStderrBytes f)
      <> sql ", stdout_digest = "
      <> maybeText (finishStdoutDigest f)
      <> sql ", stderr_digest = "
      <> maybeText (finishStderrDigest f)
      <> sql ", stdout_tail = "
      <> maybeText (finishStdoutTail f)
      <> sql ", stderr_tail = "
      <> maybeText (finishStderrTail f)
      <> sql " WHERE id = "
      <> uuid invocationId

unfinishedInvocations :: O.MonadOrville m => T.Text -> m [InvocationRow]
unfinishedInvocations txId =
  selectInvocations (sql "WHERE transaction_id = " <> uuid txId <> sql " AND finished_at IS NULL ORDER BY started_at, id")

transactionInvocations :: O.MonadOrville m => T.Text -> m [InvocationRow]
transactionInvocations txId =
  selectInvocations (sql "WHERE transaction_id = " <> uuid txId <> sql " ORDER BY started_at, id")

-- Facts from C-P4.1 -------------------------------------------------------------------

-- | The bug admission of a Work Order and its project's enablement.
data AdmissionFacts
  = AdmissionFacts
  { factWorkOrder :: T.Text
  , factTask :: T.Text
  , factProject :: T.Text
  , factRepository :: T.Text
  , factEngineer :: T.Text
  , factFolder :: T.Text
  }
  deriving (Eq)

admissionFacts :: O.MonadOrville m => T.Text -> m (Maybe AdmissionFacts)
admissionFacts workOrder =
  headMay
    <$> O.executeAndDecode
      O.SelectQuery
      ( sql "SELECT a.work_order_id::text AS work_order_id, a.task_id::text AS task_id, a.project_id::text AS project_id, e.repository_id::text AS repository_id, e.engineer_name, e.folder FROM lockstep_bug_admissions a JOIN lockstep_execution_enablements e ON e.project_id = a.project_id WHERE a.work_order_id = "
          <> uuid workOrder
      )
      ( O.annotateSqlMarshallerEmptyAnnotation $
          AdmissionFacts
            <$> O.marshallField factWorkOrder (O.unboundedTextField "work_order_id")
            <*> O.marshallField factTask (O.unboundedTextField "task_id")
            <*> O.marshallField factProject (O.unboundedTextField "project_id")
            <*> O.marshallField factRepository (O.unboundedTextField "repository_id")
            <*> O.marshallField factEngineer (O.unboundedTextField "engineer_name")
            <*> O.marshallField factFolder (O.unboundedTextField "folder")
      )

-- | Whether Lockstep has started on any bug of the project (C-P4.16).
projectStarted :: O.MonadOrville m => T.Text -> m Bool
projectStarted project =
  not . L.null
    <$> O.executeAndDecode
      O.SelectQuery
      (sql "SELECT t.id::text AS id FROM lockstep_transactions t JOIN lockstep_bug_admissions a ON a.work_order_id = t.work_order_id WHERE a.project_id = " <> uuid project <> sql " LIMIT 1")
      (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.unboundedTextField "id")))

-- | The admitted bug Work Orders that have no transaction yet, in hand-over order (C-P4.15 W1).
pendingAdmissions :: O.MonadOrville m => m [T.Text]
pendingAdmissions =
  O.executeAndDecode
    O.SelectQuery
    (sql "SELECT a.work_order_id::text AS work_order_id FROM lockstep_bug_admissions a WHERE NOT EXISTS (SELECT 1 FROM lockstep_transactions t WHERE t.work_order_id = a.work_order_id) ORDER BY a.id")
    (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.unboundedTextField "work_order_id")))
