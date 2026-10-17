-- | NEGATIVE FIXTURE (added in the P1.2 implementation, after the test freeze).
-- Web must reach the database only through Application (ARCHITECTURE §2);
-- scripts/check requires Henforcer to reject this import.
module Lockstep.Web.PersistenceViolation
  ( migrationCount
  ) where

import Flipstone.Prelude

import Lockstep.Persistence.Migrations (migrations)

migrationCount :: Int
migrationCount =
  length migrations
