{- | The Human Inbox's words for what each choice of a stopped fix does
(contract C-P6.3 I2), from the Supervisor's own vocabulary. Pure.
-}
module Lockstep.Kernel.Inbox
  ( choiceConsequence
  , maxClarifications
  ) where

import Data.Text qualified as T
import Flipstone.Prelude

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
