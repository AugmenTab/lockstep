{-# LANGUAGE TypeFamilies #-}

{- | Storage for the Planner's attempts to answer a person's questions
(contract C-P6.3 I6, I7; migration 23). One row per (request, message): an
attempt is started once, finished once, and never deleted.
-}
module Lockstep.Persistence.Clarification
  ( ClarificationRow (..)
  , ClarificationEnding (..)
  , clarificationEndingCode
  , startClarification
  , finishClarification
  , unfinishedClarifications
  , requestClarifications
  ) where

import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text qualified as T
import Data.Time (UTCTime)
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Text.Show (Show)

import Lockstep.Kernel.Identity (HumanRequestId, InvocationId (..))
import Lockstep.Persistence.Conversation (requestIdField, requestTable)
import Lockstep.Persistence.Entity (EntityKey, Table, foreignKeyTo, keyField, mkEntityTable)
import Lockstep.Persistence.Fields (ConflictTarget (AnyConflict), insertIgnoringConflict, setNow)

-- | How an attempt ended (the @outcome@ column); Nothing while it runs.
data ClarificationEnding
  = EndedAnswered
  | EndedFailed
  | EndedNoHelper
  | EndedUncertain
  deriving (Eq, Show, Enum, Bounded)

clarificationEndingCode :: ClarificationEnding -> T.Text
clarificationEndingCode ending =
  T.pack $
    case ending of
      EndedAnswered -> "answered"
      EndedFailed -> "failed"
      EndedNoHelper -> "no-helper"
      EndedUncertain -> "uncertain"

data ClarificationRow
  = ClarificationRow
  { clarificationId :: InvocationId
  -- ^ The Planner invocation's identity (the evidence of its message, C-P4.3 @planner-invocation@).
  , clarificationRequest :: HumanRequestId
  , clarificationSequence :: Int32
  , clarificationRevision :: Int32
  , clarificationOutcome :: Maybe T.Text
  , clarificationCode :: Maybe T.Text
  }
  deriving (Eq, Show)

type instance EntityKey ClarificationRow = InvocationId

clarificationTable :: Table ClarificationRow ClarificationRow
clarificationTable =
  mkEntityTable "lockstep_clarifications" clarificationIdField $
    ClarificationRow
      <$> O.marshallField clarificationId clarificationIdField
      <*> O.marshallField clarificationRequest (foreignKeyTo requestTable requestIdField "request_id")
      <*> O.marshallField clarificationSequence clarificationSequenceField
      <*> O.marshallField clarificationRevision (O.integerField "request_revision")
      <*> O.marshallReadOnly (O.marshallField clarificationOutcome outcomeField)
      <*> O.marshallReadOnly (O.marshallField clarificationCode codeField)

clarificationIdField :: O.FieldDefinition O.NotNull InvocationId
clarificationIdField =
  keyField "id"

clarificationRequestField :: O.FieldDefinition O.NotNull HumanRequestId
clarificationRequestField =
  foreignKeyTo requestTable requestIdField "request_id"

clarificationSequenceField :: O.FieldDefinition O.NotNull Int32
clarificationSequenceField =
  O.integerField "message_sequence"

outcomeField :: O.FieldDefinition O.Nullable (Maybe T.Text)
outcomeField =
  O.nullableField (O.unboundedTextField "outcome")

codeField :: O.FieldDefinition O.Nullable (Maybe T.Text)
codeField =
  O.nullableField (O.unboundedTextField "code")

finishedAtField :: O.FieldDefinition O.Nullable (Maybe UTCTime)
finishedAtField =
  O.nullableField (O.utcTimestampField "finished_at")

-- | Starts an attempt; True only for the call that inserted it (one per request and message).
startClarification :: O.MonadOrville m => ClarificationRow -> m Bool
startClarification =
  insertIgnoringConflict AnyConflict clarificationTable

-- | Finishes an attempt once, with its ending, a code, and the answer's digest when it answered.
finishClarification :: O.MonadOrville m => InvocationId -> ClarificationEnding -> Maybe T.Text -> Maybe T.Text -> m ()
finishClarification invocation ending code digest =
  void $
    O.updateFields
      clarificationTable
      ( O.setField outcomeField (Just (clarificationEndingCode ending))
          :| [ O.setField codeField code
             , O.setField (O.nullableField (O.unboundedTextField "answer_digest")) digest
             , setNow finishedAtField
             ]
      )
      (Just (O.fieldEquals clarificationIdField invocation `O.andExpr` O.fieldIsNull finishedAtField))

-- | Attempts that never finished (the worker stopped while they ran).
unfinishedClarifications :: O.MonadOrville m => m [ClarificationRow]
unfinishedClarifications =
  O.findEntitiesBy clarificationTable (O.where_ (O.fieldIsNull finishedAtField))

-- | A request's attempts, in message order.
requestClarifications :: O.MonadOrville m => HumanRequestId -> m [ClarificationRow]
requestClarifications request =
  O.findEntitiesBy
    clarificationTable
    (O.where_ (O.fieldEquals clarificationRequestField request) <> O.orderBy (O.orderByField clarificationSequenceField O.ascendingOrder))
