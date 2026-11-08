{- | Tasks in projects (contract C-P3.6 K1, K2, K5). A task is a C-P2.2 Ticket
plus a task row (what done looks like, priority, revision) and its dependencies
on other tasks of the same project. Creating and editing happen in one
transaction under the task lock; ready, block, unblock and cancel are the
C-P2.2 'decideTicket' with principal Human. Nothing here creates a Work Order,
schedules or runs anything.
-}
module Lockstep.Application.Tasks
  ( NewTask (..)
  , TaskEdit (..)
  , TaskDecision (..)
  , TaskView (..)
  , createTask
  , editTask
  , decideTask
  , listTasks
  , listAllTasks
  , findTask
  , findTaskIn
  , findTaskWithProjectIn
  , mostImportantReadyTask
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Text.Show (Show)

import Lockstep.Application.Command (IdempotencyKey, idempotencyKeyText)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason, Readiness (..), checkReadiness, withDatabase)
import Lockstep.Application.Identity (newUuid)
import Lockstep.Application.Ledger (LedgerFailure (..), createTicketIn, decideTicketIn, ledgerFailureCode, reviseTicketIn, ticketFactsIn)
import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Kernel.Evidence (mkHumanSignoff)
import Lockstep.Kernel.Identity (ProjectId (..), TaskId (..), TicketId (..), identityText, parseIdentity)
import Lockstep.Kernel.Profile (Hasher (..), contentDigestText)
import Lockstep.Kernel.Task
  ( DependencyFact (..)
  , Priority
  , TaskFacts (..)
  , TaskReadiness
  , TaskTitle
  , createsCycleOf
  , mkAcceptance
  , mkTaskTitle
  , mostImportantReady
  , priorityValue
  , taskReadiness
  , taskRequestText
  , taskRuleCode
  , taskTitleText
  )
import Lockstep.Kernel.Ticket (TicketInput (..))
import Lockstep.Kernel.Transition (Command (..), Principal (Human))
import Lockstep.Persistence.Integrity (integrityViolation)
import Lockstep.Persistence.Projects qualified as Projects
import Lockstep.Persistence.Tasks qualified as Store

data NewTask
  = NewTask
  { newTaskKey :: IdempotencyKey
  , newTaskProject :: T.Text
  , newTaskTitle :: T.Text
  , newTaskAcceptance :: T.Text
  , newTaskPriority :: Priority
  , newTaskDependencies :: [T.Text]
  }

data TaskEdit
  = TaskEdit
  { editTitle :: T.Text
  , editAcceptance :: T.Text
  , editPriority :: Priority
  , editDependencies :: [T.Text]
  }

data TaskDecision
  = MarkReady
  | BlockTask T.Text
  | UnblockTask
  | CancelTask
  deriving (Eq, Show)

data TaskView
  = TaskView
  { taskId :: T.Text
  , taskProject :: T.Text
  , taskTitle :: T.Text
  , taskAcceptance :: T.Text
  , taskPriority :: Int
  , taskState :: T.Text
  , taskBlockReason :: Maybe T.Text
  , taskDependencies :: [T.Text]
  , taskReadinessOf :: TaskReadiness
  , taskRevision :: Int64
  , taskTicketRevision :: Int
  }
  deriving (Eq, Show)

maxDependencies :: Int
maxDependencies =
  20

whenReady :: DatabaseRuntime -> IO (Either NotReadyReason a) -> IO (Either NotReadyReason a)
whenReady runtime action = do
  readiness <- checkReadiness (Just runtime)
  case readiness of
    NotReady reason -> pure (Left reason)
    Ready _ -> action

refuse :: String -> Either T.Text a
refuse =
  Left . T.pack

{- | A task's Ticket: the two are made together with one UUID (C-P3.6 K2), so
the Ticket of a task is the identity of the same UUID, as a Ticket.
-}
taskTicket :: TaskId -> TicketId
taskTicket (TaskId u) =
  TicketId u

-- | The view of a stored task: its row, its Ticket's facts and its dependencies' facts.
loadView :: Store.TaskRow -> O.Orville (Either T.Text TaskView)
loadView row = do
  facts <- ticketFactsIn (taskTicket (Store.rowTaskId row))
  deps <- Store.dependenciesOf (Store.rowTaskId row)
  depFacts <- traverse (ticketFactsIn . taskTicket) deps
  pure $ do
    (state, reason, revision, _) <- either (Left . ledgerFailureCode) Right facts
    dependencyFacts <- traverse (either (Left . ledgerFailureCode) (\(s, _, _, title) -> Right (DependencyFact title s))) depFacts
    pure
      TaskView
        { taskId = identityText (Store.rowTaskId row)
        , taskProject = identityText (Store.rowProjectId row)
        , taskTitle = Store.rowTitle row
        , taskAcceptance = Store.rowAcceptance row
        , taskPriority = fromIntegral (Store.rowPriority row)
        , taskState = state
        , taskBlockReason = reason
        , taskDependencies = fmap identityText deps
        , taskReadinessOf = taskReadiness (TaskFacts state reason dependencyFacts)
        , taskRevision = Store.rowRevision row
        , taskTicketRevision = revision
        }

{- | Each dependency must be another task of the project, at most 20, no
repeats. The given texts are parsed here, once; one that is not a task
identity is @unknown-dependency@.
-}
checkDependencies :: ProjectId -> Maybe TaskId -> [T.Text] -> O.Orville (Either T.Text [TaskId])
checkDependencies projectId self raw
  | L.length raw > maxDependencies = pure (refuse "too-many-dependencies")
  | otherwise =
      case traverse parseIdentity raw of
        Nothing -> pure (refuse "unknown-dependency")
        Just ids
          | Just s <- self, s `L.elem` ids -> pure (refuse "dependency-self")
          | otherwise -> do
              rows <- traverse Store.findTaskRow (L.nub ids)
              pure $
                if L.all (maybe False ((== projectId) . Store.rowProjectId)) rows
                  then Right (L.nub ids)
                  else refuse "unknown-dependency"

-- | The creation digest's canonical request (C-C.R1 R9), the identities in their canonical text.
requestDigest :: ProjectId -> TaskTitle -> T.Text -> Priority -> [TaskId] -> T.Text
requestDigest projectId title acceptance priority dependencies =
  sha256Text (taskRequestText (identityText projectId) title acceptance priority (fmap identityText dependencies))

createTask :: DatabaseRuntime -> NewTask -> IO (Either NotReadyReason (Either T.Text TaskView))
createTask runtime request =
  whenReady runtime $
    case (mkTaskTitle (newTaskTitle request), mkAcceptance (newTaskAcceptance request), parseIdentity (newTaskProject request)) of
      (Left e, _, _) -> pure (Right (Left (taskRuleCode e)))
      (_, Left e, _) -> pure (Right (Left (taskRuleCode e)))
      (_, _, Nothing) -> pure (Right (Left (T.pack "unknown-project")))
      (Right title, Right acceptance, Just projectId) -> do
        u <- newUuid
        let
          priority = newTaskPriority request
          -- A request naming a dependency that is not a task identity matches no stored request.
          dependencies = L.sort . L.nub <$> traverse parseIdentity (newTaskDependencies request)
          digest = requestDigest projectId title acceptance priority <$> dependencies
        withDatabase runtime . O.withTransaction $ do
          Store.lockTasks
          existing <- Store.findTaskByKey (idempotencyKeyText (newTaskKey request))
          case existing of
            Just row
              | Store.rowProjectId row /= projectId -> pure (refuse "key-conflict")
              | otherwise ->
                  case Store.rowCreationDigest row of
                    Just stored
                      | Just stored == digest -> loadView row
                      | otherwise -> pure (refuse "key-conflict")
                    Nothing -> do
                      -- C-C.R1 R9: a row made before migration 17 replays only when the
                      -- request is shown equal to it, which needs a task never edited since.
                      stored <- L.sort <$> Store.dependenciesOf (Store.rowTaskId row)
                      if Store.rowRevision row == 1
                        && Store.rowTitle row == taskTitleText title
                        && Store.rowAcceptance row == acceptance
                        && fromIntegral (Store.rowPriority row) == priorityValue priority
                        && Just stored == dependencies
                        then loadView row
                        else pure (refuse "key-conflict")
            Nothing -> do
              project <- Projects.findProjectById projectId
              case project of
                Nothing -> pure (refuse "unknown-project")
                Just _ -> do
                  deps <- checkDependencies projectId Nothing (newTaskDependencies request)
                  case deps of
                    Left code -> pure (Left code)
                    Right ids -> do
                      made <- createTicketIn u (taskTitleText title)
                      case made of
                        Left failure -> pure (Left (ledgerFailureCode failure))
                        Right _ -> do
                          let
                            newId = TaskId u
                          Store.insertTask newId projectId (idempotencyKeyText (newTaskKey request)) acceptance (priorityValue priority) (requestDigest projectId title acceptance priority ids)
                          Store.replaceDependencies newId ids
                          Store.findTaskRow newId >>= maybe (pure (refuse "unknown-task")) loadView

editTask :: DatabaseRuntime -> T.Text -> Int64 -> TaskEdit -> IO (Either NotReadyReason (Either T.Text TaskView))
editTask runtime rawId expected edit =
  whenReady runtime $
    case (parseIdentity rawId, mkTaskTitle (editTitle edit), mkAcceptance (editAcceptance edit)) of
      (Nothing, _, _) -> pure (Right (refuse "unknown-task"))
      (_, Left e, _) -> pure (Right (Left (taskRuleCode e)))
      (_, _, Left e) -> pure (Right (Left (taskRuleCode e)))
      (Just tid, Right title, Right acceptance) ->
        withDatabase runtime . O.withTransaction $ do
          Store.lockTasks
          found <- Store.findTaskRow tid
          case found of
            Nothing -> pure (refuse "unknown-task")
            Just row
              | Store.rowRevision row /= expected -> pure (refuse "stale-revision")
              | otherwise -> do
                  deps <- checkDependencies (Store.rowProjectId row) (Just tid) (editDependencies edit)
                  edges <- Store.projectEdges (Store.rowProjectId row)
                  case deps of
                    Left code -> pure (Left code)
                    Right ids
                      | createsCycleOf edges tid ids -> pure (refuse "dependency-cycle")
                      | otherwise -> do
                          revised <-
                            if taskTitleText title /= Store.rowTitle row
                              then fmap (const ()) <$> reviseTicketIn (taskTicket tid) (taskTitleText title)
                              else pure (Right ())
                          case revised of
                            Left failure -> pure (Left (ledgerFailureCode failure))
                            Right () -> do
                              updated <- Store.updateTask tid expected acceptance (priorityValue (editPriority edit))
                              if not updated
                                then pure (refuse "stale-revision")
                                else do
                                  Store.replaceDependencies tid ids
                                  Store.findTaskRow tid >>= maybe (pure (refuse "unknown-task")) loadView

{- | K2 as C-C.R1 R7 enforces it: one transaction under the task lock; the
C-P2.2 Ticket decision runs inside it. A Ticket revision outside the stored
range is refused before anything is read or recorded (C-C.R1 R3).
-}
decideTask :: DatabaseRuntime -> T.Text -> T.Text -> Int -> TaskDecision -> IO (Either NotReadyReason (Either T.Text TaskView))
decideTask runtime session rawId expected decision =
  whenReady runtime $
    case parseIdentity rawId of
      Just tid
        | expected < 0 || expected > 2147483647 -> pure (Right (refuse "revision-out-of-range"))
        | otherwise ->
            withDatabase runtime . O.withTransaction $ do
              Store.lockTasks
              found <- Store.findTaskRow tid
              case (found, input) of
                (Nothing, _) -> pure (refuse "unknown-task")
                (Just _, Left code) -> pure (Left code)
                (Just row, Right ticketInput) -> do
                  decided <- decideTicketIn (taskTicket tid) expected (Command Human ticketInput)
                  case decided of
                    Left (LedgerRefused code _)
                      | code == T.pack "stale-revision" -> pure (refuse "stale-revision")
                      | otherwise -> pure (refuse "not-allowed-now")
                    Left failure -> pure (Left (ledgerFailureCode failure))
                    Right _ -> loadView row
      _ -> pure (Right (refuse "unknown-task"))
 where
  input =
    case decision of
      MarkReady -> Right TicketAccept
      UnblockTask -> Right TicketUnblock
      BlockTask reason
        | T.null (T.strip reason) -> refuse "reason-empty"
        | otherwise -> Right (TicketBlock (T.strip reason))
      CancelTask ->
        maybe (refuse "not-allowed-now") (Right . TicketCancel) (mkHumanSignoff (T.pack "canceled in the application (" <> session <> T.pack ")"))

listTasks :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason [TaskView])
listTasks runtime rawProject =
  whenReady runtime $
    case parseIdentity rawProject of
      Nothing -> pure (Right [])
      Just projectId -> withDatabase runtime (Store.projectTaskRows projectId >>= views)

listAllTasks :: DatabaseRuntime -> IO (Either NotReadyReason [TaskView])
listAllTasks runtime =
  whenReady runtime (withDatabase runtime (Store.allTaskRows >>= views))

{- | Views of rows. A row whose Ticket cannot be replayed is an integrity
violation (reported as corrupt data with its code), never shown wrongly and
never silently left out.
-}
views :: [Store.TaskRow] -> O.Orville [TaskView]
views =
  traverse replayed

-- | One row's view; a Ticket that does not replay aborts the read.
replayed :: Store.TaskRow -> O.Orville TaskView
replayed row =
  loadView row >>= either (\code -> integrityViolation ("task " <> T.unpack (identityText (Store.rowTaskId row)) <> " does not replay: " <> T.unpack code)) pure

findTask :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Maybe TaskView))
findTask runtime rawId =
  case parseIdentity rawId of
    Nothing -> pure (Right Nothing)
    Just tid ->
      whenReady runtime . withDatabase runtime $ do
        found <- Store.findTaskRow tid
        case found of
          Nothing -> pure Nothing
          Just row -> Just <$> replayed row

-- | A task as it stands, inside the caller's transaction (C-P4.1 X6); a Ticket that does not replay is its code.
findTaskIn :: TaskId -> O.Orville (Maybe (Either T.Text TaskView))
findTaskIn tid =
  fmap (fmap snd) <$> findTaskWithProjectIn tid

-- | 'findTaskIn' with the task's project identity, typed (the view carries it as text).
findTaskWithProjectIn :: TaskId -> O.Orville (Maybe (Either T.Text (ProjectId, TaskView)))
findTaskWithProjectIn tid =
  Store.findTaskRow tid >>= traverse (\row -> fmap ((,) (Store.rowProjectId row)) <$> loadView row)

-- | The SHA-256 of a canonical request text, as 64 lowercase hex.
sha256Text :: T.Text -> T.Text
sha256Text text =
  case sha256Hasher of
    Hasher f -> contentDigestText (f text)

-- | The most important task that is ready to work on, from a list in the project order.
mostImportantReadyTask :: [TaskView] -> Maybe TaskView
mostImportantReadyTask tasks =
  mostImportantReady [(t, taskPriority t, n, taskReadinessOf t) | (n, t) <- L.zip [0 :: Int ..] tasks]
