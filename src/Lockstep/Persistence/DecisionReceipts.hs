{- | Storage for the receipts of human decisions made in the browser (contract
C-P3.8 M4) and for the attempt markers that come before them (C-C.R1 R1, R2).
Rows are never updated or deleted; the migrations' triggers refuse it.
-}
module Lockstep.Persistence.DecisionReceipts
  ( ReceiptRow (..)
  , findReceipt
  , insertReceipt
  , latestReceiptFor
  , attemptDigest
  , insertAttempt
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O

import Lockstep.Persistence.Fields (ConflictTarget (..), insertIgnoringConflict, uuidField)

data ReceiptRow
  = ReceiptRow
  { receiptRowKey :: T.Text
  , receiptRowDigest :: T.Text
  , receiptRowSubject :: T.Text
  , receiptRowChoice :: T.Text
  , receiptRowExpected :: Int32
  , receiptRowOutcome :: T.Text
  , receiptRowRefusal :: Maybe T.Text
  , receiptRowActor :: T.Text
  , receiptRowBasis :: Maybe T.Text
  }

receiptTable :: O.TableDefinition O.NoKey ReceiptRow ReceiptRow
receiptTable =
  O.mkTableDefinitionWithoutKey "lockstep_decision_receipts" $
    ReceiptRow
      <$> O.marshallField receiptRowKey keyField
      <*> O.marshallField receiptRowDigest payloadDigestField
      <*> O.marshallField receiptRowSubject subjectField
      <*> O.marshallField receiptRowChoice (O.unboundedTextField "choice")
      <*> O.marshallField receiptRowExpected (O.integerField "expected")
      <*> O.marshallField receiptRowOutcome outcomeField
      <*> O.marshallField receiptRowRefusal (O.nullableField (O.unboundedTextField "refusal_code"))
      <*> O.marshallField receiptRowActor (O.unboundedTextField "actor")
      <*> O.marshallField receiptRowBasis (O.nullableField (O.unboundedTextField "ledger_basis"))

keyField :: O.FieldDefinition O.NotNull T.Text
keyField =
  O.unboundedTextField "idempotency_key"

payloadDigestField :: O.FieldDefinition O.NotNull T.Text
payloadDigestField =
  O.unboundedTextField "payload_digest"

subjectField :: O.FieldDefinition O.NotNull T.Text
subjectField =
  uuidField "subject"

outcomeField :: O.FieldDefinition O.NotNull T.Text
outcomeField =
  O.unboundedTextField "outcome"

-- | The identity column; only ordered by.
identityField :: O.FieldDefinition O.NotNull Int64
identityField =
  O.bigIntegerField "id"

findReceipt :: O.MonadOrville m => T.Text -> m (Maybe ReceiptRow)
findReceipt key =
  O.findFirstEntityBy receiptTable (O.where_ (O.fieldEquals keyField key))

-- | The latest applied receipt for a subject, if any.
latestReceiptFor :: O.MonadOrville m => T.Text -> m (Maybe ReceiptRow)
latestReceiptFor subject =
  O.findFirstEntityBy
    receiptTable
    ( O.where_ (O.fieldEquals outcomeField (T.pack "applied") `O.andExpr` O.fieldEquals subjectField subject)
        <> O.orderBy (O.orderByField identityField O.descendingOrder)
    )

-- | Inserts the receipt unless one with its key exists; True when this call inserted it.
insertReceipt :: O.MonadOrville m => ReceiptRow -> m Bool
insertReceipt =
  insertIgnoringConflict (ConflictOn "idempotency_key") receiptTable

-- lockstep_decision_attempts -----------------------------------------------------

-- | (key, payload digest, subject).
attemptTable :: O.TableDefinition O.NoKey (T.Text, T.Text, T.Text) (T.Text, T.Text, T.Text)
attemptTable =
  O.mkTableDefinitionWithoutKey "lockstep_decision_attempts" $
    (,,)
      <$> O.marshallField (\(k, _, _) -> k) keyField
      <*> O.marshallField (\(_, d, _) -> d) payloadDigestField
      <*> O.marshallField (\(_, _, s) -> s) subjectField

-- | The payload digest of the attempt started with this key, if one was.
attemptDigest :: O.MonadOrville m => T.Text -> m (Maybe T.Text)
attemptDigest key =
  fmap (\(_, digest, _) -> digest) <$> O.findFirstEntityBy attemptTable (O.where_ (O.fieldEquals keyField key))

-- | Records that an attempt with this key starts now; True when this call recorded it.
insertAttempt :: O.MonadOrville m => T.Text -> T.Text -> T.Text -> m Bool
insertAttempt key digest subject =
  insertIgnoringConflict (ConflictOn "idempotency_key") attemptTable (key, digest, subject)
