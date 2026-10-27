{- | Human decisions made in the browser (contract C-P3.8 M1, M3): the open
decisions read from the C-P2.8 projection, and each choice applied through
the existing C-P2.5/C-P2.9 operation as a Human, with the expected revision or
generation, behind an idempotency key and an immutable receipt; serialized per
key under a session lock, with an attempt marker first (C-C.R1 R1).
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
import Orville.PostgreSQL qualified as O
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, idempotencyKeyText)
import Lockstep.Application.Database (DatabaseRuntime, LockFailure (..), Locked (..), SessionLock (..), withDatabase, withSessionLock)
import Lockstep.Application.Ledger
  ( LedgerFailure (..)
  , Receipt (..)
  , StoredObservation (..)
  , WorkOrderView (..)
  , abandonIntentAcknowledged
  , decideWorkOrder
  , loadIntent
  , noFaults
  , resolveOutcome
  , showWorkOrder
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
import Lockstep.Kernel.Effect (Intent (..), OperationId (..), effectSpecName, intentStateName)
import Lockstep.Kernel.EffectView (EffectStatus (..))
import Lockstep.Kernel.Identity (WorkOrderId (..), parseUuid, uuidText)
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
  , receiptCurrent :: Bool
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

{- | The latest applied receipt for a subject: what was decided, once it is no
longer open; current only while the subject's ledger basis is still the one
that decision produced (C-C.R1 R4).
-}
decidedReceipt :: DatabaseRuntime -> T.Text -> IO (Either LedgerFailure (Maybe DecisionReceipt))
decidedReceipt runtime subject = do
  found <- withDatabase runtime (Store.latestReceiptFor subject)
  case found of
    Left _ -> pure (Left unavailable)
    Right Nothing -> pure (Right Nothing)
    Right (Just row) -> Right . Just <$> receiptOf runtime False row

unavailable :: LedgerFailure
unavailable =
  LedgerUnavailable (T.pack "unavailable")

receiptOf :: DatabaseRuntime -> Bool -> Store.ReceiptRow -> IO DecisionReceipt
receiptOf runtime replayed row = do
  current <-
    case Store.receiptRowBasis row of
      Nothing -> pure False
      Just stored -> (== Just stored) <$> currentBasis runtime (Store.receiptRowChoice row) (Store.receiptRowSubject row)
  pure
    DecisionReceipt
      { receiptSubject = Store.receiptRowSubject row
      , receiptChoice = Store.receiptRowChoice row
      , receiptExpected = fromIntegral (Store.receiptRowExpected row)
      , receiptOutcome = Store.receiptRowOutcome row
      , receiptRefusal = Store.receiptRowRefusal row
      , receiptReplayed = replayed
      , receiptCurrent = current
      }

-- | The subject's ledger basis as it is now: the stopped work's revision, or the step's state and generation.
currentBasis :: DatabaseRuntime -> T.Text -> T.Text -> IO (Maybe T.Text)
currentBasis runtime choice subject =
  case parseUuid subject of
    Left _ -> pure Nothing
    Right u
      | choice `L.elem` fmap T.pack ["put-back", "cancel"] -> either (const Nothing) (Just . orderBasis . woRevision) <$> showWorkOrder runtime (WorkOrderId u)
      | otherwise -> either (const Nothing) (Just . intentBasis) <$> loadIntent runtime (OperationId u)

orderBasis :: Int -> T.Text
orderBasis revision =
  T.pack ("order:" <> show revision)

intentBasis :: Intent -> T.Text
intentBasis intent =
  T.pack "intent:" <> intentStateName (intentState intent) <> T.pack (":" <> show (intentGeneration intent))

payloadDigest :: DecisionRequest -> T.Text
payloadDigest request =
  case sha256Hasher of
    Hasher f -> contentDigestText (f (decisionPayload request))

-- | The range of the stored expected value (a PostgreSQL integer that is never negative).
expectedInRange :: Int -> Bool
expectedInRange n =
  n >= 0 && n <= 2147483647

{- | M3 as C-C.R1 R1 serializes it: the expected value's range and the text
rules (no receipt); then, under the session lock for the key on a connection
of its own: a receipt with this key (the same request replays it, another is
@key-conflict@); an attempt marker without a receipt (@decision-outcome-uncertain@:
nothing is applied again and nothing is made up); the marker; the operation as
a Human; one receipt for what it did, inserted only after the lock is proved
still held. A lock held elsewhere for longer than the bound is
@decision-busy@. A database that cannot be reached, or an integrity failure,
records no receipt.
-}
applyDecision :: DatabaseRuntime -> IdempotencyKey -> DecisionRequest -> IO (Either LedgerFailure (Either T.Text DecisionReceipt))
applyDecision runtime key request
  | not (expectedInRange (decisionExpected request)) = pure (Right (Left (T.pack "revision-out-of-range")))
  | otherwise =
      case checkDecisionText request of
        Left code -> pure (Right (Left code))
        Right () -> do
          result <- withSessionLock runtime DecisionKeyLock keyText (underLock runtime keyText (payloadDigest request) request)
          pure $
            case result of
              Right answer -> answer
              Left LockBusy -> Right (Left (T.pack "decision-busy"))
              Left (LockUnavailable _) -> Left unavailable
 where
  keyText =
    idempotencyKeyText key

underLock :: DatabaseRuntime -> T.Text -> T.Text -> DecisionRequest -> Locked -> IO (Either LedgerFailure (Either T.Text DecisionReceipt))
underLock runtime keyText digest request lock = do
  existing <- onLockConnection lock (Store.findReceipt keyText)
  case existing of
    Just stored -> replayOrConflict stored
    Nothing -> do
      attempted <- onLockConnection lock (Store.attemptDigest keyText)
      marked <- maybe (onLockConnection lock (Store.insertAttempt keyText digest (decisionSubject request))) (const (pure False)) attempted
      case (marked, attempted) of
        (False, Just earlier)
          | earlier /= digest -> pure (Right (Left (T.pack "key-conflict")))
        (False, _) -> pure (Right (Left (T.pack "decision-outcome-uncertain")))
        (True, _) -> do
          performed <- perform runtime request
          case performed of
            Right basis -> store (row "applied" Nothing (Just basis))
            Left (LedgerRefused code _) -> store (row "refused" (Just code) Nothing)
            Left failure -> pure (Left failure)
 where
  replayOrConflict found
    | Store.receiptRowDigest found == digest = Right . Right <$> receiptOf runtime True found
    | otherwise = pure (Right (Left (T.pack "key-conflict")))
  row outcome refusal basis =
    Store.ReceiptRow
      { Store.receiptRowKey = keyText
      , Store.receiptRowDigest = digest
      , Store.receiptRowSubject = decisionSubject request
      , Store.receiptRowChoice = decisionChoiceName request
      , Store.receiptRowExpected = fromIntegral (decisionExpected request)
      , Store.receiptRowOutcome = T.pack outcome
      , Store.receiptRowRefusal = refusal
      , Store.receiptRowActor = T.pack "application-session"
      , Store.receiptRowBasis = basis
      }
  store receipt = do
    stored <-
      onLockConnection lock . O.withTransaction $ do
        stillHeld <- lockStillHeld lock
        if not stillHeld
          then pure Nothing
          else do
            inserted <- Store.insertReceipt receipt
            if inserted then pure (Just (Left receipt)) else fmap Right <$> Store.findReceipt keyText
    case stored of
      Nothing -> pure (Left unavailable)
      Just (Left receipt') -> Right . Right <$> receiptOf runtime False receipt'
      Just (Right found) -> replayOrConflict found

-- | The one existing operation for each choice, as a Human; the subject's ledger basis after it.
perform :: DatabaseRuntime -> DecisionRequest -> IO (Either LedgerFailure T.Text)
perform runtime request =
  case request of
    PutBackInLine wo n -> order (decideWorkOrder runtime noFaults wo n (Command Human WoRequeue) [])
    CancelWork wo n -> order (decideWorkOrder runtime noFaults wo n (Command Human WoCancel) [])
    ItHappened op n t -> step (resolveOutcome runtime op n (AttestApplied (T.strip t)))
    ItDidNotHappen op n t -> step (resolveOutcome runtime op n (AttestNotApplied (T.strip t)))
    TryAgain op n acknowledged -> step (resolveOutcome runtime op n (RetryAcknowledgingDuplication acknowledged))
    GiveUp op n t acknowledged -> do
      current <- loadIntent runtime op
      case current of
        Left failure -> pure (Left failure)
        Right intent
          | intentGeneration intent /= n -> pure (Left (LedgerRefused (T.pack "stale-revision") (T.pack "the step changed since the page was shown")))
          | otherwise -> step (abandonIntentAcknowledged runtime op (T.strip t) acknowledged)
 where
  order =
    fmap (fmap (orderBasis . receiptRevision))
  step =
    fmap (fmap intentBasis)
