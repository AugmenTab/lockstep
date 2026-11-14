{- | The project's Progress page (contract C-P6.2 C2, C4, C5, C7): a read-only
fragment rendered from a 'ProgressView'.
-}
module Lockstep.Web.ProgressPage
  ( progressPage
  ) where

import Data.ByteString.Lazy qualified as LBS
import Flipstone.Prelude

import Lockstep.Application.Progress (ProgressView)

progressPage :: ProgressView -> LBS.ByteString
progressPage =
  const LBS.empty
