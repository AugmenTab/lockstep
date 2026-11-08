{- | Stable typed identities (contract C-P2.1 I1, DG-03 D-3.1a). Each kind is
its own newtype over an abstract UUID, so one kind cannot be passed where
another is expected. Identities are generated at the boundary and enter the
Kernel as values; none is derived from a path, remote or commit.
-}
module Lockstep.Kernel.Identity
  ( Uuid
  , IdentityError (..)
  , parseUuid
  , uuidText
  , uuidFromBytes
  , uuidFromWords
  , RepositoryId (..)
  , EngineerId (..)
  , TicketId (..)
  , WorkOrderId (..)
  , WorkUnitId (..)
  , ContractId (..)
  , AttemptId (..)
  ) where

import Data.ByteString qualified as BS
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

-- | A 128-bit identifier, held as two big-endian 64-bit halves.
data Uuid
  = Uuid Word64 Word64
  deriving (Eq, Ord, Show)

data IdentityError
  = UuidMalformed
  | UuidWrongLength
  deriving (Eq, Show)

newtype RepositoryId
  = RepositoryId Uuid
  deriving (Eq, Ord, Show)

newtype EngineerId
  = EngineerId Uuid
  deriving (Eq, Ord, Show)

newtype TicketId
  = TicketId Uuid
  deriving (Eq, Ord, Show)

newtype WorkOrderId
  = WorkOrderId Uuid
  deriving (Eq, Ord, Show)

newtype WorkUnitId
  = WorkUnitId Uuid
  deriving (Eq, Ord, Show)

newtype ContractId
  = ContractId Uuid
  deriving (Eq, Ord, Show)

newtype AttemptId
  = AttemptId Uuid
  deriving (Eq, Ord, Show)

uuidFromWords :: Word64 -> Word64 -> Uuid
uuidFromWords =
  Uuid

-- | Exactly 16 bytes, big-endian.
uuidFromBytes :: BS.ByteString -> Either IdentityError Uuid
uuidFromBytes bytes =
  if BS.length bytes /= 16
    then Left UuidWrongLength
    else
      let
        word = BS.foldl' (\acc b -> acc * 256 + fromIntegral b) 0
      in
        Right (Uuid (word (BS.take 8 bytes)) (word (BS.drop 8 bytes)))

{- | The canonical form only: lowercase hex in 8-4-4-4-12 groups. Anything
else, including uppercase, is 'UuidMalformed'.
-}
parseUuid :: T.Text -> Either IdentityError Uuid
parseUuid text =
  let
    groups = T.splitOn (T.pack "-") text
    hex = T.concat groups
  in
    if fmap T.length groups == [8, 4, 4, 4, 12] && T.all isLowerHex hex
      then Right (Uuid (hexWord (T.take 16 hex)) (hexWord (T.drop 16 hex)))
      else Left UuidMalformed

isLowerHex :: Char -> Bool
isLowerHex c =
  Char.isDigit c || (c >= 'a' && c <= 'f')

hexWord :: T.Text -> Word64
hexWord =
  T.foldl' (\acc c -> acc * 16 + fromIntegral (Char.digitToInt c)) 0

uuidText :: Uuid -> T.Text
uuidText (Uuid high low) =
  let
    digits = T.pack (hexDigits high <> hexDigits low)
  in
    T.intercalate
      (T.pack "-")
      [ T.take 8 digits
      , T.take 4 (T.drop 8 digits)
      , T.take 4 (T.drop 12 digits)
      , T.take 4 (T.drop 16 digits)
      , T.drop 20 digits
      ]

-- | Sixteen lowercase hex digits.
hexDigits :: Word64 -> String
hexDigits word =
  L.reverse (L.take 16 (L.unfoldr (\w -> Just (Char.intToDigit (fromIntegral (w `mod` 16)), w `div` 16)) word))
