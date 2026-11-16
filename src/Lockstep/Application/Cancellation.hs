{- | Update 2 R6.3: a person's cancel of a task whose fix is live (update 1 §5
target semantics). A task with no live fix is canceled at once, as before. A
task whose fix is handed over, running or waiting for a person is not
canceled then: the cancel is recorded, the engine stops the fix at its next
safe point (between stages) as the person's Stop, withdraws its open requests,
and only then is the task canceled ('settleCancellations'). A fix whose
helper's outcome is uncertain is not stopped by the cancel: it waits for the
person's own decision, so the uncertainty is never discarded. A fix that is
accepted is never canceled this way: the person decides Done or Not done first
(@fix-accepted@). Nothing is deleted.
-}
module Lockstep.Application.Cancellation
  ( CancelOutcome (..)
  , CancellationView (..)
  , requestCancel
  , cancellationOf
  , settleCancellations
  ) where

import Data.List qualified as L
import Data.Maybe (catMaybes, isNothing)
import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Text.Show (Show)

import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason, Readiness (..), checkReadiness, withDatabase)
import Lockstep.Application.Tasks (TaskDecision (CancelTask), TaskView (..), decideTask, findTaskIn, fixFactOf)
import Lockstep.Kernel.Dispatch (FixFact (..))
import Lockstep.Kernel.Identity (TaskId (..), identityText, parseIdentity)
import Lockstep.Kernel.Transaction (TxState (..), uncertainOutstanding)
import Lockstep.Persistence.Cancellations qualified as Store
import Lockstep.Persistence.Execution qualified as Execution
import Lockstep.Persistence.Tasks qualified as Tasks
import Lockstep.Persistence.Transactions qualified as Transactions

-- | What a person's cancel did.
data CancelOutcome
  = -- | The task is canceled: it had no live fix.
    CancelSettled TaskView
  | -- | Its fix is being stopped at a safe point; the task is canceled once it has stopped.
    CancelStopping TaskView
  deriving (Eq, Show)

-- | Where a cancel of a task stands.
data CancellationView
  = CancellationView
  { cancellationState :: T.Text
  -- ^ @stopping@, @waiting-for-you@, @canceled@ or @not-canceled@.
  , cancellationWords :: T.Text
  }
  deriving (Eq, Show)

whenReady :: DatabaseRuntime -> IO (Either NotReadyReason a) -> IO (Either NotReadyReason a)
whenReady runtime action = do
  readiness <- checkReadiness (Just runtime)
  case readiness of
    NotReady reason -> pure (Left reason)
    Ready _ -> action

-- | What the recording step found.
data Recorded
  = Stopping TaskView
  | CancelNow
  | Refused T.Text

{- | A person's cancel. A replay while the cancel is pending is the same
cancel. The Ticket revision must be the task's (@stale-revision@).
-}
requestCancel :: DatabaseRuntime -> T.Text -> T.Text -> Int -> IO (Either NotReadyReason (Either T.Text CancelOutcome))
requestCancel runtime session rawId expected =
  whenReady runtime $
    case parseIdentity rawId of
      Nothing -> pure (Right (Left (T.pack "unknown-task")))
      Just tid -> do
        recorded <- withDatabase runtime (O.withTransaction (record tid))
        case recorded of
          Left reason -> pure (Left reason)
          Right (Refused code) -> pure (Right (Left code))
          Right (Stopping view) -> pure (Right (Right (CancelStopping view)))
          -- No live fix: canceled now, under the task lock, as before (it refuses a fix that became live meanwhile).
          Right CancelNow -> fmap (fmap CancelSettled) <$> decideTask runtime session rawId expected CancelTask
 where
  record tid = do
    Tasks.lockTasks
    found <- findTaskIn tid
    fix <- fixFactOf tid
    admission <- Execution.findAdmissionByTask tid
    case (found, admission) of
      (Nothing, _) -> pure (Refused (T.pack "unknown-task"))
      (Just (Left code), _) -> pure (Refused code)
      (Just (Right view), Just a)
        | taskTicketRevision view /= expected -> pure (Refused (T.pack "stale-revision"))
        | fix == FixUnderWay -> do
            let
              workOrder = Execution.admissionRowWorkOrder a
            existing <- Store.cancellationFor workOrder
            case existing of
              Just _ -> pure ()
              Nothing -> Store.insertCancellation (Store.CancellationRow workOrder tid (T.take 200 session))
            pure (Stopping view)
        | fix `L.elem` [FixAccepted, FixAcceptanceInvalidated] -> pure (Refused (T.pack "fix-accepted"))
      (Just (Right _), _) -> pure CancelNow

-- | Where the latest cancel of the task stands, if one was made while its fix was live.
cancellationOf :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Maybe CancellationView))
cancellationOf runtime rawId =
  whenReady runtime $
    case parseIdentity rawId of
      Nothing -> pure (Right Nothing)
      Just tid ->
        withDatabase runtime $ do
          latest <- Store.latestCancellationOfTask tid
          case latest of
            Nothing -> pure Nothing
            Just c -> do
              settlement <- Store.settlementFor (Store.cancellationWorkOrder c)
              tx <- Transactions.findTransactionByWorkOrder (Store.cancellationWorkOrder c)
              records <- maybe (pure []) (Transactions.transactionRecords . Transactions.txRowId) tx
              pure (Just (viewOf settlement (Transactions.txRowState <$> tx) (uncertainOutstanding (fmap Transactions.recordRowKind records))))
 where
  viewOf settled state uncertain =
    case (settled, state) of
      (Just s, _)
        | Store.settlementOutcome s == T.pack "canceled" -> CancellationView (T.pack "canceled") (T.pack "Canceled: its fix stopped first.")
        | otherwise -> CancellationView (T.pack "not-canceled") (T.pack "Not canceled: " <> Store.settlementReason s)
      -- R-U2-1: read from the records, whatever the halt code now says.
      (Nothing, Just (Halted _ _))
        | uncertain ->
            CancellationView (T.pack "waiting-for-you") (T.pack "Waiting for you: what a helper did is not known, so Lockstep does not stop the fix by itself. Decide on its request; the task is canceled once the fix has stopped.")
      _ -> CancellationView (T.pack "stopping") (T.pack "Cancel requested: Lockstep stops its fix at the next safe point, then cancels the task.")

{- | Settles every pending cancel whose fix has stopped (the task is canceled)
or was accepted first (not canceled: the person decides Done or Not done).
A fix still running or waiting is left for a later pass. What was settled,
by task.
-}
settleCancellations :: DatabaseRuntime -> IO (Either NotReadyReason [(T.Text, Either T.Text T.Text)])
settleCancellations runtime =
  whenReady runtime $ do
    pending <- withDatabase runtime $ do
      all' <- Store.allCancellations
      catMaybes
        <$> traverse
          ( \c -> do
              settlement <- Store.settlementFor (Store.cancellationWorkOrder c)
              tx <- Transactions.findTransactionByWorkOrder (Store.cancellationWorkOrder c)
              latest <- Execution.findAdmissionByTask (Store.cancellationTask c)
              let
                superseded = maybe False ((/= Store.cancellationWorkOrder c) . Execution.admissionRowWorkOrder) latest
              pure (if isNothing settlement then Just (c, Transactions.txRowState <$> tx, superseded) else Nothing)
          )
          all'
    case pending of
      Left reason -> pure (Left reason)
      Right cs -> fmap catMaybes . sequenceA <$> traverse settle cs
 where
  settle (c, state, superseded) =
    case state of
      -- R-U2-3: a cancel of an earlier fix never acts on a newer one; it is settled, not applied.
      _ | superseded -> notCanceled c (T.pack "a newer fix of the task was handed over after this cancel")
      Just (Stopped _) -> cancelTask c
      Just Accepted -> notCanceled c (T.pack "its fix was accepted before it stopped; decide Done or Not done")
      Just Done -> notCanceled c (T.pack "its fix was marked Done before it stopped")
      _ -> pure (Right Nothing)
  task c =
    identityText (Store.cancellationTask c)
  notCanceled c reason = do
    written <- withDatabase runtime (Store.insertSettlement (Store.SettlementRow (Store.cancellationWorkOrder c) (T.pack "not-canceled") reason))
    pure (fmap (const (Just (task c, Left reason))) written)
  cancelTask c = do
    current <- withDatabase runtime (findTaskIn (Store.cancellationTask c))
    case current of
      Left reason -> pure (Left reason)
      Right (Just (Right view))
        | taskState view == T.pack "canceled" -> settled c
        | otherwise -> do
            decided <- decideTask runtime (Store.cancellationSession c) (task c) (taskTicketRevision view) CancelTask
            case decided of
              Left reason -> pure (Left reason)
              Right (Right _) -> settled c
              -- Changed meanwhile (a stale revision, say): tried again on the next pass.
              Right (Left code) -> pure (Right (Just (task c, Left code)))
      Right _ -> pure (Right (Just (task c, Left (T.pack "unknown-task"))))
  settled c = do
    written <- withDatabase runtime (Store.insertSettlement (Store.SettlementRow (Store.cancellationWorkOrder c) (T.pack "canceled") (T.pack "its fix stopped first")))
    pure (fmap (const (Just (task c, Right (T.pack "canceled")))) written)
