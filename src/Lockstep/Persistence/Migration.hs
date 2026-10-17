{- | Explicit, ordered, forward-only migrations (ADR-0002 Q3) and the pure plan
that decides what to apply (contract C-P1.2 E4/E5).
-}
module Lockstep.Persistence.Migration
  ( MigrationId
  , mkMigrationId
  , migrationIdInt
  , Migration (..)
  , sequentialMigrations
  , Checksum
  , checksumText
  , mkChecksum
  , migrationChecksum
  , AppliedMigration (..)
  , MigrationRefusal (..)
  , planMigrations
  ) where

import Crypto.Hash qualified as Hash
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Text.Show (Show, show)

newtype MigrationId
  = MigrationId Int
  deriving (Eq, Ord, Show)

-- | Migration ids start at 1.
mkMigrationId :: Int -> Maybe MigrationId
mkMigrationId n =
  if n >= 1
    then Just (MigrationId n)
    else Nothing

migrationIdInt :: MigrationId -> Int
migrationIdInt (MigrationId n) =
  n

data Migration
  = Migration
  { migrationId :: MigrationId
  , migrationDescription :: T.Text
  , migrationSql :: T.Text
  }

{- | Numbers @(description, sql)@ pairs 1, 2, 3, ... so a production list is
ordered by construction.
-}
sequentialMigrations :: [(T.Text, T.Text)] -> [Migration]
sequentialMigrations =
  L.zipWith (\n (description, sql) -> Migration (MigrationId n) description sql) [1 ..]

-- | Lowercase hexadecimal SHA-256.
newtype Checksum
  = Checksum T.Text
  deriving (Eq, Show)

checksumText :: Checksum -> T.Text
checksumText (Checksum text) =
  text

-- | A checksum as stored in the ledger.
mkChecksum :: T.Text -> Checksum
mkChecksum =
  Checksum

migrationChecksum :: Migration -> Checksum
migrationChecksum migration =
  Checksum . T.pack . show $
    Hash.hashWith Hash.SHA256 (TE.encodeUtf8 (migrationSql migration))

data AppliedMigration
  = AppliedMigration
  { appliedId :: MigrationId
  , appliedChecksum :: Checksum
  }

data MigrationRefusal
  = InvalidMigrationList
  | ChecksumMismatch MigrationId
  | UnknownAppliedMigration MigrationId
  | MissingAppliedMigration MigrationId
  deriving (Eq, Show)

{- | The migrations still to apply, in order. The ledger must be exactly a prefix
of the list, with matching checksums; anything else is refused and nothing is
applied.
-}
planMigrations :: [Migration] -> [AppliedMigration] -> Either MigrationRefusal [Migration]
planMigrations list applied =
  let
    ids = fmap migrationId list
    increasing = L.and (L.zipWith (<) ids (L.drop 1 ids))

    go pending ledger =
      case (pending, ledger) of
        (_, []) ->
          Right pending
        ([], a : _) ->
          Left (UnknownAppliedMigration (appliedId a))
        (m : pending', a : ledger')
          | appliedId a == migrationId m ->
              if appliedChecksum a == migrationChecksum m
                then go pending' ledger'
                else Left (ChecksumMismatch (migrationId m))
          | appliedId a > migrationId m ->
              Left (MissingAppliedMigration (migrationId m))
          | otherwise ->
              Left (UnknownAppliedMigration (appliedId a))
  in
    if increasing
      then go list (L.sortOn appliedId applied)
      else Left InvalidMigrationList
