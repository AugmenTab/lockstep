{- | The work policy of each kind of engineering work (contract C-P6.6 G1–G3,
G5): its class tag, its legitimate test-first rule, whether a reproduction is
expected, whether it is non-behavioural, its budgets, the checks every Profile
for it must hold (its floor), the built-in Profile that holds every floor, and
the classification of a changed path. Stub (the freeze's RED baseline).
-}
module Lockstep.Kernel.WorkPolicy
  ( TestFirst (..)
  , testFirstCode
  , WorkPolicy (..)
  , workPolicy
  , kindClass
  , kindFloor
  , engineeringProfileId
  , engineeringRaw
  , engineeringDefinition
  , missingChecks
  , pathClassOf
  , documentationOnly
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Plan (WorkKind (..))
import Lockstep.Kernel.Profile (Gate, PathClass (..), ProfileDefinition, ProfileRefusal, RawGate, RawProfile (..), mkProfileDefinition)

-- | The legitimate test-first behaviour of a kind.
data TestFirst
  = -- | At least one frozen test fails at the basis for its stated reason: what is asked is not there yet.
    RedFirst
  | -- | Every frozen test passes at the basis and must still pass: behaviour is kept.
    GreenOnly
  deriving (Eq, Show, Enum, Bounded)

testFirstCode :: TestFirst -> T.Text
testFirstCode _ =
  T.empty

data WorkPolicy
  = WorkPolicy
  { policyKind :: WorkKind
  , policyClass :: T.Text
  , policyTestFirst :: TestFirst
  , policyReproduction :: Bool
  -- ^ Whether the discovery may name a reproduction.
  , policyNonBehavioural :: Bool
  , policyCorrections :: Int
  , policyAttempts :: Int
  }
  deriving (Eq, Show)

workPolicy :: WorkKind -> WorkPolicy
workPolicy k =
  WorkPolicy k T.empty RedFirst True False 0 0

kindClass :: WorkKind -> T.Text
kindClass _ =
  T.empty

-- | The checks every Profile used for this kind must hold unchanged.
kindFloor :: WorkKind -> [RawGate]
kindFloor _ =
  []

engineeringProfileId :: T.Text
engineeringProfileId =
  T.pack "lockstep-engineering"

-- | The built-in Profile that holds every kind's floor.
engineeringRaw :: RawProfile
engineeringRaw =
  RawProfile
    { rawProfileId = engineeringProfileId
    , rawProfileVersion = 1
    , rawAllowsNonBehavioural = Nothing
    , rawInvariantExceptions = []
    , rawGates = []
    , rawSpecializations = []
    }

engineeringDefinition :: Either ProfileRefusal ProfileDefinition
engineeringDefinition =
  mkProfileDefinition engineeringRaw

-- | The kind's floor checks that are not among these gates unchanged, sorted by id.
missingChecks :: WorkKind -> [Gate] -> [T.Text]
missingChecks _ _ =
  []

-- | The class of a changed path, by its name.
pathClassOf :: T.Text -> PathClass
pathClassOf _ =
  PathDocs

-- | Whether every path is documentation.
documentationOnly :: [T.Text] -> Bool
documentationOnly _ =
  True
