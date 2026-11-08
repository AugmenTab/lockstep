{- | The typed operator command (contract C-P1.4): a versioned envelope with
an actor, an expected revision and an idempotency key, a pure decision, and
admission that records a durable receipt in the same transaction as the
effect. The CLI and Web build envelopes and call 'submitCommand'; neither has
its own logic.
-}
module Lockstep.Application.Command
  ( Actor (..)
  , WorkspaceName
  , mkWorkspaceName
  , workspaceNameText
  , IdempotencyKey
  , mkIdempotencyKey
  , idempotencyKeyText
  , generateIdempotencyKey
  , Revision (..)
  , revisionInt
  , InvalidReason (..)
  , renderInvalidReason
  , OperatorCommand (..)
  , NoopSpec (..)
  , mkNoopSpec
  , CommandEnvelope (..)
  , mkEnvelope
  , buildRename
  , buildQueue
  , payloadDigest
  , WorkspaceState (..)
  , PriorReceipt (..)
  , Outcome (..)
  , outcomeCode
  , Receipt (..)
  , actorCode
  , Decision (..)
  , decide
  , CommandRefusal (..)
  , submitCommand
  , readWorkspace
  , findReceipt
  ) where

import Control.Exception (throwIO)
import Crypto.Hash (SHA256 (SHA256), hashWith)
import Crypto.Random (getRandomBytes)
import Data.ByteArray qualified as BA
import Data.ByteArray.Encoding (Base (Base16, Base64URLUnpadded), convertFromBase, convertToBase)
import Data.ByteString qualified as BS
import Data.Char qualified as Char
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time qualified as Time
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import System.IO.Error (userError)
import Text.Show (Show, show)

import Lockstep.Application.Database
  ( DatabaseRuntime
  , NotReadyReason (DatabaseError)
  , Readiness (..)
  , checkReadiness
  , withDatabase
  )
import Lockstep.Persistence.Commands qualified as Store
import Lockstep.Persistence.Jobs qualified as Jobs

-- | Who submitted the command; authority was checked by the caller (E1).
data Actor
  = ActorCli
  | ActorBrowserSession
  deriving (Eq, Show)

actorCode :: Actor -> T.Text
actorCode actor =
  case actor of
    ActorCli -> T.pack "cli"
    ActorBrowserSession -> T.pack "browser-session"

parseActor :: T.Text -> Maybe Actor
parseActor code
  | code == actorCode ActorCli = Just ActorCli
  | code == actorCode ActorBrowserSession = Just ActorBrowserSession
  | otherwise = Nothing

newtype WorkspaceName
  = WorkspaceName T.Text
  deriving (Eq, Show)

data InvalidReason
  = NameEmpty
  | NameTooLong
  | NameHasControl
  | KeyMalformed
  | RevisionNegative
  | StepsOutOfRange
  | StepMillisOutOfRange
  | FailAtOutOfRange
  deriving (Eq, Show)

renderInvalidReason :: InvalidReason -> String
renderInvalidReason reason =
  case reason of
    NameEmpty -> "the workspace name is empty"
    NameTooLong -> "the workspace name is longer than 80 characters"
    NameHasControl -> "the workspace name contains a control character"
    KeyMalformed -> "the idempotency key must be 16-64 characters of A-Z a-z 0-9 - _"
    RevisionNegative -> "the expected revision is negative"
    StepsOutOfRange -> "steps must be 1-20"
    StepMillisOutOfRange -> "step milliseconds must be 0-5000"
    FailAtOutOfRange -> "the failure step must be between 1 and the number of steps"

-- | Trimmed, 1–80 characters, no control characters (E2).
mkWorkspaceName :: T.Text -> Either InvalidReason WorkspaceName
mkWorkspaceName raw =
  let
    name = T.strip raw
  in
    if T.null name
      then Left NameEmpty
      else
        if T.length name > 80
          then Left NameTooLong
          else
            if T.any Char.isControl name
              then Left NameHasControl
              else Right (WorkspaceName name)

workspaceNameText :: WorkspaceName -> T.Text
workspaceNameText (WorkspaceName name) =
  name

newtype IdempotencyKey
  = IdempotencyKey T.Text
  deriving (Eq, Show)

mkIdempotencyKey :: T.Text -> Either InvalidReason IdempotencyKey
mkIdempotencyKey key =
  if T.length key >= 16 && T.length key <= 64 && T.all isKeyChar key
    then Right (IdempotencyKey key)
    else Left KeyMalformed
 where
  isKeyChar c =
    Char.isAsciiUpper c || Char.isAsciiLower c || Char.isDigit c || c == '-' || c == '_'

idempotencyKeyText :: IdempotencyKey -> T.Text
idempotencyKeyText (IdempotencyKey key) =
  key

-- | 16 CSPRNG bytes as 22 base64url characters.
generateIdempotencyKey :: IO IdempotencyKey
generateIdempotencyKey = do
  bytes <- getRandomBytes 16 :: IO BS.ByteString
  pure (IdempotencyKey (TE.decodeLatin1 (convertToBase Base64URLUnpadded bytes)))

newtype Revision
  = Revision Int64
  deriving (Eq, Ord, Show)

revisionInt :: Revision -> Int64
revisionInt (Revision n) =
  n

data OperatorCommand
  = RenameWorkspace WorkspaceName
  | QueueNoop NoopSpec
  deriving (Eq, Show)

-- | A model-free no-op job: steps, a delay per step, an optional injected failure (C-P1.5 E1).
data NoopSpec
  = NoopSpec
  { noopSteps :: Int
  , noopStepMillis :: Int
  , noopFailAtStep :: Maybe Int
  }
  deriving (Eq, Show)

mkNoopSpec :: Int -> Int -> Maybe Int -> Either InvalidReason NoopSpec
mkNoopSpec steps millis failAt
  | steps < 1 || steps > 20 = Left StepsOutOfRange
  | millis < 0 || millis > 5000 = Left StepMillisOutOfRange
  | any (\k -> k < 1 || k > steps) failAt = Left FailAtOutOfRange
  | otherwise = Right (NoopSpec steps millis failAt)

noopPayload :: NoopSpec -> T.Text
noopPayload spec =
  T.pack
    ( "steps="
        <> show (noopSteps spec)
        <> ";step_ms="
        <> show (noopStepMillis spec)
        <> ";fail_at="
        <> maybe "none" show (noopFailAtStep spec)
    )

-- | Validates raw CLI/HTTP input into a queue-noop envelope.
buildQueue :: Actor -> T.Text -> Integer -> Integer -> Integer -> Maybe Integer -> Either InvalidReason CommandEnvelope
buildQueue actor keyText expected steps millis failAt = do
  key <- mkIdempotencyKey keyText
  revision <- if expected < 0 then Left RevisionNegative else Right (Revision (fromInteger expected))
  stepsInt <- bounded StepsOutOfRange steps
  millisInt <- bounded StepMillisOutOfRange millis
  failInt <- traverse (bounded FailAtOutOfRange) failAt
  spec <- mkNoopSpec stepsInt millisInt failInt
  pure (mkEnvelope actor key revision (QueueNoop spec))
 where
  bounded reason n =
    if n < 0 || n > 100000 then Left reason else Right (fromInteger n)

commandKind :: OperatorCommand -> T.Text
commandKind command =
  case command of
    RenameWorkspace _ -> T.pack "rename-workspace"
    QueueNoop _ -> T.pack "queue-noop"

data CommandEnvelope
  = CommandEnvelope
  { envelopeVersion :: Int
  , envelopeActor :: Actor
  , envelopeKey :: IdempotencyKey
  , envelopeExpected :: Revision
  , envelopeCommand :: OperatorCommand
  }
  deriving (Eq, Show)

mkEnvelope :: Actor -> IdempotencyKey -> Revision -> OperatorCommand -> CommandEnvelope
mkEnvelope =
  CommandEnvelope 1

-- | Validates raw CLI/HTTP input into a rename envelope.
buildRename :: Actor -> T.Text -> Integer -> T.Text -> Either InvalidReason CommandEnvelope
buildRename actor keyText expected nameText = do
  key <- mkIdempotencyKey keyText
  name <- mkWorkspaceName nameText
  revision <-
    if expected < 0
      then Left RevisionNegative
      else Right (Revision (fromInteger expected))
  pure (mkEnvelope actor key revision (RenameWorkspace name))

-- | SHA-256 of the kind, expected revision and payload; not the actor (E3).
payloadDigest :: CommandEnvelope -> BS.ByteString
payloadDigest envelope =
  let
    payload =
      case envelopeCommand envelope of
        RenameWorkspace name -> workspaceNameText name
        QueueNoop spec -> noopPayload spec
    canonical =
      T.intercalate
        (T.pack "\n")
        [ T.pack "lockstep-command-v1"
        , commandKind (envelopeCommand envelope)
        , T.pack (show (revisionInt (envelopeExpected envelope)))
        , payload
        ]
  in
    BA.convert (hashWith SHA256 (TE.encodeUtf8 canonical))

data WorkspaceState
  = WorkspaceState
  { workspaceName :: T.Text
  , workspaceRevision :: Revision
  }
  deriving (Eq, Show)

data Outcome
  = Applied
  | RefusedStale
  | Queued
  deriving (Eq, Show)

outcomeCode :: Outcome -> T.Text
outcomeCode outcome =
  case outcome of
    Applied -> T.pack "applied"
    RefusedStale -> T.pack "refused_stale"
    Queued -> T.pack "queued"

parseOutcome :: T.Text -> Maybe Outcome
parseOutcome code
  | code == outcomeCode Applied = Just Applied
  | code == outcomeCode RefusedStale = Just RefusedStale
  | code == outcomeCode Queued = Just Queued
  | otherwise = Nothing

data Receipt
  = Receipt
  { receiptId :: Int64
  , receiptKey :: T.Text
  , receiptKind :: T.Text
  , receiptOutcome :: Outcome
  , receiptExpected :: Revision
  , receiptRevision :: Revision
  , receiptActor :: Actor
  , receiptAcceptedAt :: Time.UTCTime
  , receiptReplayed :: Bool
  }
  deriving (Eq, Show)

data PriorReceipt
  = PriorReceipt
  { priorDigest :: BS.ByteString
  , priorReceipt :: Receipt
  }
  deriving (Eq, Show)

data Decision
  = Replay Receipt
  | KeyConflict
  | Apply Revision
  | RefuseStale Revision
  deriving (Eq, Show)

-- | E4, in order: replay, key conflict, apply, stale. Pure and total.
decide :: WorkspaceState -> Maybe PriorReceipt -> CommandEnvelope -> Decision
decide current prior envelope =
  case prior of
    Just found
      | priorDigest found == payloadDigest envelope -> Replay (priorReceipt found)
      | otherwise -> KeyConflict
    Nothing ->
      let
        Revision now = workspaceRevision current
      in
        if envelopeExpected envelope == workspaceRevision current
          then case envelopeCommand envelope of
            RenameWorkspace _ -> Apply (Revision (now + 1))
            QueueNoop _ -> Apply (workspaceRevision current)
          else RefuseStale (workspaceRevision current)

data CommandRefusal
  = CommandInvalid InvalidReason
  | CommandKeyConflict
  | CommandNotReady NotReadyReason
  deriving (Eq, Show)

fromRow :: Store.ReceiptRow -> Maybe PriorReceipt
fromRow row = do
  outcome <- parseOutcome (Store.rowOutcome row)
  actor <- parseActor (Store.rowActor row)
  digest <- either (const Nothing) Just (decodeHex (Store.rowDigestHex row))
  pure
    PriorReceipt
      { priorDigest = digest
      , priorReceipt =
          Receipt
            { receiptId = Store.rowId row
            , receiptKey = Store.rowKey row
            , receiptKind = Store.rowKind row
            , receiptOutcome = outcome
            , receiptExpected = Revision (Store.rowExpected row)
            , receiptRevision = Revision (Store.rowRevision row)
            , receiptActor = actor
            , receiptAcceptedAt = Store.rowAcceptedAt row
            , receiptReplayed = False
            }
      }

decodeHex :: T.Text -> Either String BS.ByteString
decodeHex =
  convertFromBase Base16 . TE.encodeUtf8

whenReady :: DatabaseRuntime -> IO (Either NotReadyReason a) -> IO (Either NotReadyReason a)
whenReady runtime action = do
  readiness <- checkReadiness (Just runtime)
  case readiness of
    NotReady reason -> pure (Left reason)
    Ready _ -> action

{- | E5: one transaction under the workspace row lock. The effect and its
receipt commit together; a replay returns the stored receipt unchanged.
-}
submitCommand :: DatabaseRuntime -> CommandEnvelope -> IO (Either CommandRefusal Receipt)
submitCommand runtime envelope = do
  result <- whenReady runtime (withDatabase runtime (O.withTransaction admit))
  pure $
    case result of
      Left reason -> Left (CommandNotReady reason)
      Right outcome -> outcome
 where
  key = idempotencyKeyText (envelopeKey envelope)
  record outcome revision = do
    inserted <-
      Store.insertReceipt
        Store.NewReceipt
          { Store.newKey = key
          , Store.newVersion = fromIntegral (envelopeVersion envelope)
          , Store.newKind = commandKind (envelopeCommand envelope)
          , Store.newDigest = payloadDigest envelope
          , Store.newActor = actorCode (envelopeActor envelope)
          , Store.newExpected = revisionInt (envelopeExpected envelope)
          , Store.newOutcome = outcomeCode outcome
          , Store.newRevision = revisionInt revision
          }
    case inserted of
      -- An effect must never commit without its receipt: abort the transaction (review finding 7).
      Nothing -> liftIO (throwIO (userError "lockstep: the command receipt insert returned no row"))
      Just _ -> pure ()
    pure $
      case inserted of
        Nothing -> Left (CommandNotReady DatabaseError)
        Just (newId, acceptedAt) ->
          Right
            Receipt
              { receiptId = newId
              , receiptKey = key
              , receiptKind = commandKind (envelopeCommand envelope)
              , receiptOutcome = outcome
              , receiptExpected = envelopeExpected envelope
              , receiptRevision = revision
              , receiptActor = envelopeActor envelope
              , receiptAcceptedAt = acceptedAt
              , receiptReplayed = False
              }
  admit = do
    locked <- Store.lockWorkspace
    row <- Store.findReceiptByKey key
    case (locked, traverse fromRow row) of
      (Just (name, revision), Just prior) ->
        case decide (WorkspaceState name (Revision revision)) prior envelope of
          Replay receipt ->
            pure (Right receipt {receiptReplayed = True})
          KeyConflict ->
            pure (Left CommandKeyConflict)
          Apply next ->
            case envelopeCommand envelope of
              RenameWorkspace newName -> do
                Store.updateWorkspace (workspaceNameText newName) (revisionInt next)
                record Applied next
              QueueNoop spec -> do
                recorded <- record Queued next
                case recorded of
                  Right receipt -> do
                    Jobs.insertNoopJob
                      (receiptId receipt)
                      (fromIntegral (noopSteps spec))
                      (fromIntegral (noopStepMillis spec))
                      (fmap fromIntegral (noopFailAtStep spec))
                    pure recorded
                  Left _ -> pure recorded
          RefuseStale now ->
            record RefusedStale now
      _ ->
        pure (Left (CommandNotReady DatabaseError))

readWorkspace :: DatabaseRuntime -> IO (Either NotReadyReason WorkspaceState)
readWorkspace runtime = do
  result <- whenReady runtime (withDatabase runtime Store.readWorkspace)
  pure $ do
    found <- result
    maybe (Left DatabaseError) (\(name, revision) -> Right (WorkspaceState name (Revision revision))) found

findReceipt :: DatabaseRuntime -> Int64 -> IO (Maybe Receipt)
findReceipt runtime receiptId = do
  result <- withDatabase runtime (Store.findReceiptById receiptId)
  pure (either (const Nothing) (>>= fmap priorReceipt . fromRow) result)
