{- | Storage for the workspace and command receipts (contract C-P1.4 E5, E7).
Callers run these inside one transaction; 'lockWorkspace' takes the row lock
that serializes every command.
-}
module Lockstep.Persistence.Commands
  ( ReceiptRow (..)
  , NewReceipt (..)
  , lockWorkspace
  , readWorkspace
  , updateWorkspace
  , findReceiptByKey
  , findReceiptById
  , insertReceipt
  ) where

import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString qualified as BS
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time qualified as Time
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql
import Orville.PostgreSQL.Raw.SqlValue qualified as SqlValue

data ReceiptRow
  = ReceiptRow
  { rowId :: Int64
  , rowKey :: T.Text
  , rowKind :: T.Text
  , rowDigestHex :: T.Text
  , rowActor :: T.Text
  , rowExpected :: Int64
  , rowOutcome :: T.Text
  , rowRevision :: Int64
  , rowAcceptedAt :: Time.UTCTime
  }

data NewReceipt
  = NewReceipt
  { newKey :: T.Text
  , newVersion :: Int32
  , newKind :: T.Text
  , newDigest :: BS.ByteString
  , newActor :: T.Text
  , newExpected :: Int64
  , newOutcome :: T.Text
  , newRevision :: Int64
  }

text :: T.Text -> RawSql.RawSql
text =
  RawSql.parameter . SqlValue.fromText

int64 :: Int64 -> RawSql.RawSql
int64 =
  RawSql.parameter . SqlValue.fromInt64

sql :: String -> RawSql.RawSql
sql =
  RawSql.fromString

workspaceMarshaller :: O.AnnotatedSqlMarshaller (T.Text, Int64) (T.Text, Int64)
workspaceMarshaller =
  O.annotateSqlMarshallerEmptyAnnotation $
    (,)
      <$> O.marshallField fst (O.unboundedTextField "name")
      <*> O.marshallField snd (O.bigIntegerField "revision")

-- | The workspace name and revision, locked until the transaction ends.
lockWorkspace :: O.MonadOrville m => m (Maybe (T.Text, Int64))
lockWorkspace =
  headMay
    <$> O.executeAndDecode
      O.SelectQuery
      (sql "SELECT name, revision FROM lockstep_workspace WHERE singleton FOR UPDATE")
      workspaceMarshaller

readWorkspace :: O.MonadOrville m => m (Maybe (T.Text, Int64))
readWorkspace =
  headMay
    <$> O.executeAndDecode
      O.SelectQuery
      (sql "SELECT name, revision FROM lockstep_workspace WHERE singleton")
      workspaceMarshaller

updateWorkspace :: O.MonadOrville m => T.Text -> Int64 -> m ()
updateWorkspace name revision =
  O.executeVoid O.UpdateQuery $
    sql "UPDATE lockstep_workspace SET name = "
      <> text name
      <> sql ", revision = "
      <> int64 revision
      <> sql ", updated_at = now() WHERE singleton"

receiptColumns :: String
receiptColumns =
  "SELECT id, idempotency_key, command_kind, encode(payload_digest, 'hex') AS digest_hex, actor, expected_revision, outcome, resulting_revision, accepted_at FROM lockstep_command_receipts WHERE "

receiptMarshaller :: O.AnnotatedSqlMarshaller ReceiptRow ReceiptRow
receiptMarshaller =
  O.annotateSqlMarshallerEmptyAnnotation $
    ReceiptRow
      <$> O.marshallField rowId (O.bigIntegerField "id")
      <*> O.marshallField rowKey (O.unboundedTextField "idempotency_key")
      <*> O.marshallField rowKind (O.unboundedTextField "command_kind")
      <*> O.marshallField rowDigestHex (O.unboundedTextField "digest_hex")
      <*> O.marshallField rowActor (O.unboundedTextField "actor")
      <*> O.marshallField rowExpected (O.bigIntegerField "expected_revision")
      <*> O.marshallField rowOutcome (O.unboundedTextField "outcome")
      <*> O.marshallField rowRevision (O.bigIntegerField "resulting_revision")
      <*> O.marshallField rowAcceptedAt (O.utcTimestampField "accepted_at")

findReceiptByKey :: O.MonadOrville m => T.Text -> m (Maybe ReceiptRow)
findReceiptByKey key =
  headMay <$> O.executeAndDecode O.SelectQuery (sql receiptColumns <> sql "idempotency_key = " <> text key) receiptMarshaller

findReceiptById :: O.MonadOrville m => Int64 -> m (Maybe ReceiptRow)
findReceiptById receiptId =
  headMay <$> O.executeAndDecode O.SelectQuery (sql receiptColumns <> sql "id = " <> int64 receiptId) receiptMarshaller

-- | Inserts a receipt; returns its id and acceptance time.
insertReceipt :: O.MonadOrville m => NewReceipt -> m (Maybe (Int64, Time.UTCTime))
insertReceipt receipt =
  headMay
    <$> O.executeAndDecode
      O.InsertQuery
      ( sql "INSERT INTO lockstep_command_receipts (idempotency_key, envelope_version, command_kind, payload_digest, actor, expected_revision, outcome, resulting_revision) VALUES ("
          <> text (newKey receipt)
          <> sql ", "
          <> RawSql.parameter (SqlValue.fromInt32 (newVersion receipt))
          <> sql ", "
          <> text (newKind receipt)
          <> sql ", decode("
          <> text (TE.decodeLatin1 (convertToBase Base16 (newDigest receipt)))
          <> sql ", 'hex'), "
          <> text (newActor receipt)
          <> sql ", "
          <> int64 (newExpected receipt)
          <> sql ", "
          <> text (newOutcome receipt)
          <> sql ", "
          <> int64 (newRevision receipt)
          <> sql ") RETURNING id, accepted_at"
      )
      ( O.annotateSqlMarshallerEmptyAnnotation $
          (,)
            <$> O.marshallField fst (O.bigIntegerField "id")
            <*> O.marshallField snd (O.utcTimestampField "accepted_at")
      )

headMay :: [a] -> Maybe a
headMay xs =
  case xs of
    [] -> Nothing
    x : _ -> Just x
