{- | Update 2 R6.4: the effective checks a handed-over task runs under. Stub. -}
module Lockstep.Application.EffectiveChecks
  ( EffectiveChecks (..)
  , effectiveChecksOf
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason)

data EffectiveChecks
  = EffectiveChecks
  { checksProfile :: T.Text
  , checksVersion :: Int
  , checksKind :: T.Text
  , checksFloor :: [(T.Text, T.Text)]
  -- ^ Each floor check of the kind and how the bound checks hold it.
  , checksExceptions :: [T.Text]
  , checksCorrections :: Int
  , checksAttempts :: Int
  , checksNonBehavioural :: Bool
  }
  deriving (Eq, Show)

-- | Stub.
effectiveChecksOf :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Maybe EffectiveChecks))
effectiveChecksOf _ _ =
  pure (Right Nothing)
