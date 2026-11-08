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

import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Maybe (isJust)
import Data.Text qualified as T
import Data.Time (UTCTime)
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O

import Lockstep.Persistence.Fields (forUpdate, setNow, uuidField)
import Lockstep.Persistence.Ledger (workOrderIdField, workOrderTable)

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

-- lockstep_human_requests -----------------------------------------------------

requestTable :: O.TableDefinition (O.HasKey T.Text) RequestRow RequestRow
requestTable =
  O.mkTableDefinition "lockstep_human_requests" (O.primaryKey requestIdField) $
    RequestRow
      <$> O.marshallField requestRowId requestIdField
      <*> O.marshallField requestRowKey requestKeyField
      <*> O.marshallField requestRowDigest (O.unboundedTextField "payload_digest")
      <*> O.marshallField requestRowWorkOrder (uuidField "work_order_id")
      <*> O.marshallField requestRowEngineer (O.unboundedTextField "engineer_name")
      <*> O.marshallField requestRowContract (O.nullableField (O.unboundedTextField "contract_digest"))
      <*> O.marshallField requestRowKind (O.unboundedTextField "kind")
      <*> O.marshallField requestRowChoices (O.unboundedTextField "choices")
      <*> O.marshallField requestRowQuestion (O.unboundedTextField "question")
      <*> O.marshallField requestRowEvidence (O.unboundedTextField "evidence")
      <*> O.marshallField requestRowAuthority (O.unboundedTextField "requested_authority")
      <*> O.marshallField requestRowRevision requestRevisionField
      <*> O.marshallField requestRowState requestStateField
      <*> O.marshallField requestRowAnswer requestAnswerField

requestIdField :: O.FieldDefinition O.NotNull T.Text
requestIdField =
  uuidField "id"

requestKeyField :: O.FieldDefinition O.NotNull T.Text
requestKeyField =
  O.unboundedTextField "idempotency_key"

requestRevisionField :: O.FieldDefinition O.NotNull Int32
requestRevisionField =
  O.integerField "revision"

requestStateField :: O.FieldDefinition O.NotNull T.Text
requestStateField =
  O.unboundedTextField "state"

requestAnswerField :: O.FieldDefinition O.Nullable (Maybe T.Text)
requestAnswerField =
  O.nullableField (O.unboundedTextField "answer")

-- | Set by the database on insert; only ordered by.
requestCreatedAtField :: O.FieldDefinition O.NotNull UTCTime
requestCreatedAtField =
  O.utcTimestampField "created_at"

requestUpdatedAtField :: O.FieldDefinition O.NotNull UTCTime
requestUpdatedAtField =
  O.utcTimestampField "updated_at"

findRequestByKey :: O.MonadOrville m => T.Text -> m (Maybe RequestRow)
findRequestByKey key =
  O.findFirstEntityBy requestTable (O.where_ (O.fieldEquals requestKeyField key))

findRequest :: O.MonadOrville m => T.Text -> m (Maybe RequestRow)
findRequest requestId =
  O.findFirstEntityBy requestTable (O.where_ (O.fieldEquals requestIdField requestId))

-- | The request row, locked until the transaction ends.
lockRequest :: O.MonadOrville m => T.Text -> m (Maybe RequestRow)
lockRequest requestId =
  O.findFirstEntityBy requestTable (O.where_ (O.fieldEquals requestIdField requestId) <> forUpdate)

openRequestRows :: O.MonadOrville m => m [RequestRow]
openRequestRows =
  O.findEntitiesBy
    requestTable
    ( O.where_ (O.fieldEquals requestStateField (T.pack "open"))
        <> O.orderBy (O.orderByField requestCreatedAtField O.ascendingOrder <> O.orderByField requestIdField O.ascendingOrder)
    )

insertRequest :: O.MonadOrville m => RequestRow -> m ()
insertRequest =
  O.insertEntity requestTable

-- | The request's revision, state and answer after a message.
updateRequest :: O.MonadOrville m => T.Text -> Int32 -> T.Text -> Maybe T.Text -> m ()
updateRequest requestId revision state answer =
  O.updateFields
    requestTable
    ( O.setField requestRevisionField revision
        :| [ O.setField requestStateField state
           , O.setField requestAnswerField answer
           , setNow requestUpdatedAtField
           ]
    )
    (Just (O.fieldEquals requestIdField requestId))

-- lockstep_conversation_messages ----------------------------------------------

-- | Messages are keyed by an identity column the rows do not carry.
messageTable :: O.TableDefinition O.NoKey MessageRow MessageRow
messageTable =
  O.mkTableDefinitionWithoutKey "lockstep_conversation_messages" $
    MessageRow
      <$> O.marshallField messageRowRequest messageRequestField
      <*> O.marshallField messageRowSequence messageSequenceField
      <*> O.marshallField messageRowKey messageKeyField
      <*> O.marshallField messageRowDigest (O.unboundedTextField "payload_digest")
      <*> O.marshallField messageRowKind (O.unboundedTextField "kind")
      <*> O.marshallField messageRowPrincipal (O.unboundedTextField "principal")
      <*> O.marshallField messageRowEvidence (O.unboundedTextField "sender_evidence")
      <*> O.marshallField messageRowChannel (O.unboundedTextField "channel")
      <*> O.marshallField messageRowRevision (O.integerField "request_revision")
      <*> O.marshallField messageRowBody (O.unboundedTextField "body")
      <*> O.marshallField messageRowChoice (O.nullableField (O.unboundedTextField "choice"))

messageRequestField :: O.FieldDefinition O.NotNull T.Text
messageRequestField =
  uuidField "request_id"

messageSequenceField :: O.FieldDefinition O.NotNull Int32
messageSequenceField =
  O.integerField "sequence"

messageKeyField :: O.FieldDefinition O.NotNull T.Text
messageKeyField =
  O.unboundedTextField "idempotency_key"

findMessageByKey :: O.MonadOrville m => T.Text -> m (Maybe MessageRow)
findMessageByKey key =
  O.findFirstEntityBy messageTable (O.where_ (O.fieldEquals messageKeyField key))

requestMessages :: O.MonadOrville m => T.Text -> m [MessageRow]
requestMessages requestId =
  O.findEntitiesBy
    messageTable
    (O.where_ (O.fieldEquals messageRequestField requestId) <> O.orderBy (O.orderByField messageSequenceField O.ascendingOrder))

insertMessage :: O.MonadOrville m => MessageRow -> m ()
insertMessage =
  O.insertEntity messageTable

workOrderExists :: O.MonadOrville m => T.Text -> m Bool
workOrderExists workOrder =
  isJust <$> O.findFirstEntityBy workOrderTable (O.where_ (O.fieldEquals workOrderIdField workOrder))
