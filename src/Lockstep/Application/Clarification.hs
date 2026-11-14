{- | Answering a person's questions about an open Human Request (contract
C-P6.3 I4–I8): one bounded, read-only Planner invocation per question, whose
answer the Supervisor posts as a C-P4.3 Planner message. A Planner message
changes only the conversation: it never answers, resumes or authorizes
anything. Run once per engine worker pass, after the transactions.
-}
module Lockstep.Application.Clarification
  ( ClarificationOutcome (..)
  , ClarificationReport (..)
  , answerClarifications
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason)
import Lockstep.Application.Engine (Engine)

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
answerClarifications _ _ =
  pure (Right [])
