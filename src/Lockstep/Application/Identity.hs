{- | Identity generation at the boundary (contract C-P2.1 I1): 16 bytes from
the CSPRNG with the RFC 4122 version 4 and variant bits set. The Kernel only
receives the resulting values.
-}
module Lockstep.Application.Identity
  ( newUuid
  , newRepositoryId
  , newEngineerId
  ) where

import Crypto.Random (getRandomBytes)
import Data.Bits ((.&.), (.|.))
import Data.ByteString qualified as BS
import Data.List qualified as L
import Flipstone.Prelude

import Lockstep.Kernel.Identity (EngineerId (..), RepositoryId (..), Uuid, uuidFromBytes, uuidFromWords)

newUuid :: IO Uuid
newUuid = do
  bytes <- getRandomBytes 16 :: IO BS.ByteString
  let
    versioned =
      BS.pack
        ( L.zipWith
            ( \i b -> case i :: Int of
                6 -> (b .&. 0x0f) .|. 0x40
                8 -> (b .&. 0x3f) .|. 0x80
                _ -> b
            )
            [0 ..]
            (BS.unpack bytes)
        )
  -- 16 bytes always decode; the fallback only satisfies totality.
  pure (fromRight (uuidFromWords 0 0) (uuidFromBytes versioned))

newRepositoryId :: IO RepositoryId
newRepositoryId =
  RepositoryId <$> newUuid

newEngineerId :: IO EngineerId
newEngineerId =
  EngineerId <$> newUuid
