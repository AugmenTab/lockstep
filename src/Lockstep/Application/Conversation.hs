{- | Human Requests and their conversations, durably (contract C-P4.3 H3–H6).
PRE-FREEZE STUB: the types are final; the operations refuse until implemented.
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
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Application.Command (IdempotencyKey)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason)
import Lockstep.Kernel.Conversation (RequestInput)
import Lockstep.Kernel.Transition (Principal (..))

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

openRequest :: DatabaseRuntime -> IdempotencyKey -> Sender -> NewHumanRequest -> IO (Either NotReadyReason (Either T.Text StoredRequest))
openRequest _ _ _ _ =
  pure (Right (Left (T.pack "not-implemented")))

postMessage :: DatabaseRuntime -> IdempotencyKey -> T.Text -> Sender -> RequestInput -> IO (Either NotReadyReason (Either T.Text StoredMessage))
postMessage _ _ _ _ _ =
  pure (Right (Left (T.pack "not-implemented")))

conversation :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Maybe Conversation))
conversation _ _ =
  pure (Right Nothing)

openRequests :: DatabaseRuntime -> IO (Either NotReadyReason [StoredRequest])
openRequests _ =
  pure (Right [])
