{- | Pure task rules (contract C-P3.6 K3, K4, K7): a task's title, what done
looks like, how much it matters, where it stands (from the facts the database
holds), the most important task that is ready, dependency cycles, and the plain
words shown for each. No Ticket, Work Order, Engineer or scheduler word reaches
the person (PRD FR-UX-06).
-}
module Lockstep.Kernel.Task
  ( TaskTitle
  , mkTaskTitle
  , taskTitleText
  , mkAcceptance
  , TaskRuleError (..)
  , taskRuleCode
  , Priority (..)
  , priorityValue
  , priorityOf
  , parsePriority
  , priorityCode
  , priorityWords
  , DependencyFact (..)
  , TaskFacts (..)
  , TaskReadiness (..)
  , taskReadiness
  , readinessWords
  , mostImportantReady
  , createsCycle
  , taskRefusalCodes
  , taskRefusalWords
  ) where

import Data.Bifunctor (bimap)
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

newtype TaskTitle
  = TaskTitle T.Text
  deriving (Eq, Show)

data TaskRuleError
  = TitleEmpty
  | TitleTooLong
  | TitleHasControl
  | AcceptanceTooLong
  | AcceptanceHasControl
  deriving (Eq, Show)

-- | 1 to 200 characters after trimming, no control character (the C-P2.2 title rule).
mkTaskTitle :: T.Text -> Either TaskRuleError TaskTitle
mkTaskTitle raw =
  let
    title = T.strip raw
  in
    if T.null title
      then Left TitleEmpty
      else
        if T.any Char.isControl title
          then Left TitleHasControl
          else
            if T.length title > 200
              then Left TitleTooLong
              else Right (TaskTitle title)

taskTitleText :: TaskTitle -> T.Text
taskTitleText (TaskTitle t) =
  t

-- | At most 4000 characters after trimming, @\\r\\n@ as @\\n@; new lines and tabs are kept.
mkAcceptance :: T.Text -> Either TaskRuleError T.Text
mkAcceptance raw =
  let
    text = T.strip (T.replace (T.pack "\r\n") (T.pack "\n") raw)
  in
    if T.any (\c -> Char.isControl c && c /= '\n' && c /= '\t') text
      then Left AcceptanceHasControl
      else
        if T.length text > 4000
          then Left AcceptanceTooLong
          else Right text

taskRuleCode :: TaskRuleError -> T.Text
taskRuleCode e =
  T.pack $
    case e of
      TitleEmpty -> "title-empty"
      TitleTooLong -> "title-too-long"
      TitleHasControl -> "title-control"
      AcceptanceTooLong -> "acceptance-too-long"
      AcceptanceHasControl -> "acceptance-control"

data Priority
  = High
  | Normal
  | Low
  deriving (Eq, Show, Enum, Bounded)

priorityValue :: Priority -> Int
priorityValue p =
  case p of
    High -> 800
    Normal -> 500
    Low -> 200

-- | A stored value read back by band: 700 or more is High, 400 or more Normal, else Low.
priorityOf :: Int -> Priority
priorityOf n
  | n >= 700 = High
  | n >= 400 = Normal
  | otherwise = Low

priorityCode :: Priority -> T.Text
priorityCode p =
  T.pack $
    case p of
      High -> "high"
      Normal -> "normal"
      Low -> "low"

parsePriority :: T.Text -> Maybe Priority
parsePriority code =
  L.find ((== code) . priorityCode) [minBound .. maxBound]

priorityWords :: Priority -> T.Text
priorityWords p =
  T.pack $
    case p of
      High -> "High"
      Normal -> "Normal"
      Low -> "Low"

-- | A task this one depends on: its title and its state name (as C-P2.2 names it).
data DependencyFact
  = DependencyFact
  { dependencyTitle :: T.Text
  , dependencyState :: T.Text
  }
  deriving (Eq, Show)

data TaskFacts
  = TaskFacts
  { factState :: T.Text
  , factBlockReason :: Maybe T.Text
  , factDependencies :: [DependencyFact]
  }
  deriving (Eq, Show)

data TaskReadiness
  = NotYetReady
  | ReadyToWork
  | WaitingFor [T.Text]
  | BlockedBecause T.Text
  | CannotStart [T.Text]
  | Finished
  | TaskCanceled
  | BeingWorkedOn
  deriving (Eq, Show)

-- | Where a task stands, in the order of contract K4.
taskReadiness :: TaskFacts -> TaskReadiness
taskReadiness facts =
  let
    state = T.unpack (factState facts)
    titlesWhere p = [dependencyTitle d | d <- factDependencies facts, p (T.unpack (dependencyState d))]
    canceledDeps = titlesWhere (== "canceled")
    unfinished = titlesWhere (`L.notElem` ["done", "canceled"])
  in
    case state of
      "canceled" -> TaskCanceled
      "done" -> Finished
      "blocked" -> BlockedBecause (fromMaybe T.empty (factBlockReason facts))
      _
        | not (L.null canceledDeps) -> CannotStart canceledDeps
        | state == "proposed" -> NotYetReady
        | not (L.null unfinished) -> WaitingFor unfinished
        | state == "ready" -> ReadyToWork
        | otherwise -> BeingWorkedOn

readinessWords :: TaskReadiness -> T.Text
readinessWords readiness =
  case readiness of
    NotYetReady -> T.pack "Not yet ready to work on."
    ReadyToWork -> T.pack "Ready to work on."
    WaitingFor titles -> T.pack "Waiting for: " <> T.intercalate (T.pack ", ") titles <> T.pack "."
    BlockedBecause reason -> T.pack "Blocked: " <> (if T.null reason then T.pack "no reason was given." else reason)
    CannotStart titles -> T.pack "Cannot start: a task it needs was canceled (" <> T.intercalate (T.pack ", ") titles <> T.pack ")."
    Finished -> T.pack "Finished."
    TaskCanceled -> T.pack "Canceled."
    BeingWorkedOn -> T.pack "Being worked on."

{- | The highest-priority task that is ready to work on, then the oldest (the
lowest creation order); a blocked or waiting task is never chosen, whatever its
priority.
-}
mostImportantReady :: [(a, Int, Int, TaskReadiness)] -> Maybe a
mostImportantReady tasks =
  case L.sortOn (\(_, priority, order, _) -> (negate priority, order)) [t | t@(_, _, _, ReadyToWork) <- tasks] of
    (a, _, _, _) : _ -> Just a
    [] -> Nothing

{- | Whether giving @task@ exactly these dependencies would close a loop, given
the other edges (task, depends on); the task's own current edges are replaced.
-}
createsCycle :: [(T.Text, T.Text)] -> T.Text -> [T.Text] -> Bool
createsCycle edges task deps =
  let
    others = [e | e@(from, _) <- edges, from /= task]
    reaches seen from =
      from == task
        || ( from `L.notElem` seen
               && L.any (reaches (from : seen)) [to | (f, to) <- others, f == from]
           )
  in
    L.any (reaches []) deps

refusals :: [(T.Text, T.Text)]
refusals =
  fmap
    (bimap T.pack T.pack)
    [ ("title-empty", "Say what needs doing.")
    , ("title-too-long", "What needs doing can be at most 200 characters long; put the details in what done looks like.")
    , ("title-control", "What needs doing is one line of text.")
    , ("acceptance-too-long", "What done looks like can be at most 4000 characters long.")
    , ("acceptance-control", "What done looks like contains characters that cannot be shown.")
    , ("unknown-priority", "Choose how much it matters: High, Normal or Low.")
    , ("unknown-dependency", "One of the tasks it should wait for is not a task of this project.")
    , ("dependency-self", "A task cannot wait for itself.")
    , ("dependency-cycle", "That would make tasks wait for each other in a circle, so none could ever start.")
    , ("too-many-dependencies", "A task can wait for at most 20 other tasks.")
    , ("stale-revision", "This task changed since this page was shown. Nothing was changed; the page now shows it as it is.")
    , ("unknown-task", "Lockstep has no such task.")
    , ("unknown-project", "Lockstep has no such project.")
    , ("not-allowed-now", "That cannot be done to the task as it is now. The page shows what can.")
    , ("reason-empty", "Say why it is blocked, so whoever looks at it next knows.")
    , ("key-conflict", "This form was already used for another project. Nothing was changed. Open New task again.")
    , ("revision-out-of-range", "Lockstep could not read this form. Try again.")
    ]

taskRefusalCodes :: [T.Text]
taskRefusalCodes =
  fmap fst refusals

taskRefusalWords :: T.Text -> T.Text
taskRefusalWords code =
  fromMaybe (T.pack "Something went wrong. The exact reason is under Technical details.") (L.lookup code refusals)
