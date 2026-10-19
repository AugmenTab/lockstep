-- | POSITIVE CONTROL for the Kernel boundary fixtures (C-P2.1 I2): a pure
-- Kernel module importing the prelude, text and another Kernel module must
-- compile with the same command.
module Lockstep.Kernel.KernelControl
  ( identityLength
  ) where

import Data.Text qualified as T
import Flipstone.Prelude

import Lockstep.Kernel.Identity (uuidFromWords, uuidText)

identityLength :: Int
identityLength =
  T.length (uuidText (uuidFromWords 0 0))
