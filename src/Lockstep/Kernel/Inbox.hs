{- | The Human Inbox's words for what each choice of a stopped fix does
(contract C-P6.3 I2), from the Supervisor's own vocabulary. Pure.
-}
module Lockstep.Kernel.Inbox
  ( choiceConsequence
  , maxClarifications
  ) where

import Data.Text qualified as T
import Flipstone.Prelude

import Lockstep.Kernel.Transaction (Stage)

-- | What choosing this at a fix stopped at this step does.
choiceConsequence :: Stage -> T.Text -> T.Text
choiceConsequence _ _ =
  T.empty

-- | C-P6.3 I6: at most this many Planner answers to a person's questions on one request.
maxClarifications :: Int
maxClarifications =
  3
