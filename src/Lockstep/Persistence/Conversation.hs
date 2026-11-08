{- | Storage for Human Requests and their conversations (contract C-P4.3 H4).
Messages are never updated or deleted; the migration's triggers refuse it. A
request row changes only together with the message that changes it, under
'lockRequest'. Callers run these inside one transaction.
-}
module Lockstep.Persistence.Conversation
  ( RequestRow (..)
  , MessageRow (..)
  , findRequestByKey
  , findRequest
  , lockRequest
  , openRequestRows
  , insertRequest
  , updateRequest
  , findMessageByKey
  , requestMessages
  , insertMessage
  , workOrderExists
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql
import Orville.PostgreSQL.Raw.SqlValue qualified as SqlValue

data RequestRow
  = RequestRow
  { requestRowId :: T.Text
  , requestRowKey :: T.Text
  , requestRowDigest :: T.Text
  , requestRowWorkOrder :: T.Text
  , requestRowEngineer :: T.Text
  , requestRowContract :: Maybe T.Text
  , requestRowKind :: T.Text
  , requestRowChoices :: T.Text
  , requestRowQuestion :: T.Text
  , requestRowEvidence :: T.Text
  , requestRowAuthority :: T.Text
  , requestRowRevision :: Int32
  , requestRowState :: T.Text
  , requestRowAnswer :: Maybe T.Text
  }
  deriving (Eq)

data MessageRow
  = MessageRow
  { messageRowRequest :: T.Text
  , messageRowSequence :: Int32
  , messageRowKey :: T.Text
  , messageRowDigest :: T.Text
  , messageRowKind :: T.Text
  , messageRowPrincipal :: T.Text
  , messageRowEvidence :: T.Text
  , messageRowChannel :: T.Text
  , messageRowRevision :: Int32
  , messageRowBody :: T.Text
  , messageRowChoice :: Maybe T.Text
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

uuid :: T.Text -> RawSql.RawSql
uuid value =
  sql "CAST(" <> text value <> sql " AS uuid)"

headMay :: [a] -> Maybe a
headMay xs =
  case xs of
    [] -> Nothing
    x : _ -> Just x

requestMarshaller :: O.AnnotatedSqlMarshaller RequestRow RequestRow
requestMarshaller =
  O.annotateSqlMarshallerEmptyAnnotation $
    RequestRow
      <$> O.marshallField requestRowId (O.unboundedTextField "id")
      <*> O.marshallField requestRowKey (O.unboundedTextField "idempotency_key")
      <*> O.marshallField requestRowDigest (O.unboundedTextField "payload_digest")
      <*> O.marshallField requestRowWorkOrder (O.unboundedTextField "work_order_id")
      <*> O.marshallField requestRowEngineer (O.unboundedTextField "engineer_name")
      <*> O.marshallField requestRowContract (O.nullableField (O.unboundedTextField "contract_digest"))
      <*> O.marshallField requestRowKind (O.unboundedTextField "kind")
      <*> O.marshallField requestRowChoices (O.unboundedTextField "choices")
      <*> O.marshallField requestRowQuestion (O.unboundedTextField "question")
      <*> O.marshallField requestRowEvidence (O.unboundedTextField "evidence")
      <*> O.marshallField requestRowAuthority (O.unboundedTextField "requested_authority")
      <*> O.marshallField requestRowRevision (O.integerField "revision")
      <*> O.marshallField requestRowState (O.unboundedTextField "state")
      <*> O.marshallField requestRowAnswer (O.nullableField (O.unboundedTextField "answer"))

selectRequests :: O.MonadOrville m => RawSql.RawSql -> m [RequestRow]
selectRequests rest =
  O.executeAndDecode
    O.SelectQuery
    ( sql "SELECT id::text AS id, idempotency_key, payload_digest, work_order_id::text AS work_order_id, engineer_name, contract_digest, kind, choices, question, evidence, requested_authority, revision, state, answer FROM lockstep_human_requests "
        <> rest
    )
    requestMarshaller

findRequestByKey :: O.MonadOrville m => T.Text -> m (Maybe RequestRow)
findRequestByKey key =
  headMay <$> selectRequests (sql "WHERE idempotency_key = " <> text key)

findRequest :: O.MonadOrville m => T.Text -> m (Maybe RequestRow)
findRequest requestId =
  headMay <$> selectRequests (sql "WHERE id = " <> uuid requestId)

-- | The request row, locked until the transaction ends.
lockRequest :: O.MonadOrville m => T.Text -> m (Maybe RequestRow)
lockRequest requestId =
  headMay <$> selectRequests (sql "WHERE id = " <> uuid requestId <> sql " FOR UPDATE")

openRequestRows :: O.MonadOrville m => m [RequestRow]
openRequestRows =
  selectRequests (sql "WHERE state = 'open' ORDER BY created_at, id")

insertRequest :: O.MonadOrville m => RequestRow -> m ()
insertRequest row =
  O.executeVoid O.InsertQuery $
    sql "INSERT INTO lockstep_human_requests (id, idempotency_key, payload_digest, work_order_id, engineer_name, contract_digest, kind, choices, question, evidence, requested_authority, revision, state, answer) VALUES ("
      <> uuid (requestRowId row)
      <> sql ", "
      <> text (requestRowKey row)
      <> sql ", "
      <> text (requestRowDigest row)
      <> sql ", "
      <> uuid (requestRowWorkOrder row)
      <> sql ", "
      <> text (requestRowEngineer row)
      <> sql ", "
      <> maybeText (requestRowContract row)
      <> sql ", "
      <> text (requestRowKind row)
      <> sql ", "
      <> text (requestRowChoices row)
      <> sql ", "
      <> text (requestRowQuestion row)
      <> sql ", "
      <> text (requestRowEvidence row)
      <> sql ", "
      <> text (requestRowAuthority row)
      <> sql ", "
      <> int (requestRowRevision row)
      <> sql ", "
      <> text (requestRowState row)
      <> sql ", "
      <> maybeText (requestRowAnswer row)
      <> sql ")"

-- | The request's revision, state and answer after a message.
updateRequest :: O.MonadOrville m => T.Text -> Int32 -> T.Text -> Maybe T.Text -> m ()
updateRequest requestId revision state answer =
  O.executeVoid O.UpdateQuery $
    sql "UPDATE lockstep_human_requests SET revision = "
      <> int revision
      <> sql ", state = "
      <> text state
      <> sql ", answer = "
      <> maybeText answer
      <> sql ", updated_at = now() WHERE id = "
      <> uuid requestId

messageMarshaller :: O.AnnotatedSqlMarshaller MessageRow MessageRow
messageMarshaller =
  O.annotateSqlMarshallerEmptyAnnotation $
    MessageRow
      <$> O.marshallField messageRowRequest (O.unboundedTextField "request_id")
      <*> O.marshallField messageRowSequence (O.integerField "sequence")
      <*> O.marshallField messageRowKey (O.unboundedTextField "idempotency_key")
      <*> O.marshallField messageRowDigest (O.unboundedTextField "payload_digest")
      <*> O.marshallField messageRowKind (O.unboundedTextField "kind")
      <*> O.marshallField messageRowPrincipal (O.unboundedTextField "principal")
      <*> O.marshallField messageRowEvidence (O.unboundedTextField "sender_evidence")
      <*> O.marshallField messageRowChannel (O.unboundedTextField "channel")
      <*> O.marshallField messageRowRevision (O.integerField "request_revision")
      <*> O.marshallField messageRowBody (O.unboundedTextField "body")
      <*> O.marshallField messageRowChoice (O.nullableField (O.unboundedTextField "choice"))

selectMessages :: O.MonadOrville m => RawSql.RawSql -> m [MessageRow]
selectMessages rest =
  O.executeAndDecode
    O.SelectQuery
    ( sql "SELECT request_id::text AS request_id, sequence, idempotency_key, payload_digest, kind, principal, sender_evidence, channel, request_revision, body, choice FROM lockstep_conversation_messages "
        <> rest
    )
    messageMarshaller

findMessageByKey :: O.MonadOrville m => T.Text -> m (Maybe MessageRow)
findMessageByKey key =
  headMay <$> selectMessages (sql "WHERE idempotency_key = " <> text key)

requestMessages :: O.MonadOrville m => T.Text -> m [MessageRow]
requestMessages requestId =
  selectMessages (sql "WHERE request_id = " <> uuid requestId <> sql " ORDER BY sequence")

insertMessage :: O.MonadOrville m => MessageRow -> m ()
insertMessage row =
  O.executeVoid O.InsertQuery $
    sql "INSERT INTO lockstep_conversation_messages (request_id, sequence, idempotency_key, payload_digest, kind, principal, sender_evidence, channel, request_revision, body, choice) VALUES ("
      <> uuid (messageRowRequest row)
      <> sql ", "
      <> int (messageRowSequence row)
      <> sql ", "
      <> text (messageRowKey row)
      <> sql ", "
      <> text (messageRowDigest row)
      <> sql ", "
      <> text (messageRowKind row)
      <> sql ", "
      <> text (messageRowPrincipal row)
      <> sql ", "
      <> text (messageRowEvidence row)
      <> sql ", "
      <> text (messageRowChannel row)
      <> sql ", "
      <> int (messageRowRevision row)
      <> sql ", "
      <> text (messageRowBody row)
      <> sql ", "
      <> maybeText (messageRowChoice row)
      <> sql ")"

workOrderExists :: O.MonadOrville m => T.Text -> m Bool
workOrderExists workOrder =
  not . null
    <$> O.executeAndDecode
      O.SelectQuery
      (sql "SELECT id::text AS id FROM lockstep_work_orders WHERE id = " <> uuid workOrder)
      (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.unboundedTextField "id")))
