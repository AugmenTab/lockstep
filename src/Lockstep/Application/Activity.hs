{- | What the Activity view reads (contract C-P3.9 N2, N3): the C-P2.8
projection, its canonical text and its time, from one read of the database.
-}
module Lockstep.Application.Activity
  ( ActivityView (..)
  , readActivity
  , retryLeft
  ) where

import Data.Text qualified as T
import Flipstone.Prelude

import Lockstep.Application.Database (DatabaseRuntime)
import Lockstep.Application.Ledger (LedgerFailure)
import Lockstep.Application.LedgerView (LedgerProjection, projectLedger, projectionTimeText, renderProjection)
import Lockstep.Kernel.Effect (Intent (..), effectSpecBudget)

data ActivityView
  = ActivityView
  { activityProjection :: LedgerProjection
  , activityRaw :: T.Text
  , activityTime :: T.Text
  }

readActivity :: DatabaseRuntime -> IO (Either LedgerFailure ActivityView)
readActivity runtime =
  fmap (\p -> ActivityView p (renderProjection p) (projectionTimeText p)) <$> projectLedger runtime

-- | N3: a retry is left while the dispatches are within the budget (as C-P2.8 words its reason).
retryLeft :: Intent -> Bool
retryLeft intent =
  intentDispatches intent <= effectSpecBudget (intentSpec intent)
