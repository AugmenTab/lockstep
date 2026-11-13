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

import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text qualified as T
import Data.Time qualified as Time
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Expr qualified as Expr

import Lockstep.Kernel.Identity (JobId, ReceiptId)
import Lockstep.Persistence.Commands
  ( receiptAcceptedAtField
  , receiptActorField
  , receiptIdField
  , receiptKindField
  , receiptOutcomeField
  , receiptRevisionField
  , receiptTable
  )
import Lockstep.Persistence.Fields (countOf, hexDigest, joinedOn, qualified, qualifiedOrder, qualifiedReference, selectJoined, tableReference)
import Lockstep.Persistence.Jobs
  ( JobState
  , jobErrorField
  , jobIdField
  , jobOutcomeDigestField
  , jobReceiptField
  , jobStateField
  , jobStepsDoneField
  , jobStepsTotalField
  , jobTable
  )

data ActivityRow
  = ActivityRow
  { activityId :: ReceiptId
  , activityKind :: T.Text
  , activityOutcome :: T.Text
  , activityActor :: T.Text
  , activityAcceptedAt :: Time.UTCTime
  , activityRevision :: Int64
  , activityJobState :: Maybe JobState
  }

data JobEvidenceRow
  = JobEvidenceRow
  { evidenceJobId :: JobId
  , evidenceReceiptId :: ReceiptId
  , evidenceState :: JobState
  , evidenceStepsDone :: Int32
  , evidenceStepsTotal :: Int32
  , evidenceError :: Maybe T.Text
  , evidenceDigestHex :: Maybe T.Text
  }

-- | Rows per value of one column of a table.
countsBy :: O.MonadOrville m => O.TableDefinition key w r -> O.FieldDefinition O.NotNull a -> m [(a, Int32)]
countsBy table field =
  selectJoined
    ((,) <$> O.marshallReadOnlyField field <*> countOf "n")
    (tableReference table)
    (O.groupBy (Expr.groupByColumnsExpr (Expr.unqualified (O.fieldColumnName field) :| [])))

jobCounts :: O.MonadOrville m => m [(JobState, Int32)]
jobCounts =
  countsBy jobTable jobStateField

receiptCounts :: O.MonadOrville m => m [(T.Text, Int32)]
receiptCounts =
  countsBy receiptTable receiptOutcomeField

-- | The newest 20 receipts, with the state of their job if any.
recentActivity :: O.MonadOrville m => m [ActivityRow]
recentActivity =
  selectJoined
    ( ActivityRow
        <$> receiptColumn receiptIdField
        <*> receiptColumn receiptKindField
        <*> receiptColumn receiptOutcomeField
        <*> receiptColumn receiptActorField
        <*> receiptColumn receiptAcceptedAtField
        <*> receiptColumn receiptRevisionField
        <*> O.marshallQualifyFields (O.tableIdentifier jobTable) (O.marshallReadOnlyField (O.nullableField jobStateField))
    )
    ( joinedOn
        receiptTable
        [
          ( Expr.leftJoinType
          , tableReference jobTable
          , Expr.equals (qualifiedReference (qualified jobTable jobReceiptField)) (qualifiedReference (qualified receiptTable receiptIdField))
          )
        ]
    )
    (O.orderBy (qualifiedOrder (qualified receiptTable receiptIdField) O.descendingOrder) <> O.limit 20)

-- | A column of @lockstep_command_receipts@, read from the join.
receiptColumn :: O.FieldDefinition nullability a -> O.SqlMarshaller w a
receiptColumn field =
  O.marshallQualifyFields (O.tableIdentifier receiptTable) (O.marshallReadOnlyField field)

-- | The newest 20 jobs with their stored outcome digest (hex), if any.
recentJobs :: O.MonadOrville m => m [JobEvidenceRow]
recentJobs =
  selectJoined
    ( JobEvidenceRow
        <$> O.marshallReadOnlyField jobIdField
        <*> O.marshallReadOnlyField jobReceiptField
        <*> O.marshallReadOnlyField jobStateField
        <*> O.marshallReadOnlyField jobStepsDoneField
        <*> O.marshallReadOnlyField jobStepsTotalField
        <*> O.marshallReadOnlyField jobErrorField
        <*> (fmap hexDigest <$> O.marshallReadOnlyField jobOutcomeDigestField)
    )
    (tableReference jobTable)
    (O.orderBy (O.orderByField jobIdField O.descendingOrder) <> O.limit 20)
