{- | A project's evidence-linked summary (contract C-P6.8): every task in one
category, its fix's verification and review as recorded for its current
candidate, the evidence each claim rests on, the decisions waiting for a
person, the interventions people made, the usage helpers reported, and the
plan revision it describes. The fixes are read in one database transaction;
it writes nothing, and no agent text decides anything in it.
-}
module Lockstep.Application.Summary
  ( SummaryItem (..)
  , InterventionItem (..)
  , ProjectSummary (..)
  , projectSummary
  , usageFromOutput
  ) where

import Data.List qualified as L
import Data.Maybe (catMaybes, fromMaybe, isJust, listToMaybe, mapMaybe)
import Data.Text qualified as T
import Fleece.Core ((#+))
import Fleece.Core qualified as FC
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Text.Show (Show)

import Lockstep.Application.Conversation (StoredRequest (..), openRequests)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason, Readiness (..), checkReadiness, withDatabase)
import Lockstep.Application.Dispatch (DispatchView (..), dispatchView)
import Lockstep.Application.EngineRecords (Completion (completionChoice), Halt (haltCode), ReviewRecord (reviewCommit, reviewVerdict), VerificationSummary (summaryPassed), completionSchema, haltSchema, reviewSchema, verificationSummarySchema)
import Lockstep.Application.EngineRecords qualified as Records
import Lockstep.Application.Invalidations (invalidationOf)
import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Application.Tasks (TaskView (..), listTasks)
import Lockstep.Foundation.Fleece (decodeText)
import Lockstep.Kernel.Identity (InvocationId (..), ProjectId (..), TaskId (..), TransactionId (..), WorkOrderId (..), identityText, parseIdentity)
import Lockstep.Kernel.Profile (Hasher (..), contentDigestText)
import Lockstep.Kernel.Roles (Role (..), Verdict (..), roleName)
import Lockstep.Kernel.Summary
  ( Category
  , Checks (..)
  , Evidence (..)
  , FixSummary (..)
  , Intervention
  , ItemFacts (..)
  , ReviewOutcome (..)
  , RunUsage (..)
  , Usage (..)
  , UsageStanding
  , addUsage
  , categoryOf
  , interventionOf
  , noUsage
  , runEvidence
  , usageKnown
  , usageStanding
  )
import Lockstep.Kernel.Transaction (RecordKind (..), TxState (Halted), stateColumns, txStateName)
import Lockstep.Persistence.Execution qualified as Execution
import Lockstep.Persistence.Plans qualified as Plans
import Lockstep.Persistence.Projects qualified as Projects
import Lockstep.Persistence.Transactions qualified as Transactions

data SummaryItem
  = SummaryItem
  { summaryTask :: T.Text
  , summaryTitle :: T.Text
  , summaryCategory :: Category
  , summaryChecks :: Checks
  , summaryReview :: ReviewOutcome
  , summaryCommit :: Maybe T.Text
  , summaryPublication :: T.Text
  -- ^ @local@ for a commit (nothing is pushed or merged in Phase 6), @none@ without one.
  , summaryEvidence :: [Evidence]
  , summaryChecksRecord :: Maybe Int
  -- ^ Which of the evidence's records the checks, the review and the halt come from (R-P6.8-12).
  , summaryReviewRecord :: Maybe Int
  , summaryHaltRecord :: Maybe Int
  }
  deriving (Eq, Show)

data InterventionItem
  = InterventionItem
  { interventionTask :: T.Text
  , interventionWhat :: T.Text
  -- ^ The halt code answered, or @done@ / @not-done@.
  , interventionKind :: Intervention
  , interventionEvidence :: Evidence
  }
  deriving (Eq, Show)

data ProjectSummary
  = ProjectSummary
  { summaryRevision :: Maybe T.Text
  -- ^ The digest of the plan revision in effect it was made for.
  , summaryItems :: [SummaryItem]
  , summaryPending :: [(T.Text, Evidence)]
  -- ^ Decisions waiting for a person: the task's title and the open request.
  , summaryInterventions :: [InterventionItem]
  , summaryUsage :: Usage
  , summaryRuns :: Int
  -- ^ Role runs.
  , summaryRunsUnknown :: Int
  -- ^ Role runs whose helper reported no usage.
  , summaryConstraints :: [(T.Text, T.Text)]
  -- ^ Plan units waiting on a resource: the unit and its waiting code.
  , summaryRecords :: Int
  -- ^ How many fix records it was made from (R-P6.8-9).
  , summaryUsageStanding :: UsageStanding
  -- ^ Update 2 R6.5: what the usage evidence establishes (complete, partial, unavailable, no invocation).
  , summaryUsageRuns :: [(T.Text, T.Text)]
  -- ^ Update 2 R6.5: each role run counted, by its recorded invocation, with what its own evidence is.
  }
  deriving (Eq, Show)

whenReady :: DatabaseRuntime -> IO (Either NotReadyReason a) -> IO (Either NotReadyReason a)
whenReady runtime action = do
  readiness <- checkReadiness (Just runtime)
  case readiness of
    NotReady reason -> pure (Left reason)
    Ready _ -> action

-- Usage ------------------------------------------------------------------------------------------

data UsageDoc
  = UsageDoc (Maybe Integer) (Maybe Integer) (Maybe Integer) (Maybe Integer)

newtype UsageEnvelope
  = UsageEnvelope UsageDoc

usageEnvelopeSchema :: FC.Fleece t => FC.Schema t UsageEnvelope
usageEnvelopeSchema =
  FC.object $
    FC.constructor UsageEnvelope
      #+ FC.required "usage" (\(UsageEnvelope u) -> u) usageDocSchema

usageDocSchema :: FC.Fleece t => FC.Schema t UsageDoc
usageDocSchema =
  FC.object $
    FC.constructor UsageDoc
      #+ FC.optional "input_tokens" (\(UsageDoc a _ _ _) -> a) FC.integer
      #+ FC.optional "output_tokens" (\(UsageDoc _ b _ _) -> b) FC.integer
      #+ FC.optional "cache_creation_input_tokens" (\(UsageDoc _ _ c _) -> c) FC.integer
      #+ FC.optional "cache_read_input_tokens" (\(UsageDoc _ _ _ d) -> d) FC.integer

{- | E5: the usage a helper printed, as the last line of its output that is a
JSON object with @usage@ (the Claude CLI's result); classes it does not name
are unknown, and output with none is unknown usage.
-}
usageFromOutput :: T.Text -> Usage
usageFromOutput output =
  fromMaybe noUsage (listToMaybe (L.reverse (mapMaybe parse (T.lines output))))
 where
  parse line =
    either (const Nothing) (\(UsageEnvelope (UsageDoc a b c d)) -> Just (Usage a b c d)) (decodeText usageEnvelopeSchema (T.strip line))

-- One fix ----------------------------------------------------------------------------------------

-- | What one fix says, from its rows.
data FixRead
  = FixRead
  { readSummary :: FixSummary
  , readWorkOrder :: T.Text
  , readHaltRecord :: Maybe Int
  , readInterventions :: [(T.Text, Evidence)]
  , readUsage :: [Usage]
  , readRuns :: [RunUsage]
  , readRecords :: Int
  }

-- | R-P6.8-2: the latest record of a kind, whether it decodes or not.
latestRow :: RecordKind -> [Transactions.RecordRow] -> Maybe Transactions.RecordRow
latestRow kind records =
  listToMaybe [r | r <- L.sortOn (negate . Transactions.recordRowSequence) records, Transactions.recordRowKind r == kind]

-- | The halts of a verification that could not run: not a failure (R-P6.8-8).
inconclusiveHalts :: [T.Text]
inconclusiveHalts =
  fmap T.pack ["verification-environment-missing", "verification-run-failed"]

-- | The role names, so role runs are told apart from the Supervisor's commands (R-P6.8-13).
roleNames :: [T.Text]
roleNames =
  fmap roleName [Planner, Challenger, Implementer, Reviewer]

fixOfRow :: Transactions.TransactionRow -> O.Orville FixRead
fixOfRow row = do
  let
    txId = Transactions.txRowId row
    tx = identityText txId
    candidate = Transactions.txRowCandidate row
    halt = snd (stateColumns (Transactions.txRowState row))
    halted =
      case Transactions.txRowState row of
        Halted _ _ -> True
        _ -> False
  records <- Transactions.transactionRecords txId
  invocations <- Transactions.transactionInvocations txId
  invalid <- invalidationOf txId
  let
    sequenceOf r = fromIntegral (Transactions.recordRowSequence r)
    -- R-P6.8-1, R-P6.8-2: the latest record counts only when it reads and is about the current candidate.
    checks =
      case latestRow RecordVerificationSummary records of
        Just r
          | Right s <- decodeText verificationSummarySchema (Transactions.recordRowBody r)
          , Just (Records.summaryCommit s) == candidate
          , not (maybe False (`L.elem` inconclusiveHalts) halt) ->
              (if summaryPassed s then ChecksPassed else ChecksFailed, Just (sequenceOf r))
        _ -> (ChecksNotRun, Nothing)
    review =
      case latestRow RecordReview records of
        Just r
          | Right v <- decodeText reviewSchema (Transactions.recordRowBody r)
          , Just (reviewCommit v) == candidate ->
              (verdictOutcome (reviewVerdict v), Just (sequenceOf r))
        _ -> (ReviewNotRun, Nothing)
    {- Update 2 R6.5: each role run's usage, from its recorded invocation. Its counts are read from the output's kept
    tail, so they are complete accounting only when the run finished and the tail is its whole output. -}
    runs =
      [ RunUsage
          { runSource = identityText (Transactions.invocationRowId i)
          , runUsage = usageFromOutput tailText
          , -- R-U2-9: the kept tail is the whole output only when its own digest is the recorded output's.
            runComplete =
              isJust (Transactions.invocationRowOutcome i)
                && Transactions.invocationRowStdoutDigest i == Just (case sha256Hasher of Hasher f -> contentDigestText (f tailText))
          }
      | i <- invocations
      , Transactions.invocationRowWhat i `L.elem` roleNames
      , let
          tailText = fromMaybe T.empty (Transactions.invocationRowStdoutTail i)
      ]
  pure
    FixRead
      { readSummary =
          FixSummary
            { fixId = tx
            , fixState = txStateName (Transactions.txRowState row)
            , fixHalt = halt
            , fixInvalidated = isJust invalid
            , fixChecks = fst checks
            , fixChecksRecord = snd checks
            , fixReview = fst review
            , fixReviewRecord = snd review
            , fixCommit = Transactions.txRowAccepted row
            }
      , readWorkOrder = identityText (Transactions.txRowWorkOrder row)
      , readHaltRecord = if halted then sequenceOf <$> latestRow RecordHalt records else Nothing
      , readInterventions = interventionsOf tx records
      , readUsage = fmap runUsage runs
      , readRuns = runs
      , readRecords = L.length records
      }
 where
  verdictOutcome v =
    case v of
      Approve -> ReviewSaidApprove
      Reject -> ReviewSaidReject
      NeedsHuman -> ReviewSaidNeedsPerson

{- | E4: each person's answer to a halt (with the code of the halt before it,
@unknown@ when that halt does not read) and each Done or Not done, with the
record that holds it.
-}
interventionsOf :: T.Text -> [Transactions.RecordRow] -> [(T.Text, Evidence)]
interventionsOf tx records =
  L.reverse (snd (L.foldl' step (Nothing, []) (L.sortOn Transactions.recordRowSequence records)))
 where
  step (lastHalt, found) r =
    let
      here = OfRecord tx (fromIntegral (Transactions.recordRowSequence r))
    in
      case Transactions.recordRowKind r of
        RecordHalt -> (Just (either (const (T.pack "unknown")) haltCode (decodeText haltSchema (Transactions.recordRowBody r))), found)
        RecordResume -> (lastHalt, (fromMaybe (T.pack "unknown") lastHalt, here) : found)
        RecordCompletion ->
          (lastHalt, either (const found) (\c -> (completionChoice c, here) : found) (decodeText completionSchema (Transactions.recordRowBody r)))
        _ -> (lastHalt, found)

-- | A task's fixes, newest first: each hand-over and its fix, if it has started.
data TaskRead
  = TaskRead
  { taskRead :: TaskView
  , taskHandedOver :: Bool
  , taskLatestStarted :: Bool
  -- ^ Whether its latest hand-over's fix has started.
  , taskFixes :: [FixRead]
  -- ^ Every fix that started, newest first.
  }

-- The summary ------------------------------------------------------------------------------------

-- | The project's summary now; Nothing for an unknown project.
projectSummary :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Maybe ProjectSummary))
projectSummary runtime rawProject =
  whenReady runtime $
    case parseIdentity rawProject of
      Nothing -> pure (Right Nothing)
      Just project -> do
        tasks <- listTasks runtime rawProject
        requests <- openRequests runtime
        view <- dispatchView runtime rawProject
        case (tasks, requests, view) of
          (Left r, _, _) -> pure (Left r)
          (_, Left r, _) -> pure (Left r)
          (_, _, Left r) -> pure (Left r)
          (Right ts, Right open, Right v) -> do
            read' <- withDatabase runtime (O.withTransaction (readAll project ts))
            pure (fmap (fmap (assemble open (either (const []) dispatchViewWaiting v))) read')
 where
  readAll :: ProjectId -> [TaskView] -> O.Orville (Maybe (Maybe T.Text, [T.Text], [TaskRead]))
  readAll project ts = do
    found <- Projects.findProjectById project
    case found of
      -- R-P6.8-15: an unknown project has no summary.
      Nothing -> pure Nothing
      Just _ -> do
        effective <- Plans.effectiveRevision project
        units <- maybe (pure []) (Plans.revisionUnits . Plans.revisionRowId) effective
        -- Newest first: a task's latest hand-over counts for its category; every one counts for its history (R-P6.8-3).
        admissions <- Execution.projectAdmissions project
        reads <-
          traverse
            ( \t -> do
                let
                  mine = [a | a <- admissions, Execution.admissionRowTask a == taskKey t]
                rows <- traverse (Transactions.findTransactionByWorkOrder . Execution.admissionRowWorkOrder) mine
                fixes <- traverse fixOfRow (catMaybes rows)
                pure (TaskRead t (not (L.null mine)) (isJust (join (listToMaybe rows))) fixes)
            )
            ts
        pure (Just (Plans.revisionRowDigest <$> effective, fmap (identityText . Plans.unitRowTask) units, reads))
  assemble open waiting (revision, planned, reads) =
    let
      latestFix r = if taskLatestStarted r then listToMaybe (taskFixes r) else Nothing
      latestOf r =
        case (taskHandedOver r, latestFix r) of
          (_, Just f) -> Just (readSummary f)
          -- R-P6.8-4: handed over, not started: neither eligible nor any earlier fix's state.
          (True, Nothing) -> Just queued
          (False, Nothing) -> Nothing
      items =
        [ SummaryItem
            { summaryTask = taskId t
            , summaryTitle = taskTitle t
            , summaryCategory = categoryOf (ItemFacts (taskId t `L.elem` planned) (taskReadinessOf t) (latestOf r))
            , summaryChecks = maybe ChecksNotRun (fixChecks . readSummary) f
            , summaryReview = maybe ReviewNotRun (fixReview . readSummary) f
            , summaryCommit = f >>= fixCommit . readSummary
            , summaryPublication = T.pack (if isJust (f >>= fixCommit . readSummary) then "local" else "none")
            , summaryEvidence = maybe [] (evidenceOf open) f
            , summaryChecksRecord = f >>= fixChecksRecord . readSummary
            , summaryReviewRecord = f >>= fixReviewRecord . readSummary
            , summaryHaltRecord = f >>= readHaltRecord
            }
        | r <- reads
        , let
            t = taskRead r
            f = latestFix r
        ]
      allFixes = [(taskRead r, f) | r <- reads, f <- taskFixes r]
      byWorkOrder = [(readWorkOrder f, taskTitle t) | (t, f) <- allFixes]
      usages = L.concatMap (readUsage . snd) allFixes
    in
      ProjectSummary
        { summaryRevision = revision
        , summaryItems = items
        , summaryPending = [(title, OfRequest (storedRequestId q)) | q <- open, Just title <- [L.lookup (storedWorkOrder q) byWorkOrder]]
        , summaryInterventions =
            [ InterventionItem (taskTitle t) what (interventionOf what) evidence
            | (t, f) <- allFixes
            , (what, evidence) <- readInterventions f
            ]
        , summaryUsage = L.foldl' addUsage noUsage usages
        , summaryRuns = L.length usages
        , summaryRunsUnknown = L.length (L.filter (not . usageKnown) usages)
        , summaryConstraints = [(k, c) | (k, c) <- waiting, c `L.elem` fmap T.pack ["usage-unknown", "writer-busy", "execution-not-enabled", "refused"]]
        , summaryRecords = L.sum (fmap (readRecords . snd) allFixes)
        , summaryUsageStanding = usageStanding (L.concatMap (readRuns . snd) allFixes)
        , summaryUsageRuns = [(runSource r, runEvidence r) | r <- L.concatMap (readRuns . snd) allFixes]
        }
  queued =
    FixSummary
      { fixId = T.empty
      , fixState = T.pack "handed-over"
      , fixHalt = Nothing
      , fixInvalidated = False
      , fixChecks = ChecksNotRun
      , fixChecksRecord = Nothing
      , fixReview = ReviewNotRun
      , fixReviewRecord = Nothing
      , fixCommit = Nothing
      }
  -- R-P6.8-5: a halted fix's evidence names its halt record and its open request.
  evidenceOf open f =
    let
      s = readSummary f
    in
      [OfFix (fixId s)]
        <> [OfRecord (fixId s) n | Just n <- [fixChecksRecord s]]
        <> [OfRecord (fixId s) n | Just n <- [fixReviewRecord s]]
        <> [OfRecord (fixId s) n | Just n <- [readHaltRecord f]]
        <> [OfCommit c | Just c <- [fixCommit s]]
        <> [OfInvalidation (fixId s) | fixInvalidated s]
        <> [OfRequest (storedRequestId q) | q <- open, storedWorkOrder q == readWorkOrder f]
