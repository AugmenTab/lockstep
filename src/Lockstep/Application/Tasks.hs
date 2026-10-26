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
import Lockstep.Application.Ledger (LedgerFailure (..), createTicketIn, decideTicket, ledgerFailureCode, noFaults, reviseTicketIn, ticketFactsIn)
import Lockstep.Kernel.Evidence (mkHumanSignoff)
import Lockstep.Kernel.Identity (TicketId (..), parseUuid, uuidText)
import Lockstep.Kernel.Task
  ( DependencyFact (..)
  , Priority
  , TaskFacts (..)
  , TaskReadiness
  , createsCycle
  , mkAcceptance
  , mkTaskTitle
  , mostImportantReady
  , priorityValue
  , taskReadiness
  , taskRuleCode
  , taskTitleText
  )
import Lockstep.Kernel.Ticket (TicketInput (..))
import Lockstep.Kernel.Transition (Command (..), Principal (Human))
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

canonicalId :: T.Text -> Maybe T.Text
canonicalId =
  either (const Nothing) (Just . uuidText) . parseUuid

refuse :: String -> Either T.Text a
refuse =
  Left . T.pack

-- | The view of a stored task: its row, its Ticket's facts and its dependencies' facts.
loadView :: Store.TaskRow -> O.Orville (Either T.Text TaskView)
loadView row = do
  facts <- ticketFactsIn (Store.rowTaskId row)
  deps <- Store.dependenciesOf (Store.rowTaskId row)
  depFacts <- traverse ticketFactsIn deps
  pure $ do
    (state, reason, revision, _) <- either (Left . ledgerFailureCode) Right facts
    dependencyFacts <- traverse (either (Left . ledgerFailureCode) (\(s, _, _, title) -> Right (DependencyFact title s))) depFacts
    pure
      TaskView
        { taskId = Store.rowTaskId row
        , taskProject = Store.rowProjectId row
        , taskTitle = Store.rowTitle row
        , taskAcceptance = Store.rowAcceptance row
        , taskPriority = fromIntegral (Store.rowPriority row)
        , taskState = state
        , taskBlockReason = reason
        , taskDependencies = deps
        , taskReadinessOf = taskReadiness (TaskFacts state reason dependencyFacts)
        , taskRevision = Store.rowRevision row
        , taskTicketRevision = revision
        }

-- | Each dependency must be another task of the project, at most 20, no repeats.
checkDependencies :: T.Text -> Maybe T.Text -> [T.Text] -> O.Orville (Either T.Text [T.Text])
checkDependencies projectId self raw
  | L.length raw > maxDependencies = pure (refuse "too-many-dependencies")
  | otherwise =
      case traverse canonicalId raw of
        Nothing -> pure (refuse "unknown-dependency")
        Just ids
          | Just s <- self, s `L.elem` ids -> pure (refuse "dependency-self")
          | otherwise -> do
              rows <- traverse Store.findTaskRow (L.nub ids)
              pure $
                if L.all (maybe False ((== projectId) . Store.rowProjectId)) rows
                  then Right (L.nub ids)
                  else refuse "unknown-dependency"

createTask :: DatabaseRuntime -> NewTask -> IO (Either NotReadyReason (Either T.Text TaskView))
createTask runtime request =
  whenReady runtime $
    case (mkTaskTitle (newTaskTitle request), mkAcceptance (newTaskAcceptance request), canonicalId (newTaskProject request)) of
      (Left e, _, _) -> pure (Right (Left (taskRuleCode e)))
      (_, Left e, _) -> pure (Right (Left (taskRuleCode e)))
      (_, _, Nothing) -> pure (Right (Left (T.pack "unknown-project")))
      (Right title, Right acceptance, Just projectId) -> do
        u <- newUuid
        withDatabase runtime . O.withTransaction $ do
          Store.lockTasks
          existing <- Store.findTaskByKey (idempotencyKeyText (newTaskKey request))
          case existing of
            Just row -> loadView row
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
                            newId = uuidText u
                          Store.insertTask newId projectId (idempotencyKeyText (newTaskKey request)) acceptance (priorityValue (newTaskPriority request))
                          Store.replaceDependencies newId ids
                          Store.findTaskRow newId >>= maybe (pure (refuse "unknown-task")) loadView

editTask :: DatabaseRuntime -> T.Text -> Int64 -> TaskEdit -> IO (Either NotReadyReason (Either T.Text TaskView))
editTask runtime rawId expected edit =
  whenReady runtime $
    case (canonicalId rawId, mkTaskTitle (editTitle edit), mkAcceptance (editAcceptance edit)) of
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
                      | createsCycle edges tid ids -> pure (refuse "dependency-cycle")
                      | otherwise -> do
                          revised <-
                            if taskTitleText title /= Store.rowTitle row
                              then fmap (const ()) <$> reviseTicketIn tid (taskTitleText title)
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

decideTask :: DatabaseRuntime -> T.Text -> T.Text -> Int -> TaskDecision -> IO (Either NotReadyReason (Either T.Text TaskView))
decideTask runtime session rawId expected decision =
  whenReady runtime $
    case canonicalId rawId of
      Nothing -> pure (Right (refuse "unknown-task"))
      Just tid -> do
        known <- findTask runtime tid
        case known of
          Left reason -> pure (Left reason)
          Right Nothing -> pure (Right (refuse "unknown-task"))
          Right (Just _) ->
            case input of
              Left code -> pure (Right (Left code))
              Right ticketInput ->
                case parseUuid tid of
                  Left _ -> pure (Right (refuse "unknown-task"))
                  Right u -> do
                    decided <- decideTicket runtime noFaults (TicketId u) expected (Command Human ticketInput)
                    case decided of
                      Left (LedgerRefused code _)
                        | code == T.pack "stale-revision" -> pure (Right (refuse "stale-revision"))
                        | otherwise -> pure (Right (refuse "not-allowed-now"))
                      Left failure -> pure (Right (Left (ledgerFailureCode failure)))
                      Right _ -> fmap (maybe (refuse "unknown-task") Right) <$> findTask runtime tid
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
    case canonicalId rawProject of
      Nothing -> pure (Right [])
      Just projectId -> withDatabase runtime (Store.projectTaskRows projectId >>= views)

listAllTasks :: DatabaseRuntime -> IO (Either NotReadyReason [TaskView])
listAllTasks runtime =
  whenReady runtime (withDatabase runtime (Store.allTaskRows >>= views))

-- | Views of rows; a row whose Ticket cannot be replayed is left out rather than shown wrongly.
views :: [Store.TaskRow] -> O.Orville [TaskView]
views rows =
  L.concatMap (either (const []) pure) <$> traverse loadView rows

findTask :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Maybe TaskView))
findTask runtime rawId =
  case canonicalId rawId of
    Nothing -> pure (Right Nothing)
    Just tid ->
      whenReady runtime . withDatabase runtime $ do
        found <- Store.findTaskRow tid
        case found of
          Nothing -> pure Nothing
          Just row -> either (const Nothing) Just <$> loadView row

-- | The most important task that is ready to work on, from a list in the project order.
mostImportantReadyTask :: [TaskView] -> Maybe TaskView
mostImportantReadyTask tasks =
  mostImportantReady [(t, taskPriority t, n, taskReadinessOf t) | (n, t) <- L.zip [0 :: Int ..] tasks]
