{- | Human Requests and their conversations, durably (contract C-P4.3 H3–H6):
opening a request, posting a message to it, and reading it back. Each
operation is one transaction with an idempotency key; a request row changes
only together with the message that changes it, under its row lock. Nothing
here applies a decision, changes a Work Order or invokes a model.
-}
module Lockstep.Application.Conversation
  ( Channel (..)
  , Sender (..)
  , senderPrincipal
  , senderEvidence
  , senderChannel
  , NewHumanRequest (..)
  , StoredRequest (..)
  , StoredMessage (..)
  , Conversation (..)
  , openRequest
  , postMessage
  , conversation
  , openRequests
  , requestByKey
  ) where

import Data.Char qualified as Char
import Data.List qualified as L
import Data.List.NonEmpty qualified as NE
import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, idempotencyKeyText)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason, Readiness (..), checkReadiness, withDatabase)
import Lockstep.Application.Identity (newUuid)
import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Kernel.Conversation
  ( HumanRequest (..)
  , RequestInput (..)
  , RequestKind (..)
  , RequestState (..)
  , checkRequestText
  , choiceText
  , inputMessageKind
  , inputText
  , messageKindName
  , messagePayloadText
  , mkChoice
  , mkDecisionKind
  , requestKindName
  , requestPayloadText
  , requestStateName
  , stepRequest
  )
import Lockstep.Kernel.Identity (parseUuid, uuidText)
import Lockstep.Kernel.Profile (Hasher (..), contentDigestText)
import Lockstep.Kernel.Transition (Command (..), Principal (..))
import Lockstep.Persistence.Conversation qualified as Store

data Channel
  = ApplicationChannel
  | CliChannel
  deriving (Eq, Show)

-- | H3: who sends a message; the principal follows from it, never from a request field.
data Sender
  = SenderHuman Channel
  | SenderPlanner T.Text
  | SenderSupervisor
  | SenderAgent T.Text
  deriving (Eq, Show)

senderPrincipal :: Sender -> Principal
senderPrincipal sender =
  case sender of
    SenderHuman _ -> Human
    SenderPlanner _ -> Supervisor
    SenderSupervisor -> Supervisor
    SenderAgent _ -> Agent

senderEvidence :: Sender -> T.Text
senderEvidence sender =
  case sender of
    SenderHuman ApplicationChannel -> T.pack "application-session"
    SenderHuman CliChannel -> T.pack "cli-session"
    SenderPlanner invocation -> T.pack "planner-invocation " <> invocation
    SenderSupervisor -> T.pack "supervisor"
    SenderAgent label -> T.pack "agent " <> label

senderChannel :: Sender -> T.Text
senderChannel sender =
  T.pack $
    case sender of
      SenderHuman ApplicationChannel -> "application"
      SenderHuman CliChannel -> "cli"
      _ -> "engine"

data NewHumanRequest
  = NewHumanRequest
  { newRequestWorkOrder :: T.Text
  , newRequestEngineer :: T.Text
  , newRequestContract :: Maybe T.Text
  , newRequestChoices :: Maybe [T.Text]
  , newRequestQuestion :: T.Text
  , newRequestEvidence :: T.Text
  , newRequestAuthority :: T.Text
  }
  deriving (Eq, Show)

data StoredRequest
  = StoredRequest
  { storedRequestId :: T.Text
  , storedWorkOrder :: T.Text
  , storedEngineer :: T.Text
  , storedContract :: Maybe T.Text
  , storedKind :: T.Text
  , storedChoices :: [T.Text]
  , storedQuestion :: T.Text
  , storedEvidence :: T.Text
  , storedAuthority :: T.Text
  , storedRevision :: Int
  , storedState :: T.Text
  , storedAnswer :: Maybe T.Text
  }
  deriving (Eq, Show)

data StoredMessage
  = StoredMessage
  { messageRequest :: T.Text
  , messageSequence :: Int
  , messageKind :: T.Text
  , messagePrincipal :: T.Text
  , messageEvidence :: T.Text
  , messageChannel :: T.Text
  , messageRevision :: Int
  , messageBody :: T.Text
  , messageChoice :: Maybe T.Text
  }
  deriving (Eq, Show)

data Conversation
  = Conversation
  { conversationRequest :: StoredRequest
  , conversationMessages :: [StoredMessage]
  }
  deriving (Eq, Show)

whenReady :: DatabaseRuntime -> IO (Either NotReadyReason a) -> IO (Either NotReadyReason a)
whenReady runtime action = do
  readiness <- checkReadiness (Just runtime)
  case readiness of
    NotReady reason -> pure (Left reason)
    Ready _ -> action

sha256Text :: T.Text -> T.Text
sha256Text text =
  case sha256Hasher of
    Hasher f -> contentDigestText (f text)

canonicalId :: T.Text -> Maybe T.Text
canonicalId =
  either (const Nothing) (Just . uuidText) . parseUuid

splitChoices :: T.Text -> [T.Text]
splitChoices text =
  if T.null text then [] else T.splitOn (T.pack ",") text

requestOf :: Store.RequestRow -> StoredRequest
requestOf row =
  StoredRequest
    { storedRequestId = Store.requestRowId row
    , storedWorkOrder = Store.requestRowWorkOrder row
    , storedEngineer = Store.requestRowEngineer row
    , storedContract = Store.requestRowContract row
    , storedKind = Store.requestRowKind row
    , storedChoices = splitChoices (Store.requestRowChoices row)
    , storedQuestion = Store.requestRowQuestion row
    , storedEvidence = Store.requestRowEvidence row
    , storedAuthority = Store.requestRowAuthority row
    , storedRevision = fromIntegral (Store.requestRowRevision row)
    , storedState = Store.requestRowState row
    , storedAnswer = Store.requestRowAnswer row
    }

messageOf :: Store.MessageRow -> StoredMessage
messageOf row =
  StoredMessage
    { messageRequest = Store.messageRowRequest row
    , messageSequence = fromIntegral (Store.messageRowSequence row)
    , messageKind = Store.messageRowKind row
    , messagePrincipal = Store.messageRowPrincipal row
    , messageEvidence = Store.messageRowEvidence row
    , messageChannel = Store.messageRowChannel row
    , messageRevision = fromIntegral (Store.messageRowRevision row)
    , messageBody = Store.messageRowBody row
    , messageChoice = Store.messageRowChoice row
    }

-- | The Kernel's view of a stored request; Nothing for a row that does not read back.
kernelRequest :: Store.RequestRow -> Maybe HumanRequest
kernelRequest row = do
  kind <-
    case T.unpack (Store.requestRowKind row) of
      "clarification" -> Just ClarificationRequest
      "decision" -> either (const Nothing) Just (mkDecisionKind (splitChoices (Store.requestRowChoices row)))
      _ -> Nothing
  state <-
    case (T.unpack (Store.requestRowState row), Store.requestRowAnswer row) of
      ("open", Nothing) -> Just Open
      ("withdrawn", Nothing) -> Just Withdrawn
      ("answered", Just answer) -> Answered <$> mkChoice answer
      _ -> Nothing
  pure (HumanRequest kind (fromIntegral (Store.requestRowRevision row)) state)

validDigest :: T.Text -> Bool
validDigest text =
  T.length text == 64 && T.all (\c -> Char.isDigit c || (c >= 'a' && c <= 'f')) text

-- | H5: opens a request about one Work Order, with its first message; the Supervisor only.
openRequest :: DatabaseRuntime -> IdempotencyKey -> Sender -> NewHumanRequest -> IO (Either NotReadyReason (Either T.Text StoredRequest))
openRequest runtime key sender request =
  whenReady runtime $
    case checked of
      Left code -> pure (Right (Left code))
      Right (workOrder, kind, question, evidence, authority) -> do
        u <- newUuid
        let
          digest = sha256Text (requestPayloadText workOrder (newRequestEngineer request) (newRequestContract request) kind question evidence authority)
          keyText = idempotencyKeyText key
        withDatabase runtime . O.withTransaction $ do
          existing <- Store.findRequestByKey keyText
          case existing of
            Just row
              | Store.requestRowDigest row == digest -> pure (Right (requestOf row))
              | otherwise -> pure (Left (T.pack "key-conflict"))
            Nothing -> do
              known <- Store.workOrderExists workOrder
              if not known
                then pure (Left (T.pack "unknown-work-order"))
                else do
                  let
                    row =
                      Store.RequestRow
                        { Store.requestRowId = uuidText u
                        , Store.requestRowKey = keyText
                        , Store.requestRowDigest = digest
                        , Store.requestRowWorkOrder = workOrder
                        , Store.requestRowEngineer = newRequestEngineer request
                        , Store.requestRowContract = newRequestContract request
                        , Store.requestRowKind = requestKindName kind
                        , Store.requestRowChoices = choicesText kind
                        , Store.requestRowQuestion = question
                        , Store.requestRowEvidence = evidence
                        , Store.requestRowAuthority = authority
                        , Store.requestRowRevision = 1
                        , Store.requestRowState = requestStateName Open
                        , Store.requestRowAnswer = Nothing
                        }
                  Store.insertRequest row
                  Store.insertMessage
                    Store.MessageRow
                      { Store.messageRowRequest = uuidText u
                      , Store.messageRowSequence = 1
                      , Store.messageRowKey = keyText
                      , Store.messageRowDigest = digest
                      , Store.messageRowKind = T.pack "opened"
                      , Store.messageRowPrincipal = T.pack (show Supervisor)
                      , Store.messageRowEvidence = senderEvidence sender
                      , Store.messageRowChannel = senderChannel sender
                      , Store.messageRowRevision = 1
                      , Store.messageRowBody = question
                      , Store.messageRowChoice = Nothing
                      }
                  pure (Right (requestOf row))
 where
  checked = do
    case sender of
      SenderAgent _ -> Left (T.pack "agent-assertion")
      SenderSupervisor -> Right ()
      _ -> Left (T.pack "not-authorized")
    workOrder <- maybe (Left (T.pack "unknown-work-order")) Right (canonicalId (newRequestWorkOrder request))
    case newRequestContract request of
      Just c | not (validDigest c) -> Left (T.pack "invalid-contract-digest")
      _ -> Right ()
    kind <- maybe (Right ClarificationRequest) mkDecisionKind (newRequestChoices request)
    question <- checkRequestText (newRequestQuestion request)
    evidence <- checkRequestText (newRequestEvidence request)
    authority <- checkRequestText (newRequestAuthority request)
    pure (workOrder, kind, question, evidence, authority)
  choicesText kind =
    case kind of
      ClarificationRequest -> T.empty
      DecisionRequest cs -> T.intercalate (T.pack ",") (fmap choiceText (NE.toList cs))

-- | H2, H5: one message to a request, under its row lock; a replay returns the stored message.
postMessage :: DatabaseRuntime -> IdempotencyKey -> T.Text -> Sender -> RequestInput -> IO (Either NotReadyReason (Either T.Text StoredMessage))
postMessage runtime key rawId sender input =
  whenReady runtime $
    case canonicalId rawId of
      Nothing -> pure (Right (Left (T.pack "unknown-request")))
      Just requestId -> do
        let
          principal = senderPrincipal sender
          digest = sha256Text (messagePayloadText requestId principal (senderEvidence sender) input)
          keyText = idempotencyKeyText key
        withDatabase runtime . O.withTransaction $ do
          existing <- Store.findMessageByKey keyText
          case existing of
            Just row
              | Store.messageRowRequest row == requestId && Store.messageRowDigest row == digest -> pure (Right (messageOf row))
              | otherwise -> pure (Left (T.pack "key-conflict"))
            Nothing -> do
              locked <- Store.lockRequest requestId
              case locked of
                Nothing -> pure (Left (T.pack "unknown-request"))
                Just row ->
                  case kernelRequest row of
                    Nothing -> pure (Left (T.pack "integrity"))
                    Just current ->
                      case stepRequest current (Command principal input) of
                        Left code -> pure (Left code)
                        Right next -> do
                          messages <- Store.requestMessages requestId
                          let
                            body = fromRight (inputText input) (checkRequestText (inputText input))
                            choice =
                              case requestState next of
                                Answered c -> Just (choiceText c)
                                _ -> Nothing
                            message =
                              Store.MessageRow
                                { Store.messageRowRequest = requestId
                                , Store.messageRowSequence = fromIntegral (L.length messages + 1)
                                , Store.messageRowKey = keyText
                                , Store.messageRowDigest = digest
                                , Store.messageRowKind = messageKindName (inputMessageKind input)
                                , Store.messageRowPrincipal = T.pack (show principal)
                                , Store.messageRowEvidence = senderEvidence sender
                                , Store.messageRowChannel = senderChannel sender
                                , Store.messageRowRevision = Store.requestRowRevision row
                                , Store.messageRowBody = body
                                , Store.messageRowChoice = choice
                                }
                          Store.insertMessage message
                          Store.updateRequest requestId (fromIntegral (requestRevision next)) (requestStateName (requestState next)) choice
                          pure (Right (messageOf message))

conversation :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Maybe Conversation))
conversation runtime rawId =
  case canonicalId rawId of
    Nothing -> pure (Right Nothing)
    Just requestId ->
      whenReady runtime . withDatabase runtime $ do
        found <- Store.findRequest requestId
        case found of
          Nothing -> pure Nothing
          Just row -> Just . Conversation (requestOf row) . fmap messageOf <$> Store.requestMessages requestId

openRequests :: DatabaseRuntime -> IO (Either NotReadyReason [StoredRequest])
openRequests runtime =
  whenReady runtime (withDatabase runtime (fmap requestOf <$> Store.openRequestRows))

-- | The request opened with this key, in whatever state it is now; reads only.
requestByKey :: DatabaseRuntime -> IdempotencyKey -> IO (Either NotReadyReason (Maybe StoredRequest))
requestByKey runtime key =
  whenReady runtime (withDatabase runtime (fmap requestOf <$> Store.findRequestByKey (idempotencyKeyText key)))
