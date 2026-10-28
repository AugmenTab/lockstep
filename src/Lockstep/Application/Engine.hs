{- | The coding transaction engine (contract C-P4.6 E1–E7; @engine-design.md@).
One transaction per admitted bug Work Order. 'advance' does exactly one
stage's work and records it; the Kernel ('stepTransaction') decides what
comes next. A stage's inputs come from the Supervisor's own observations;
an Agent's words are recorded as data and never decide anything.

Role invocations are recorded before they run and finished after. An
invocation found started but not finished (a crash, a restart) is never run
again by itself: it is finished as @uncertain@ and the transaction halts for
a person. Commands and Git steps are deterministic and simply run again.

Every halt opens a durable decision request to a person (C-P4.3).
-}
module Lockstep.Application.Engine
  ( Engine (..)
  , StepReport (..)
  , TransactionView (..)
  , RecordView (..)
  , InvocationView (..)
  , startTransaction
  , advance
  , transactionView
  , transactionForWorkOrder
  ) where

import Control.Exception (IOException, try)
import Crypto.Hash (SHA256 (SHA256), hashWith)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString qualified as BS
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error (lenientDecode)
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import System.IO (FilePath)
import Text.Show (Show, show)

import Lockstep.Application.Command (mkIdempotencyKey)
import Lockstep.Application.Conversation (NewHumanRequest (..), Sender (..), openRequest)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason, Readiness (..), checkReadiness, withDatabase)
import Lockstep.Application.Identity (newUuid)
import Lockstep.Application.Repositories (ownershipHolds)
import Lockstep.Application.Tasks (TaskView (..), findTaskIn)
import Lockstep.Effects.GitSupervisor (Basis (..), createWorkBranch, observeBasis, writeSnapshot)
import Lockstep.Effects.Process (RunResult (..))
import Lockstep.Effects.Roles (Adapter (..), Runner (..), RunnerFailure (..), Workspace (..), decodeAnswer, prepareRole, runPrepared)
import Lockstep.Effects.Roles qualified as Roles
import Lockstep.Foundation.Json (Json (..), renderJson, string, strings)
import Lockstep.Foundation.RunnerProtocol (RunProfile (..))
import Lockstep.Kernel.GitBasis (TreeEntry (..), workBranch)
import Lockstep.Kernel.Identity (parseUuid, uuidText)
import Lockstep.Kernel.Roles (Check (..), Citation (..), Discovery (..), Role (..), RoleAnswer (..), roleName)
import Lockstep.Kernel.Runner (RoleKind (..), RunOutcome (..), outcomeName, roleLimits)
import Lockstep.Kernel.Transaction
  ( Counters (..)
  , Stage (..)
  , Transaction (..)
  , TxInput (..)
  , TxState (..)
  , haltChoices
  , parseStage
  , reproduces
  , stageName
  , stateColumns
  , stateFromColumns
  , stepTransaction
  , txInputName
  )
import Lockstep.Kernel.Transition (Principal (..))
import Lockstep.Persistence.Transactions qualified as Store

-- | What the engine runs roles with: the runner, and the adapter for a role's nth invocation.
data Engine
  = Engine
  { engineRunner :: Runner
  , engineAdapter :: Role -> Int -> Maybe Adapter
  }

data StepReport
  = -- | the input the stage produced, and the transaction after it
    Stepped T.Text TransactionView
  | -- | nothing to do (halted, accepted, done, stopped)
    Idle T.Text TransactionView
  deriving (Eq, Show)

data RecordView
  = RecordView
  { recordSequence :: Int
  , recordKind :: T.Text
  , recordPrincipal :: T.Text
  , recordStage :: T.Text
  , recordBody :: T.Text
  }
  deriving (Eq, Show)

data InvocationView
  = InvocationView
  { invocationId :: T.Text
  , invocationStage :: T.Text
  , invocationWhat :: T.Text
  , invocationRunner :: T.Text
  , invocationAdapter :: T.Text
  , invocationArgv :: T.Text
  , invocationOutcome :: Maybe T.Text
  , invocationExit :: Maybe Int
  }
  deriving (Eq, Show)

data TransactionView
  = TransactionView
  { viewId :: T.Text
  , viewWorkOrder :: T.Text
  , viewTask :: T.Text
  , viewEngineer :: T.Text
  , viewFolder :: T.Text
  , viewState :: T.Text
  , viewStage :: T.Text
  , viewHalt :: Maybe T.Text
  , viewBasis :: Maybe T.Text
  , viewBranch :: Maybe T.Text
  , viewCandidates :: Int
  , viewAttempts :: Int
  , viewRecords :: [RecordView]
  , viewInvocations :: [InvocationView]
  }
  deriving (Eq, Show)

-- Plumbing --------------------------------------------------------------------------

whenReady :: DatabaseRuntime -> IO (Either NotReadyReason a) -> IO (Either NotReadyReason a)
whenReady runtime action = do
  readiness <- checkReadiness (Just runtime)
  case readiness of
    NotReady reason -> pure (Left reason)
    Ready _ -> action

-- | A database step inside a stage: unavailability becomes a refusal code.
db :: DatabaseRuntime -> O.Orville (Either T.Text a) -> IO (Either T.Text a)
db runtime action =
  fromRight (Left (T.pack "database-unavailable")) <$> withDatabase runtime action

canonicalId :: T.Text -> Maybe T.Text
canonicalId =
  either (const Nothing) (Just . uuidText) . parseUuid

sha256Hex :: BS.ByteString -> T.Text
sha256Hex bytes =
  TE.decodeLatin1 (convertToBase Base16 (hashWith SHA256 bytes))

decodeLenient :: BS.ByteString -> T.Text
decodeLenient =
  TE.decodeUtf8With lenientDecode

-- | The last 2000 characters of a stream, as evidence.
tailOf :: BS.ByteString -> T.Text
tailOf bytes =
  T.takeEnd 2000 (decodeLenient bytes)

kernelOf :: Store.TransactionRow -> Maybe Transaction
kernelOf row = do
  state <- stateFromColumns (Store.txRowState row) (Store.txRowStage row) (Store.txRowHaltCode row)
  pure (Transaction state (Counters (fromIntegral (Store.txRowCandidates row)) (fromIntegral (Store.txRowAttempts row))))

-- | The stage the row was last at (a stored stage always reads back; basis otherwise).
lastStage :: Store.TransactionRow -> Stage
lastStage row =
  fromMaybe StageBasis (parseStage (Store.txRowStage row))

viewOf :: Store.TransactionRow -> [Store.RecordRow] -> [Store.InvocationRow] -> TransactionView
viewOf row records invocations =
  TransactionView
    { viewId = Store.txRowId row
    , viewWorkOrder = Store.txRowWorkOrder row
    , viewTask = Store.txRowTask row
    , viewEngineer = Store.txRowEngineer row
    , viewFolder = Store.txRowFolder row
    , viewState = Store.txRowState row
    , viewStage = Store.txRowStage row
    , viewHalt = Store.txRowHaltCode row
    , viewBasis = Store.txRowBasis row
    , viewBranch = Store.txRowBranch row
    , viewCandidates = fromIntegral (Store.txRowCandidates row)
    , viewAttempts = fromIntegral (Store.txRowAttempts row)
    , viewRecords =
        [ RecordView (fromIntegral (Store.recordRowSequence r)) (Store.recordRowKind r) (Store.recordRowPrincipal r) (Store.recordRowStage r) (Store.recordRowBody r)
        | r <- records
        ]
    , viewInvocations =
        [ InvocationView
            (Store.invocationRowId i)
            (Store.invocationRowStage i)
            (Store.invocationRowWhat i)
            (Store.invocationRowRunner i)
            (Store.invocationRowAdapter i)
            (Store.invocationRowArgv i)
            (Store.invocationRowOutcome i)
            (fromIntegral <$> Store.invocationRowExit i)
        | i <- invocations
        ]
    }

loadView :: T.Text -> O.Orville (Maybe TransactionView)
loadView txId = do
  row <- Store.findTransaction txId
  case row of
    Nothing -> pure Nothing
    Just r -> do
      records <- Store.transactionRecords txId
      invocations <- Store.transactionInvocations txId
      pure (Just (viewOf r records invocations))

-- Reading ------------------------------------------------------------------------------

transactionView :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Maybe TransactionView))
transactionView runtime raw =
  whenReady runtime $
    case canonicalId raw of
      Nothing -> pure (Right Nothing)
      Just txId -> withDatabase runtime (loadView txId)

transactionForWorkOrder :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Maybe TransactionView))
transactionForWorkOrder runtime raw =
  whenReady runtime $
    case canonicalId raw of
      Nothing -> pure (Right Nothing)
      Just workOrder ->
        withDatabase runtime $ do
          row <- Store.findTransactionByWorkOrder workOrder
          maybe (pure Nothing) (loadView . Store.txRowId) row

-- Starting -----------------------------------------------------------------------------

{- | E1: the transaction for an admitted bug Work Order (C-P4.1), at the basis
stage. Again for the same Work Order: the same transaction. Refused:
@unknown-work-order@, @not-admitted@, @engineer-busy@ (the Engineer's one
writer holds another running or halted transaction).
-}
startTransaction :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Either T.Text TransactionView))
startTransaction runtime raw =
  whenReady runtime $
    case canonicalId raw of
      Nothing -> pure (Right (Left (T.pack "unknown-work-order")))
      Just workOrder -> do
        u <- newUuid
        withDatabase runtime . O.withTransaction $ do
          existing <- Store.findTransactionByWorkOrder workOrder
          case existing of
            Just row -> maybe (Left (T.pack "transaction-unreadable")) Right <$> loadView (Store.txRowId row)
            Nothing -> do
              facts <- Store.admissionFacts workOrder
              case facts of
                Nothing -> pure (Left (T.pack "not-admitted"))
                Just f -> do
                  busy <- Store.busyTransactions (Store.factEngineer f)
                  if not (L.null busy)
                    then pure (Left (T.pack "engineer-busy"))
                    else do
                      let
                        txId = uuidText u
                        row =
                          Store.TransactionRow
                            { Store.txRowId = txId
                            , Store.txRowWorkOrder = workOrder
                            , Store.txRowTask = Store.factTask f
                            , Store.txRowEngineer = Store.factEngineer f
                            , Store.txRowFolder = Store.factFolder f
                            , Store.txRowState = T.pack "running"
                            , Store.txRowStage = stageName StageBasis
                            , Store.txRowHaltCode = Nothing
                            , Store.txRowCandidates = 0
                            , Store.txRowAttempts = 0
                            , Store.txRowBasis = Nothing
                            , Store.txRowBranch = Nothing
                            , Store.txRowFreeze = Nothing
                            , Store.txRowCandidate = Nothing
                            , Store.txRowAccepted = Nothing
                            , Store.txRowContract = Nothing
                            , Store.txRowRevision = 1
                            }
                      Store.insertTransaction row
                      appendRecord txId 1 (T.pack "started") Supervisor StageBasis $
                        JObject [(T.pack "work_order", string workOrder), (T.pack "engineer", string (Store.factEngineer f)), (T.pack "folder", string (Store.factFolder f))]
                      maybe (Left (T.pack "transaction-unreadable")) Right <$> loadView txId

appendRecord :: T.Text -> Int32 -> T.Text -> Principal -> Stage -> Json -> O.Orville ()
appendRecord txId sequence kind principal stage body =
  let
    rendered = renderJson body
  in
    Store.appendRecord
      Store.RecordRow
        { Store.recordRowTransaction = txId
        , Store.recordRowSequence = sequence
        , Store.recordRowKind = kind
        , Store.recordRowPrincipal = T.toLower (T.pack (show principal))
        , Store.recordRowStage = stageName stage
        , Store.recordRowBody = rendered
        , Store.recordRowDigest = sha256Hex (TE.encodeUtf8 rendered)
        }

{- | E2: applies one input under the row lock, at the revision the stage
started from (@stale-step@ otherwise), with its records; a halt adds a
@halt@ record. Returns the new row.
-}
applyInput :: DatabaseRuntime -> T.Text -> Int32 -> Principal -> TxInput -> [(T.Text, Json)] -> (Store.TransactionRow -> Store.TransactionRow) -> IO (Either T.Text Store.TransactionRow)
applyInput runtime txId revision principal input records change =
  db runtime . O.withTransaction $ do
    locked <- Store.lockTransaction txId
    case locked of
      Nothing -> pure (Left (T.pack "unknown-transaction"))
      Just row
        | Store.txRowRevision row /= revision -> pure (Left (T.pack "stale-step"))
        | otherwise ->
            case kernelOf row of
              Nothing -> pure (Left (T.pack "transaction-unreadable"))
              Just tx ->
                case stepTransaction principal input tx of
                  Left code -> pure (Left code)
                  Right next -> do
                    existing <- Store.transactionRecords txId
                    let
                      stage = lastStage row
                      (stateName, stageText, code) = stateColumns stage (txState next)
                      updated =
                        (change row)
                          { Store.txRowState = stateName
                          , Store.txRowStage = stageText
                          , Store.txRowHaltCode = code
                          , Store.txRowCandidates = fromIntegral (candidatesMade (txCounters next))
                          , Store.txRowAttempts = fromIntegral (attemptsMade (txCounters next))
                          , Store.txRowRevision = revision + 1
                          }
                      halted =
                        case txState next of
                          Halted s c -> [(T.pack "halt", JObject [(T.pack "stage", string (stageName s)), (T.pack "code", string c)])]
                          _ -> []
                      inputRecord = (T.pack "input", JObject [(T.pack "input", string (txInputName input)), (T.pack "state", string stateName)])
                      numbered = L.zip [fromIntegral (L.length existing) + 1 ..] (records <> [inputRecord] <> halted)
                    Store.updateTransaction updated
                    traverse_ (\(n, (kind, body)) -> appendRecord txId n kind principal stage body) numbered
                    pure (Right updated)

-- Advancing ----------------------------------------------------------------------------

{- | E3: one stage of a running transaction, or, for a halted one, its open
request to a person (opened again if it is missing). Refused:
@unknown-transaction@, @transaction-unreadable@, @stale-step@ (another advance
changed it first).
-}
advance :: DatabaseRuntime -> Engine -> T.Text -> IO (Either NotReadyReason (Either T.Text StepReport))
advance runtime engine raw =
  whenReady runtime $
    case canonicalId raw of
      Nothing -> pure (Right (Left (T.pack "unknown-transaction")))
      Just txId -> do
        loaded <- withDatabase runtime (Store.findTransaction txId)
        case loaded of
          Left reason -> pure (Left reason)
          Right Nothing -> pure (Right (Left (T.pack "unknown-transaction")))
          Right (Just row) -> Right <$> advanceRow runtime engine row

advanceRow :: DatabaseRuntime -> Engine -> Store.TransactionRow -> IO (Either T.Text StepReport)
advanceRow runtime engine row =
  case kernelOf row of
    Nothing -> pure (Left (T.pack "transaction-unreadable"))
    Just tx ->
      case txState tx of
        Running stage -> do
          settled <- settleUnfinished runtime row stage
          case settled of
            Left code -> pure (Left code)
            Right (Just input) -> report input
            Right Nothing -> do
              result <- runStage runtime engine row stage
              case result of
                Left code -> pure (Left code)
                Right input -> report input
        Halted stage code -> do
          _ <- ensureRequest runtime row stage code
          idle (T.pack "halted")
        Accepted -> idle (T.pack "accepted")
        Done -> idle (T.pack "done")
        Stopped _ -> idle (T.pack "stopped")
 where
  current =
    db runtime (maybe (Left (T.pack "unknown-transaction")) Right <$> loadView (Store.txRowId row))
  idle why = fmap (Idle why) <$> current
  report input = do
    after <- db runtime (maybe (Left (T.pack "unknown-transaction")) Right <$> Store.findTransaction (Store.txRowId row))
    case after of
      Left code -> pure (Left code)
      Right r -> do
        case kernelOf r >>= halt . txState of
          Just (s, c) -> () <$ ensureRequest runtime r s c
          Nothing -> pure ()
        fmap (Stepped (txInputName input)) <$> current
  halt state =
    case state of
      Halted s c -> Just (s, c)
      _ -> Nothing

{- | E4: invocations found started but not finished. A role's is finished as
@uncertain@ and the transaction halts (never run again by itself); a
command's is finished as @interrupted@ and the stage runs again.
-}
settleUnfinished :: DatabaseRuntime -> Store.TransactionRow -> Stage -> IO (Either T.Text (Maybe TxInput))
settleUnfinished runtime row _ = do
  unfinished <- db runtime (Right <$> Store.unfinishedInvocations (Store.txRowId row))
  case unfinished of
    Left code -> pure (Left code)
    Right [] -> pure (Right Nothing)
    Right invocations -> do
      let
        isRole i = Store.invocationRowWhat i `L.elem` fmap roleName [Planner, Challenger, Implementer, Reviewer]
        roles = L.filter isRole invocations
      finished <-
        db runtime . O.withTransaction $ do
          traverse_
            (\i -> Store.finishInvocation (Store.invocationRowId i) (emptyFinish (T.pack (if isRole i then "uncertain" else "interrupted"))))
            invocations
          pure (Right ())
      case finished of
        Left code -> pure (Left code)
        Right ()
          | L.null roles -> pure (Right Nothing)
          | otherwise -> do
              let
                input = RoleUncertain (T.pack "unfinished-invocation")
                body = JObject [(T.pack "invocations", strings (fmap Store.invocationRowId roles))]
              applied <- applyInput runtime (Store.txRowId row) (Store.txRowRevision row) Supervisor input [(T.pack "uncertain", body)] id
              pure (Just input <$ applied)

emptyFinish :: T.Text -> Store.Finish
emptyFinish outcome =
  Store.Finish outcome Nothing Nothing Nothing Nothing Nothing Nothing Nothing Nothing

finishOf :: T.Text -> RunResult -> Store.Finish
finishOf outcome r =
  Store.Finish
    { Store.finishOutcome = outcome
    , Store.finishExit =
        case resultOutcome r of
          Exited n -> Just (fromIntegral n)
          _ -> Nothing
    , Store.finishMillis = Just (fromIntegral (resultMillis r))
    , Store.finishStdoutBytes = Just (fromIntegral (resultStdoutBytes r))
    , Store.finishStderrBytes = Just (fromIntegral (resultStderrBytes r))
    , Store.finishStdoutDigest = Just (sha256Hex (resultStdout r))
    , Store.finishStderrDigest = Just (sha256Hex (resultStderr r))
    , Store.finishStdoutTail = Just (tailOf (resultStdout r))
    , Store.finishStderrTail = Just (tailOf (resultStderr r))
    }

-- | The stage's work: its input and records, applied.
runStage :: DatabaseRuntime -> Engine -> Store.TransactionRow -> Stage -> IO (Either T.Text TxInput)
runStage runtime engine row stage =
  case stage of
    StageBasis -> basisStage runtime row
    StageDiscovery -> discoveryStage runtime engine row
    StageReproduction -> reproductionStage runtime engine row
    _ -> pure (Left (T.pack "stage-not-built"))

-- | Applies the input and returns it.
settle :: DatabaseRuntime -> Store.TransactionRow -> TxInput -> [(T.Text, Json)] -> (Store.TransactionRow -> Store.TransactionRow) -> IO (Either T.Text TxInput)
settle runtime row input records change =
  (input <$) <$> applyInput runtime (Store.txRowId row) (Store.txRowRevision row) Supervisor input records change

-- Basis (E5) ---------------------------------------------------------------------------

{- | E5: the Engineer still owns the repository (C-P4.1), its main worktree is
clean and @HEAD@ is a commit; that commit is the basis, and the Work Order's
branch is created at it.
-}
basisStage :: DatabaseRuntime -> Store.TransactionRow -> IO (Either T.Text TxInput)
basisStage runtime row = do
  let
    folder = T.unpack (Store.txRowFolder row)
    refuse code = settle runtime row (BasisRefused code) [(T.pack "basis-refused", JObject [(T.pack "code", string code)])] id
  owned <-
    db runtime $ do
      facts <- Store.admissionFacts (Store.txRowWorkOrder row)
      case facts of
        Nothing -> pure (Left (T.pack "not-admitted"))
        Just f -> fmap Right (ownershipHolds (Store.factRepository f) (Store.factEngineer f) folder)
  case owned of
    Left code -> pure (Left code)
    Right (Left code) -> refuse code
    Right (Right ()) -> do
      observed <- observeBasis folder
      case observed of
        Left code -> refuse code
        Right basis -> do
          let
            branch = workBranch (Store.txRowWorkOrder row)
          made <- createWorkBranch folder branch (basisCommit basis)
          case made of
            Left code -> refuse code
            Right () ->
              settle
                runtime
                row
                BasisReady
                [
                  ( T.pack "basis"
                  , JObject
                      [ (T.pack "commit", string (basisCommit basis))
                      , (T.pack "tree", string (basisTree basis))
                      , (T.pack "branch", string branch)
                      ]
                  )
                ]
                (\r -> r {Store.txRowBasis = Just (basisCommit basis), Store.txRowBranch = Just branch})

-- Workspaces ---------------------------------------------------------------------------

-- | A fresh workspace with the exact tree of the commit.
workspaceAt :: Engine -> Store.TransactionRow -> T.Text -> IO (Either T.Text (Workspace, [TreeEntry]))
workspaceAt engine row commit = do
  prepared <- runnerPrepare (engineRunner engine)
  case prepared of
    Left code -> pure (Left code)
    Right workspace -> do
      written <- writeSnapshot (T.unpack (Store.txRowFolder row)) commit (workspaceTree workspace)
      pure ((,) workspace <$> written)

-- Discovery (E6) -----------------------------------------------------------------------

{- | E6: the Planner's discovery on a read-only snapshot of the basis. Its
citations must name files of the basis and lines they have
(@citation-outside-source@ otherwise); the answer is kept as data.
-}
discoveryStage :: DatabaseRuntime -> Engine -> Store.TransactionRow -> IO (Either T.Text TxInput)
discoveryStage runtime engine row =
  case Store.txRowBasis row of
    Nothing -> settle runtime row (SupervisorFailed (T.pack "basis-missing")) [] id
    Just basis -> do
      task <- db runtime (fromMaybe (Left (T.pack "unknown-task")) <$> findTaskIn (Store.txRowTask row))
      case task of
        Left code -> settle runtime row (SupervisorFailed code) [] id
        Right view -> do
          let
            context =
              renderJson $
                JObject
                  [ (T.pack "role", string (roleName Planner))
                  , (T.pack "stage", string (stageName StageDiscovery))
                  , (T.pack "ticket", JObject [(T.pack "title", string (taskTitle view)), (T.pack "what_done_looks_like", string (taskAcceptance view))])
                  , (T.pack "basis", string basis)
                  , (T.pack "answer", JObject [(T.pack "file", string (T.pack "result.json")), (T.pack "kind", string (T.pack "discovery"))])
                  ]
          invoked <- invokeRecorded runtime engine row Planner StageDiscovery basis context
          case invoked of
            Left code -> pure (Left code)
            Right (Left input) -> settle runtime row input [] id
            Right (Right (answer, entries, workspace, _)) ->
              case answer of
                AnswerDiscovery d -> do
                  cited <- citationsHold (workspaceTree workspace) entries (discoveryCitations d)
                  if not cited
                    then settle runtime row (RoleFailed (T.pack "citation-outside-source")) [] id
                    else settle runtime row DiscoveryAnswered [(T.pack "discovery", discoveryJson d)] id
                _ -> settle runtime row (RoleFailed (T.pack "answer-invalid wrong-stage")) [] id

-- | Every citation names a file of the snapshot and lines it has.
citationsHold :: FilePath -> [TreeEntry] -> [Citation] -> IO Bool
citationsHold tree entries citations =
  L.and <$> traverse holds citations
 where
  holds c =
    if citationPath c `L.notElem` fmap entryPath entries
      then pure False
      else do
        bytes <- try (BS.readFile (tree <> "/" <> T.unpack (citationPath c)))
        pure $ case bytes of
          Left (_ :: IOException) -> False
          Right b -> citationLast c <= L.length (T.lines (decodeLenient b))

-- | The discovery in its answer form (the invocation it came from is in the invocations).
discoveryJson :: Discovery -> Json
discoveryJson d =
  JObject
    ( [ (T.pack "kind", string (T.pack "discovery"))
      , (T.pack "summary", string (discoverySummary d))
      , (T.pack "hypothesis", string (discoveryHypothesis d))
      , (T.pack "citations", JArray [JObject [(T.pack "path", string (citationPath c)), (T.pack "first", JNumber (toInteger (citationFirst c))), (T.pack "last", JNumber (toInteger (citationLast c)))] | c <- discoveryCitations d])
      , (T.pack "allowed_paths", strings (discoveryAllowedPaths d))
      ]
        <> [(T.pack "reproduction", JObject [(T.pack "argv", strings (checkArgv c)), (T.pack "signature", string (checkSignature c))]) | Just c <- [discoveryReproduction d]]
    )

-- | The discovery a record holds, read back through the answer decoder.
recordedDiscovery :: T.Text -> Maybe Discovery
recordedDiscovery body =
  case decodeAnswer (TE.encodeUtf8 body) of
    Right (AnswerDiscovery d) -> Just d
    _ -> Nothing

{- | A role run, recorded before and finished after. Right Left: the role
ended without an answer (its input); Right Right: the answer, the snapshot's
entries, the workspace and the invocation id.
-}
invokeRecorded :: DatabaseRuntime -> Engine -> Store.TransactionRow -> Role -> Stage -> T.Text -> T.Text -> IO (Either T.Text (Either TxInput (RoleAnswer, [TreeEntry], Workspace, T.Text)))
invokeRecorded runtime engine row role stage commit context = do
  ordinal <- db runtime (Right . L.length . L.filter ((== roleName role) . Store.invocationRowWhat) <$> Store.transactionInvocations (Store.txRowId row))
  case ordinal of
    Left code -> pure (Left code)
    Right n ->
      case engineAdapter engine role n of
        Nothing -> pure (Right (Left (RoleFailed (T.pack "no-coding-agent"))))
        Just adapter -> do
          ws <- workspaceAt engine row commit
          case ws of
            Left code -> pure (Right (Left (SupervisorFailed code)))
            Right (workspace, entries) -> do
              prepared <- prepareRole adapter workspace context
              case prepared of
                Left code -> pure (Right (Left (SupervisorFailed code)))
                Right argv -> do
                  u <- newUuid
                  let
                    invocation = uuidText u
                  started <-
                    db runtime . O.withTransaction $ do
                      locked <- Store.lockTransaction (Store.txRowId row)
                      case locked of
                        Just current
                          | Store.txRowRevision current == Store.txRowRevision row -> do
                              Store.insertInvocation
                                Store.InvocationRow
                                  { Store.invocationRowId = invocation
                                  , Store.invocationRowTransaction = Store.txRowId row
                                  , Store.invocationRowStage = stageName stage
                                  , Store.invocationRowWhat = roleName role
                                  , Store.invocationRowRunner = runnerName (engineRunner engine)
                                  , Store.invocationRowAdapter = adapterName adapter
                                  , Store.invocationRowArgv = renderJson (strings argv)
                                  , Store.invocationRowOutcome = Nothing
                                  , Store.invocationRowExit = Nothing
                                  , Store.invocationRowMillis = Nothing
                                  , Store.invocationRowStdoutBytes = Nothing
                                  , Store.invocationRowStderrBytes = Nothing
                                  , Store.invocationRowStdoutDigest = Nothing
                                  , Store.invocationRowStderrDigest = Nothing
                                  , Store.invocationRowStdoutTail = Nothing
                                  , Store.invocationRowStderrTail = Nothing
                                  }
                              pure (Right ())
                        _ -> pure (Left (T.pack "stale-step"))
                  case started of
                    Left code -> pure (Left code)
                    Right () -> do
                      outcome <- runPrepared (engineRunner engine) role workspace argv []
                      let
                        (code, evidence, input) =
                          case outcome of
                            Roles.RoleAnswered _ r -> (T.pack "answered", Just r, Nothing)
                            Roles.RoleFailed c r -> (c, r, Just (RoleFailed c))
                            Roles.RoleUncertain c -> (T.pack "uncertain " <> c, Nothing, Just (RoleUncertain c))
                      finished <- db runtime (Right <$> Store.finishInvocation invocation (maybe (emptyFinish code) (finishOf code) evidence))
                      pure $ case (finished, outcome, input) of
                        (Left c, _, _) -> Left c
                        (_, Roles.RoleAnswered a _, _) -> Right (Right (a, entries, workspace, invocation))
                        (_, _, Just i) -> Right (Left i)
                        (_, _, Nothing) -> Right (Left (RoleFailed code))

-- Reproduction (E7) --------------------------------------------------------------------

{- | E7: the discovery's reproduction command, run at the basis by the
Supervisor (a fresh snapshot, the runner's verification profile). It
reproduces only if it fails with its signature ('reproduces'); without a
command, or when it does not reproduce, the transaction halts with
@reproduction-missing@ (only a person may accept non-reproduction).
-}
reproductionStage :: DatabaseRuntime -> Engine -> Store.TransactionRow -> IO (Either T.Text TxInput)
reproductionStage runtime engine row = do
  records <- db runtime (Right <$> Store.transactionRecords (Store.txRowId row))
  case (records, Store.txRowBasis row) of
    (Left code, _) -> pure (Left code)
    (_, Nothing) -> settle runtime row (SupervisorFailed (T.pack "basis-missing")) [] id
    (Right rs, Just basis) ->
      case L.reverse [d | r <- rs, Store.recordRowKind r == T.pack "discovery", Just d <- [recordedDiscovery (Store.recordRowBody r)]] of
        [] -> settle runtime row (SupervisorFailed (T.pack "discovery-missing")) [] id
        d : _ ->
          case discoveryReproduction d of
            Nothing -> settle runtime row NotReproduced [(T.pack "reproduction", JObject [(T.pack "command", JNull), (T.pack "reproduced", JBool False)])] id
            Just check -> runCheck basis check
 where
  runCheck basis check = do
    ws <- workspaceAt engine row basis
    case ws of
      Left code -> settle runtime row (SupervisorFailed code) [] id
      Right (workspace, _) -> do
        u <- newUuid
        let
          invocation = uuidText u
        started <-
          db runtime $ do
            Store.insertInvocation
              Store.InvocationRow
                { Store.invocationRowId = invocation
                , Store.invocationRowTransaction = Store.txRowId row
                , Store.invocationRowStage = stageName StageReproduction
                , Store.invocationRowWhat = T.pack "reproduction"
                , Store.invocationRowRunner = runnerName (engineRunner engine)
                , Store.invocationRowAdapter = T.pack "supervisor"
                , Store.invocationRowArgv = renderJson (strings (checkArgv check))
                , Store.invocationRowOutcome = Nothing
                , Store.invocationRowExit = Nothing
                , Store.invocationRowMillis = Nothing
                , Store.invocationRowStdoutBytes = Nothing
                , Store.invocationRowStderrBytes = Nothing
                , Store.invocationRowStdoutDigest = Nothing
                , Store.invocationRowStderrDigest = Nothing
                , Store.invocationRowStdoutTail = Nothing
                , Store.invocationRowStderrTail = Nothing
                }
            pure (Right ())
        case started of
          Left code -> pure (Left code)
          Right () -> do
            ran <- try (runnerRun (engineRunner engine) workspace ProfileVerify (roleLimits RoleCommand) (checkArgv check) [])
            case ran of
              Left (_ :: IOException) -> finishAndHalt invocation (T.pack "runner-exception")
              Right (Left (RunnerRefused code)) -> finishAndHalt invocation code
              Right (Left (RunnerUncertain code)) -> finishAndHalt invocation code
              Right (Right result) -> do
                let
                  out = decodeLenient (resultStdout result)
                  err = decodeLenient (resultStderr result)
                  reproduced = reproduces check (resultOutcome result) out err
                  body =
                    JObject
                      [ (T.pack "command", strings (checkArgv check))
                      , (T.pack "signature", string (checkSignature check))
                      , (T.pack "outcome", string (outcomeName (resultOutcome result)))
                      , (T.pack "exit", maybe JNull (JNumber . toInteger) (exitOf (resultOutcome result)))
                      , (T.pack "reproduced", JBool reproduced)
                      , (T.pack "stdout_tail", string (tailOf (resultStdout result)))
                      , (T.pack "stderr_tail", string (tailOf (resultStderr result)))
                      , (T.pack "invocation", string invocation)
                      ]
                finished <- db runtime (Right <$> Store.finishInvocation invocation (finishOf (outcomeName (resultOutcome result)) result))
                case finished of
                  Left code -> pure (Left code)
                  Right () -> settle runtime row (if reproduced then Reproduced else NotReproduced) [(T.pack "reproduction", body)] id
  finishAndHalt invocation code = do
    _ <- db runtime (Right <$> Store.finishInvocation invocation (emptyFinish (T.pack "runner-failed")))
    settle runtime row (SupervisorFailed code) [] id
  exitOf outcome =
    case outcome of
      Exited n -> Just n
      _ -> Nothing

-- Halts (E3) ---------------------------------------------------------------------------

{- | The open decision request for a halt, made once per halt record (its key
comes from the transaction and the record's sequence, so it is made again
with the same key and identity if a previous attempt was cut short).
-}
ensureRequest :: DatabaseRuntime -> Store.TransactionRow -> Stage -> T.Text -> IO (Either T.Text ())
ensureRequest runtime row stage code = do
  records <- db runtime (Right <$> Store.transactionRecords (Store.txRowId row))
  case records of
    Left c -> pure (Left c)
    Right rs ->
      case L.reverse [r | r <- rs, Store.recordRowKind r == T.pack "halt"] of
        [] -> pure (Left (T.pack "halt-record-missing"))
        h : _ ->
          case mkIdempotencyKey (T.pack "halt-" <> T.filter (/= '-') (Store.txRowId row) <> T.pack "-" <> T.pack (show (Store.recordRowSequence h))) of
            Left _ -> pure (Left (T.pack "halt-key-invalid"))
            Right key -> do
              opened <-
                openRequest
                  runtime
                  key
                  SenderSupervisor
                  NewHumanRequest
                    { newRequestWorkOrder = Store.txRowWorkOrder row
                    , newRequestEngineer = Store.txRowEngineer row
                    , newRequestContract = Store.txRowContract row
                    , newRequestChoices = Just (haltChoices stage code)
                    , newRequestQuestion = haltQuestion stage code
                    , newRequestEvidence = T.pack "Transaction " <> Store.txRowId row <> T.pack ", record " <> T.pack (show (Store.recordRowSequence h)) <> T.pack ": " <> code
                    , newRequestAuthority = T.pack "Whether Lockstep tries this step again, accepts it as it is, or stops this bug fix."
                    }
              pure $ case opened of
                Left _ -> Left (T.pack "database-unavailable")
                Right (Left c) -> Left c
                Right (Right _) -> Right ()

haltQuestion :: Stage -> T.Text -> T.Text
haltQuestion stage code =
  T.pack "Lockstep stopped this bug fix at the " <> stageName stage <> T.pack " step (" <> code <> T.pack "). What should happen next?"
