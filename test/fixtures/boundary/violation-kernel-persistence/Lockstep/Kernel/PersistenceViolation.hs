-- | NEGATIVE FIXTURE (C-P2.1 I2): the Kernel must not import another layer.
-- Henforcer must reject the Persistence import.
module Lockstep.Kernel.PersistenceViolation
  ( migrationCount
  ) where

import Flipstone.Prelude

import Lockstep.Persistence.Migrations (migrations)

migrationCount :: Int
migrationCount =
  length migrations
