{- | The Supervisor's Git rules (contract C-P4.4 G1). Pure: which paths a
snapshot or a change may name, the work branch of a Work Order, the
Supervisor's commit identity, and what a set of changes may contain. The
Git commands themselves are in 'Lockstep.Effects.GitSupervisor'.
-}
module Lockstep.Kernel.GitBasis
  ( TreeMode (..)
  , treeModeText
  , parseTreeMode
  , TreeEntry (..)
  , Change (..)
  , treePathValid
  , isCommitId
  , workBranch
  , supervisorName
  , supervisorEmail
  , checkChanges
  ) where

import Data.ByteString qualified as BS
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

-- | The modes a snapshot carries: a file, an executable file, a symbolic link.
data TreeMode
  = ModeFile
  | ModeExecutable
  | ModeSymlink
  deriving (Eq, Show)

treeModeText :: TreeMode -> T.Text
treeModeText mode =
  T.pack $
    case mode of
      ModeFile -> "100644"
      ModeExecutable -> "100755"
      ModeSymlink -> "120000"

parseTreeMode :: T.Text -> Maybe TreeMode
parseTreeMode text =
  L.lookup text [(treeModeText m, m) | m <- [ModeFile, ModeExecutable, ModeSymlink]]

-- | One entry of a commit's tree: its path, mode and blob id.
data TreeEntry
  = TreeEntry
  { entryPath :: T.Text
  , entryMode :: TreeMode
  , entryBlob :: T.Text
  }
  deriving (Eq, Show)

{- | A change to a regular file of the tree: its new mode and bytes, or its
removal ('Nothing').
-}
data Change
  = Change
  { changePath :: T.Text
  , changeContent :: Maybe (TreeMode, BS.ByteString)
  }
  deriving (Eq, Show)

{- | G1: a relative path of 1–4096 bytes, segments separated by @/@, no empty,
@.@ or @..@ segment, no segment that is @.git@ in any letter case, no
control character, no backslash.
-}
treePathValid :: T.Text -> Bool
treePathValid path =
  not (T.null path)
    && T.length path <= 4096
    && not (T.any (\c -> Char.isControl c || c == '\\') path)
    && L.all segmentValid (T.splitOn (T.pack "/") path)
 where
  segmentValid s =
    not (T.null s)
      && s /= T.pack "."
      && s /= T.pack ".."
      && T.toLower s /= T.pack ".git"

-- | Forty lower-case hex characters.
isCommitId :: T.Text -> Bool
isCommitId text =
  T.length text == 40 && T.all (\c -> Char.isDigit c || (c >= 'a' && c <= 'f')) text

-- | The Work Order's branch: @lockstep/<work order>@.
workBranch :: T.Text -> T.Text
workBranch workOrder =
  T.pack "lockstep/" <> workOrder

supervisorName :: T.Text
supervisorName =
  T.pack "Lockstep Supervisor"

supervisorEmail :: T.Text
supervisorEmail =
  T.pack "supervisor@lockstep.invalid"

{- | G4: a change set the Supervisor may commit. In order: @change-path-invalid@
(a path fails 'treePathValid'), @change-duplicated@ (a path twice),
@change-symlink@ (a change that makes a symbolic link), @change-empty@ (no
change at all).
-}
checkChanges :: [Change] -> Either T.Text [Change]
checkChanges changes
  | not (L.all (treePathValid . changePath) changes) = Left (T.pack "change-path-invalid")
  | L.nub paths /= paths = Left (T.pack "change-duplicated")
  | L.any ((== Just ModeSymlink) . fmap fst . changeContent) changes = Left (T.pack "change-symlink")
  | L.null changes = Left (T.pack "change-empty")
  | otherwise = Right changes
 where
  paths = fmap changePath changes
