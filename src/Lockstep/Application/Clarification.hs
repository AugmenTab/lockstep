{- | Answering a person's questions about an open Human Request (contract
C-P6.3 I4–I8): one bounded, read-only Planner invocation per question, whose
answer the Supervisor posts as a C-P4.3 Planner message. A Planner message
changes only the conversation: it never answers, resumes or authorizes
anything. Run once per engine worker pass, after the transactions.

Each attempt is a row in @lockstep_clarifications@, started before the
Planner runs (one per request and question, so no pass, worker or replay can
run it twice) and finished once. An attempt found unfinished when a pass
begins was cut off by a stopped worker: it is finished @uncertain@ and never
run again, and nothing is posted for it.
-}
module Lockstep.Application.Clarification
  ( ClarificationOutcome (..)
  , ClarificationReport (..)
  , clarificationOutcomeCode
  , answerClarifications
  , answerClarificationsUntil
  , clarificationContext
  ) where

import Control.Exception.Safe (finally)
import Data.List qualified as L
import Data.Maybe (catMaybes, fromMaybe)
import Data.Text qualified as T
import Fleece.Core ((#+))
import Fleece.Core qualified as FC
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Text.Show (Show)

import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Conversation (Sender (..), StoredMessage (..), postMessage)
import Lockstep.Application.Database (DatabaseRuntime, LockFailure (..), NotReadyReason, SessionLock (ClarificationLock), withDatabase, withSessionLock)
import Lockstep.Application.Engine (Engine (..))
import Lockstep.Application.Identity (newUuid)
import Lockstep.Application.Inbox (InboxChoice (..), InboxEntry (..), inboxEntries)
import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Effects.Roles (RoleOutcome (..), Runner (..), invokeRole)
import Lockstep.Foundation.Fleece (encodeText)
import Lockstep.Kernel.Conversation (RequestInput (PlannerSays))
import Lockstep.Kernel.Identity (HumanRequestId (..), InvocationId (..), identityText, parseIdentity)
import Lockstep.Kernel.Inbox (maxClarifications)
import Lockstep.Kernel.Profile (Hasher (..), contentDigestText)
import Lockstep.Kernel.Roles (Clarification (..), Role (Planner), RoleAnswer (..))
import Lockstep.Persistence.Clarification (ClarificationEnding (..), ClarificationRow (..), clarificationEndingCode)
import Lockstep.Persistence.Clarification qualified as Store
import Lockstep.Persistence.Conversation qualified as Conversations

data ClarificationOutcome
  = -- | The Planner answered and its answer was posted.
    ClarifiedAnswered
  | -- | The run failed (its code); nothing was posted.
    ClarifiedFailed T.Text
  | -- | No coding helper is set up; nothing was posted, nothing invented.
    ClarifiedNoHelper
  | -- | An attempt left unfinished by a stopped worker; never run again; nothing posted.
    ClarifiedUncertain
  | -- | The request already had its most answers; the question is left for the person.
    ClarifiedLimit
  deriving (Eq, Show)

-- | The outcome's word in the worker's pass report.
clarificationOutcomeCode :: ClarificationOutcome -> T.Text
clarificationOutcomeCode outcome =
  case outcome of
    ClarifiedAnswered -> T.pack "answered"
    ClarifiedFailed code -> T.pack "failed " <> code
    ClarifiedNoHelper -> T.pack "no-helper"
    ClarifiedUncertain -> T.pack "uncertain"
    ClarifiedLimit -> T.pack "limit"

data ClarificationReport
  = ClarificationReport
  { reportRequest :: T.Text
  , reportSequence :: Int
  -- ^ The question's message sequence.
  , reportOutcome :: ClarificationOutcome
  }
  deriving (Eq, Show)

-- | One pass: settle attempts a stopped worker left, then answer each pending question once.
answerClarifications :: DatabaseRuntime -> Engine -> IO (Either NotReadyReason [ClarificationReport])
answerClarifications runtime engine =
  answerClarificationsUntil runtime engine (pure False)

-- | 'answerClarifications' that ends early, between questions, once the check says so.

{- | R-P6.3: the phase runs under its own session lock, so only one worker
settles and answers at a time (another skips the phase while one holds it);
the stop is checked before each question.
-}
answerClarificationsUntil :: DatabaseRuntime -> Engine -> IO Bool -> IO (Either NotReadyReason [ClarificationReport])
answerClarificationsUntil runtime engine stopping = do
  halt <- stopping
  if halt
    then pure (Right [])
    else do
      locked <- withSessionLock runtime ClarificationLock (T.pack "clarifications") (const (phase runtime engine stopping))
      pure $
        case locked of
          Right result -> result
          Left LockBusy -> Right []
          Left (LockUnavailable reason) -> Left reason

phase :: DatabaseRuntime -> Engine -> IO Bool -> IO (Either NotReadyReason [ClarificationReport])
phase runtime engine stopping = do
  settled <-
    withDatabase runtime . O.withTransaction $ do
      rows <- Store.unfinishedClarifications
      traverse settle rows
  case settled of
    Left reason -> pure (Left reason)
    Right cut -> do
      open <- inboxEntries runtime
      case open of
        Left reason -> pure (Left reason)
        Right entries -> do
          answered <- each entries
          pure (fmap ((cut <>) . catMaybes) (sequenceA answered))
 where
  each entries =
    case entries of
      [] -> pure []
      entry : rest -> do
        stop <- stopping
        if stop
          then pure []
          else (:) <$> answerOne runtime engine entry <*> each rest
  {- R-P6.3-2: an attempt a stopped worker left unfinished. If its answer was
  already posted (its message's key names the attempt), it is finished answered
  with that answer's digest; otherwise it is finished uncertain and never run
  again. -}
  settle r = do
    posted <- Conversations.findMessageByKey (T.pack "clarification-" <> identityText (clarificationId r))
    let
      report = ClarificationReport (identityText (clarificationRequest r)) (fromIntegral (clarificationSequence r))
    case posted of
      Just m -> do
        Store.finishClarification (clarificationId r) EndedAnswered Nothing (Just (digestOf (Conversations.messageRowBody m)))
        pure (report ClarifiedAnswered)
      Nothing -> do
        Store.finishClarification (clarificationId r) EndedUncertain (Just (T.pack "worker-stopped")) Nothing
        pure (report ClarifiedUncertain)

{- | The request's latest message, when it is a person's question no attempt
was made for; Nothing otherwise.
-}
answerOne :: DatabaseRuntime -> Engine -> InboxEntry -> IO (Either NotReadyReason (Maybe ClarificationReport))
answerOne runtime engine entry =
  case (L.reverse (entryMessages entry), parseIdentity (entryRequest entry) :: Maybe HumanRequestId) of
    (question : _, Just requestId) | messageKind question == T.pack "human" -> do
      attempts <- withDatabase runtime (Store.requestClarifications requestId)
      case attempts of
        Left reason -> pure (Left reason)
        Right rows
          | L.any ((== fromIntegral (messageSequence question)) . clarificationSequence) rows -> pure (Right Nothing)
          -- R-P6.3-5: only attempts that ran count against the bound; one without a helper ran nothing.
          | L.length (L.filter ran rows) >= maxClarifications -> pure (Right (Just (report question ClarifiedLimit)))
          | otherwise -> fmap (fmap (report question)) <$> attempt runtime engine entry requestId question (L.length rows)
    _ -> pure (Right Nothing)
 where
  report question =
    ClarificationReport (entryRequest entry) (messageSequence question)
  ran r =
    clarificationOutcome r /= Just (clarificationEndingCode EndedNoHelper)

attempt :: DatabaseRuntime -> Engine -> InboxEntry -> HumanRequestId -> StoredMessage -> Int -> IO (Either NotReadyReason (Maybe ClarificationOutcome))
attempt runtime engine entry requestId question earlier = do
  invocation <- InvocationId <$> newUuid
  started <-
    withDatabase runtime $
      Store.startClarification
        ClarificationRow
          { clarificationId = invocation
          , clarificationRequest = requestId
          , clarificationSequence = fromIntegral (messageSequence question)
          , clarificationRevision = fromIntegral (entryRevision entry)
          , clarificationOutcome = Nothing
          , clarificationCode = Nothing
          }
  case started of
    Left reason -> pure (Left reason)
    -- Another pass or worker started this one: it is theirs.
    Right False -> pure (Right Nothing)
    Right True -> do
      outcome <- run invocation
      finished <- withDatabase runtime (finishWith invocation outcome)
      pure (Just (clarified outcome) <$ finished)
 where
  run invocation =
    case engineAdapter engine Planner earlier of
      Nothing -> pure NoHelper
      Just adapter -> do
        let
          runner = engineRunner engine
        prepared <- runnerPrepare runner
        case prepared of
          Left code -> pure (RunFailed code)
          Right workspace -> do
            -- R-P6.3: the workspace is released whatever happens, an asynchronous stop included.
            outcome <- invokeRole runner adapter Planner workspace (clarificationContext entry) [] `finally` runnerRelease runner workspace
            case outcome of
              RoleAnswered (AnswerClarification c) _ -> post invocation (clarificationText c)
              RoleAnswered _ _ -> pure (RunFailed (T.pack "wrong-kind"))
              RoleFailed code _ -> pure (RunFailed code)
              RoleUncertain code -> pure (RunUncertain code)
  post invocation text =
    case messageKey invocation of
      Nothing -> pure (RunFailed (T.pack "message-key"))
      Just k -> do
        posted <- postMessage runtime k (entryRequest entry) (SenderPlanner (identityText invocation)) (PlannerSays (entryRevision entry) text)
        pure $
          case posted of
            Right (Right _) -> RunAnswered (digestOf text)
            Right (Left code) -> RunFailed (T.pack "post-refused " <> code)
            Left _ -> RunFailed (T.pack "post-unavailable")
  finishWith invocation outcome =
    case outcome of
      RunAnswered digest -> Store.finishClarification invocation EndedAnswered Nothing (Just digest)
      RunFailed code -> Store.finishClarification invocation EndedFailed (Just (T.take 200 code)) Nothing
      RunUncertain code -> Store.finishClarification invocation EndedUncertain (Just (T.take 200 code)) Nothing
      NoHelper -> Store.finishClarification invocation EndedNoHelper Nothing Nothing
  clarified outcome =
    case outcome of
      RunAnswered _ -> ClarifiedAnswered
      RunFailed code -> ClarifiedFailed code
      RunUncertain _ -> ClarifiedUncertain
      NoHelper -> ClarifiedNoHelper

-- | How one run ended, before it is recorded.
data RunEnding
  = RunAnswered T.Text
  | RunFailed T.Text
  | RunUncertain T.Text
  | NoHelper

-- | The message's idempotency key: fixed by the invocation, so a retried post is the same message.
messageKey :: InvocationId -> Maybe IdempotencyKey
messageKey invocation =
  either (const Nothing) Just (mkIdempotencyKey (T.pack "clarification-" <> identityText invocation))

digestOf :: T.Text -> T.Text
digestOf text =
  case sha256Hasher of
    Hasher f -> contentDigestText (f text)

-- The Planner's context (I4) ---------------------------------------------------------------

data Context
  = Context
  { ctxRole :: T.Text
  , ctxStage :: T.Text
  , ctxAnswer :: AnswerKind
  , ctxRequest :: RequestContext
  , ctxConversation :: [Said]
  , ctxTicket :: TicketContext
  }

newtype AnswerKind
  = AnswerKind T.Text

data RequestContext
  = RequestContext
  { rcQuestion :: T.Text
  , rcEvidence :: T.Text
  , rcStoppedFor :: T.Text
  , rcChoices :: [ChoiceContext]
  , rcRule :: T.Text
  }

data ChoiceContext
  = ChoiceContext T.Text T.Text

data Said
  = Said T.Text T.Text

data TicketContext
  = TicketContext T.Text T.Text

contextSchema :: FC.Fleece t => FC.Schema t Context
contextSchema =
  FC.object $
    FC.constructor Context
      #+ FC.required "role" ctxRole FC.text
      #+ FC.required "stage" ctxStage FC.text
      #+ FC.required "answer" ctxAnswer (FC.object (FC.constructor AnswerKind #+ FC.required "kind" (\(AnswerKind k) -> k) FC.text))
      #+ FC.required "request" ctxRequest requestSchema
      #+ FC.required "conversation" ctxConversation (FC.list saidSchema)
      #+ FC.required "ticket" ctxTicket ticketSchema
 where
  requestSchema =
    FC.object $
      FC.constructor RequestContext
        #+ FC.required "question" rcQuestion FC.text
        #+ FC.required "evidence" rcEvidence FC.text
        #+ FC.required "stopped_for" rcStoppedFor FC.text
        #+ FC.required "choices" rcChoices (FC.list choiceSchema)
        #+ FC.required "rule" rcRule FC.text
  choiceSchema =
    FC.object $
      FC.constructor ChoiceContext
        #+ FC.required "choice" (\(ChoiceContext c _) -> c) FC.text
        #+ FC.required "consequence" (\(ChoiceContext _ w) -> w) FC.text
  saidSchema =
    FC.object $
      FC.constructor Said
        #+ FC.required "from" (\(Said f _) -> f) FC.text
        #+ FC.required "text" (\(Said _ t) -> t) FC.text
  ticketSchema =
    FC.object $
      FC.constructor TicketContext
        #+ FC.required "title" (\(TicketContext t _) -> t) FC.text
        #+ FC.required "acceptance" (\(TicketContext _ a) -> a) FC.text

{- | What the Planner reads: the request (its question, its evidence, the code
the fix stopped for, its choices with their consequences), the conversation so
far and the task; and the rule that its answer is information only. No
repository is given (the workspace is empty).
-}
clarificationContext :: InboxEntry -> T.Text
clarificationContext entry =
  encodeText
    contextSchema
    Context
      { ctxRole = T.pack "planner"
      , ctxStage = T.pack "clarification"
      , ctxAnswer = AnswerKind (T.pack "clarification")
      , ctxRequest =
          RequestContext
            { rcQuestion = entryQuestion entry
            , rcEvidence = entryEvidence entry
            , rcStoppedFor = fromMaybe (T.pack "unknown") (entryHalt entry)
            , rcChoices = [ChoiceContext (inboxChoiceName c) (inboxChoiceConsequence c) | c <- entryChoices entry]
            , rcRule = T.pack "Answer the person's last question with information only. You cannot decide, approve, choose or resume anything; only the person decides."
            }
      , ctxConversation = [Said (messageKind m) (messageBody m) | m <- entryMessages entry]
      , ctxTicket = TicketContext (entryTaskTitle entry) (entryAcceptance entry)
      }
