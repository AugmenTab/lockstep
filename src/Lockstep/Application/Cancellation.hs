{- | Update 2 R6.3: a person's cancel of a task whose fix is live (update 1 §5
target semantics). Stub.
-}
module Lockstep.Application.Cancellation
  ( CancelOutcome (..)
  , CancellationView (..)
  , requestCancel
  , cancellationOf
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason)
import Lockstep.Application.Tasks (TaskView)

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

-- | Stub.
requestCancel :: DatabaseRuntime -> T.Text -> T.Text -> Int -> IO (Either NotReadyReason (Either T.Text CancelOutcome))
requestCancel _ _ _ _ =
  pure (Right (Left (T.pack "not-implemented")))

-- | Stub.
cancellationOf :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Maybe CancellationView))
cancellationOf _ _ =
  pure (Right Nothing)
