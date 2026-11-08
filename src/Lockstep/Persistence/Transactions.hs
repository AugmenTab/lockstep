{-# LANGUAGE TypeFamilies #-}

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
  , lockEngineer
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
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text qualified as T
import Data.Time (UTCTime)
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Expr qualified as Expr
import Orville.PostgreSQL.Raw.SqlValue qualified as SqlValue

import Lockstep.Kernel.Identity (InvocationId (..), ProjectId, RepositoryId, TaskId, TransactionId (..), WorkOrderId)
import Lockstep.Kernel.Transaction (Stage, parseStage, stageName)
import Lockstep.Persistence.Entity (EntityKey, Table, foreignKeyTo, keyField, mkEntityTable)
import Lockstep.Persistence.Execution
  ( admissionIdField
  , admissionProjectField
  , admissionTable
  , admissionTaskField
  , admissionWorkOrderField
  , enablementEngineerField
  , enablementFolderField
  , enablementProjectField
  , enablementRepositoryField
  , enablementTable
  )
import Lockstep.Persistence.Fields
  ( clockTimestamp
  , codeField
  , forUpdate
  , headMay
  , joinedOn
  , qualified
  , qualifiedEquals
  , qualifiedOrder
  , qualifiedReference
  , selectJoined
  , selectValue
  , setExpression
  , setNow
  , tableReference
  )
import Lockstep.Persistence.Ledger (workOrderIdField, workOrderTable)
import Lockstep.Persistence.Tasks (taskIdField, taskTable)

data TransactionRow
  = TransactionRow
  { txRowId :: TransactionId
  , txRowWorkOrder :: WorkOrderId
  , txRowTask :: TaskId
  , txRowEngineer :: T.Text
  , txRowFolder :: T.Text
  , txRowState :: T.Text
  , txRowStage :: Stage
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

type instance EntityKey TransactionRow = TransactionId

data RecordRow
  = RecordRow
  { recordRowTransaction :: TransactionId
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
  { invocationRowId :: InvocationId
  , invocationRowTransaction :: TransactionId
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
  , invocationRowRevision :: Maybe Int32
  -- ^ C-P4.R1 R-I1: the transaction revision it ran at.
  , invocationRowAnswer :: Maybe T.Text
  -- ^ C-P4.R1 R-I1: a role's answer document, kept when it answered.
  , invocationRowAnswerDigest :: Maybe T.Text
  -- ^ Its sha256 (the table keeps both or neither).
  }
  deriving (Eq)

type instance EntityKey InvocationRow = InvocationId

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
  , finishAnswer :: Maybe T.Text
  -- ^ The answer document, written with the outcome.
  , finishAnswerDigest :: Maybe T.Text
  }
  deriving (Eq)

-- Transactions ---------------------------------------------------------------------

transactionTable :: Table TransactionRow TransactionRow
transactionTable =
  mkEntityTable "lockstep_transactions" txIdField $
    TransactionRow
      <$> O.marshallField txRowId txIdField
      <*> O.marshallField txRowWorkOrder txWorkOrderField
      <*> O.marshallField txRowTask (foreignKeyTo taskTable taskIdField "task_id")
      <*> O.marshallField txRowEngineer txEngineerField
      <*> O.marshallField txRowFolder (O.unboundedTextField "folder")
      <*> O.marshallField txRowState txStateField
      <*> O.marshallField txRowStage txStageField
      <*> O.marshallField txRowHaltCode txHaltCodeField
      <*> O.marshallField txRowCandidates txCandidatesField
      <*> O.marshallField txRowAttempts txAttemptsField
      <*> O.marshallField txRowBasis txBasisField
      <*> O.marshallField txRowBranch txBranchField
      <*> O.marshallField txRowFreeze txFreezeField
      <*> O.marshallField txRowCandidate txCandidateField
      <*> O.marshallField txRowAccepted txAcceptedField
      <*> O.marshallField txRowContract txContractField
      <*> O.marshallField txRowRevision txRevisionField

txIdField :: O.FieldDefinition O.NotNull TransactionId
txIdField =
  keyField "id"

txWorkOrderField :: O.FieldDefinition O.NotNull WorkOrderId
txWorkOrderField =
  foreignKeyTo workOrderTable workOrderIdField "work_order_id"

txEngineerField :: O.FieldDefinition O.NotNull T.Text
txEngineerField =
  O.unboundedTextField "engineer_name"

txStateField :: O.FieldDefinition O.NotNull T.Text
txStateField =
  O.unboundedTextField "state"

-- | The stage the transaction is or was last at; a code the Kernel does not know fails the read.
txStageField :: O.FieldDefinition O.NotNull Stage
txStageField =
  codeField "transaction stage" stageName parseStage "stage"

txHaltCodeField :: O.FieldDefinition O.Nullable (Maybe T.Text)
txHaltCodeField =
  O.nullableField (O.unboundedTextField "halt_code")

txCandidatesField :: O.FieldDefinition O.NotNull Int32
txCandidatesField =
  O.integerField "candidates_made"

txAttemptsField :: O.FieldDefinition O.NotNull Int32
txAttemptsField =
  O.integerField "attempts_made"

txBasisField :: O.FieldDefinition O.Nullable (Maybe T.Text)
txBasisField =
  O.nullableField (O.unboundedTextField "basis_commit")

txBranchField :: O.FieldDefinition O.Nullable (Maybe T.Text)
txBranchField =
  O.nullableField (O.unboundedTextField "branch")

txFreezeField :: O.FieldDefinition O.Nullable (Maybe T.Text)
txFreezeField =
  O.nullableField (O.unboundedTextField "freeze_commit")

txCandidateField :: O.FieldDefinition O.Nullable (Maybe T.Text)
txCandidateField =
  O.nullableField (O.unboundedTextField "candidate_commit")

txAcceptedField :: O.FieldDefinition O.Nullable (Maybe T.Text)
txAcceptedField =
  O.nullableField (O.unboundedTextField "accepted_commit")

txContractField :: O.FieldDefinition O.Nullable (Maybe T.Text)
txContractField =
  O.nullableField (O.unboundedTextField "contract_digest")

txRevisionField :: O.FieldDefinition O.NotNull Int32
txRevisionField =
  O.integerField "revision"

txCreatedAtField :: O.FieldDefinition O.NotNull UTCTime
txCreatedAtField =
  O.utcTimestampField "created_at"

ofTransaction :: O.FieldDefinition nullability a -> O.QualifiedFieldDefinition O.TableIdentifier nullability a
ofTransaction =
  qualified transactionTable

-- | Transactions, by start then id.
inStartOrder :: O.SelectOptions
inStartOrder =
  O.orderBy (O.orderByField txCreatedAtField O.ascendingOrder <> O.orderByField txIdField O.ascendingOrder)

-- | Still holding its Engineer's one writer: running or halted.
holdsWriter :: Expr.BooleanExpr
holdsWriter =
  O.fieldIn txStateField (T.pack "running" :| [T.pack "halted"])

insertTransaction :: O.MonadOrville m => TransactionRow -> m ()
insertTransaction =
  O.insertEntity transactionTable

findTransaction :: O.MonadOrville m => TransactionId -> m (Maybe TransactionRow)
findTransaction =
  O.findEntity transactionTable

-- | The transaction row, locked until the database transaction ends.
lockTransaction :: O.MonadOrville m => TransactionId -> m (Maybe TransactionRow)
lockTransaction txId =
  O.findFirstEntityBy transactionTable (O.where_ (O.fieldEquals txIdField txId) <> forUpdate)

findTransactionByWorkOrder :: O.MonadOrville m => WorkOrderId -> m (Maybe TransactionRow)
findTransactionByWorkOrder workOrder =
  O.findFirstEntityBy transactionTable (O.where_ (O.fieldEquals txWorkOrderField workOrder))

{- | C-P4.R1 R-O1: holds the Engineer's start lock until the database
transaction ends, so two starts for one Engineer check and insert one after
the other (the partial unique index refuses a second writer in any case).
@pg_advisory_xact_lock(hashtextextended(engineer, 7371))@; it returns void,
read as its (empty) text.
-}
lockEngineer :: O.MonadOrville m => T.Text -> m ()
lockEngineer engineer =
  void $
    selectValue
      ( Expr.functionCall
          (Expr.functionName "pg_advisory_xact_lock")
          [ Expr.functionCall
              (Expr.functionName "hashtextextended")
              [ Expr.cast (Expr.valueExpression (SqlValue.fromText engineer)) Expr.text
              , Expr.cast (Expr.valueExpression (SqlValue.fromInt64 7371)) Expr.bigInt
              ]
          ]
      )
      (O.unboundedTextField "v")

-- | The Engineer's transactions that still hold its one writer: running or halted.
busyTransactions :: O.MonadOrville m => T.Text -> m [TransactionRow]
busyTransactions engineer =
  O.findEntitiesBy transactionTable (O.where_ (O.fieldEquals txEngineerField engineer `O.andExpr` holdsWriter) <> inStartOrder)

runningTransactions :: O.MonadOrville m => m [TransactionRow]
runningTransactions =
  O.findEntitiesBy transactionTable (O.where_ (O.fieldEquals txStateField (T.pack "running")) <> inStartOrder)

-- | Every running or halted transaction, in start order (C-P4.15 W1).
activeTransactions :: O.MonadOrville m => m [TransactionRow]
activeTransactions =
  O.findEntitiesBy transactionTable (O.where_ holdsWriter <> inStartOrder)

-- | Rewrites the head row (call under 'lockTransaction').
updateTransaction :: O.MonadOrville m => TransactionRow -> m ()
updateTransaction row =
  O.updateFields
    transactionTable
    ( O.setField txStateField (txRowState row)
        :| [ O.setField txStageField (txRowStage row)
           , O.setField txHaltCodeField (txRowHaltCode row)
           , O.setField txCandidatesField (txRowCandidates row)
           , O.setField txAttemptsField (txRowAttempts row)
           , O.setField txBasisField (txRowBasis row)
           , O.setField txBranchField (txRowBranch row)
           , O.setField txFreezeField (txRowFreeze row)
           , O.setField txCandidateField (txRowCandidate row)
           , O.setField txAcceptedField (txRowAccepted row)
           , O.setField txContractField (txRowContract row)
           , O.setField txRevisionField (txRowRevision row)
           , setNow (O.utcTimestampField "updated_at")
           ]
    )
    (Just (O.fieldEquals txIdField (txRowId row)))

-- Records --------------------------------------------------------------------------

recordTable :: O.TableDefinition O.NoKey RecordRow RecordRow
recordTable =
  O.mkTableDefinitionWithoutKey "lockstep_transaction_records" $
    RecordRow
      <$> O.marshallField recordRowTransaction recordTransactionField
      <*> O.marshallField recordRowSequence recordSequenceField
      <*> O.marshallField recordRowKind (O.unboundedTextField "kind")
      <*> O.marshallField recordRowPrincipal (O.unboundedTextField "principal")
      <*> O.marshallField recordRowStage (O.unboundedTextField "stage")
      <*> O.marshallField recordRowBody (O.unboundedTextField "body")
      <*> O.marshallField recordRowDigest (O.unboundedTextField "body_digest")

recordTransactionField :: O.FieldDefinition O.NotNull TransactionId
recordTransactionField =
  foreignKeyTo transactionTable txIdField "transaction_id"

recordSequenceField :: O.FieldDefinition O.NotNull Int32
recordSequenceField =
  O.integerField "sequence"

transactionRecords :: O.MonadOrville m => TransactionId -> m [RecordRow]
transactionRecords txId =
  O.findEntitiesBy
    recordTable
    (O.where_ (O.fieldEquals recordTransactionField txId) <> O.orderBy (O.orderByField recordSequenceField O.ascendingOrder))

-- | Appends the next record (call under 'lockTransaction', so the sequence is the next one).
appendRecord :: O.MonadOrville m => RecordRow -> m ()
appendRecord =
  O.insertEntity recordTable

-- Invocations ----------------------------------------------------------------------

invocationTable :: Table InvocationRow InvocationRow
invocationTable =
  mkEntityTable "lockstep_invocations" invocationIdField $
    InvocationRow
      <$> O.marshallField invocationRowId invocationIdField
      <*> O.marshallField invocationRowTransaction invocationTransactionField
      <*> O.marshallField invocationRowStage (O.unboundedTextField "stage")
      <*> O.marshallField invocationRowWhat (O.unboundedTextField "what")
      <*> O.marshallField invocationRowRunner (O.unboundedTextField "runner")
      <*> O.marshallField invocationRowAdapter (O.unboundedTextField "adapter")
      <*> O.marshallField invocationRowArgv (O.unboundedTextField "argv")
      <*> O.marshallField invocationRowOutcome invocationOutcomeField
      <*> O.marshallField invocationRowExit invocationExitField
      <*> O.marshallField invocationRowMillis invocationMillisField
      <*> O.marshallField invocationRowStdoutBytes invocationStdoutBytesField
      <*> O.marshallField invocationRowStderrBytes invocationStderrBytesField
      <*> O.marshallField invocationRowStdoutDigest invocationStdoutDigestField
      <*> O.marshallField invocationRowStderrDigest invocationStderrDigestField
      <*> O.marshallField invocationRowStdoutTail invocationStdoutTailField
      <*> O.marshallField invocationRowStderrTail invocationStderrTailField
      <*> O.marshallField invocationRowRevision (O.nullableField (O.integerField "tx_revision"))
      <*> O.marshallField invocationRowAnswer invocationAnswerField
      <*> O.marshallField invocationRowAnswerDigest invocationAnswerDigestField

invocationIdField :: O.FieldDefinition O.NotNull InvocationId
invocationIdField =
  keyField "id"

invocationTransactionField :: O.FieldDefinition O.NotNull TransactionId
invocationTransactionField =
  foreignKeyTo transactionTable txIdField "transaction_id"

nullableText :: String -> O.FieldDefinition O.Nullable (Maybe T.Text)
nullableText =
  O.nullableField . O.unboundedTextField

nullableInt :: String -> O.FieldDefinition O.Nullable (Maybe Int32)
nullableInt =
  O.nullableField . O.integerField

invocationOutcomeField :: O.FieldDefinition O.Nullable (Maybe T.Text)
invocationOutcomeField =
  nullableText "outcome"

invocationExitField :: O.FieldDefinition O.Nullable (Maybe Int32)
invocationExitField =
  nullableInt "exit_code"

invocationMillisField :: O.FieldDefinition O.Nullable (Maybe Int32)
invocationMillisField =
  nullableInt "millis"

invocationStdoutBytesField :: O.FieldDefinition O.Nullable (Maybe Int32)
invocationStdoutBytesField =
  nullableInt "stdout_bytes"

invocationStderrBytesField :: O.FieldDefinition O.Nullable (Maybe Int32)
invocationStderrBytesField =
  nullableInt "stderr_bytes"

invocationStdoutDigestField :: O.FieldDefinition O.Nullable (Maybe T.Text)
invocationStdoutDigestField =
  nullableText "stdout_digest"

invocationStderrDigestField :: O.FieldDefinition O.Nullable (Maybe T.Text)
invocationStderrDigestField =
  nullableText "stderr_digest"

invocationStdoutTailField :: O.FieldDefinition O.Nullable (Maybe T.Text)
invocationStdoutTailField =
  nullableText "stdout_tail"

invocationStderrTailField :: O.FieldDefinition O.Nullable (Maybe T.Text)
invocationStderrTailField =
  nullableText "stderr_tail"

invocationAnswerField :: O.FieldDefinition O.Nullable (Maybe T.Text)
invocationAnswerField =
  nullableText "answer"

invocationAnswerDigestField :: O.FieldDefinition O.Nullable (Maybe T.Text)
invocationAnswerDigestField =
  nullableText "answer_digest"

invocationFinishedAtField :: O.FieldDefinition O.Nullable (Maybe UTCTime)
invocationFinishedAtField =
  O.nullableField (O.utcTimestampField "finished_at")

-- | Invocations, by start then id.
invocationOrder :: O.SelectOptions
invocationOrder =
  O.orderBy (O.orderByField (O.utcTimestampField "started_at") O.ascendingOrder <> O.orderByField invocationIdField O.ascendingOrder)

{- | Recorded before the run starts: the run has not ended until
'finishInvocation'. How it ended starts empty, whatever the row says, as the
columns' defaults always made it.
-}
insertInvocation :: O.MonadOrville m => InvocationRow -> m ()
insertInvocation row =
  O.insertEntity
    invocationTable
    row
      { invocationRowOutcome = Nothing
      , invocationRowExit = Nothing
      , invocationRowMillis = Nothing
      , invocationRowStdoutBytes = Nothing
      , invocationRowStderrBytes = Nothing
      , invocationRowStdoutDigest = Nothing
      , invocationRowStderrDigest = Nothing
      , invocationRowStdoutTail = Nothing
      , invocationRowStderrTail = Nothing
      , invocationRowAnswer = Nothing
      , invocationRowAnswerDigest = Nothing
      }

-- | Writes how the invocation ended; a second finish is refused by the trigger.
finishInvocation :: O.MonadOrville m => InvocationId -> Finish -> m ()
finishInvocation invocationId f =
  O.updateFields
    invocationTable
    ( setExpression invocationFinishedAtField clockTimestamp
        :| [ O.setField invocationOutcomeField (Just (finishOutcome f))
           , O.setField invocationExitField (finishExit f)
           , O.setField invocationMillisField (finishMillis f)
           , O.setField invocationStdoutBytesField (finishStdoutBytes f)
           , O.setField invocationStderrBytesField (finishStderrBytes f)
           , O.setField invocationStdoutDigestField (finishStdoutDigest f)
           , O.setField invocationStderrDigestField (finishStderrDigest f)
           , O.setField invocationStdoutTailField (finishStdoutTail f)
           , O.setField invocationStderrTailField (finishStderrTail f)
           , O.setField invocationAnswerField (finishAnswer f)
           , O.setField invocationAnswerDigestField (finishAnswerDigest f)
           ]
    )
    (Just (O.fieldEquals invocationIdField invocationId))

unfinishedInvocations :: O.MonadOrville m => TransactionId -> m [InvocationRow]
unfinishedInvocations txId =
  O.findEntitiesBy
    invocationTable
    (O.where_ (O.fieldEquals invocationTransactionField txId `O.andExpr` O.fieldIsNull invocationFinishedAtField) <> invocationOrder)

transactionInvocations :: O.MonadOrville m => TransactionId -> m [InvocationRow]
transactionInvocations txId =
  O.findEntitiesBy invocationTable (O.where_ (O.fieldEquals invocationTransactionField txId) <> invocationOrder)

-- Facts from C-P4.1 -------------------------------------------------------------------

-- | The bug admission of a Work Order and its project's enablement.
data AdmissionFacts
  = AdmissionFacts
  { factWorkOrder :: WorkOrderId
  , factTask :: TaskId
  , factProject :: ProjectId
  , factRepository :: RepositoryId
  , factEngineer :: T.Text
  , factFolder :: T.Text
  }
  deriving (Eq)

ofAdmission :: O.FieldDefinition nullability a -> O.QualifiedFieldDefinition O.TableIdentifier nullability a
ofAdmission =
  qualified admissionTable

ofEnablement :: O.FieldDefinition nullability a -> O.QualifiedFieldDefinition O.TableIdentifier nullability a
ofEnablement =
  qualified enablementTable

admissionFacts :: O.MonadOrville m => WorkOrderId -> m (Maybe AdmissionFacts)
admissionFacts workOrder =
  headMay
    <$> selectJoined
      ( AdmissionFacts
          <$> admissionColumn admissionWorkOrderField
          <*> admissionColumn admissionTaskField
          <*> admissionColumn admissionProjectField
          <*> enablementColumn enablementRepositoryField
          <*> enablementColumn enablementEngineerField
          <*> enablementColumn enablementFolderField
      )
      ( joinedOn
          admissionTable
          [(Expr.innerJoinType, tableReference enablementTable, Expr.equals (qualifiedReference (ofEnablement enablementProjectField)) (qualifiedReference (ofAdmission admissionProjectField)))]
      )
      (O.where_ (qualifiedEquals (ofAdmission admissionWorkOrderField) workOrder))

-- | A column of @lockstep_bug_admissions@, read from a join.
admissionColumn :: O.FieldDefinition nullability a -> O.SqlMarshaller w a
admissionColumn field =
  O.marshallQualifyFields (O.tableIdentifier admissionTable) (O.marshallReadOnlyField field)

-- | A column of @lockstep_execution_enablements@, read from a join.
enablementColumn :: O.FieldDefinition nullability a -> O.SqlMarshaller w a
enablementColumn field =
  O.marshallQualifyFields (O.tableIdentifier enablementTable) (O.marshallReadOnlyField field)

-- | Whether Lockstep has started on any bug of the project (C-P4.16).
projectStarted :: O.MonadOrville m => ProjectId -> m Bool
projectStarted project =
  not . L.null
    <$> selectJoined
      (O.marshallQualifyFields (O.tableIdentifier transactionTable) (O.marshallReadOnlyField txIdField))
      ( joinedOn
          transactionTable
          [(Expr.innerJoinType, tableReference admissionTable, Expr.equals (qualifiedReference (ofAdmission admissionWorkOrderField)) (qualifiedReference (ofTransaction txWorkOrderField)))]
      )
      (O.where_ (qualifiedEquals (ofAdmission admissionProjectField) project) <> O.limit 1)

{- | The admitted bug Work Orders that have no transaction yet, in hand-over
order (C-P4.15 W1): admissions with no matching transaction in a left join
(what @NOT EXISTS (SELECT 1 FROM lockstep_transactions ...)@ selected).
-}
pendingAdmissions :: O.MonadOrville m => m [WorkOrderId]
pendingAdmissions =
  selectJoined
    (O.marshallQualifyFields (O.tableIdentifier admissionTable) (O.marshallReadOnlyField admissionWorkOrderField))
    ( joinedOn
        admissionTable
        [(Expr.leftJoinType, tableReference transactionTable, Expr.equals (qualifiedReference (ofTransaction txWorkOrderField)) (qualifiedReference (ofAdmission admissionWorkOrderField)))]
    )
    ( O.where_ (Expr.isNull (qualifiedReference (ofTransaction txIdField)))
        <> O.orderBy (qualifiedOrder (ofAdmission admissionIdField) O.ascendingOrder)
    )
