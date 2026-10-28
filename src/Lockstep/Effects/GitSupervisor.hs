{- | The Supervisor's Git boundary (contract C-P4.4 G2–G6). Pre-freeze stub:
the final types, every operation refused with @not-implemented@; 'blobId' is
real (pure).
-}
module Lockstep.Effects.GitSupervisor
  ( Basis (..)
  , observeBasis
  , createWorkBranch
  , branchHead
  , treeEntries
  , writeSnapshot
  , snapshotChanges
  , CommitMeta (..)
  , commitChanges
  , advanceBranch
  , blobId
  ) where

import Crypto.Hash (SHA1 (SHA1), hashWith)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import System.IO (FilePath)
import Text.Show (Show, show)

import Lockstep.Kernel.GitBasis (Change, TreeEntry)

data Basis
  = Basis
  { basisCommit :: T.Text
  , basisTree :: T.Text
  }
  deriving (Eq, Show)

data CommitMeta
  = CommitMeta
  { metaMessage :: T.Text
  , metaEpoch :: Integer
  }
  deriving (Eq, Show)

notImplemented :: IO (Either T.Text a)
notImplemented =
  pure (Left (T.pack "not-implemented"))

observeBasis :: FilePath -> IO (Either T.Text Basis)
observeBasis _ =
  notImplemented

branchHead :: FilePath -> T.Text -> IO (Either T.Text (Maybe T.Text))
branchHead _ _ =
  notImplemented

createWorkBranch :: FilePath -> T.Text -> T.Text -> IO (Either T.Text ())
createWorkBranch _ _ _ =
  notImplemented

advanceBranch :: FilePath -> T.Text -> T.Text -> T.Text -> IO (Either T.Text ())
advanceBranch _ _ _ _ =
  notImplemented

treeEntries :: FilePath -> T.Text -> IO (Either T.Text ([TreeEntry], [T.Text]))
treeEntries _ _ =
  notImplemented

writeSnapshot :: FilePath -> T.Text -> FilePath -> IO (Either T.Text [TreeEntry])
writeSnapshot _ _ _ =
  notImplemented

snapshotChanges :: [TreeEntry] -> FilePath -> IO (Either T.Text [Change])
snapshotChanges _ _ =
  notImplemented

commitChanges :: FilePath -> T.Text -> [Change] -> CommitMeta -> IO (Either T.Text T.Text)
commitChanges _ _ _ _ =
  notImplemented

-- | Git's blob id of these bytes (SHA-1 of @blob <size>\\0@ and the bytes).
blobId :: BS.ByteString -> T.Text
blobId bytes =
  TE.decodeLatin1 (convertToBase Base16 (hashWith SHA1 (BS8.pack ("blob " <> show (BS.length bytes)) <> BS.singleton 0 <> bytes)))
