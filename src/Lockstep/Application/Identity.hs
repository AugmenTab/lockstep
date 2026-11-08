{- | Identity generation at the boundary (contract C-P2.1 I1): RFC 4122
version 4 UUIDs from the @uuid@ library ('V4.nextRandom', the system's
entropy). The Kernel only receives the resulting values.
-}
module Lockstep.Application.Identity
  ( newUuid
  , newIdentity
  , newRepositoryId
  , newEngineerId
  ) where

import Data.Coerce (Coercible, coerce)
import Data.UUID.V4 qualified as V4
import Flipstone.Prelude

import Lockstep.Kernel.Identity (EngineerId (..), RepositoryId (..), Uuid)

newUuid :: IO Uuid
newUuid =
  V4.nextRandom

-- | A new identity of any kind.
newIdentity :: Coercible Uuid identity => IO identity
newIdentity =
  coerce <$> newUuid

newRepositoryId :: IO RepositoryId
newRepositoryId =
  newIdentity

newEngineerId :: IO EngineerId
newEngineerId =
  newIdentity
