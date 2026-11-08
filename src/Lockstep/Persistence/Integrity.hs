{- | A database integrity violation: stored or just-written state that the
application's invariants say cannot exist (a row that must be there and is
not, a statement that must return a row and returned none).

Raised inside an Orville action it aborts the enclosing transaction, so a
half-written change is rolled back instead of committed with a stand-in
value. 'Lockstep.Application.Database.withDatabase' reports it as a database
error; the description names what was violated.
-}
module Lockstep.Persistence.Integrity
  ( IntegrityViolation (..)
  , integrityViolation
  ) where

import Control.Exception (Exception, throwIO)
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

-- | What was violated, for diagnosis.
newtype IntegrityViolation
  = IntegrityViolation T.Text
  deriving (Eq, Show)

instance Exception IntegrityViolation

-- | Aborts the current action (and its transaction) with the violation.
integrityViolation :: MonadIO m => String -> m a
integrityViolation =
  liftIO . throwIO . IntegrityViolation . T.pack
