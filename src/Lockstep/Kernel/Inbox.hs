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

-- | Update 2 R6.3 (stub).
requestStandingCode :: RequestStanding -> T.Text
requestStandingCode _ =
  T.empty

-- | Update 2 R6.3 (stub).
requestStandingWords :: RequestStanding -> T.Text
requestStandingWords _ =
  T.empty

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

-- | Update 2 R6.3 (stub).
requestStanding :: RequestFacts -> RequestStanding
requestStanding _ =
  StandingWithdrawn

-- | Why the Supervisor withdrew a request.
data WithdrawalReason
  = -- | Its fix no longer counts, with the invalidation's code.
    WithdrawnInvalidated T.Text
  | -- | Its fix halted again for another reason, with the newer halt's code.
    WithdrawnSuperseded T.Text
  | -- | The person canceled the task; the fix was stopped.
    WithdrawnCanceled
  deriving (Eq, Show)

-- | Update 2 R6.3 (stub).
withdrawalText :: WithdrawalReason -> T.Text
withdrawalText _ =
  T.empty
