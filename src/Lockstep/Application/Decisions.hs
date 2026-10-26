{- | Human decisions made in the browser (contract C-P3.8 M1, M3): the open
decisions read from the C-P2.8 projection, and each choice applied through
the existing C-P2.5/C-P2.9 operation as a Human, with the expected revision or
generation, behind an idempotency key and an immutable receipt.
-}
module Lockstep.Application.Decisions
  ( OpenDecision (..)
  , StoppedFacts (..)
  , UnknownFacts (..)
  , decisionId
  , DecisionReceipt (..)
  , listDecisions
  , findDecision
  , decidedReceipt
  , applyDecision
  ) where

import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Application.Command (IdempotencyKey, idempotencyKeyText)
import Lockstep.Application.Database (DatabaseRuntime, withDatabase)
import Lockstep.Application.Ledger
  ( LedgerFailure (..)
  , StoredObservation (..)
  , abandonIntentAcknowledged
  , decideWorkOrder
  , loadIntent
  , noFaults
  , resolveOutcome
  )
import Lockstep.Application.LedgerView (EffectLine (..), LedgerProjection (..), OrderLine (..), TicketLine (..), projectLedger)
import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Kernel.Decision
  ( DecisionRequest (..)
  , checkDecisionText
  , decisionChoiceName
  , decisionExpected
  , decisionPayload
  , decisionSubject
  )
import Lockstep.Kernel.Effect (Intent (..), OperationId (..), effectSpecName)
import Lockstep.Kernel.EffectView (EffectStatus (..))
import Lockstep.Kernel.Identity (WorkOrderId (..), uuidText)
import Lockstep.Kernel.Profile (Hasher (..), contentDigestText)
import Lockstep.Kernel.Reconciliation (Resolution (..))
import Lockstep.Kernel.Transition (Command (..), Principal (..))
import Lockstep.Kernel.WorkOrder (WorkOrderInput (..), WorkOrderState (..))
import Lockstep.Persistence.DecisionReceipts qualified as Store

-- | Work a person or the Supervisor stopped (a halted Work Order).
data StoppedFacts
  = StoppedFacts
  { stoppedOrder :: WorkOrderId
  , stoppedRevision :: Int
  , stoppedReason :: T.Text
  , stoppedTitle :: T.Text
  }
  deriving (Eq, Show)

-- | A step whose outcome nobody knows (an effect intent in the UNKNOWN status).
data UnknownFacts
  = UnknownFacts
  { unknownOperation :: OperationId
  , unknownGeneration :: Int
  , unknownStep :: T.Text
  , unknownReason :: T.Text
  , unknownObservations :: [T.Text]
  , unknownOrder :: WorkOrderId
  , unknownTitle :: T.Text
  }
  deriving (Eq, Show)

data OpenDecision
  = StoppedWork StoppedFacts
  | UnknownOutcome UnknownFacts
  deriving (Eq, Show)

-- | The id a decision is addressed by: the stopped order's, or the unknown step's.
decisionId :: OpenDecision -> T.Text
decisionId decision =
  case decision of
    StoppedWork facts -> case stoppedOrder facts of WorkOrderId u -> uuidText u
    UnknownOutcome facts -> case unknownOperation facts of OperationId u -> uuidText u

data DecisionReceipt
  = DecisionReceipt
  { receiptSubject :: T.Text
  , receiptChoice :: T.Text
  , receiptExpected :: Int
  , receiptOutcome :: T.Text
  , receiptRefusal :: Maybe T.Text
  , receiptReplayed :: Bool
  }
  deriving (Eq, Show)

-- | M1: unknown outcomes first (they block their work), then stopped work; each by id.
listDecisions :: DatabaseRuntime -> IO (Either LedgerFailure [OpenDecision])
listDecisions runtime =
  fmap decisionsOf <$> projectLedger runtime

decisionsOf :: LedgerProjection -> [OpenDecision]
decisionsOf projection =
  let
    titles = [(ticketLineId t, ticketLineTitle t) | t <- projectionTickets projection]
    titleOf o = fromMaybe T.empty (L.lookup (orderLineTicket o) titles)
    orders = projectionOrders projection
    unknowns =
      [ UnknownOutcome
          UnknownFacts
            { unknownOperation = intentOperation i
            , unknownGeneration = intentGeneration i
            , unknownStep = effectSpecName (intentSpec i)
            , unknownReason = effectLineReason e
            , unknownObservations = fmap storedObservation (effectLineObservations e)
            , unknownOrder = orderLineId o
            , unknownTitle = titleOf o
            }
      | o <- orders
      , e <- orderLineEffects o
      , effectLineStatus e == StatusUnknown
      , let
          i = effectLineIntent e
      ]
    stopped =
      [ StoppedWork (StoppedFacts (orderLineId o) (orderLineRevision o) reason (titleOf o))
      | o <- orders
      , Halted reason <- [orderLineState o]
      ]
  in
    L.sortOn decisionId unknowns <> L.sortOn decisionId stopped

findDecision :: DatabaseRuntime -> T.Text -> IO (Either LedgerFailure (Maybe OpenDecision))
findDecision runtime subject =
  fmap (L.find ((== subject) . decisionId)) <$> listDecisions runtime

-- | The latest applied receipt for a subject: what was decided, once it is no longer open.
decidedReceipt :: DatabaseRuntime -> T.Text -> IO (Either LedgerFailure (Maybe DecisionReceipt))
decidedReceipt runtime subject = do
  found <- withDatabase runtime (Store.latestReceiptFor subject)
  pure (either (const (Left unavailable)) (Right . fmap (receiptOf False)) found)

unavailable :: LedgerFailure
unavailable =
  LedgerUnavailable (T.pack "unavailable")

receiptOf :: Bool -> Store.ReceiptRow -> DecisionReceipt
receiptOf replayed row =
  DecisionReceipt
    { receiptSubject = Store.receiptRowSubject row
    , receiptChoice = Store.receiptRowChoice row
    , receiptExpected = fromIntegral (Store.receiptRowExpected row)
    , receiptOutcome = Store.receiptRowOutcome row
    , receiptRefusal = Store.receiptRowRefusal row
    , receiptReplayed = replayed
    }

payloadDigest :: DecisionRequest -> T.Text
payloadDigest request =
  case sha256Hasher of
    Hasher f -> contentDigestText (f (decisionPayload request))

{- | M3: the text rules (no receipt); a receipt with this key (the same request
replays it, another is @key-conflict@); the operation as a Human; one receipt
for what it did. A database that cannot be reached, or an integrity failure,
records nothing.
-}
applyDecision :: DatabaseRuntime -> IdempotencyKey -> DecisionRequest -> IO (Either LedgerFailure (Either T.Text DecisionReceipt))
applyDecision runtime key request =
  case checkDecisionText request of
    Left code -> pure (Right (Left code))
    Right () -> do
      let
        keyText = idempotencyKeyText key
        digest = payloadDigest request
      existing <- withDatabase runtime (Store.findReceipt keyText)
      case existing of
        Left _ -> pure (Left unavailable)
        Right (Just row)
          | Store.receiptRowDigest row == digest -> pure (Right (Right (receiptOf True row)))
          | otherwise -> pure (Right (Left (T.pack "key-conflict")))
        Right Nothing -> do
          performed <- perform runtime request
          let
            row outcome refusal =
              Store.ReceiptRow
                { Store.receiptRowKey = keyText
                , Store.receiptRowDigest = digest
                , Store.receiptRowSubject = decisionSubject request
                , Store.receiptRowChoice = decisionChoiceName request
                , Store.receiptRowExpected = fromIntegral (decisionExpected request)
                , Store.receiptRowOutcome = T.pack outcome
                , Store.receiptRowRefusal = refusal
                , Store.receiptRowActor = T.pack "application-session"
                }
          case performed of
            Right () -> store keyText (row "applied" Nothing)
            Left (LedgerRefused code _) -> store keyText (row "refused" (Just code))
            Left failure -> pure (Left failure)
 where
  store keyText row = do
    stored <-
      withDatabase runtime $ do
        inserted <- Store.insertReceipt row
        if inserted
          then pure (Just (receiptOf False row))
          else fmap (receiptOf True) <$> Store.findReceipt keyText
    pure $
      case stored of
        Left _ -> Left unavailable
        Right Nothing -> Left unavailable
        Right (Just receipt) -> Right (Right receipt)

-- | The one existing operation for each choice, as a Human.
perform :: DatabaseRuntime -> DecisionRequest -> IO (Either LedgerFailure ())
perform runtime request =
  case request of
    PutBackInLine wo n -> void' (decideWorkOrder runtime noFaults wo n (Command Human WoRequeue) [])
    CancelWork wo n -> void' (decideWorkOrder runtime noFaults wo n (Command Human WoCancel) [])
    ItHappened op n t -> void' (resolveOutcome runtime op n (AttestApplied (T.strip t)))
    ItDidNotHappen op n t -> void' (resolveOutcome runtime op n (AttestNotApplied (T.strip t)))
    TryAgain op n acknowledged -> void' (resolveOutcome runtime op n (RetryAcknowledgingDuplication acknowledged))
    GiveUp op n t acknowledged -> do
      current <- loadIntent runtime op
      case current of
        Left failure -> pure (Left failure)
        Right intent
          | intentGeneration intent /= n -> pure (Left (LedgerRefused (T.pack "stale-revision") (T.pack "the step changed since the page was shown")))
          | otherwise -> void' (abandonIntentAcknowledged runtime op (T.strip t) acknowledged)
 where
  void' =
    fmap (fmap (const ()))
