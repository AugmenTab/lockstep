{- | Canonical texts of closed enumerations. Each enumeration defines its one
text form (a @fooText@ or @fooName@ function); its parser is derived from it
here, so the two cannot disagree (Artificer's @EnumAux.parseEnumText@).
-}
module Lockstep.Kernel.Enum
  ( parseEnumText
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude

-- | The value whose canonical text this is; nothing for a text no value has.
parseEnumText :: (Bounded a, Enum a) => (a -> T.Text) -> T.Text -> Maybe a
parseEnumText toText text =
  L.lookup text [(toText a, a) | a <- [minBound .. maxBound]]
