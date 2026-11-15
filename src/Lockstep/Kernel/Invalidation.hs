{- | When a technically accepted fix stops counting (contract C-P6.7 V2, V4):
why, as a code, and which fixes were built on it, directly or through others.
Pure: the application records the invalidations and stops what they affect.
-}
module Lockstep.Kernel.Invalidation
  ( InvalidationCause (..)
  , invalidationCode
  , descendantsOf
  , stopOnlyCodes
  ) where

import Data.List qualified as L
import Data.Set qualified as Set
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
invalidationCode c =
  T.pack $
    case c of
      AncestorRejected -> "ancestor-rejected"
      PlanChanged -> "plan-changed"

{- | V2 b: every fix built on one of the roots, directly or through others,
by the recorded bases (each pair is a fix and one fix it was built on); a
root is in it only when the bases loop back to it. Sorted; it terminates
whatever the pairs.
-}
descendantsOf :: Ord a => [(a, a)] -> [a] -> [a]
descendantsOf bases roots =
  Set.toAscList (go Set.empty Set.empty roots)
 where
  go _ found [] = found
  go seen found (r : rest) =
    let
      children = [fix | (fix, ancestor) <- bases, ancestor == r, not (Set.member fix seen)]
      seen' = L.foldl' (flip Set.insert) seen children
    in
      go seen' (L.foldl' (flip Set.insert) found children) (rest <> children)

-- | V4: the halts that offer only Stop (no stage may run again on what they found).
stopOnlyCodes :: [T.Text]
stopOnlyCodes =
  fmap invalidationCode [minBound .. maxBound] <> [T.pack "basis-stale"]
