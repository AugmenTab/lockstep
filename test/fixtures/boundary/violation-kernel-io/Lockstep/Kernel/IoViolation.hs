-- | NEGATIVE FIXTURE (C-P2.1 I2): the Kernel must not run processes.
-- Henforcer must reject the System.Process import, and the purity scan must
-- find the IO token below.
module Lockstep.Kernel.IoViolation
  ( listing
  ) where

import Flipstone.Prelude
import System.Process (readProcess)

listing :: IO String
listing =
  readProcess "ls" [] ""
