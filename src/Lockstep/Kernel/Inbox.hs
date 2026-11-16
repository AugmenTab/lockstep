{- | The Human Inbox's words for what each choice of a stopped fix does
(contract C-P6.3 I2), from the Supervisor's own vocabulary. Pure.
-}
module Lockstep.Kernel.Inbox
  ( choiceConsequence
  , maxClarifications

    -- * Where a request stands (Update 2 R6.3)
  , RequestStanding (..)
  , requestStandingCode
  , requestStandingWords
  , RequestFacts (..)
  , requestStanding
  , WithdrawalReason (..)
  , withdrawalText
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Transaction (Stage, retryOperation)

-- | What choosing this at a fix stopped at this step does.
choiceConsequence :: Stage -> T.Text -> T.Text
choiceConsequence stage choice =
  case T.unpack choice of
    "retry" -> retryOperation stage
    "stop" -> T.pack "Stop ends this fix: nothing more runs, its work branch is kept as it is, and nothing is published."
    "replan" -> T.pack "Replan runs the Planner's search for the cause again, from the start."
    "accept-non-reproduction" ->
      T.pack "Going on without a reproduction: the fix continues, and the tests it writes must still fail because of the bug."
    _ -> T.pack "Lockstep cannot describe what this choice does."

-- | C-P6.3 I6: at most this many Planner answers to a person's questions on one request.
maxClarifications :: Int
maxClarifications =
  3

-- | Update 2 R6.3: where a Human Request stands.
data RequestStanding
  = StandingCurrent
  | StandingSuperseded
  | StandingResolved
  | StandingInvalidated
  | StandingAwaitingEffect
  | StandingWithdrawn
  deriving (Eq, Show, Enum, Bounded)

requestStandingCode :: RequestStanding -> T.Text
requestStandingCode s =
  T.pack $
    case s of
      StandingCurrent -> "current"
      StandingSuperseded -> "superseded"
      StandingResolved -> "resolved"
      StandingInvalidated -> "invalidated"
      StandingAwaitingEffect -> "answered-not-acted"
      StandingWithdrawn -> "withdrawn"

-- | Plain words for the page; no character in them is escaped in HTML.
requestStandingWords :: RequestStanding -> T.Text
requestStandingWords s =
  T.pack $
    case s of
      StandingCurrent -> "Waiting for your answer now."
      StandingSuperseded -> "Superseded: the fix moved on, so this request no longer decides anything. Kept as a record."
      StandingResolved -> "Resolved: you answered, and Lockstep acted on the answer."
      StandingInvalidated -> "Invalidated: its fix no longer counts, so this request no longer decides anything. Kept as a record."
      StandingAwaitingEffect -> "Answered: Lockstep has not acted on the answer yet."
      StandingWithdrawn -> "Withdrawn. Kept as a record."

-- | What a request's standing is read from.
data RequestFacts
  = RequestFacts
  { requestFactState :: T.Text
  -- ^ The stored state: @open@, @answered@ or @withdrawn@.
  , requestFactWithdrawal :: Maybe T.Text
  -- ^ The Supervisor's withdrawal message, if it was withdrawn.
  , requestFactFixInvalidated :: Bool
  -- ^ Whether its fix's acceptance, or the fix itself, no longer counts.
  , requestFactCurrent :: Bool
  -- ^ Whether its fix is halted on this very request now.
  , requestFactActedOn :: Bool
  -- ^ Whether its fix recorded acting on its answer.
  }
  deriving (Eq, Show)

{- | Update 2 R6.3. An open request is the current one while its fix is
halted on it (for a fix that no longer counts, that is its Stop-only request);
any other open request is invalidated when its fix no longer counts, else
superseded. An answer is resolved once the fix recorded acting on it. A
withdrawal says why by the Supervisor's own text ('withdrawalText').
-}
requestStanding :: RequestFacts -> RequestStanding
requestStanding f =
  case T.unpack (requestFactState f) of
    "open"
      | requestFactCurrent f -> StandingCurrent
      | requestFactFixInvalidated f -> StandingInvalidated
      | otherwise -> StandingSuperseded
    "answered"
      | requestFactActedOn f -> StandingResolved
      | otherwise -> StandingAwaitingEffect
    _ ->
      case requestFactWithdrawal f of
        Just body
          | invalidatedPrefix `T.isPrefixOf` body -> StandingInvalidated
          | supersededPrefix `T.isPrefixOf` body -> StandingSuperseded
        _ -> StandingWithdrawn

invalidatedPrefix :: T.Text
invalidatedPrefix =
  T.pack "Invalidated ("

supersededPrefix :: T.Text
supersededPrefix =
  T.pack "Superseded ("

-- | Why the Supervisor withdrew a request.
data WithdrawalReason
  = -- | Its fix no longer counts, with the invalidation's code.
    WithdrawnInvalidated T.Text
  | -- | Its fix halted again for another reason, with the newer halt's code.
    WithdrawnSuperseded T.Text
  | -- | The person canceled the task; the fix was stopped.
    WithdrawnCanceled
  deriving (Eq, Show)

-- | The message the Supervisor withdraws a request with: its cause first, then that it is kept.
withdrawalText :: WithdrawalReason -> T.Text
withdrawalText reason =
  case reason of
    WithdrawnInvalidated code ->
      invalidatedPrefix <> code <> T.pack "): this fix no longer counts, so an answer here can no longer change it. This request is kept as a record."
    WithdrawnSuperseded code ->
      supersededPrefix <> code <> T.pack "): the fix stopped again for another reason; answer its newer request instead. This request is kept as a record."
    WithdrawnCanceled ->
      supersededPrefix <> T.pack "canceled): you canceled the task, so Lockstep stopped this fix. This request is kept as a record."
