{- | A project's evidence-linked summary (contract C-P6.8): every task in one
category, its fix's verification and review as recorded, the evidence each
claim rests on, the decisions waiting for a person, the interventions people
made, the usage helpers reported, and the plan revision it describes. Read
from the canonical rows in one database transaction; it writes nothing, and no
agent text decides anything in it.
-}
module Lockstep.Application.Summary
  ( SummaryItem (..)
  , InterventionItem (..)
  , ProjectSummary (..)
  , projectSummary
  , usageFromOutput
  ) where

import Data.List qualified as L
import Data.Maybe (fromMaybe, isJust, listToMaybe, mapMaybe)
import Data.Text qualified as T
import Fleece.Core ((#+))
import Fleece.Core qualified as FC
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Text.Show (Show)

import Lockstep.Application.Conversation (StoredRequest (..), openRequests)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason, Readiness (..), checkReadiness, withDatabase)
import Lockstep.Application.Dispatch (DispatchView (..), dispatchView)
import Lockstep.Application.EngineRecords (Completion (completionChoice), Halt (haltCode), ReviewRecord (reviewVerdict), VerificationSummary (summaryPassed), completionSchema, haltSchema, reviewSchema, verificationSummarySchema)
import Lockstep.Application.Invalidations (invalidationOf)
import Lockstep.Application.Tasks (TaskView (..), listTasks)
import Lockstep.Foundation.Fleece (decodeText)
import Lockstep.Kernel.Identity (ProjectId (..), TaskId (..), TransactionId (..), WorkOrderId (..), identityText, parseIdentity)
import Lockstep.Kernel.Roles (Verdict (..))
import Lockstep.Kernel.Summary
  ( Category
  , Checks (..)
  , Evidence (..)
  , FixSummary (..)
  , Intervention
  , ItemFacts (..)
  , ReviewOutcome (..)
  , Usage (..)
  , addUsage
  , categoryOf
  , interventionOf
  , noUsage
  , usageKnown
  )
import Lockstep.Kernel.Transaction (RecordKind (..), stateColumns, txStateName)
import Lockstep.Persistence.Execution qualified as Execution
import Lockstep.Persistence.Plans qualified as Plans
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

-- The summary ------------------------------------------------------------------------------------

-- | What a task's latest fix says, from its rows.
data FixRead
  = FixRead
  { readSummary :: FixSummary
  , readWorkOrder :: T.Text
  , readInterventions :: [(T.Text, Evidence)]
  , readUsage :: [Usage]
  }

-- | The latest record of a kind, decoded, with its sequence.
latestOf :: RecordKind -> (T.Text -> Either String a) -> [Transactions.RecordRow] -> Maybe (a, Int)
latestOf kind decode records =
  listToMaybe
    [ (value, fromIntegral (Transactions.recordRowSequence r))
    | r <- L.sortOn (negate . Transactions.recordRowSequence) records
    , Transactions.recordRowKind r == kind
    , Right value <- [decode (Transactions.recordRowBody r)]
    ]

fixRead :: TaskView -> O.Orville (Maybe FixRead)
fixRead task = do
  admission <- Execution.findAdmissionByTask (taskKey task)
  found <- maybe (pure Nothing) (Transactions.findTransactionByWorkOrder . Execution.admissionRowWorkOrder) admission
  case found of
    Nothing -> pure Nothing
    Just row -> do
      let
        txId = Transactions.txRowId row
        tx = identityText txId
      records <- Transactions.transactionRecords txId
      invocations <- Transactions.transactionInvocations txId
      invalid <- invalidationOf txId
      let
        checks =
          case latestOf RecordVerificationSummary (decodeText verificationSummarySchema) records of
            Just (s, n) -> (if summaryPassed s then ChecksPassed else ChecksFailed, Just n)
            Nothing -> (ChecksNotRun, Nothing)
        review =
          case latestOf RecordReview (decodeText reviewSchema) records of
            Just (r, n) -> (verdictOutcome (reviewVerdict r), Just n)
            Nothing -> (ReviewNotRun, Nothing)
        summary =
          FixSummary
            { fixId = tx
            , fixState = txStateName (Transactions.txRowState row)
            , fixHalt = snd (stateColumns (Transactions.txRowState row))
            , fixInvalidated = isJust invalid
            , fixChecks = fst checks
            , fixChecksRecord = snd checks
            , fixReview = fst review
            , fixReviewRecord = snd review
            , fixCommit = Transactions.txRowAccepted row
            }
      pure
        ( Just
            FixRead
              { readSummary = summary
              , readWorkOrder = identityText (Transactions.txRowWorkOrder row)
              , readInterventions = interventionsOf tx records
              , readUsage =
                  [ usageFromOutput (fromMaybe T.empty (Transactions.invocationRowStdoutTail i))
                  | i <- invocations
                  , Transactions.invocationRowAdapter i /= T.pack "supervisor"
                  ]
              }
        )
 where
  verdictOutcome v =
    case v of
      Approve -> ReviewSaidApprove
      Reject -> ReviewSaidReject
      NeedsHuman -> ReviewSaidNeedsPerson

{- | E4: each person's answer to a halt (with the code of the halt before it)
and each Done or Not done, with the record that holds it.
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
        RecordHalt -> (either (const lastHalt) (Just . haltCode) (decodeText haltSchema (Transactions.recordRowBody r)), found)
        RecordResume -> (lastHalt, (fromMaybe (T.pack "unknown") lastHalt, here) : found)
        RecordCompletion ->
          (lastHalt, either (const found) (\c -> (completionChoice c, here) : found) (decodeText completionSchema (Transactions.recordRowBody r)))
        _ -> (lastHalt, found)

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
            pure (fmap (assemble ts open (either (const []) dispatchViewWaiting v)) read')
 where
  readAll :: ProjectId -> [TaskView] -> O.Orville (Maybe (Maybe T.Text, [T.Text], [(TaskView, Maybe FixRead)]))
  readAll project ts = do
    effective <- Plans.effectiveRevision project
    units <- maybe (pure []) (Plans.revisionUnits . Plans.revisionRowId) effective
    fixes <- traverse (\t -> (,) t <$> fixRead t) ts
    pure (Just (Plans.revisionRowDigest <$> effective, fmap (identityText . Plans.unitRowTask) units, fixes))
  assemble _ open waiting read' =
    case read' of
      Nothing -> Nothing
      Just (revision, planned, fixes) ->
        let
          items =
            [ SummaryItem
                { summaryTask = taskId t
                , summaryTitle = taskTitle t
                , summaryCategory = categoryOf (ItemFacts (taskId t `L.elem` planned) (taskReadinessOf t) (readSummary <$> f))
                , summaryChecks = maybe ChecksNotRun (fixChecks . readSummary) f
                , summaryReview = maybe ReviewNotRun (fixReview . readSummary) f
                , summaryCommit = f >>= fixCommit . readSummary
                , summaryPublication = T.pack (if isJust (f >>= fixCommit . readSummary) then "local" else "none")
                , summaryEvidence = maybe [] (evidenceOf . readSummary) f
                }
            | (t, f) <- fixes
            ]
          byWorkOrder = [(readWorkOrder f, taskTitle t) | (t, Just f) <- fixes]
          usages = L.concat [readUsage f | (_, Just f) <- fixes]
        in
          Just
            ProjectSummary
              { summaryRevision = revision
              , summaryItems = items
              , summaryPending = [(title, OfRequest (storedRequestId q)) | q <- open, Just title <- [L.lookup (storedWorkOrder q) byWorkOrder]]
              , summaryInterventions =
                  [ InterventionItem (taskTitle t) what (interventionOf what) evidence
                  | (t, Just f) <- fixes
                  , (what, evidence) <- readInterventions f
                  ]
              , summaryUsage = L.foldl' addUsage noUsage usages
              , summaryRuns = L.length usages
              , summaryRunsUnknown = L.length (L.filter (not . usageKnown) usages)
              , summaryConstraints = [(k, c) | (k, c) <- waiting, c `L.elem` fmap T.pack ["usage-unknown", "writer-busy", "execution-not-enabled", "refused"]]
              }
  evidenceOf f =
    [OfFix (fixId f)]
      <> [OfRecord (fixId f) n | Just n <- [fixChecksRecord f]]
      <> [OfRecord (fixId f) n | Just n <- [fixReviewRecord f]]
      <> [OfCommit c | Just c <- [fixCommit f]]
      <> [OfInvalidation (fixId f) | fixInvalidated f]
