{- | When a technically accepted fix stops counting (contract C-P6.7 V2, V4).
Stub (the freeze's RED baseline).
-}
module Lockstep.Kernel.Invalidation
  ( InvalidationCause (..)
  , invalidationCode
  , descendantsOf
  , stopOnlyCodes
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

data InvalidationCause
  = -- | A fix it was built on was rejected by the person, or itself invalidated.
    AncestorRejected
  | -- | The owner approved a plan revision that changed its unit, or something its unit builds on.
    PlanChanged
  deriving (Eq, Show, Enum, Bounded)

invalidationCode :: InvalidationCause -> T.Text
invalidationCode _ =
  T.empty

-- | V2 b: every fix built on one of the roots, directly or through others.
descendantsOf :: Ord a => [(a, a)] -> [a] -> [a]
descendantsOf _ roots =
  L.drop (L.length roots) (L.sort roots)

-- | V4: the halts that offer only Stop.
stopOnlyCodes :: [T.Text]
stopOnlyCodes =
  []
