{- | Canonical backlog intake (contract C-P6.1 B2–B9): the identities of a
work source and its items, the canonical item, and the pure decision of what
an import does to the items already imported. An imported item becomes an
ordinary task; nothing here creates, schedules or authorizes work. Pure.
-}
module Lockstep.Kernel.Backlog
  ( -- * Sources and items
    SourceProvider (..)
  , sourceProviderCode
  , parseSourceProvider
  , SourceLocator
  , mkSourceLocator
  , sourceLocatorText
  , SourceKey
  , mkSourceKey
  , sourceKeyText
  , SourceRevision
  , mkSourceRevision
  , sourceRevisionValue
  , SourceIdentity (..)
  , Criterion (..)
  , BacklogItem (..)
  , BacklogDocument (..)
  , maxItems
  , maxBlockers
  , acceptanceText
  , itemContentText

    -- * What is already imported
  , LocalCondition (..)
  , StoredItem (..)
  , PriorImport (..)

    -- * The decision
  , ItemOutcome (..)
  , ItemRefusal (..)
  , itemRefusalCode
  , DocumentRefusal (..)
  , documentRefusalCode
  , ImportDecision (..)
  , decideImport
  , renderImportDecision
  ) where

import Data.Char qualified as Char
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Enum (parseEnumText)
import Lockstep.Kernel.Identity (RepositoryId)
import Lockstep.Kernel.Profile (ContentDigest, Hasher)
import Lockstep.Kernel.Task (TaskRuleError)

-- Sources and items ------------------------------------------------------------

-- | Where a backlog comes from (B2). @canonical@ is Lockstep's own format.
data SourceProvider
  = ProviderCanonical
  | ProviderJira
  | ProviderShortcut
  deriving (Eq, Ord, Show, Enum, Bounded)

sourceProviderCode :: SourceProvider -> T.Text
sourceProviderCode provider =
  T.pack $
    case provider of
      ProviderCanonical -> "canonical"
      ProviderJira -> "jira"
      ProviderShortcut -> "shortcut"

parseSourceProvider :: T.Text -> Maybe SourceProvider
parseSourceProvider =
  parseEnumText sourceProviderCode

-- | Which instance of a provider: 1–200 characters, no control character or space.
newtype SourceLocator
  = SourceLocator T.Text
  deriving (Eq, Ord, Show)

mkSourceLocator :: T.Text -> Maybe SourceLocator
mkSourceLocator text =
  if T.null text || T.length text > 200 || T.any (\c -> Char.isControl c || Char.isSpace c) text
    then Nothing
    else Just (SourceLocator text)

sourceLocatorText :: SourceLocator -> T.Text
sourceLocatorText (SourceLocator text) =
  text

-- | An item's key at its source: 1–100 of @A-Z a-z 0-9 . _ : / # -@.
newtype SourceKey
  = SourceKey T.Text
  deriving (Eq, Ord, Show)

mkSourceKey :: T.Text -> Maybe SourceKey
mkSourceKey text =
  if T.null text || T.length text > 100 || not (T.all keyChar text)
    then Nothing
    else Just (SourceKey text)
 where
  keyChar c =
    Char.isAsciiUpper c || Char.isAsciiLower c || Char.isDigit c || c `elem` ("._:/#-" :: String)

sourceKeyText :: SourceKey -> T.Text
sourceKeyText (SourceKey text) =
  text

-- | A revision at the source: a non-negative number that only grows there.
newtype SourceRevision
  = SourceRevision Int64
  deriving (Eq, Ord, Show)

mkSourceRevision :: Integer -> Maybe SourceRevision
mkSourceRevision n =
  if n < 0 || n > toInteger (maxBound :: Int64)
    then Nothing
    else Just (SourceRevision (fromInteger n))

sourceRevisionValue :: SourceRevision -> Int64
sourceRevisionValue (SourceRevision n) =
  n

data SourceIdentity
  = SourceIdentity
  { sourceProvider :: SourceProvider
  , sourceLocator :: SourceLocator
  }
  deriving (Eq, Ord, Show)

-- | One acceptance criterion and, optionally, where at the source it is written.
data Criterion
  = Criterion
  { criterionText :: T.Text
  , criterionRef :: Maybe T.Text
  }
  deriving (Eq, Show)

data BacklogItem
  = BacklogItem
  { itemKey :: SourceKey
  , itemRevision :: SourceRevision
  , itemTitle :: T.Text
  , itemCriteria :: [Criterion]
  , itemBlockers :: [SourceKey]
  }
  deriving (Eq, Show)

data BacklogDocument
  = BacklogDocument
  { documentSource :: SourceIdentity
  , documentRevision :: SourceRevision
  , documentRepository :: Maybe RepositoryId
  , documentItems :: [BacklogItem]
  }
  deriving (Eq, Show)

maxItems :: Int
maxItems =
  500

maxBlockers :: Int
maxBlockers =
  20

-- | B8: the task's acceptance text, one criterion a line, @- text (ref)@.
acceptanceText :: [Criterion] -> T.Text
acceptanceText _ =
  T.empty

-- | The canonical content of an item, whose digest says whether it changed (B4).
itemContentText :: BacklogItem -> T.Text
itemContentText _ =
  T.empty

-- What is already imported ---------------------------------------------------

-- | Whether the task an item became is still as the import left it (B6).
data LocalCondition
  = LocalUntouched
  | LocalEdited
  | LocalProgressed
  deriving (Eq, Show)

data StoredItem
  = StoredItem
  { storedKey :: SourceKey
  , storedRevision :: SourceRevision
  , storedDigest :: ContentDigest
  , storedBlockers :: [SourceKey]
  , storedCondition :: LocalCondition
  }
  deriving (Eq, Show)

data PriorImport
  = PriorImport
  { priorRevision :: SourceRevision
  , priorItems :: [StoredItem]
  }
  deriving (Eq, Show)

-- The decision -----------------------------------------------------------------

data ItemOutcome
  = ItemCreated
  | ItemUpdated
  | ItemUnchanged
  | ItemRefused ItemRefusal
  deriving (Eq, Show)

data ItemRefusal
  = TitleInvalid TaskRuleError
  | AcceptanceInvalid TaskRuleError
  | CriterionInvalid
  | StaleRevision SourceRevision SourceRevision
  | RevisionReused SourceRevision
  | DanglingBlocker SourceKey
  | BlockerRefused SourceKey
  | BlockerCycle
  | BlockerSelf
  | TooManyBlockers
  | LocallyEdited
  | LocallyProgressed
  deriving (Eq, Show)

itemRefusalCode :: ItemRefusal -> T.Text
itemRefusalCode _ =
  T.empty

data DocumentRefusal
  = DuplicateKey SourceKey
  | StaleDocument SourceRevision SourceRevision
  | TooManyItems Int
  deriving (Eq, Show)

documentRefusalCode :: DocumentRefusal -> T.Text
documentRefusalCode _ =
  T.empty

data ImportDecision
  = ImportDecision
  { decisionSource :: SourceIdentity
  , decisionRevision :: SourceRevision
  , decisionItems :: [(SourceKey, ItemOutcome)]
  -- ^ In document order.
  , decisionAbsent :: [SourceKey]
  -- ^ Imported before, not in this document; in key order. Nothing is deleted.
  }
  deriving (Eq, Show)

decideImport :: Hasher -> Maybe PriorImport -> BacklogDocument -> Either DocumentRefusal ImportDecision
decideImport _ _ document =
  Right (ImportDecision (documentSource document) (documentRevision document) [] [])

renderImportDecision :: ImportDecision -> T.Text
renderImportDecision _ =
  T.empty
