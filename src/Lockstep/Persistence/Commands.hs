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
  , receiptTable
  , receiptIdField
  , receiptKindField
  , receiptActorField
  , receiptOutcomeField
  , receiptRevisionField
  , receiptAcceptedAtField
  ) where

import Data.ByteString qualified as BS
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text qualified as T
import Data.Time qualified as Time
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O

import Lockstep.Persistence.Fields (digestField, forUpdate, headMay, hexDigest, setNow)

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

-- lockstep_workspace ---------------------------------------------------------------

-- | The one workspace row: (name, revision).
workspaceTable :: O.TableDefinition (O.HasKey Bool) (T.Text, Int64) (T.Text, Int64)
workspaceTable =
  O.mkTableDefinition "lockstep_workspace" (O.primaryKey singletonField) $
    (,)
      <$> O.marshallField fst workspaceNameField
      <*> O.marshallField snd workspaceRevisionField

-- | The primary key, always @true@ (a CHECK constraint keeps the table to one row).
singletonField :: O.FieldDefinition O.NotNull Bool
singletonField =
  O.booleanField "singleton"

workspaceNameField :: O.FieldDefinition O.NotNull T.Text
workspaceNameField =
  O.unboundedTextField "name"

workspaceRevisionField :: O.FieldDefinition O.NotNull Int64
workspaceRevisionField =
  O.bigIntegerField "revision"

theWorkspace :: O.SelectOptions
theWorkspace =
  O.where_ (O.fieldEquals singletonField True)

-- | The workspace name and revision, locked until the transaction ends.
lockWorkspace :: O.MonadOrville m => m (Maybe (T.Text, Int64))
lockWorkspace =
  O.findFirstEntityBy workspaceTable (theWorkspace <> forUpdate)

readWorkspace :: O.MonadOrville m => m (Maybe (T.Text, Int64))
readWorkspace =
  O.findFirstEntityBy workspaceTable theWorkspace

updateWorkspace :: O.MonadOrville m => T.Text -> Int64 -> m ()
updateWorkspace name revision =
  O.updateFields
    workspaceTable
    (O.setField workspaceNameField name :| [O.setField workspaceRevisionField revision, setNow (O.utcTimestampField "updated_at")])
    (Just (O.fieldEquals singletonField True))

-- lockstep_command_receipts --------------------------------------------------------

{- | A receipt is written as a 'NewReceipt' and read back as a 'ReceiptRow'
with its id, its payload digest as lowercase hex, and the time the database
accepted it.
-}
receiptTable :: O.TableDefinition (O.HasKey Int64) NewReceipt ReceiptRow
receiptTable =
  O.mkTableDefinition "lockstep_command_receipts" (O.primaryKey receiptIdField) $
    (\receiptId key _version kind digest actor expected outcome revision acceptedAt -> ReceiptRow receiptId key kind (hexDigest digest) actor expected outcome revision acceptedAt)
      <$> O.marshallReadOnlyField receiptIdField
      <*> O.marshallField newKey receiptKeyField
      <*> O.marshallField newVersion (O.integerField "envelope_version")
      <*> O.marshallField newKind receiptKindField
      <*> O.marshallField newDigest (digestField "payload_digest")
      <*> O.marshallField newActor receiptActorField
      <*> O.marshallField newExpected (O.bigIntegerField "expected_revision")
      <*> O.marshallField newOutcome receiptOutcomeField
      <*> O.marshallField newRevision receiptRevisionField
      <*> O.marshallReadOnlyField receiptAcceptedAtField

receiptIdField :: O.FieldDefinition O.NotNull Int64
receiptIdField =
  O.bigIntegerField "id"

receiptKindField :: O.FieldDefinition O.NotNull T.Text
receiptKindField =
  O.unboundedTextField "command_kind"

receiptActorField :: O.FieldDefinition O.NotNull T.Text
receiptActorField =
  O.unboundedTextField "actor"

receiptOutcomeField :: O.FieldDefinition O.NotNull T.Text
receiptOutcomeField =
  O.unboundedTextField "outcome"

receiptRevisionField :: O.FieldDefinition O.NotNull Int64
receiptRevisionField =
  O.bigIntegerField "resulting_revision"

receiptAcceptedAtField :: O.FieldDefinition O.NotNull Time.UTCTime
receiptAcceptedAtField =
  O.utcTimestampField "accepted_at"

receiptKeyField :: O.FieldDefinition O.NotNull T.Text
receiptKeyField =
  O.unboundedTextField "idempotency_key"

findReceiptByKey :: O.MonadOrville m => T.Text -> m (Maybe ReceiptRow)
findReceiptByKey key =
  O.findFirstEntityBy receiptTable (O.where_ (O.fieldEquals receiptKeyField key))

findReceiptById :: O.MonadOrville m => Int64 -> m (Maybe ReceiptRow)
findReceiptById =
  O.findEntity receiptTable

-- | Inserts a receipt; returns its id and acceptance time.
insertReceipt :: O.MonadOrville m => NewReceipt -> m (Maybe (Int64, Time.UTCTime))
insertReceipt receipt =
  fmap (\row -> (rowId row, rowAcceptedAt row)) . headMay <$> O.insertAndReturnEntities receiptTable (receipt :| [])
