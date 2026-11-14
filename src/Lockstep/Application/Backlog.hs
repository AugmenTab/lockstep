{- | Importing and exporting a project's backlog (contract C-P6.1 B1–B13). An
imported item becomes an ordinary task, made by the same storage steps as
'Lockstep.Application.Tasks.createTask' (a C-P2.2 Ticket, its task row and
its dependencies), with its provenance beside it. The import is one
transaction under the task lock and the source lock, and everything it would
refuse is refused before anything is written. Nothing here creates a Work
Order, schedules or runs anything.
-}
module Lockstep.Application.Backlog
  ( ImportReport (..)
  , TaskSource (..)
  , importBacklog
  , importBacklogDocument
  , importJiraSearch
  , importBacklogFile
  , exportBacklog
  , taskSources
  ) where

import Control.Applicative ((<|>))
import Control.Exception.Safe (tryIO)
import Crypto.Hash (SHA256 (SHA256), hashWith)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isNothing, mapMaybe)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import System.IO (FilePath)
import Text.Show (Show)

import Lockstep.Application.BacklogDocument (criteriaText, decodeBacklogDocument, decodeCriteria, documentErrorCode, encodeBacklogDocument)
import Lockstep.Application.BacklogJira (fromJiraSearch)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason, Readiness (..), checkReadiness, withDatabase)
import Lockstep.Application.Identity (newUuid)
import Lockstep.Application.Ledger (createTicketIn, reviseTicketIn, ticketFactsIn)
import Lockstep.Application.LedgerRefusal (LedgerError (..), ledgerRefusalCode)
import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Application.Tasks (requestDigest)
import Lockstep.Kernel.Backlog
  ( BacklogDocument (..)
  , BacklogItem (..)
  , Criterion (..)
  , ImportDecision (..)
  , ItemOutcome (..)
  , LocalCondition (..)
  , PriorImport (..)
  , SourceIdentity (..)
  , SourceKey
  , SourceProvider (ProviderCanonical)
  , StoredItem (..)
  , acceptanceText
  , decideImport
  , documentRefusalCode
  , itemContentText
  , maxItems
  , mkSourceKey
  , mkSourceLocator
  , mkSourceRevision
  , renderImportDecision
  , sourceKeyText
  , sourceLocatorText
  , sourceRevisionValue
  )
import Lockstep.Kernel.Identity (BacklogSourceId (..), ProjectId (..), TaskId (..), TicketId (..), identityText, parseIdentity)
import Lockstep.Kernel.Profile (Hasher (..), contentDigestText, mkContentDigest)
import Lockstep.Kernel.Task (Priority (Normal), createsCycleOf, mkTaskTitle, priorityValue)
import Lockstep.Persistence.Backlog qualified as Store
import Lockstep.Persistence.Execution (projectRepository)
import Lockstep.Persistence.Integrity (integrityViolation)
import Lockstep.Persistence.Projects qualified as Projects
import Lockstep.Persistence.Tasks qualified as Tasks

data ImportReport
  = ImportReport
  { reportDecision :: ImportDecision
  , reportRendered :: T.Text
  , reportTasks :: [(SourceKey, TaskId)]
  -- ^ The task each created, updated or unchanged item is, in document order.
  }
  deriving (Eq, Show)

-- | Where an imported task came from (B8).
data TaskSource
  = TaskSource
  { taskSourceTask :: TaskId
  , taskSourceProvider :: SourceProvider
  , taskSourceLocator :: T.Text
  , taskSourceKey :: T.Text
  , taskSourceRevision :: Int64
  , taskSourceCriteria :: [Criterion]
  }
  deriving (Eq, Show)

whenReady :: DatabaseRuntime -> IO (Either NotReadyReason a) -> IO (Either NotReadyReason a)
whenReady runtime action = do
  readiness <- checkReadiness (Just runtime)
  case readiness of
    NotReady reason -> pure (Left reason)
    Ready _ -> action

refuse :: String -> Either T.Text a
refuse =
  Left . T.pack

-- | A Ledger step inside the import: a refusal is its code; stored state that does not replay aborts.
ledgerStep :: Either LedgerError a -> O.Orville (Either T.Text a)
ledgerStep result =
  case result of
    Right value -> pure (Right value)
    Left (LedgerRefusedBy refusal) -> pure (Left (ledgerRefusalCode refusal))
    Left (LedgerCorrupt message) -> integrityViolation (T.unpack message)

taskTicket :: TaskId -> TicketId
taskTicket (TaskId u) =
  TicketId u

sha256Hex :: T.Text -> T.Text
sha256Hex text =
  case sha256Hasher of
    Hasher f -> contentDigestText (f text)

bytesDigest :: LBS.ByteString -> T.Text
bytesDigest =
  TE.decodeLatin1 . convertToBase Base16 . hashWith SHA256 . LBS.toStrict

-- | A canonical document's bytes into a project; the refusal is its code.
importBacklog :: DatabaseRuntime -> T.Text -> LBS.ByteString -> IO (Either NotReadyReason (Either T.Text ImportReport))
importBacklog runtime rawProject bytes =
  case decodeBacklogDocument bytes of
    Left e -> whenReady runtime (pure (Right (Left (documentErrorCode e))))
    Right document -> importBacklogDocument runtime rawProject (bytesDigest bytes) document

{- | B14: a file into a project — a canonical document, or with a Jira
locator a Jira search response; @file-unreadable@ when it cannot be read.
-}
importBacklogFile :: DatabaseRuntime -> T.Text -> Maybe T.Text -> FilePath -> IO (Either NotReadyReason (Either T.Text ImportReport))
importBacklogFile runtime rawProject jira file = do
  read' <- tryIO (LBS.readFile file)
  case read' of
    Left _ -> whenReady runtime (pure (Right (refuse "file-unreadable")))
    Right bytes ->
      maybe (importBacklog runtime rawProject bytes) (\locator -> importJiraSearch runtime rawProject locator bytes) jira

{- | A Jira search response's bytes, read by the offline adapter (B12), into a
project: @invalid-locator@ or @jira-unreadable@ when it cannot be read.
-}
importJiraSearch :: DatabaseRuntime -> T.Text -> T.Text -> LBS.ByteString -> IO (Either NotReadyReason (Either T.Text ImportReport))
importJiraSearch runtime rawProject rawLocator bytes =
  case fmap (`fromJiraSearch` bytes) (mkSourceLocator rawLocator) of
    Nothing -> whenReady runtime (pure (Right (refuse "invalid-locator")))
    Just (Left _) -> whenReady runtime (pure (Right (refuse "jira-unreadable")))
    Just (Right document) -> importBacklogDocument runtime rawProject (bytesDigest bytes) document

-- Importing ------------------------------------------------------------------------

-- | What one written item becomes.
data Written
  = Written
  { writtenItem :: BacklogItem
  , writtenTask :: TaskId
  , writtenDependencies :: [TaskId]
  , writtenCreated :: Bool
  }

-- | An already decoded document (e.g. from a provider adapter) with the digest of the bytes it was read from.
importBacklogDocument :: DatabaseRuntime -> T.Text -> T.Text -> BacklogDocument -> IO (Either NotReadyReason (Either T.Text ImportReport))
importBacklogDocument runtime rawProject documentDigest document =
  whenReady runtime $
    case (parseIdentity rawProject, mkContentDigest documentDigest) of
      (Nothing, _) -> pure (Right (refuse "unknown-project"))
      (_, Nothing) -> pure (Right (refuse "invalid-digest"))
      (Just projectId, Just _) -> do
        -- Identities are made at the boundary: one for the source and one per item, used only as needed.
        sourceUuid <- newUuid
        itemUuids <- traverse (const newUuid) (documentItems document)
        withDatabase runtime . O.withTransaction $ do
          Tasks.lockTasks
          Store.lockBacklog
          project <- Projects.findProjectById projectId
          repository <- projectRepository projectId
          let
            identity = documentSource document
          existing <- Store.findSource (sourceProvider identity) (sourceLocatorText (sourceLocator identity))
          case (project, documentRepository document, repository, existing) of
            (Nothing, _, _, _) -> pure (refuse "unknown-project")
            (_, Just _, Nothing, _) -> pure (refuse "repository-unbound")
            (_, Just wanted, Just own, _) | wanted /= own -> pure (refuse "repository-mismatch")
            (_, _, _, Just source) | Store.sourceRowProject source /= projectId -> pure (refuse "source-owned-elsewhere")
            (Just _, _, _, _) -> do
              stored <- maybe (pure []) (Store.sourceItems . Store.sourceRowId) existing
              edges <- Tasks.projectEdges projectId
              let
                reaches = effectiveBlockers edges (Map.fromList (mapMaybe (\src -> (,) (Store.taskSourceRowTask src) <$> mkSourceKey (Store.taskSourceRowKey src)) stored))
              conditions <- traverse (storedItem reaches) stored
              case sequenceA conditions of
                Left code -> pure (Left code)
                Right storedItems -> do
                  prior <- traverse (\s -> (\r -> PriorImport r (fmap fst storedItems)) <$> storedRevision (Store.sourceRowRevision s)) existing
                  case decideImport sha256Hasher prior document of
                    Left refusal -> pure (Left (documentRefusalCode refusal))
                    Right decision ->
                      apply projectId (maybe (BacklogSourceId sourceUuid) Store.sourceRowId existing) (isNothing existing) storedItems itemUuids decision
 where
  storedRevision n =
    maybe (integrityViolation "a stored source revision is out of range") pure (mkSourceRevision (toInteger n))
  apply projectId sourceId isNew storedItems itemUuids decision = do
    let
      items = documentItems document
      outcomes = decisionItems decision
      outcomeOf key = L.lookup key outcomes
      storedTask = Map.fromList [(storedKey s, Tasks.rowTaskId row) | (s, (row, _)) <- storedItems]
      storedRow = Map.fromList [(storedKey s, src) | (s, (_, src)) <- storedItems]
      newTask = Map.fromList [(itemKey i, TaskId u) | (i, u) <- L.zip items itemUuids, outcomeOf (itemKey i) == Just ItemCreated]
      taskOf key = Map.lookup key newTask <|> Map.lookup key storedTask
      writes key = outcomeOf key `L.elem` [Just ItemCreated, Just ItemUpdated]
      written =
        [ Written i task (mapMaybe taskOf (L.nub (itemBlockers i))) (outcomeOf (itemKey i) == Just ItemCreated)
        | i <- items
        , writes (itemKey i)
        , Just task <- [taskOf (itemKey i)]
        ]
    edges <- Tasks.projectEdges projectId
    -- R-P6.1-1: the Kernel saw the project's real dependencies, so a cycle here would be a defect, not a refusal.
    if closesCycle edges written
      then integrityViolation "the import would close a dependency cycle the decision did not refuse"
      else do
        when isNew $
          Store.insertSource
            ( Store.SourceRow
                sourceId
                projectId
                (sourceProvider (documentSource document))
                (sourceLocatorText (sourceLocator (documentSource document)))
                (sourceRevisionValue (documentRevision document))
            )
        when (not isNew) (Store.advanceSourceRevision sourceId (sourceRevisionValue (documentRevision document)))
        tasksDone <- traverse (writeTask projectId sourceId storedRow) written
        -- Every refusal was decided before the first write; a write that fails now aborts the whole transaction.
        case sequenceA_ tasksDone of
          Left code -> integrityViolation ("the import could not write a task it had validated: " <> T.unpack code)
          Right () -> do
            traverse_ (\w -> Tasks.replaceDependencies (writtenTask w) (writtenDependencies w)) written
            traverse_ (recordSource sourceId storedRow) written
            -- An unchanged item at a newer revision: only the revision is recorded.
            traverse_
              ( \i -> case Map.lookup (itemKey i) storedRow of
                  Just src
                    | outcomeOf (itemKey i) == Just ItemUnchanged ->
                        Store.advanceItemRevision (Store.taskSourceRowTask src) (sourceRevisionValue (itemRevision i))
                  _ -> pure ()
              )
              items
            let
              rendered = renderImportDecision decision
              countOf p = fromIntegral (L.length (L.filter (p . snd) outcomes))
            Store.insertImport
              Store.ImportRow
                { Store.importRowSource = sourceId
                , Store.importRowDigest = documentDigest
                , Store.importRowRevision = sourceRevisionValue (documentRevision document)
                , Store.importRowCreated = countOf (== ItemCreated)
                , Store.importRowUpdated = countOf (== ItemUpdated)
                , Store.importRowUnchanged = countOf (== ItemUnchanged)
                , Store.importRowRefused = countOf (\o -> o `L.notElem` [ItemCreated, ItemUpdated, ItemUnchanged])
                , Store.importRowDecision = rendered
                }
            pure
              ( Right
                  ImportReport
                    { reportDecision = decision
                    , reportRendered = rendered
                    , reportTasks =
                        [ (key, task)
                        | (key, o) <- outcomes
                        , o `L.elem` [ItemCreated, ItemUpdated, ItemUnchanged]
                        , Just task <- [taskOf key]
                        ]
                    }
              )

{- | R-P6.1-1, R-P6.1-2: for each task of this source, the source items its
current dependencies reach — directly, or through tasks that are not from this
source (a person's own tasks), which are followed until a source task is met.
This is the graph as it stands, so a dependency a person added counts and one
a person removed does not.
-}
effectiveBlockers :: [(TaskId, TaskId)] -> Map.Map TaskId SourceKey -> TaskId -> [SourceKey]
effectiveBlockers edges sourceKeys start =
  L.sort (go Set.empty (dependsOn start) [])
 where
  dependsOn t = [d | (t', d) <- edges, t' == t]
  go _ [] found = L.nub found
  go seen (t : rest) found
    | Set.member t seen = go seen rest found
    | otherwise =
        case Map.lookup t sourceKeys of
          Just k -> go (Set.insert t seen) rest (k : found)
          Nothing -> go (Set.insert t seen) (dependsOn t <> rest) found

-- | A stored item as the Kernel sees it, with the task row and provenance row it came from (B6).
storedItem :: (TaskId -> [SourceKey]) -> Store.TaskSourceRow -> O.Orville (Either T.Text (StoredItem, (Tasks.TaskRow, Store.TaskSourceRow)))
storedItem reaches src = do
  row <- Tasks.findTaskRow (Store.taskSourceRowTask src)
  facts <- ticketFactsIn (taskTicket (Store.taskSourceRowTask src))
  case (row, facts, mkSourceKey (Store.taskSourceRowKey src), mkContentDigest (Store.taskSourceRowDigest src), mkSourceRevision (toInteger (Store.taskSourceRowItemRevision src)), Just (reaches (Store.taskSourceRowTask src))) of
    (Just taskRow, Right (state, _, _, _), Just key, Just digest, Just revision, Just blockers) ->
      let
        condition
          | state /= T.pack "proposed" = LocalProgressed
          | Tasks.rowRevision taskRow /= Store.taskSourceRowTaskRevision src = LocalEdited
          | otherwise = LocalUntouched
      in
        pure (Right (StoredItem key revision digest blockers condition, (taskRow, src)))
    (_, Left (LedgerCorrupt message), _, _, _, _) -> integrityViolation (T.unpack message)
    (_, Left (LedgerRefusedBy refusal), _, _, _, _) -> pure (Left (ledgerRefusalCode refusal))
    _ -> integrityViolation ("the provenance of task " <> T.unpack (identityText (Store.taskSourceRowTask src)) <> " does not read back")

{- | Whether the written items' dependencies would close a cycle through the
project's other dependencies (a person may have added some). The Kernel has
already refused cycles among the source's own items; this covers the rest.
-}
closesCycle :: [(TaskId, TaskId)] -> [Written] -> Bool
closesCycle edges written =
  let
    rewritten = fmap writtenTask written
    kept = L.filter (\(t, _) -> t `L.notElem` rewritten) edges
    final = kept <> [(writtenTask w, d) | w <- written, d <- writtenDependencies w]
  in
    L.any (\w -> createsCycleOf (L.filter ((/= writtenTask w) . fst) final) (writtenTask w) (writtenDependencies w)) written

-- | The creation digest of a task, as 'Lockstep.Application.Tasks.createTask' computes it (C-C.R1 R9).
creationDigest :: ProjectId -> T.Text -> T.Text -> [TaskId] -> Either T.Text T.Text
creationDigest projectId title acceptance dependencies =
  case mkTaskTitle title of
    Left _ -> refuse "title-invalid"
    Right t -> Right (requestDigest projectId t acceptance Normal (L.sort dependencies))

-- | Creates or updates one item's task (its dependencies are written once every task exists).
writeTask :: ProjectId -> BacklogSourceId -> Map.Map SourceKey Store.TaskSourceRow -> Written -> O.Orville (Either T.Text ())
writeTask projectId sourceId storedRow w =
  let
    i = writtenItem w
    title = T.strip (itemTitle i)
    acceptance = acceptanceText (itemCriteria i)
  in
    if writtenCreated w
      then case creationDigest projectId title acceptance (writtenDependencies w) of
        Left code -> pure (Left code)
        Right digest -> do
          made <- createTicketIn ((\(TaskId u) -> u) (writtenTask w)) title >>= ledgerStep
          case made of
            Left code -> pure (Left code)
            Right _ -> do
              Tasks.insertTask (writtenTask w) projectId (creationKey sourceId (itemKey i)) acceptance (priorityValue Normal) digest
              pure (Right ())
      else do
        row <- Tasks.findTaskRow (writtenTask w)
        case (row, Map.lookup (itemKey i) storedRow) of
          (Just taskRow, Just _) -> do
            revised <-
              if title /= Tasks.rowTitle taskRow
                then fmap (const ()) <$> (reviseTicketIn (taskTicket (writtenTask w)) title >>= ledgerStep)
                else pure (Right ())
            case revised of
              Left code -> pure (Left code)
              Right () -> do
                updated <- Tasks.updateTask (writtenTask w) (Tasks.rowRevision taskRow) acceptance (fromIntegral (Tasks.rowPriority taskRow))
                pure (if updated then Right () else refuse "stale-revision")
          _ -> integrityViolation "an imported task to update is gone"

-- | The task row's creation key for an item: fixed by the source and the key (64 characters).
creationKey :: BacklogSourceId -> SourceKey -> T.Text
creationKey sourceId key =
  T.pack "backlog-" <> T.take 56 (sha256Hex (identityText sourceId <> T.pack "\n" <> sourceKeyText key))

-- | Writes the item's provenance row, with the task revision the import leaves (B6, B8).
recordSource :: BacklogSourceId -> Map.Map SourceKey Store.TaskSourceRow -> Written -> O.Orville ()
recordSource sourceId storedRow w = do
  row <- Tasks.findTaskRow (writtenTask w)
  let
    i = writtenItem w
    record =
      Store.TaskSourceRow
        { Store.taskSourceRowTask = writtenTask w
        , Store.taskSourceRowSource = sourceId
        , Store.taskSourceRowKey = sourceKeyText (itemKey i)
        , Store.taskSourceRowItemRevision = sourceRevisionValue (itemRevision i)
        , Store.taskSourceRowDigest = sha256Hex (itemContentText i)
        , Store.taskSourceRowBlockers = T.intercalate (T.pack "\n") (fmap sourceKeyText (L.sort (L.nub (itemBlockers i))))
        , Store.taskSourceRowCriteria = criteriaText (itemCriteria i)
        , Store.taskSourceRowTaskRevision = maybe 1 Tasks.rowRevision row
        }
  if Map.member (itemKey i) storedRow
    then Store.updateTaskSource record
    else Store.insertTaskSource record

-- Exporting and reading provenance ---------------------------------------------------

{- | The project's backlog as a canonical document (B11): one item per task,
its key the task's identity, its revision the task's and its Ticket's
revisions together, its acceptance one criterion a line. No state, priority or
authority is written.
-}
exportBacklog :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Either T.Text T.Text))
exportBacklog runtime rawProject =
  whenReady runtime $
    case parseIdentity rawProject of
      Nothing -> pure (Right (refuse "unknown-project"))
      Just projectId ->
        withDatabase runtime $ do
          project <- Projects.findProjectById projectId
          case project of
            Nothing -> pure (refuse "unknown-project")
            Just _ -> do
              rows <- Tasks.projectTaskRows projectId
              items <- traverse exportedItem rows
              pure $ do
                -- R-P6.1-3: never write a document the import would refuse whole.
                when (L.length rows > maxItems) (refuse "too-many-items")
                exported <- sequenceA items
                locator <- maybe (refuse "invalid-locator") Right (mkSourceLocator (T.pack "lockstep:project/" <> identityText projectId))
                revision <- maybe (refuse "revision-out-of-range") Right (mkSourceRevision (L.sum (fmap (toInteger . sourceRevisionValue . itemRevision) exported)))
                pure
                  ( encodeBacklogDocument
                      BacklogDocument
                        { documentSource = SourceIdentity ProviderCanonical locator
                        , documentRevision = revision
                        , documentRepository = Nothing
                        , documentItems = exported
                        }
                  )

{- | One task as an item. R-P6.1-3: an imported task whose acceptance is still
exactly what its criteria render exports those criteria, with their own
references, so an export imported and exported again is the same; any other
task exports one criterion a line (a leading @- @ marker removed), referenced to
the task.
-}
exportedItem :: Tasks.TaskRow -> O.Orville (Either T.Text BacklogItem)
exportedItem row = do
  let
    task = Tasks.rowTaskId row
  facts <- ticketFactsIn (taskTicket task) >>= ledgerStep
  dependencies <- Tasks.dependenciesOf task
  provenance <- Store.findTaskSource task
  pure $ do
    (_, _, ticketRevision, _) <- facts
    key <- keyFor task
    blockers <- traverse keyFor dependencies
    revision <- maybe (refuse "revision-out-of-range") Right (mkSourceRevision (toInteger (Tasks.rowRevision row) + toInteger ticketRevision))
    let
      reference = T.pack "lockstep:task/" <> identityText task
      byLine =
        [ Criterion line (Just reference)
        | raw <- T.lines (Tasks.rowAcceptance row)
        , let
            words' = T.words raw
            line = T.unwords (if L.take 1 words' == [T.pack "-"] then L.drop 1 words' else words')
        , not (T.null line)
        ]
      imported' =
        case fmap (decodeCriteria . Store.taskSourceRowCriteria) provenance of
          Just (Right criteria) | acceptanceText criteria == Tasks.rowAcceptance row -> Just criteria
          _ -> Nothing
    pure (BacklogItem key revision (Tasks.rowTitle row) (fromMaybe byLine imported') blockers)
 where
  keyFor t = maybe (refuse "invalid-key") Right (mkSourceKey (identityText t))

-- | The provenance of a project's imported tasks, source by source, in import order.
taskSources :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason [TaskSource])
taskSources runtime rawProject =
  whenReady runtime $
    case parseIdentity rawProject of
      Nothing -> pure (Right [])
      Just projectId ->
        withDatabase runtime $ do
          sources <- Store.projectSources projectId
          perSource <- traverse (\s -> fmap ((,) s) (Store.sourceItems (Store.sourceRowId s))) sources
          traverse
            ( \(s, src) -> case decodeCriteria (Store.taskSourceRowCriteria src) of
                Left _ -> integrityViolation ("the criteria of task " <> T.unpack (identityText (Store.taskSourceRowTask src)) <> " do not read back")
                Right criteria ->
                  pure
                    TaskSource
                      { taskSourceTask = Store.taskSourceRowTask src
                      , taskSourceProvider = Store.sourceRowProvider s
                      , taskSourceLocator = Store.sourceRowLocator s
                      , taskSourceKey = Store.taskSourceRowKey src
                      , taskSourceRevision = Store.taskSourceRowItemRevision src
                      , taskSourceCriteria = criteria
                      }
            )
            [(s, src) | (s, rows) <- perSource, src <- rows]
