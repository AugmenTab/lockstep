{- | Human Requests and their conversations (contract C-P4.3 H1, H2, H5;
Bible v2.2 §13.3): a bounded question to a person about one Work Order, its
ordered messages, and the one binding answer a decision request can receive.
A clarification is information, never a decision; only a person decides, at
the request's current revision; an agent is never an accepted principal; the
Planner speaks only through the Supervisor. Pure.
-}
module Lockstep.Kernel.Conversation
  ( Choice
  , mkChoice
  , choiceText
  , RequestKind (..)
  , mkDecisionKind
  , requestKindName
  , RequestState (..)
  , requestStateName
  , HumanRequest (..)
  , newHumanRequest
  , checkRequestText
  , RequestInput (..)
  , MessageKind (..)
  , messageKindName
  , inputMessageKind
  , inputText
  , stepRequest
  , conversationRefusalCodes
  , requestPayloadText
  , messagePayloadText
  ) where

import Data.Char qualified as Char
import Data.List qualified as L
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NE
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show, show)

import Lockstep.Kernel.Transition (Command (..), Principal (..))

-- | A choice a decision request offers: @^[a-z][a-z0-9-]{0,39}$@.
newtype Choice
  = Choice T.Text
  deriving (Eq, Ord, Show)

mkChoice :: T.Text -> Maybe Choice
mkChoice text =
  case T.uncons text of
    Just (first, rest)
      | Char.isAsciiLower first
          && T.length text <= 40
          && T.all (\c -> Char.isAsciiLower c || Char.isDigit c || c == '-') rest ->
          Just (Choice text)
    _ -> Nothing

choiceText :: Choice -> T.Text
choiceText (Choice text) =
  text

data RequestKind
  = ClarificationRequest
  | DecisionRequest (NonEmpty Choice)
  deriving (Eq, Show)

-- | H1: 1 to 10 choices, each valid, no repeats.
mkDecisionKind :: [T.Text] -> Either T.Text RequestKind
mkDecisionKind names =
  case traverse mkChoice names of
    Just (c : cs)
      | L.length names <= 10 && L.nub names == names -> Right (DecisionRequest (c :| cs))
    _ -> Left (T.pack "invalid-choices")

requestKindName :: RequestKind -> T.Text
requestKindName kind =
  T.pack $
    case kind of
      ClarificationRequest -> "clarification"
      DecisionRequest _ -> "decision"

data RequestState
  = Open
  | Answered Choice
  | Withdrawn
  deriving (Eq, Show)

requestStateName :: RequestState -> T.Text
requestStateName state =
  T.pack $
    case state of
      Open -> "open"
      Answered _ -> "answered"
      Withdrawn -> "withdrawn"

data HumanRequest
  = HumanRequest
  { requestKind :: RequestKind
  , requestRevision :: Int
  , requestState :: RequestState
  }
  deriving (Eq, Show)

newHumanRequest :: RequestKind -> HumanRequest
newHumanRequest kind =
  HumanRequest kind 1 Open

-- | H1: 1 to 4000 characters after trimming; new lines and tabs allowed, no other control character.
checkRequestText :: T.Text -> Either T.Text T.Text
checkRequestText raw =
  let
    text = T.strip (T.replace (T.pack "\r\n") (T.pack "\n") raw)
  in
    if T.null text
      then Left (T.pack "text-empty")
      else
        if T.any (\c -> Char.isControl c && c /= '\n' && c /= '\t') text
          then Left (T.pack "text-control")
          else
            if T.length text > 4000
              then Left (T.pack "text-too-long")
              else Right text

-- | H2: each carries the request revision it was written against.
data RequestInput
  = HumanSays Int T.Text
  | PlannerSays Int T.Text
  | HumanDecides Int T.Text T.Text
  | Revise Int T.Text
  | Withdraw Int T.Text
  deriving (Eq, Show)

data MessageKind
  = MessageOpened
  | MessageHuman
  | MessagePlanner
  | MessageDecision
  | MessageRevision
  | MessageWithdrawal
  deriving (Eq, Show, Enum, Bounded)

messageKindName :: MessageKind -> T.Text
messageKindName kind =
  T.pack $
    case kind of
      MessageOpened -> "opened"
      MessageHuman -> "human"
      MessagePlanner -> "planner"
      MessageDecision -> "decision"
      MessageRevision -> "revision"
      MessageWithdrawal -> "withdrawal"

inputMessageKind :: RequestInput -> MessageKind
inputMessageKind input =
  case input of
    HumanSays _ _ -> MessageHuman
    PlannerSays _ _ -> MessagePlanner
    HumanDecides {} -> MessageDecision
    Revise _ _ -> MessageRevision
    Withdraw _ _ -> MessageWithdrawal

expectedOf :: RequestInput -> Int
expectedOf input =
  case input of
    HumanSays e _ -> e
    PlannerSays e _ -> e
    HumanDecides e _ _ -> e
    Revise e _ -> e
    Withdraw e _ -> e

-- | The free text a message carries.
inputText :: RequestInput -> T.Text
inputText input =
  case input of
    HumanSays _ t -> t
    PlannerSays _ t -> t
    HumanDecides _ _ t -> t
    Revise _ t -> t
    Withdraw _ t -> t

permitted :: RequestInput -> [Principal]
permitted input =
  case input of
    HumanSays _ _ -> [Human]
    PlannerSays _ _ -> [Supervisor]
    HumanDecides {} -> [Human]
    Revise _ _ -> [Supervisor]
    Withdraw _ _ -> [Human, Supervisor]

{- | H2, in its check order: an agent; a closed request; a stale revision; who
may give the input; the text; then the input's own rule. The result is the
request after the input; the caller appends exactly one message for it.
-}
stepRequest :: HumanRequest -> Command RequestInput -> Either T.Text HumanRequest
stepRequest request (Command principal input)
  | principal == Agent = refuse "agent-assertion"
  | requestState request /= Open = refuse "request-closed"
  | expectedOf input /= requestRevision request = refuse "stale-revision"
  | principal `L.notElem` permitted input = refuse "not-authorized"
  | otherwise = do
      _ <- checkRequestText (inputText input)
      case input of
        HumanDecides _ choice _ ->
          case requestKind request of
            ClarificationRequest -> refuse "not-a-decision"
            DecisionRequest choices ->
              case L.find ((== choice) . choiceText) (NE.toList choices) of
                Nothing -> refuse "unknown-choice"
                Just c -> Right request {requestState = Answered c}
        Revise _ _ -> Right request {requestRevision = requestRevision request + 1}
        Withdraw _ _ -> Right request {requestState = Withdrawn}
        _ -> Right request
 where
  refuse =
    Left . T.pack

conversationRefusalCodes :: [T.Text]
conversationRefusalCodes =
  fmap
    T.pack
    [ "agent-assertion"
    , "request-closed"
    , "stale-revision"
    , "not-authorized"
    , "not-a-decision"
    , "unknown-choice"
    , "invalid-choices"
    , "text-empty"
    , "text-too-long"
    , "text-control"
    ]

quoted :: T.Text -> T.Text
quoted text =
  T.pack "\"" <> T.concatMap escape text <> T.pack "\""
 where
  escape c =
    case c of
      '\\' -> T.pack "\\\\"
      '"' -> T.pack "\\\""
      '\n' -> T.pack "\\n"
      _ -> T.singleton c

{- | H5: the canonical text of a request to open a Human Request: the Work
Order, the Engineer, the Contract digest (or @none@), the kind and choices,
then the question, evidence and requested authority, quoted.
-}
requestPayloadText :: T.Text -> T.Text -> Maybe T.Text -> RequestKind -> T.Text -> T.Text -> T.Text -> T.Text
requestPayloadText workOrder engineer contract kind question evidence authority =
  T.unlines
    [ T.pack "lockstep-human-request-v1"
    , T.pack "work-order " <> workOrder
    , T.pack "engineer " <> engineer
    , T.pack "contract " <> fromMaybe (T.pack "none") contract
    , T.pack "kind " <> requestKindName kind
    , T.pack "choices " <> choices
    , T.pack "question " <> quoted question
    , T.pack "evidence " <> quoted evidence
    , T.pack "authority " <> quoted authority
    ]
 where
  choices =
    case kind of
      ClarificationRequest -> T.empty
      DecisionRequest cs -> T.intercalate (T.pack ",") (fmap choiceText (NE.toList cs))

{- | H5: the canonical text of one message: the request, the sender's principal
and evidence, the kind, the revision written against, the choice (or @none@)
and the text, quoted.
-}
messagePayloadText :: T.Text -> Principal -> T.Text -> RequestInput -> T.Text
messagePayloadText requestId principal evidence input =
  T.unlines
    [ T.pack "lockstep-conversation-message-v1"
    , T.pack "request " <> requestId
    , T.pack "principal " <> T.pack (show principal)
    , T.pack "evidence " <> quoted evidence
    , T.pack "kind " <> messageKindName (inputMessageKind input)
    , T.pack "revision " <> T.pack (show (expectedOf input))
    , T.pack "choice " <> choice
    , T.pack "text " <> quoted (inputText input)
    ]
 where
  choice =
    case input of
      HumanDecides _ c _ -> c
      _ -> T.pack "none"
