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
  , decideCompletion
  , activeTransactionIds
  , pendingWorkOrders
  ) where

import Control.Exception (IOException, try)
import Control.Monad ((>=>))
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
import System.Directory (createDirectoryIfMissing, doesDirectoryExist, pathIsSymbolicLink)
import System.IO (FilePath)
import Text.Show (Show, show)

import Lockstep.Application.Command (mkIdempotencyKey)
import Lockstep.Application.Conversation (NewHumanRequest (..), Sender (..), StoredRequest (..), openRequest, senderChannel, senderEvidence)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason, Readiness (..), checkReadiness, withDatabase)
import Lockstep.Application.EngineCandidate (baselineJson, candidateJson, findingJson, frozenContract, recordedCandidate, testFiles, unchangedAtBasis)
import Lockstep.Application.Identity (newUuid)
import Lockstep.Application.Repositories (ownershipHolds)
import Lockstep.Application.Tasks (TaskView (..), findTaskIn)
import Lockstep.Effects.GitSupervisor (Basis (..), CommitMeta (..), advanceBranch, branchHead, commitChanges, commitTime, createWorkBranch, observeBasis, snapshotChanges, writeSnapshot)
import Lockstep.Effects.Process (RunResult (..))
import Lockstep.Effects.Roles (Adapter (..), Runner (..), RunnerFailure (..), Workspace (..), decodeAnswer, prepareRole, runPrepared)
import Lockstep.Effects.Roles qualified as Roles
import Lockstep.Foundation.Json (Json (..), renderJson, string, strings)
import Lockstep.Foundation.RunnerProtocol (RunProfile (..))
import Lockstep.Kernel.Candidate (MutantRun (..), classifyTest, disposeFinding, quoteGrounded)
import Lockstep.Kernel.GitBasis (Change (..), TreeEntry (..), TreeMode (..), treePathValid, workBranch)
import Lockstep.Kernel.Identity (parseUuid, uuidText)
import Lockstep.Kernel.Roles
  ( Candidate (..)
  , CandidateTest (..)
  , Challenge (..)
  , Check (..)
  , Citation (..)
  , Criterion (..)
  , Discovery (..)
  , FileContent (..)
  , Finding (..)
  , Implementation (..)
  , Review (..)
  , Role (..)
  , RoleAnswer (..)
  , Verdict (..)
  , roleName
  , verdictName
  )
import Lockstep.Kernel.Runner (RoleKind (..), RunOutcome (..), outcomeName, roleLimits)
import Lockstep.Kernel.Transaction
  ( BaselineClass (..)
  , Counters (..)
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

-- | C-P4.15 W1: the running or halted transactions, in start order.
activeTransactionIds :: DatabaseRuntime -> IO (Either NotReadyReason [T.Text])
activeTransactionIds runtime =
  whenReady runtime (withDatabase runtime (fmap Store.txRowId <$> Store.activeTransactions))

-- | C-P4.15 W1: the handed-over bug Work Orders with no transaction yet, in hand-over order.
pendingWorkOrders :: DatabaseRuntime -> IO (Either NotReadyReason [T.Text])
pendingWorkOrders runtime =
  whenReady runtime (withDatabase runtime Store.pendingAdmissions)

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
request to a person (opened again if it is missing) and, once a person has
answered that request, their answer applied (C-P4.15 H1). Refused:
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
          opened <- ensureRequest runtime row stage code
          case either (const Nothing) resumeOf opened of
            Nothing -> idle (T.pack "halted")
            Just (request, choice, input) -> do
              let
                body = JObject [(T.pack "request", string (storedRequestId request)), (T.pack "choice", string choice), (T.pack "revision", JNumber (fromIntegral (storedRevision request)))]
              applied <- applyInput runtime (Store.txRowId row) (Store.txRowRevision row) Human input [(T.pack "resume", body)] id
              case applied of
                Left c -> pure (Left c)
                Right _ -> report input
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

{- | C-P4.15 H2: a person's Done or not-done for an accepted transaction.
Refused, in this order: @agent-assertion@ (an Agent); @not-authorized@ (the
Supervisor or a Planner: only a person decides); @unknown-choice@ (not
@done@ or @not-done@); @unknown-transaction@; @closed@ (done or stopped);
@illegal-input@ (not accepted yet); @stale-step@ (changed meanwhile).
-}
decideCompletion :: DatabaseRuntime -> T.Text -> Sender -> T.Text -> IO (Either NotReadyReason (Either T.Text TransactionView))
decideCompletion runtime raw sender choice =
  whenReady runtime $
    case sender of
      SenderAgent _ -> refuse "agent-assertion"
      SenderSupervisor -> refuse "not-authorized"
      SenderPlanner _ -> refuse "not-authorized"
      SenderHuman _ ->
        case (T.unpack choice, canonicalId raw) of
          ("done", Just txId) -> decide txId HumanDone
          ("not-done", Just txId) -> decide txId HumanStop
          ("done", Nothing) -> refuse "unknown-transaction"
          ("not-done", Nothing) -> refuse "unknown-transaction"
          _ -> refuse "unknown-choice"
 where
  refuse code =
    pure (Right (Left (T.pack code)))
  decide txId input = do
    loaded <- withDatabase runtime (Store.findTransaction txId)
    case loaded of
      Left reason -> pure (Left reason)
      Right Nothing -> refuse "unknown-transaction"
      Right (Just row) ->
        case txState <$> kernelOf row of
          Nothing -> refuse "transaction-unreadable"
          Just Done -> refuse "closed"
          Just (Stopped _) -> refuse "closed"
          Just Accepted -> do
            let
              body = JObject [(T.pack "choice", string choice), (T.pack "channel", string (senderChannel sender)), (T.pack "evidence", string (senderEvidence sender))]
            applied <- applyInput runtime txId (Store.txRowRevision row) Human input [(T.pack "completion", body)] id
            case applied of
              Left code -> pure (Right (Left code))
              Right _ -> Right <$> db runtime (maybe (Left (T.pack "unknown-transaction")) Right <$> loadView txId)
          Just _ -> refuse "illegal-input"

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
    StageCandidate -> candidateStage runtime engine row
    StageChallengePre -> challengeStage runtime engine row
    StageFreeze -> freezeStage runtime row
    StageImplement -> implementStage runtime engine row
    StageVerify -> verifyStage runtime engine row
    StageChallengePost -> challengePostStage runtime engine row
    StageReview -> reviewStage runtime engine row
    StageAccept -> acceptStage runtime row

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

-- | A file added to a snapshot: its tree path and bytes.
type ExtraFile =
  (T.Text, BS.ByteString)

{- | A fresh workspace with the exact tree of the commit, and the extra files
written into it (a test, a mutant). An extra file's path must be valid
(C-P4.4 G1) and no segment on its way may be a link (@extra-file-unusable@).
-}
workspaceAt :: Engine -> Store.TransactionRow -> T.Text -> [ExtraFile] -> IO (Either T.Text (Workspace, [TreeEntry]))
workspaceAt engine row commit extras = do
  prepared <- runnerPrepare (engineRunner engine)
  case prepared of
    Left code -> pure (Left code)
    Right workspace -> do
      written <- writeSnapshot (T.unpack (Store.txRowFolder row)) commit (workspaceTree workspace)
      case written of
        Left code -> pure (Left code)
        Right entries -> do
          added <- traverse (writeExtra (workspaceTree workspace)) extras
          pure $
            if L.and added
              then Right (workspace, entries)
              else Left (T.pack "extra-file-unusable")

writeExtra :: FilePath -> ExtraFile -> IO Bool
writeExtra tree (path, bytes)
  | not (treePathValid path) = pure False
  | otherwise = do
      let
        segments = T.splitOn (T.pack "/") path
        parents = L.drop 1 (L.scanl (\acc s -> acc <> "/" <> T.unpack s) tree (L.take (L.length segments - 1) segments))
        target = tree <> "/" <> T.unpack path
      linked <- traverse (\p -> fromRight False <$> (try (pathIsSymbolicLink p) :: IO (Either IOException Bool))) (parents <> [target])
      if L.or linked
        then pure False
        else do
          made <- try (traverse_ (createDirectoryIfMissing False) parents >> BS.writeFile target bytes)
          pure (either (\(_ :: IOException) -> False) (const True) made)

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
          invoked <- invokeRecorded runtime engine row Planner StageDiscovery basis [] [] context
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
invokeRecorded :: DatabaseRuntime -> Engine -> Store.TransactionRow -> Role -> Stage -> T.Text -> [ExtraFile] -> [T.Text] -> T.Text -> IO (Either T.Text (Either TxInput (RoleAnswer, [TreeEntry], Workspace, T.Text)))
invokeRecorded runtime engine row role stage commit extras protected context = do
  ordinal <- db runtime (Right . L.length . L.filter ((== roleName role) . Store.invocationRowWhat) <$> Store.transactionInvocations (Store.txRowId row))
  case ordinal of
    Left code -> pure (Left code)
    Right n ->
      case engineAdapter engine role n of
        Nothing -> pure (Right (Left (RoleFailed (T.pack "no-coding-agent"))))
        Just adapter -> do
          ws <- workspaceAt engine row commit extras
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
                      outcome <- runPrepared (engineRunner engine) role workspace argv protected
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
    ws <- workspaceAt engine row basis []
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

-- Commands and records (C-P4.7-9) ---------------------------------------------------------

{- | A command the Supervisor runs in a workspace (command limits, the
verification profile), recorded as an invocation before it runs and finished
after. Left: the runner refused it or its result is unknown (finished
@runner-failed@).
-}
runCommand :: DatabaseRuntime -> Engine -> Store.TransactionRow -> Stage -> T.Text -> Workspace -> [T.Text] -> IO (Either T.Text RunResult)
runCommand runtime engine row stage what workspace argv = do
  u <- newUuid
  let
    invocation = uuidText u
  started <-
    db runtime $ do
      Store.insertInvocation
        Store.InvocationRow
          { Store.invocationRowId = invocation
          , Store.invocationRowTransaction = Store.txRowId row
          , Store.invocationRowStage = stageName stage
          , Store.invocationRowWhat = what
          , Store.invocationRowRunner = runnerName (engineRunner engine)
          , Store.invocationRowAdapter = T.pack "supervisor"
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
  case started of
    Left code -> pure (Left code)
    Right () -> do
      ran <- try (runnerRun (engineRunner engine) workspace ProfileVerify (roleLimits RoleCommand) argv [])
      let
        failed code = do
          _ <- db runtime (Right <$> Store.finishInvocation invocation (emptyFinish (T.pack "runner-failed")))
          pure (Left code)
      case ran of
        Left (_ :: IOException) -> failed (T.pack "runner-exception")
        Right (Left (RunnerRefused code)) -> failed code
        Right (Left (RunnerUncertain code)) -> failed code
        Right (Right result) -> do
          finished <- db runtime (Right <$> Store.finishInvocation invocation (finishOf (outcomeName (resultOutcome result)) result))
          pure (result <$ finished)

-- | The body of the latest record of a kind.
latestRecord :: T.Text -> [Store.RecordRow] -> Maybe T.Text
latestRecord kind records =
  case L.reverse [Store.recordRowBody r | r <- records, Store.recordRowKind r == kind] of
    body : _ -> Just body
    [] -> Nothing

-- | The task's title and what done looks like.
taskTexts :: DatabaseRuntime -> Store.TransactionRow -> IO (Either T.Text (T.Text, T.Text))
taskTexts runtime row = do
  task <- db runtime (fromMaybe (Left (T.pack "unknown-task")) <$> findTaskIn (Store.txRowTask row))
  pure ((\v -> (taskTitle v, taskAcceptance v)) <$> task)

-- | The Ticket, the discovery, the reproduction record and earlier feedback records.
gathered :: DatabaseRuntime -> Store.TransactionRow -> IO (Either T.Text ((T.Text, T.Text), Json, T.Text, [T.Text], [Store.RecordRow]))
gathered runtime row = do
  ticket <- taskTexts runtime row
  records <- db runtime (Right <$> Store.transactionRecords (Store.txRowId row))
  pure $ do
    t <- ticket
    rs <- records
    d <- maybe (Left (T.pack "discovery-missing")) Right (latestRecord (T.pack "discovery") rs >>= recordedDiscovery)
    reproduction <- maybe (Left (T.pack "reproduction-missing")) Right (latestRecord (T.pack "reproduction") rs)
    let
      feedback = [Store.recordRowBody r | r <- rs, Store.recordRowKind r `L.elem` fmap T.pack ["baseline", "finding", "candidate-rejected"]]
    Right (t, discoveryJson d, reproduction, feedback, rs)

-- A program the runner could not find: never a test result (DG-17 D-17.9).
environmentMissing :: T.Text -> Bool
environmentMissing code =
  T.pack "executable-missing" `T.isInfixOf` code

-- Candidate (C-P4.7-9 S1) -----------------------------------------------------------------

{- | S1: the Planner's Contract and candidate tests, checked, then each test
run by the Supervisor at the basis with all the tests added and classified
('classifyTest'). See C-P4.7-9 S1 for every refusal.
-}
candidateStage :: DatabaseRuntime -> Engine -> Store.TransactionRow -> IO (Either T.Text TxInput)
candidateStage runtime engine row =
  case Store.txRowBasis row of
    Nothing -> settle runtime row (SupervisorFailed (T.pack "basis-missing")) [] id
    Just basis -> do
      g <- gathered runtime row
      case g of
        Left code -> settle runtime row (SupervisorFailed code) [] id
        Right ((title, acceptance), discovery, reproduction, feedback, _) -> do
          let
            context =
              renderJson $
                JObject
                  [ (T.pack "role", string (roleName Planner))
                  , (T.pack "stage", string (stageName StageCandidate))
                  , (T.pack "ticket", JObject [(T.pack "title", string title), (T.pack "what_done_looks_like", string acceptance)])
                  , (T.pack "basis", string basis)
                  , (T.pack "discovery", discovery)
                  , (T.pack "reproduction", JRaw reproduction)
                  , (T.pack "feedback", JArray (fmap JRaw feedback))
                  , (T.pack "answer", JObject [(T.pack "file", string (T.pack "result.json")), (T.pack "kind", string (T.pack "candidate"))])
                  ]
          invoked <- invokeRecorded runtime engine row Planner StageCandidate basis [] [] context
          case invoked of
            Left code -> pure (Left code)
            Right (Left input) -> settle runtime row input [] id
            Right (Right (AnswerCandidate c, entries, workspace, _)) -> examine basis (title, acceptance) c entries workspace
            Right (Right _) -> settle runtime row (RoleFailed (T.pack "answer-invalid wrong-stage")) [] id
 where
  examine basis (title, acceptance) c entries workspace = do
    cited <- citationsHold (workspaceTree workspace) entries (L.concatMap criterionCitations (candidateCriteria c))
    unusable <- traverse (unusablePath (workspaceTree workspace) entries . testPath) (candidateTests c)
    let
      record = (T.pack "candidate", candidateJson c)
      rejected code = settle runtime row (CandidateRejected code) [record, (T.pack "candidate-rejected", JObject [(T.pack "code", string code)])] id
    case () of
      _
        | not (L.all (quoteGrounded [title, acceptance] . criterionTicketQuote) (candidateCriteria c)) -> rejected (T.pack "criterion-not-grounded")
        | not cited -> rejected (T.pack "citation-outside-source")
        | L.or unusable -> rejected (T.pack "test-path-unusable")
        | otherwise -> baseline basis c entries [record]
  baseline basis c entries records = do
    runs <- traverse (baselineRun basis c) (candidateTests c)
    let
      missing = L.any (either environmentMissing (const False)) runs
      outcomes = rights runs
    case () of
      _
        | missing || L.any (\(_, r, _) -> resultOutcome r == Exited 127) outcomes ->
            settle runtime row (VerificationInconclusive (T.pack "verification-environment-missing")) (records <> [(T.pack "baseline", b) | (_, _, b) <- outcomes]) id
        | otherwise ->
            case sequenceA runs of
              Left code -> settle runtime row (SupervisorFailed code) records id
              Right classified -> do
                let
                  bodies = records <> [(T.pack "baseline", body) | (_, _, body) <- classified]
                  existingFailed =
                    L.or [cls == GreenCandidateFailed && unchangedAtBasis entries t | (t, (cls, _, _)) <- L.zip (candidateTests c) classified]
                if existingFailed
                  then settle runtime row RegressionFailed bodies id
                  else settle runtime row (CandidateClassified [cls | (cls, _, _) <- classified]) bodies id
  baselineRun basis c t = do
    ws <- workspaceAt engine row basis (testFiles c)
    case ws of
      Left code -> pure (Left code)
      Right (workspace, _) -> do
        ran <- runCommand runtime engine row StageCandidate (T.pack "baseline") workspace (testArgv t)
        pure $ do
          r <- ran
          let
            cls = classifyTest (testExpectation t) (testPath t) (testSignature t) (resultOutcome r) (decodeLenient (resultStdout r)) (decodeLenient (resultStderr r))
          Right (cls, r, baselineJson t cls (outcomeName (resultOutcome r)) (tailOf (resultStdout r)) (tailOf (resultStderr r)))

-- | A test path that the basis already has as a link or a directory.
unusablePath :: FilePath -> [TreeEntry] -> T.Text -> IO Bool
unusablePath tree entries path =
  if L.any (\e -> entryPath e == path && entryMode e == ModeSymlink) entries
    then pure True
    else doesDirectoryExist (tree <> "/" <> T.unpack path)

-- Challenge before the freeze (C-P4.7-9 S2) ---------------------------------------------------

{- | S2: the challenger, read-only, on the basis with the candidate tests, given
the Ticket, the Contract, the discovery and the reproduction record — no
transcript. The Supervisor runs every mutant and demonstration itself;
'disposeFinding' decides from what it observed.
-}
challengeStage :: DatabaseRuntime -> Engine -> Store.TransactionRow -> IO (Either T.Text TxInput)
challengeStage runtime engine row =
  case Store.txRowBasis row of
    Nothing -> settle runtime row (SupervisorFailed (T.pack "basis-missing")) [] id
    Just basis -> do
      g <- gathered runtime row
      case g of
        Left code -> settle runtime row (SupervisorFailed code) [] id
        Right ((title, acceptance), discovery, reproduction, _, rs) ->
          case latestRecord (T.pack "candidate") rs >>= recordedCandidate of
            Nothing -> settle runtime row (SupervisorFailed (T.pack "candidate-missing")) [] id
            Just c -> do
              let
                context =
                  renderJson $
                    JObject
                      [ (T.pack "role", string (roleName Challenger))
                      , (T.pack "stage", string (stageName StageChallengePre))
                      , (T.pack "ticket", JObject [(T.pack "title", string title), (T.pack "what_done_looks_like", string acceptance)])
                      , (T.pack "basis", string basis)
                      , (T.pack "contract", candidateJson c)
                      , (T.pack "discovery", discovery)
                      , (T.pack "reproduction", JRaw reproduction)
                      , (T.pack "answer", JObject [(T.pack "file", string (T.pack "result.json")), (T.pack "kind", string (T.pack "challenge"))])
                      ]
              invoked <- invokeRecorded runtime engine row Challenger StageChallengePre basis (testFiles c) [] context
              case invoked of
                Left code -> pure (Left code)
                Right (Left input) -> settle runtime row input [] id
                Right (Right (AnswerChallenge ch, _, _, _)) -> dispose basis c (challengeFindings ch)
                Right (Right _) -> settle runtime row (RoleFailed (T.pack "answer-invalid wrong-stage")) [] id
 where
  dispose basis c findings = do
    judged <- traverse (judge basis c) findings
    case sequenceA judged of
      Left code -> settle runtime row (SupervisorFailed code) [] id
      Right results ->
        settle runtime row (ChallengeDisposed (fmap fst results)) [(T.pack "finding", body) | (_, body) <- results] id
  judge basis c f = do
    run <- mutantRun basis c f
    pure $ do
      r <- run
      let
        grounded = findingRequirement f `L.elem` fmap criterionId (candidateCriteria c)
        disposition = disposeFinding grounded r (findingHint f)
      Right (disposition, findingJson f grounded r disposition)
  mutantRun basis c f
    | L.null (findingMutant f) = pure (Right NoMutant)
    | L.any ((`L.notElem` candidateAllowedPaths c) . filePath) (findingMutant f) = pure (Right MutantOutsideScope)
    | otherwise = do
        let
          mutant = [(filePath m, TE.encodeUtf8 (fileText m)) | m <- findingMutant f]
        ws <- workspaceAt engine row basis (testFiles c <> mutant)
        case ws of
          Left code -> pure (Left code)
          Right (workspace, _) -> do
            runs <- traverse (runCommand runtime engine row StageChallengePre (T.pack "mutant") workspace . testArgv) (candidateTests c)
            case sequenceA runs of
              Left code -> pure (Left code)
              Right results
                | L.any ((/= Exited 0) . resultOutcome) results -> pure (Right MutantKilled)
                | otherwise ->
                    case findingDemonstration f of
                      Nothing -> pure (Right (MutantSurvived False))
                      Just demo -> do
                        shown <- runCommand runtime engine row StageChallengePre (T.pack "demonstration") workspace (checkArgv demo)
                        pure $ do
                          r <- shown
                          Right (MutantSurvived (reproduces demo (resultOutcome r) (decodeLenient (resultStdout r)) (decodeLenient (resultStderr r))))

-- The freeze (C-P4.7-9 S3) -----------------------------------------------------------------

{- | S3: the Supervisor commits exactly the candidate tests on the work branch
on top of the basis (its identity, the basis's time plus one second, so a
retry makes the same commit), moves the branch from the basis by
compare-and-swap, and records the Contract and its digest.
-}
freezeStage :: DatabaseRuntime -> Store.TransactionRow -> IO (Either T.Text TxInput)
freezeStage runtime row = do
  records <- db runtime (Right <$> Store.transactionRecords (Store.txRowId row))
  let
    folder = T.unpack (Store.txRowFolder row)
    candidate = either (const Nothing) (latestRecord (T.pack "candidate") >=> recordedCandidate) records
  case (Store.txRowBasis row, Store.txRowBranch row, candidate) of
    (Just basis, Just branch, Just c) -> do
      head' <- branchHead folder branch
      time <- commitTime folder basis
      case (head', time) of
        (Right (Just h), Right t) | h == basis -> do
          let
            changes = [Change (testPath x) (Just (ModeFile, TE.encodeUtf8 (testContent x))) | x <- candidateTests c]
            message =
              T.pack "Lockstep: frozen tests\n\nLockstep-Work-Order: "
                <> Store.txRowWorkOrder row
                <> T.pack "\nLockstep-Transaction: "
                <> Store.txRowId row
                <> T.pack "\n"
          committed <- commitChanges folder basis changes (CommitMeta message (t + 1))
          case committed of
            Left code -> settle runtime row (SupervisorFailed code) [] id
            Right freeze -> do
              moved <- advanceBranch folder branch basis freeze
              case moved of
                Left code -> settle runtime row (SupervisorFailed code) [] id
                Right () -> do
                  let
                    contract = frozenContract basis freeze c
                    digest = sha256Hex (TE.encodeUtf8 (renderJson contract))
                  settle
                    runtime
                    row
                    TestsFrozen
                    [(T.pack "contract", contract), (T.pack "freeze", JObject [(T.pack "commit", string freeze), (T.pack "branch", string branch), (T.pack "contract_digest", string digest)])]
                    (\r -> r {Store.txRowFreeze = Just freeze, Store.txRowContract = Just digest})
        (Right (Just h), _) | h /= basis -> settle runtime row (SupervisorFailed (T.pack "branch-moved")) [] id
        (Right Nothing, _) -> settle runtime row (SupervisorFailed (T.pack "branch-missing")) [] id
        (Left code, _) -> settle runtime row (SupervisorFailed code) [] id
        (_, Left code) -> settle runtime row (SupervisorFailed code) [] id
        _ -> settle runtime row (SupervisorFailed (T.pack "branch-moved")) [] id
    _ -> settle runtime row (SupervisorFailed (T.pack "candidate-missing")) [] id

-- The implementer (C-P4.10-14 I1) ---------------------------------------------------------

{- | I1: one Implementer invocation on a Git-free snapshot of the freeze commit
(the protected tests mounted read-only by the container runner), then the
Supervisor's own comparison: refused, as one attempt, for a link, a special
file or a @.git@ (C-P4.4 G5), a change outside the allowed implementation
paths (@change-outside-scope@), any change to a protected test
(@protected-test-changed@), or no change at all (@no-change@). Otherwise the
Supervisor writes the candidate commit (its identity; on no branch) on top of
the freeze commit.
-}
implementStage :: DatabaseRuntime -> Engine -> Store.TransactionRow -> IO (Either T.Text TxInput)
implementStage runtime engine row = do
  records <- db runtime (Right <$> Store.transactionRecords (Store.txRowId row))
  ticket <- taskTexts runtime row
  case (records, ticket, Store.txRowFreeze row) of
    (Left code, _, _) -> pure (Left code)
    (_, Left code, _) -> settle runtime row (SupervisorFailed code) [] id
    (_, _, Nothing) -> settle runtime row (SupervisorFailed (T.pack "freeze-missing")) [] id
    (Right rs, Right (title, acceptance), Just freeze) ->
      case latestRecord (T.pack "candidate") rs >>= recordedCandidate of
        Nothing -> settle runtime row (SupervisorFailed (T.pack "candidate-missing")) [] id
        Just c -> do
          let
            protected = fmap testPath (candidateTests c)
            feedback = [Store.recordRowBody r | r <- rs, Store.recordRowKind r `L.elem` fmap T.pack ["implementation-refused", "verification", "post-finding", "review"]]
            context =
              renderJson $
                JObject
                  [ (T.pack "role", string (roleName Implementer))
                  , (T.pack "stage", string (stageName StageImplement))
                  , (T.pack "ticket", JObject [(T.pack "title", string title), (T.pack "what_done_looks_like", string acceptance)])
                  , (T.pack "contract", JRaw (fromMaybe (T.pack "null") (latestRecord (T.pack "contract") rs)))
                  , (T.pack "allowed_paths", strings (candidateAllowedPaths c))
                  , (T.pack "protected_tests", strings protected)
                  , (T.pack "feedback", JArray (fmap JRaw feedback))
                  , (T.pack "answer", JObject [(T.pack "file", string (T.pack "result.json")), (T.pack "kind", string (T.pack "implementation"))])
                  ]
          invoked <- invokeRecorded runtime engine row Implementer StageImplement freeze [] protected context
          case invoked of
            Left code -> pure (Left code)
            Right (Left input) -> settle runtime row input [] id
            Right (Right (AnswerImplementation i, entries, workspace, invocation)) -> do
              found <- snapshotChanges entries (workspaceTree workspace)
              let
                refused code paths = settle runtime row (ImplementationRefused code) [(T.pack "implementation-refused", JObject [(T.pack "code", string code), (T.pack "paths", strings paths), (T.pack "invocation", string invocation)])] id
              case found of
                Left code -> refused code []
                Right changes
                  | L.null changes -> refused (T.pack "no-change") []
                  | L.any ((`L.elem` protected) . changePath) changes -> refused (T.pack "protected-test-changed") (L.filter (`L.elem` protected) (fmap changePath changes))
                  | L.any ((`L.notElem` candidateAllowedPaths c) . changePath) changes -> refused (T.pack "change-outside-scope") (L.filter (`L.notElem` candidateAllowedPaths c) (fmap changePath changes))
                  | otherwise -> do
                      time <- commitTime (T.unpack (Store.txRowFolder row)) freeze
                      case time of
                        Left code -> settle runtime row (SupervisorFailed code) [] id
                        Right t -> do
                          let
                            attempt = Store.txRowAttempts row + 1
                            message =
                              T.pack "Fix: "
                                <> title
                                <> T.pack "\n\nLockstep-Work-Order: "
                                <> Store.txRowWorkOrder row
                                <> T.pack "\nLockstep-Contract: "
                                <> fromMaybe T.empty (Store.txRowContract row)
                                <> T.pack "\nLockstep-Attempt: "
                                <> T.pack (show attempt)
                                <> T.pack "\n"
                          committed <- commitChanges (T.unpack (Store.txRowFolder row)) freeze changes (CommitMeta message (t + toInteger attempt))
                          case committed of
                            Left code -> refused code []
                            Right candidate ->
                              settle
                                runtime
                                row
                                Implemented
                                [
                                  ( T.pack "implementation"
                                  , JObject
                                      [ (T.pack "summary", string (implementationSummary i))
                                      , (T.pack "changed", strings (fmap changePath changes))
                                      , (T.pack "candidate", string candidate)
                                      , (T.pack "attempt", JNumber (toInteger attempt))
                                      , (T.pack "invocation", string invocation)
                                      ]
                                  )
                                ]
                                (\r -> r {Store.txRowCandidate = Just candidate})
            Right (Right _) -> settle runtime row (RoleFailed (T.pack "answer-invalid wrong-stage")) [] id

-- Verification (C-P4.10-14 V1) -------------------------------------------------------------

{- | V1: the exact candidate commit, on a fresh snapshot: every protected test's
bytes there must be its frozen bytes (@protected-test-changed@ otherwise);
then every verification command and every frozen test runs. All pass →
passed. A program that is not there → @verification-environment-missing@; a
run that did not end normally → @verification-run-failed@ (both halt); any
other failure → failed (another attempt, if one is left).
-}
verifyStage :: DatabaseRuntime -> Engine -> Store.TransactionRow -> IO (Either T.Text TxInput)
verifyStage runtime engine row = do
  records <- db runtime (Right <$> Store.transactionRecords (Store.txRowId row))
  case (records, Store.txRowCandidate row) of
    (Left code, _) -> pure (Left code)
    (_, Nothing) -> settle runtime row (SupervisorFailed (T.pack "candidate-commit-missing")) [] id
    (Right rs, Just candidate) ->
      case latestRecord (T.pack "candidate") rs >>= recordedCandidate of
        Nothing -> settle runtime row (SupervisorFailed (T.pack "candidate-missing")) [] id
        Just c -> do
          ws <- workspaceAt engine row candidate []
          case ws of
            Left code -> settle runtime row (SupervisorFailed code) [] id
            Right (workspace, entries)
              | not (L.all (unchangedAtBasis entries) (candidateTests c)) ->
                  settle runtime row (VerificationInconclusive (T.pack "protected-test-changed")) [] id
              | otherwise -> do
                  let
                    commands = candidateVerification c <> fmap testArgv (candidateTests c)
                  runs <- traverse (\argv -> fmap ((,) argv) <$> runCommand runtime engine row StageVerify (T.pack "verification") workspace argv) commands
                  let
                    missing = L.any (either environmentMissing (const False)) runs
                    results = rights runs
                    bodies = [(T.pack "verification", JObject [(T.pack "command", strings argv), (T.pack "outcome", string (outcomeName (resultOutcome r))), (T.pack "stdout_tail", string (tailOf (resultStdout r))), (T.pack "stderr_tail", string (tailOf (resultStderr r)))]) | (argv, r) <- results]
                    summary passed = (T.pack "verification-summary", JObject [(T.pack "commit", string candidate), (T.pack "passed", JBool passed)])
                  case () of
                    _
                      | missing || L.any ((== Exited 127) . resultOutcome . snd) results ->
                          settle runtime row (VerificationInconclusive (T.pack "verification-environment-missing")) (bodies <> [summary False]) id
                      | L.any isLeft runs || not (L.all (exited . resultOutcome . snd) results) ->
                          settle runtime row (VerificationInconclusive (T.pack "verification-run-failed")) (bodies <> [summary False]) id
                      | L.all ((== Exited 0) . resultOutcome . snd) results ->
                          settle runtime row VerificationPassed (bodies <> [summary True]) id
                      | otherwise -> settle runtime row VerificationFailed (bodies <> [summary False]) id
 where
  exited outcome =
    case outcome of
      Exited _ -> True
      _ -> False

-- Challenge after the implementation (C-P4.10-14 C1) ----------------------------------------

{- | C1: the challenger again, read-only, on the exact candidate commit, given
the Ticket, the Contract, the change (paths and their new bytes) and the
verification results — never the Implementer's words. A finding's test is
added by the Supervisor to a fresh copy of the candidate and run: failing
with its signature is an observed counterexample. 'disposeFinding' decides
(a counterexample that does not appear is DISPROVED).
-}
challengePostStage :: DatabaseRuntime -> Engine -> Store.TransactionRow -> IO (Either T.Text TxInput)
challengePostStage runtime engine row = do
  records <- db runtime (Right <$> Store.transactionRecords (Store.txRowId row))
  ticket <- taskTexts runtime row
  case (records, ticket, Store.txRowCandidate row, Store.txRowFreeze row) of
    (Left code, _, _, _) -> pure (Left code)
    (_, Left code, _, _) -> settle runtime row (SupervisorFailed code) [] id
    (Right rs, Right (title, acceptance), Just candidate, Just _) ->
      case latestRecord (T.pack "candidate") rs >>= recordedCandidate of
        Nothing -> settle runtime row (SupervisorFailed (T.pack "candidate-missing")) [] id
        Just c -> do
          let
            context =
              renderJson $
                JObject
                  [ (T.pack "role", string (roleName Challenger))
                  , (T.pack "stage", string (stageName StageChallengePost))
                  , (T.pack "ticket", JObject [(T.pack "title", string title), (T.pack "what_done_looks_like", string acceptance)])
                  , (T.pack "contract", JRaw (fromMaybe (T.pack "null") (latestRecord (T.pack "contract") rs)))
                  , (T.pack "candidate", string candidate)
                  , (T.pack "verification", JArray (fmap JRaw [Store.recordRowBody r | r <- rs, Store.recordRowKind r == T.pack "verification"]))
                  , (T.pack "answer", JObject [(T.pack "file", string (T.pack "result.json")), (T.pack "kind", string (T.pack "challenge"))])
                  ]
          invoked <- invokeRecorded runtime engine row Challenger StageChallengePost candidate [] [] context
          case invoked of
            Left code -> pure (Left code)
            Right (Left input) -> settle runtime row input [] id
            Right (Right (AnswerChallenge ch, entries, _, _)) -> do
              judged <- traverse (judge candidate c entries) (challengeFindings ch)
              case sequenceA judged of
                Left code -> settle runtime row (SupervisorFailed code) [] id
                Right results -> settle runtime row (ChallengeDisposed (fmap fst results)) [(T.pack "post-finding", body) | (_, body) <- results] id
            Right (Right _) -> settle runtime row (RoleFailed (T.pack "answer-invalid wrong-stage")) [] id
    _ -> settle runtime row (SupervisorFailed (T.pack "candidate-commit-missing")) [] id
 where
  judge candidate c entries f = do
    let
      grounded = findingRequirement f `L.elem` fmap criterionId (candidateCriteria c)
    run <-
      case findingTest f of
        Nothing -> pure (Right NoMutant)
        Just (file, check)
          | filePath file `L.elem` fmap entryPath entries || filePath file `L.elem` candidateAllowedPaths c -> pure (Right MutantOutsideScope)
          | otherwise -> do
              ws <- workspaceAt engine row candidate [(filePath file, TE.encodeUtf8 (fileText file))]
              case ws of
                Left code -> pure (Left code)
                Right (workspace, _) -> do
                  ran <- runCommand runtime engine row StageChallengePost (T.pack "counterexample") workspace (checkArgv check)
                  pure $ do
                    r <- ran
                    Right $
                      if reproduces check (resultOutcome r) (decodeLenient (resultStdout r)) (decodeLenient (resultStderr r))
                        then MutantSurvived True
                        else MutantKilled
    pure $ do
      r <- run
      let
        disposition = disposeFinding grounded r (findingHint f)
      Right (disposition, findingJson f grounded r disposition)

-- Review (C-P4.10-14 R1) ------------------------------------------------------------------------

{- | R1: an independent Reviewer, read-only, on the exact candidate commit, given
the Ticket, the Contract, the change, the verification results and every
finding — not the Implementer's words. Its verdict decides; its words are
recorded. It cannot change anything (read-only profile; the Supervisor
compares nothing it could have written, because the candidate commit is
already fixed).
-}
reviewStage :: DatabaseRuntime -> Engine -> Store.TransactionRow -> IO (Either T.Text TxInput)
reviewStage runtime engine row = do
  records <- db runtime (Right <$> Store.transactionRecords (Store.txRowId row))
  ticket <- taskTexts runtime row
  case (records, ticket, Store.txRowCandidate row) of
    (Left code, _, _) -> pure (Left code)
    (_, Left code, _) -> settle runtime row (SupervisorFailed code) [] id
    (_, _, Nothing) -> settle runtime row (SupervisorFailed (T.pack "candidate-commit-missing")) [] id
    (Right rs, Right (title, acceptance), Just candidate) -> do
      let
        kinds = fmap T.pack ["verification", "verification-summary", "finding", "post-finding"]
        context =
          renderJson $
            JObject
              [ (T.pack "role", string (roleName Reviewer))
              , (T.pack "stage", string (stageName StageReview))
              , (T.pack "ticket", JObject [(T.pack "title", string title), (T.pack "what_done_looks_like", string acceptance)])
              , (T.pack "contract", JRaw (fromMaybe (T.pack "null") (latestRecord (T.pack "contract") rs)))
              , (T.pack "candidate", string candidate)
              , (T.pack "freeze", string (fromMaybe T.empty (Store.txRowFreeze row)))
              , (T.pack "evidence", JArray [JObject [(T.pack "kind", string (Store.recordRowKind r)), (T.pack "body", JRaw (Store.recordRowBody r))] | r <- rs, Store.recordRowKind r `L.elem` kinds])
              , (T.pack "answer", JObject [(T.pack "file", string (T.pack "result.json")), (T.pack "kind", string (T.pack "review"))])
              ]
      invoked <- invokeRecorded runtime engine row Reviewer StageReview candidate [] [] context
      case invoked of
        Left code -> pure (Left code)
        Right (Left input) -> settle runtime row input [] id
        Right (Right (AnswerReview r, _, _, invocation)) -> do
          let
            input =
              case reviewVerdict r of
                Approve -> ReviewApproved
                Reject -> ReviewRejected
                NeedsHuman -> ReviewNeedsHuman
          settle runtime row input [(T.pack "review", JObject [(T.pack "commit", string candidate), (T.pack "verdict", string (verdictName (reviewVerdict r))), (T.pack "reasons", strings (reviewReasons r)), (T.pack "invocation", string invocation)])] id
        Right (Right _) -> settle runtime row (RoleFailed (T.pack "answer-invalid wrong-stage")) [] id

-- Acceptance (C-P4.10-14 A1) ------------------------------------------------------------------------

{- | A1: the Supervisor accepts only the exact commit that passed verification
and review in this attempt, with no confirmed or human-needing finding left
for it, the Engineer still owning the repository, and the work branch still
at the freeze commit; then it moves the branch to the candidate commit by
compare-and-swap. Anything else halts with its reason; nothing is pushed.
-}
acceptStage :: DatabaseRuntime -> Store.TransactionRow -> IO (Either T.Text TxInput)
acceptStage runtime row = do
  records <- db runtime (Right <$> Store.transactionRecords (Store.txRowId row))
  owned <-
    db runtime $ do
      facts <- Store.admissionFacts (Store.txRowWorkOrder row)
      case facts of
        Nothing -> pure (Left (T.pack "not-admitted"))
        Just f -> fmap Right (ownershipHolds (Store.factRepository f) (Store.factEngineer f) (T.unpack (Store.txRowFolder row)))
  case (records, owned, Store.txRowCandidate row, Store.txRowFreeze row, Store.txRowBranch row) of
    (Left code, _, _, _, _) -> pure (Left code)
    (_, Left code, _, _, _) -> pure (Left code)
    (_, Right (Left code), _, _, _) -> settle runtime row (SupervisorFailed code) [] id
    (Right rs, Right (Right ()), Just candidate, Just freeze, Just branch) -> do
      let
        verified = latestRecord (T.pack "verification-summary") rs
        reviewed = latestRecord (T.pack "review") rs
        passed = maybe False (\b -> T.pack "\"passed\":true" `T.isInfixOf` b && candidate `T.isInfixOf` b) verified
        approved = maybe False (\b -> T.pack "\"verdict\":\"approve\"" `T.isInfixOf` b && candidate `T.isInfixOf` b) reviewed
      case () of
        _
          | not passed -> settle runtime row (SupervisorFailed (T.pack "verification-not-passed")) [] id
          | not approved -> settle runtime row (SupervisorFailed (T.pack "review-not-approved")) [] id
          | otherwise -> do
              moved <- advanceBranch (T.unpack (Store.txRowFolder row)) branch freeze candidate
              case moved of
                Left code -> settle runtime row (SupervisorFailed code) [] id
                Right () ->
                  settle
                    runtime
                    row
                    CommitAccepted
                    [(T.pack "acceptance", JObject [(T.pack "commit", string candidate), (T.pack "branch", string branch), (T.pack "from", string freeze)])]
                    (\r -> r {Store.txRowAccepted = Just candidate})
    _ -> settle runtime row (SupervisorFailed (T.pack "acceptance-inputs-missing")) [] id

-- Halts (E3) ---------------------------------------------------------------------------

{- | The open decision request for a halt, made once per halt record (its key
comes from the transaction and the record's sequence, so it is made again
with the same key and identity if a previous attempt was cut short).
-}
ensureRequest :: DatabaseRuntime -> Store.TransactionRow -> Stage -> T.Text -> IO (Either T.Text StoredRequest)
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
                Right (Right request) -> Right request

{- | C-P4.15 H1: a person's binding answer to the current halt's own request
and the input it gives. Only an answered request carries one; C-P4.3 lets
only a person answer, once, at the request's revision.
-}
resumeOf :: StoredRequest -> Maybe (StoredRequest, T.Text, TxInput)
resumeOf request =
  case (T.unpack (storedState request), T.unpack <$> storedAnswer request) of
    ("answered", Just "retry") -> Just (request, T.pack "retry", HumanRetry)
    ("answered", Just "stop") -> Just (request, T.pack "stop", HumanStop)
    ("answered", Just "accept-non-reproduction") -> Just (request, T.pack "accept-non-reproduction", HumanAcceptNonReproduction)
    _ -> Nothing

haltQuestion :: Stage -> T.Text -> T.Text
haltQuestion stage code =
  T.pack "Lockstep stopped this bug fix at the " <> stageName stage <> T.pack " step (" <> code <> T.pack "). What should happen next?"
