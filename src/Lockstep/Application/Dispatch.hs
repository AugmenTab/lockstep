{- | The deterministic dispatcher (contract C-P6.5): for each project with an
owner-approved effective plan, the pure 'Lockstep.Kernel.Dispatch.dispatchDecision'
over the durable facts, then the existing hand-over of the chosen unit. Stub
(the freeze's RED baseline): nothing is handed over.
-}
module Lockstep.Application.Dispatch
  ( DispatchReport (..)
  , DispatchView (..)
  , dispatchOnce
  , dispatchView
  , handOverUnit
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason)
import Lockstep.Application.Projects (ProjectFolders)

data DispatchReport
  = DispatchReport
  { reportProject :: T.Text
  , reportUnit :: T.Text
  , reportResult :: Either T.Text T.Text
  -- ^ The new Work Order, or why the hand-over was refused.
  }
  deriving (Eq, Show)

data DispatchView
  = DispatchView
  { dispatchViewNext :: Maybe T.Text
  , dispatchViewWaiting :: [(T.Text, T.Text)]
  -- ^ Each other unit's key and waiting reason code, in the plan's order.
  }
  deriving (Eq, Show)

-- | One pass: for each project with an effective plan, hand over its next unit, if any.
dispatchOnce :: DatabaseRuntime -> ProjectFolders -> IO (Either NotReadyReason [DispatchReport])
dispatchOnce _ _ =
  pure (Right [])

-- | S7: the effective revision's next unit and each other unit's waiting reason.
dispatchView :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Either T.Text DispatchView))
dispatchView _ _ =
  pure (Right (Left (T.pack "not-implemented")))

-- | S4: hands over one unit of the revision with this digest, if it is still the effective one.
handOverUnit :: DatabaseRuntime -> ProjectFolders -> T.Text -> T.Text -> T.Text -> IO (Either NotReadyReason (Either T.Text T.Text))
handOverUnit _ _ _ _ _ =
  pure (Right (Left (T.pack "not-implemented")))
