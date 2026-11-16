{- | Update 2, DG-08 local Phase signoff: the human gates of a project's
effective plan and where each stands. Stub.
-}
module Lockstep.Application.PhaseGates
  ( phaseGatesOf
  ) where

import Data.Text qualified as T
import Flipstone.Prelude

import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason)

-- | Stub.
phaseGatesOf :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Either T.Text [(T.Text, T.Text, T.Text)]))
phaseGatesOf _ _ =
  pure (Right (Right []))
