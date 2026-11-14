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
import Data.List qualified as L
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show, show)

import Lockstep.Kernel.Enum (parseEnumText)
import Lockstep.Kernel.Identity (RepositoryId)
import Lockstep.Kernel.Profile (ContentDigest, Hasher (..))
import Lockstep.Kernel.Task (TaskRuleError, mkAcceptance, mkTaskTitle, taskRuleCode)

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
    Char.isAsciiUpper c || Char.isAsciiLower c || Char.isDigit c || c `L.elem` ("._:/#-" :: String)

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
acceptanceText =
  T.intercalate (T.pack "\n") . fmap line
 where
  line c =
    T.pack "- " <> criterionText c <> maybe T.empty (\r -> T.pack " (" <> r <> T.pack ")") (criterionRef c)

{- | The canonical content of an item, whose digest says whether it changed
(B4): its title, its criteria in order with their references, and its
blockers as a set. Neither the key nor the revision is content.
-}
itemContentText :: BacklogItem -> T.Text
itemContentText i =
  T.unlines $
    [T.pack "lockstep-backlog-item 1", T.pack "title " <> quoted (itemTitle i)]
      <> [ T.pack "criterion " <> quoted (criterionText c) <> T.pack " ref " <> maybe (T.pack "-") quoted (criterionRef c)
         | c <- itemCriteria i
         ]
      <> [T.pack "blocker " <> sourceKeyText b | b <- L.sort (L.nub (itemBlockers i))]

quoted :: T.Text -> T.Text
quoted text =
  T.pack "\"" <> T.concatMap escape text <> T.pack "\""
 where
  escape c =
    case c of
      '\\' -> T.pack "\\\\"
      '"' -> T.pack "\\\""
      '\n' -> T.pack "\\n"
      _ -> T.singleton c

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
  {- ^ The source items the task's dependencies reach as they stand now (a person's edits included), not what
  the source last said: the graph a cycle is checked against.
  -}
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
  | -- | The stored revision, then the given one.
    StaleRevision SourceRevision SourceRevision
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
itemRefusalCode refusal =
  case refusal of
    TitleInvalid e -> taskRuleCode e
    AcceptanceInvalid e -> taskRuleCode e
    CriterionInvalid -> T.pack "criterion-invalid"
    StaleRevision _ _ -> T.pack "stale-revision"
    RevisionReused _ -> T.pack "revision-reused"
    DanglingBlocker _ -> T.pack "dangling-blocker"
    BlockerRefused _ -> T.pack "blocker-refused"
    BlockerCycle -> T.pack "blocker-cycle"
    BlockerSelf -> T.pack "blocker-self"
    TooManyBlockers -> T.pack "too-many-blockers"
    LocallyEdited -> T.pack "locally-edited"
    LocallyProgressed -> T.pack "locally-progressed"

data DocumentRefusal
  = DuplicateKey SourceKey
  | -- | The last imported revision, then the given one.
    StaleDocument SourceRevision SourceRevision
  | TooManyItems Int
  deriving (Eq, Show)

documentRefusalCode :: DocumentRefusal -> T.Text
documentRefusalCode refusal =
  T.pack $
    case refusal of
      DuplicateKey _ -> "duplicate-key"
      StaleDocument _ _ -> "stale-document"
      TooManyItems _ -> "too-many-items"

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

{- | What an import does (B4–B7). The document as a whole is refused for too
many items, a repeated key, or a revision older than the last import. Each
item is then created, updated, unchanged or refused; an item is refused when
it is invalid, stale, a reused revision, would overwrite a task a person
changed, or when one of its blockers would not exist or closes a cycle. A
refusal can make the items it blocks refused too, so the outcomes are
settled until they no longer change.
-}
decideImport :: Hasher -> Maybe PriorImport -> BacklogDocument -> Either DocumentRefusal ImportDecision
decideImport hasher prior document
  | count > maxItems = Left (TooManyItems count)
  | Just key <- firstDuplicate (fmap itemKey items) = Left (DuplicateKey key)
  | Just p <- prior, priorRevision p > documentRevision document = Left (StaleDocument (priorRevision p) (documentRevision document))
  | otherwise =
      Right
        ImportDecision
          { decisionSource = documentSource document
          , decisionRevision = documentRevision document
          , decisionItems = [(itemKey i, Map.findWithDefault ItemCreated (itemKey i) settled) | i <- items]
          , decisionAbsent = L.sort [k | k <- Map.keys stored, not (Set.member k inDocument)]
          }
 where
  items = documentItems document
  count = L.length items
  stored = Map.fromList [(storedKey s, s) | s <- maybe [] priorItems prior]
  inDocument = Set.fromList (fmap itemKey items)
  initial = Map.fromList [(itemKey i, maybe (compared hasher stored i) ItemRefused (intrinsic i)) | i <- items]
  settled = settle stored items (count + 1) initial

firstDuplicate :: [SourceKey] -> Maybe SourceKey
firstDuplicate =
  go Set.empty
 where
  go _ [] = Nothing
  go seen (k : rest)
    | Set.member k seen = Just k
    | otherwise = go (Set.insert k seen) rest

-- | What is wrong with an item by itself, if anything (B7, B8, C-P3.6 task rules).
intrinsic :: BacklogItem -> Maybe ItemRefusal
intrinsic i
  | Left e <- mkTaskTitle (itemTitle i) = Just (TitleInvalid e)
  | L.any badCriterion (itemCriteria i) = Just CriterionInvalid
  | Left e <- mkAcceptance (acceptanceText (itemCriteria i)) = Just (AcceptanceInvalid e)
  | itemKey i `L.elem` itemBlockers i = Just BlockerSelf
  | L.length (L.nub (itemBlockers i)) > maxBlockers = Just TooManyBlockers
  | otherwise = Nothing
 where
  badCriterion c =
    T.null (T.strip (criterionText c)) || T.any Char.isControl (criterionText c) || maybe False badRef (criterionRef c)
  badRef r =
    T.null r || T.length r > 200 || T.any Char.isControl r

-- | The item against what was imported before (B4, B6).
compared :: Hasher -> Map.Map SourceKey StoredItem -> BacklogItem -> ItemOutcome
compared (Hasher digest) stored i =
  case Map.lookup (itemKey i) stored of
    Nothing -> ItemCreated
    Just s
      | storedRevision s > itemRevision i -> ItemRefused (StaleRevision (storedRevision s) (itemRevision i))
      | storedDigest s == digest (itemContentText i) -> ItemUnchanged
      | storedRevision s == itemRevision i -> ItemRefused (RevisionReused (itemRevision i))
      | otherwise ->
          case storedCondition s of
            LocalUntouched -> ItemUpdated
            LocalEdited -> ItemRefused LocallyEdited
            LocalProgressed -> ItemRefused LocallyProgressed

-- | Whether the outcome writes a task (and so needs its blockers to hold).
writes :: ItemOutcome -> Bool
writes outcome =
  case outcome of
    ItemCreated -> True
    ItemUpdated -> True
    _ -> False

refused :: ItemOutcome -> Bool
refused outcome =
  case outcome of
    ItemRefused _ -> True
    _ -> False

{- | Refuses writing items whose blockers would not exist, then those on a
blocker cycle, until nothing changes. Each round refuses at least one more
item or ends, so the fuel (one more than the number of items) is never the
reason it stops.
-}
settle :: Map.Map SourceKey StoredItem -> [BacklogItem] -> Int -> Map.Map SourceKey ItemOutcome -> Map.Map SourceKey ItemOutcome
settle stored items fuel outcomes
  | fuel <= 0 = outcomes
  | next == outcomes = outcomes
  | otherwise = settle stored items (fuel - 1) next
 where
  outcomeOf k = Map.lookup k outcomes
  -- A blocker holds when its task will exist: an item of this document that is not refused, or one imported before.
  exists k =
    maybe False (not . refused) (outcomeOf k) || Map.member k stored
  blockerProblem i =
    case L.find (not . exists) (L.nub (itemBlockers i)) of
      Nothing -> Nothing
      Just b
        | Map.member b outcomes -> Just (BlockerRefused b)
        | otherwise -> Just (DanglingBlocker b)
  afterBlockers =
    Map.fromList
      [ (itemKey i, o')
      | i <- items
      , let
          o = Map.findWithDefault ItemCreated (itemKey i) outcomes
          o' = if writes o then maybe o ItemRefused (blockerProblem i) else o
      ]
  -- The dependency graph as it would stand: written items' new blockers, otherwise the stored ones.
  graph =
    Map.fromList $
      [ (itemKey i, itemBlockers i)
      | i <- items
      , writes (Map.findWithDefault ItemCreated (itemKey i) afterBlockers)
      ]
        <> [ (storedKey s, storedBlockers s)
           | s <- Map.elems stored
           , not (maybe False writes (Map.lookup (storedKey s) afterBlockers))
           ]
  next =
    Map.mapWithKey (\k o -> if writes o && onCycle graph k then ItemRefused BlockerCycle else o) afterBlockers

-- | Whether a key can reach itself through the graph.
onCycle :: Map.Map SourceKey [SourceKey] -> SourceKey -> Bool
onCycle graph start =
  go Set.empty (successors start)
 where
  successors k = Map.findWithDefault [] k graph
  go _ [] = False
  go seen (x : rest)
    | x == start = True
    | Set.member x seen = go seen rest
    | otherwise = go (Set.insert x seen) (successors x <> rest)

-- | The decision as text (contract §1 "Decision rendering").
renderImportDecision :: ImportDecision -> T.Text
renderImportDecision d =
  T.unlines $
    [ T.pack "lockstep-backlog-import 1"
    , T.unwords
        [ T.pack "source"
        , sourceProviderCode (sourceProvider (decisionSource d))
        , sourceLocatorText (sourceLocator (decisionSource d))
        , T.pack "revision"
        , revisionText (decisionRevision d)
        ]
    ]
      <> fmap itemLine (decisionItems d)
      <> [T.pack "absent " <> sourceKeyText k | k <- decisionAbsent d]
 where
  itemLine (k, o) =
    T.unwords ([T.pack "item", sourceKeyText k] <> outcomeWords o)
  outcomeWords o =
    case o of
      ItemCreated -> [T.pack "created"]
      ItemUpdated -> [T.pack "updated"]
      ItemUnchanged -> [T.pack "unchanged"]
      ItemRefused r -> [T.pack "refused", itemRefusalCode r] <> refusalDetail r

refusalDetail :: ItemRefusal -> [T.Text]
refusalDetail refusal =
  case refusal of
    StaleRevision s g -> [T.pack "stored=" <> revisionText s, T.pack "given=" <> revisionText g]
    RevisionReused r -> [T.pack "revision=" <> revisionText r]
    DanglingBlocker k -> [sourceKeyText k]
    BlockerRefused k -> [sourceKeyText k]
    _ -> []

revisionText :: SourceRevision -> T.Text
revisionText (SourceRevision n) =
  T.pack (show n)
