{- | Storage for the receipts of human decisions made in the browser (contract
C-P3.8 M4) and for the attempt markers that come before them (C-C.R1 R1, R2).
Rows are never updated or deleted; the migrations' triggers refuse it.
-}
module Lockstep.Persistence.DecisionReceipts
  ( ReceiptRow (..)
  , findReceipt
  , insertReceipt
  , latestReceiptFor
  , attemptExists
  , insertAttempt
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql
import Orville.PostgreSQL.Raw.SqlValue qualified as SqlValue

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

sql :: String -> RawSql.RawSql
sql =
  RawSql.fromString

text :: T.Text -> RawSql.RawSql
text =
  RawSql.parameter . SqlValue.fromText

columns :: String
columns =
  "idempotency_key, payload_digest, subject::text AS subject, choice, expected, outcome, refusal_code, actor, ledger_basis"

marshaller :: O.AnnotatedSqlMarshaller ReceiptRow ReceiptRow
marshaller =
  O.annotateSqlMarshallerEmptyAnnotation $
    ReceiptRow
      <$> O.marshallField receiptRowKey (O.unboundedTextField "idempotency_key")
      <*> O.marshallField receiptRowDigest (O.unboundedTextField "payload_digest")
      <*> O.marshallField receiptRowSubject (O.unboundedTextField "subject")
      <*> O.marshallField receiptRowChoice (O.unboundedTextField "choice")
      <*> O.marshallField receiptRowExpected (O.integerField "expected")
      <*> O.marshallField receiptRowOutcome (O.unboundedTextField "outcome")
      <*> O.marshallField receiptRowRefusal (O.nullableField (O.unboundedTextField "refusal_code"))
      <*> O.marshallField receiptRowActor (O.unboundedTextField "actor")
      <*> O.marshallField receiptRowBasis (O.nullableField (O.unboundedTextField "ledger_basis"))

select :: O.MonadOrville m => RawSql.RawSql -> m [ReceiptRow]
select rest =
  O.executeAndDecode O.SelectQuery (sql ("SELECT " <> columns <> " FROM lockstep_decision_receipts ") <> rest) marshaller

findReceipt :: O.MonadOrville m => T.Text -> m (Maybe ReceiptRow)
findReceipt key =
  headMay <$> select (sql "WHERE idempotency_key = " <> text key)

-- | The latest applied receipt for a subject, if any.
latestReceiptFor :: O.MonadOrville m => T.Text -> m (Maybe ReceiptRow)
latestReceiptFor subject =
  headMay <$> select (sql "WHERE outcome = 'applied' AND subject = CAST(" <> text subject <> sql " AS uuid) ORDER BY id DESC LIMIT 1")

-- | Inserts the receipt unless one with its key exists; True when this call inserted it.
insertReceipt :: O.MonadOrville m => ReceiptRow -> m Bool
insertReceipt row =
  returnedAny
    ( sql "INSERT INTO lockstep_decision_receipts (idempotency_key, payload_digest, subject, choice, expected, outcome, refusal_code, actor, ledger_basis) VALUES ("
        <> text (receiptRowKey row)
        <> sql ", "
        <> text (receiptRowDigest row)
        <> sql ", CAST("
        <> text (receiptRowSubject row)
        <> sql " AS uuid), "
        <> text (receiptRowChoice row)
        <> sql ", "
        <> RawSql.parameter (SqlValue.fromInt32 (receiptRowExpected row))
        <> sql ", "
        <> text (receiptRowOutcome row)
        <> sql ", "
        <> maybe (sql "NULL") text (receiptRowRefusal row)
        <> sql ", "
        <> text (receiptRowActor row)
        <> sql ", "
        <> maybe (sql "NULL") text (receiptRowBasis row)
        <> sql ") ON CONFLICT (idempotency_key) DO NOTHING RETURNING id"
    )

-- | Whether an attempt was ever started with this key.
attemptExists :: O.MonadOrville m => T.Text -> m Bool
attemptExists key =
  not . null
    <$> O.executeAndDecode
      O.SelectQuery
      (sql "SELECT id FROM lockstep_decision_attempts WHERE idempotency_key = " <> text key)
      (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.bigIntegerField "id")))

-- | Records that an attempt with this key starts now; True when this call recorded it.
insertAttempt :: O.MonadOrville m => T.Text -> T.Text -> T.Text -> m Bool
insertAttempt key digest subject =
  returnedAny
    ( sql "INSERT INTO lockstep_decision_attempts (idempotency_key, payload_digest, subject) VALUES ("
        <> text key
        <> sql ", "
        <> text digest
        <> sql ", CAST("
        <> text subject
        <> sql " AS uuid)) ON CONFLICT (idempotency_key) DO NOTHING RETURNING id"
    )

returnedAny :: O.MonadOrville m => RawSql.RawSql -> m Bool
returnedAny statement =
  not . null
    <$> O.executeAndDecode O.InsertQuery statement (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.bigIntegerField "id")))

headMay :: [a] -> Maybe a
headMay xs =
  case xs of
    [] -> Nothing
    x : _ -> Just x
