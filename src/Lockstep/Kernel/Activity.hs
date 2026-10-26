{- | Plain words for the Activity view (contract C-P3.9 N1): what each C-P2.8
status means, which steps need attention and what to do next, the state of a
piece of work, and refused requests. The C-P2.8 labels are shown unchanged
beside these words; nothing here decides a status.
-}
module Lockstep.Kernel.Activity
  ( statusMeaning
  , needsAttention
  , nextStep
  , orderStateWords
  , refusalMeaning
  ) where

import Data.Text qualified as T
import Flipstone.Prelude

import Lockstep.Kernel.EffectView (EffectStatus (..))
import Lockstep.Kernel.WorkOrder (WorkOrderState (..))

-- | The Bool: a retry is left (dispatches within the budget).
statusMeaning :: EffectStatus -> Bool -> T.Text
statusMeaning status retryLeft =
  T.pack $
    case status of
      StatusNotRun -> "Not started yet."
      StatusClaimed -> "About to start: a worker has taken it."
      StatusInProgress -> "In progress: it was sent and Lockstep is waiting for its answer."
      StatusReconciliationNeeded -> "Lockstep does not know yet whether it took effect; it can look this up at the destination."
      StatusUnknown -> "Nobody knows whether it took effect, and Lockstep cannot look it up. A person has to say."
      StatusBlocked -> "Waiting: its work is stopped, so this step cannot go on."
      StatusNotApplied
        | retryLeft -> "The destination said it did not take effect; Lockstep may try it again."
        | otherwise -> "Failed: the destination said it did not take effect, and no tries are left."
      StatusPassed -> "Done, confirmed by the destination itself."
      StatusAttested -> "Settled because a person said what happened; Lockstep did not check it."
      StatusAbandoned -> "Given up: it will not run again."

needsAttention :: EffectStatus -> Bool -> Bool
needsAttention status retryLeft =
  case status of
    StatusUnknown -> True
    StatusReconciliationNeeded -> True
    StatusBlocked -> True
    StatusNotApplied -> not retryLeft
    _ -> False

nextStep :: EffectStatus -> Bool -> Maybe T.Text
nextStep status retryLeft =
  T.pack
    <$> case status of
      StatusUnknown -> Just "Say what happened under Decisions."
      StatusReconciliationNeeded -> Just "Lockstep looks it up when it next runs its recovery; nothing is needed from you unless it asks."
      StatusBlocked -> Just "Its work was stopped: decide under Decisions whether it goes back in line."
      StatusNotApplied
        | retryLeft -> Nothing
        | otherwise -> Just "Look at what the destination said under Technical details, then decide what the work should do next."
      _ -> Nothing

orderStateWords :: WorkOrderState -> T.Text
orderStateWords state =
  case state of
    Pending -> T.pack "Waiting to start."
    Eligible -> T.pack "Able to start, in line."
    Claimed _ -> T.pack "Picked up, about to start."
    Active _ -> T.pack "Being worked on."
    Waiting _ reason -> T.pack "Paused, waiting: " <> reason
    Halted reason -> T.pack "Stopped: " <> reason
    Completed _ _ -> T.pack "Finished."
    Superseded _ -> T.pack "Replaced by other work."
    Canceled -> T.pack "Canceled."

refusalMeaning :: T.Text -> T.Text
refusalMeaning code =
  T.pack $
    case T.unpack code of
      "stale-revision" -> "Refused because it was based on an out-of-date view; nothing was changed."
      "not-authorized" -> "Refused because the one asking may not do this."
      "agent-assertion" -> "Refused because an automated helper tried to act as a person."
      "illegal-transition" -> "Refused because it is not possible from where things stood."
      "already-terminal" -> "Refused because the work had already ended."
      "intents-not-authorized" -> "Refused because steps may only be planned when work starts or resumes."
      _ -> "Refused. The exact reason is under Technical details."
