{- | Whether a class-B destination's idempotency key still protects an
operation id (contract C-P2.9-R1 M1; DG-04 binding requirement 2). The
guarantee lasts from the first dispatch for the declared key lifetime less a
conservative margin; without a first dispatch time it cannot be verified,
which counts as not holding. Other classes do not depend on a key.
-}
module Lockstep.Kernel.KeyLifetime
  ( keyMarginSeconds
  , idempotencyHolds
  ) where

import Data.Time (UTCTime, addUTCTime)
import Flipstone.Prelude

import Lockstep.Kernel.Effect (ClassTerms (..), IdempotencyTerms (..), Intent (..), effectSpecTerms)

-- | max 30 s (lifetime / 10).
keyMarginSeconds :: Integer -> Integer
keyMarginSeconds lifetime =
  max 30 (lifetime `div` 10)

-- | The first dispatch time, the time now, the intent.
idempotencyHolds :: Maybe UTCTime -> UTCTime -> Intent -> Bool
idempotencyHolds firstDispatch now intent =
  case effectSpecTerms (intentSpec intent) of
    TermsIdempotent terms ->
      let
        lifetime = keyLifetimeSeconds terms
        window = lifetime - keyMarginSeconds lifetime
      in
        case firstDispatch of
          Just first -> window > 0 && now < addUTCTime (fromInteger window) first
          Nothing -> False
    _ -> True
