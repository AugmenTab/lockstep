{-# LANGUAGE DataKinds #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Derived from Launchpad.Handler.NoPermissionError (11886bf).
module Lockstep.Web.Handler.NoPermissionError
  ( NoPermissionError
  ) where

import Data.Void qualified as Void
import Orb qualified

import Lockstep.Foundation.Types (Lockstep)

newtype NoPermissionError
  = NoPermissionError Void.Void

instance Orb.PermissionError NoPermissionError where
  type
    PermissionErrorConstraints NoPermissionError _tags =
      ()

  type
    PermissionErrorMonad NoPermissionError =
      Lockstep

  returnPermissionError (NoPermissionError v) =
    Void.absurd v
