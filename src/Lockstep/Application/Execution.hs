{- | Letting Lockstep work in a project, and handing it a bug (contract C-P4.1
X2–X8, X12). Allowing is one transaction under the C-P2.3 profile lock; handing
a bug over is one transaction under the task lock and then the profile lock, and
creates its C-P2.5 Work Order inside it. Every refusal writes nothing. Nothing
here schedules, claims, admits a Work Unit, runs a process or calls a provider.
-}
module Lockstep.Application.Execution
  ( bugFixDocument
  , Enablement (..)
  , ExecutionStatus (..)
  , Admission (..)
  , executionStatus
  , enableExecution
  , admitBug
  , findAdmission
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Maybe (fromMaybe, isNothing)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Text.Show (Show)

import Lockstep.Application.Command (IdempotencyKey, idempotencyKeyText)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason, Readiness (..), checkReadiness, withDatabase)
import Lockstep.Application.Identity (newUuid)
import Lockstep.Application.Ledger (LedgerFailure (..), NewWorkOrder (..), createWorkOrderIn)
import Lockstep.Application.ProfileDocument (GateDocument (..), decodeProfileDocument, encodeProfileDocument)
import Lockstep.Application.Profiles (loadStoredDefinition, sha256Hasher)
import Lockstep.Application.ProjectChecks (ExpectedChecks (..))
import Lockstep.Application.Projects (ProjectFolders (..))
import Lockstep.Application.Repositories (ownershipHolds)
import Lockstep.Application.Tasks (TaskView (..), findTaskIn)
import Lockstep.Kernel.Execution
  ( admissionBlock
  , admissionRequestText
  , bugClass
  , bugFixProfileId
  , enablementRequestText
  , insideProjectsFolder
  , missingBugChecks
  )
import Lockstep.Kernel.Identity (TicketId (..), parseUuid, uuidText)
import Lockstep.Kernel.Policy (checksLost)
import Lockstep.Kernel.Profile
  ( Behaviour (..)
  , Hasher (..)
  , ProfileDefinition
  , ProfileRef (..)
  , ResolutionInput (..)
  , contentDigestText
  , effectiveGates
  , gateApplies
  , mkClassTag
  , mkProfileDefinition
  , mkWorkFacts
  , profileRef
  , resolveProfile
  )
import Lockstep.Kernel.Project (SetupState (Connected))
import Lockstep.Kernel.Transition (Principal (Human))
import Lockstep.Kernel.WorkOrder (WorkOrderKind (Engineering))
import Lockstep.Persistence.Execution qualified as Store
import Lockstep.Persistence.Integrity (integrityViolation)
import Lockstep.Persistence.Profiles qualified as Profiles
import Lockstep.Persistence.Projects qualified as Projects
import Lockstep.Persistence.Tasks qualified as Tasks

-- | The stored document of the built-in Bug Profile (X1); it decodes to 'Lockstep.Kernel.Execution.bugFixDefinition'.
bugFixDocument :: LBS.ByteString
bugFixDocument =
  LBS.fromStrict (TE.encodeUtf8 bugFixText)

{- | The built-in Bug Profile document, through the Profile document schema.
Its bytes are those the stored rows and their digests hold (checked by the
lockstep-compliance suite).
-}
bugFixText :: T.Text
bugFixText =
  encodeProfileDocument
    (T.pack "lockstep-bug-fix")
    1
    [ gate "bug-reproduction" ["reproduction"] ["deterministic-command"] True
    , gate "bug-requirements" ["impact-assessment", "requirements-basis"] ["digest-check"] False
    , gate "bug-regression-test" ["frozen-tests"] ["deterministic-command", "digest-check"] False
    , gate "bug-verification" ["regression-evidence", "verification-record"] ["deterministic-command"] False
    , gate "bug-review" ["review-record"] ["independent-review"] False
    ]
 where
  gate :: String -> [String] -> [String] -> Bool -> GateDocument
  gate name artifacts verifiers exceptionPath =
    GateDocument
      { gateDocumentId = T.pack name
      , gateDocumentStage = T.pack "before-acceptance"
      , gateDocumentArtifacts = fmap T.pack artifacts
      , gateDocumentKinds = Just [T.pack "engineering"]
      , gateDocumentClasses = Just [T.pack "bug"]
      , gateDocumentVerifiers = fmap T.pack verifiers
      , gateDocumentApproval = T.pack "supervisor"
      , gateDocumentExceptionPath = Just exceptionPath
      }

-- | The built-in definition, decoded from the stored document.
bugFixStored :: Maybe ProfileDefinition
bugFixStored =
  either (const Nothing) Just (decodeProfileDocument bugFixDocument)
    >>= either (const Nothing) Just . mkProfileDefinition

-- | A project Lockstep may work in (X4): who allowed what, where, under which checks.
data Enablement
  = Enablement
  { enablementProject :: T.Text
  , enablementRepository :: T.Text
  , enablementEngineer :: T.Text
  , enablementFolder :: T.Text
  , enablementChecks :: T.Text
  , enablementChecksVersion :: Int
  , enablementChecksDigest :: T.Text
  , enablementActor :: T.Text
  , enablementAt :: T.Text
  }
  deriving (Eq, Show)

-- | X8: whether Lockstep may work in a project, and why not.
data ExecutionStatus
  = NeedsFolder
  | FolderReadOnly
  | NotEnabled (Maybe T.Text)
  | Enabled Enablement
  deriving (Eq, Show)

-- | A bug handed to Lockstep (X6).
data Admission
  = Admission
  { admissionTask :: T.Text
  , admissionProject :: T.Text
  , admissionWorkOrder :: T.Text
  , admissionEffectiveDigest :: T.Text
  , admissionActor :: T.Text
  , admissionAt :: T.Text
  }
  deriving (Eq, Show)

actor :: T.Text
actor =
  T.pack "application-session"

whenReady :: DatabaseRuntime -> IO (Either NotReadyReason a) -> IO (Either NotReadyReason a)
whenReady runtime action = do
  readiness <- checkReadiness (Just runtime)
  case readiness of
    NotReady reason -> pure (Left reason)
    Ready _ -> action

sha256Text :: T.Text -> T.Text
sha256Text text =
  case sha256Hasher of
    Hasher f -> contentDigestText (f text)

canonicalId :: T.Text -> Maybe T.Text
canonicalId =
  either (const Nothing) (Just . uuidText) . parseUuid

refuse :: String -> Either T.Text a
refuse =
  Left . T.pack

enablementOf :: Store.EnablementRow -> Enablement
enablementOf row =
  Enablement
    { enablementProject = Store.enablementRowProject row
    , enablementRepository = Store.enablementRowRepository row
    , enablementEngineer = Store.enablementRowEngineer row
    , enablementFolder = Store.enablementRowFolder row
    , enablementChecks = Store.enablementRowProfile row
    , enablementChecksVersion = fromIntegral (Store.enablementRowProfileVersion row)
    , enablementChecksDigest = Store.enablementRowProfileDigest row
    , enablementActor = Store.enablementRowActor row
    , enablementAt = Store.enablementRowAt row
    }

admissionOf :: Store.AdmissionRow -> Admission
admissionOf row =
  Admission
    { admissionTask = Store.admissionRowTask row
    , admissionProject = Store.admissionRowProject row
    , admissionWorkOrder = Store.admissionRowWorkOrder row
    , admissionEffectiveDigest = Store.admissionRowEffectiveDigest row
    , admissionActor = Store.admissionRowActor row
    , admissionAt = Store.admissionRowAt row
    }

-- | X3 for a stored project row: its folder is directly inside the projects folder given now.
writable :: ProjectFolders -> Projects.ProjectRow -> Bool
writable folders row =
  case (foldersRoot folders, Projects.rowFolder row) of
    (Just root, Just folder) -> insideProjectsFolder (T.pack root) folder
    _ -> False

-- | A connected project's folder, Engineer and repository; Nothing when it is not connected.
connection :: Projects.ProjectRow -> O.Orville (Maybe (T.Text, T.Text, T.Text))
connection row =
  case (Projects.rowSetup row, Projects.rowFolder row, Projects.rowEngineerName row) of
    (Connected, Just folder, Just engineer) -> fmap (\repository -> (folder, engineer, repository)) <$> Store.projectRepository (Projects.rowId row)
    _ -> pure Nothing

{- | X2: which bug checks the current checks of a repository lack, resolved as
C-P2.5 @createWorkOrder@ would for engineering work classed @bug@. A stored
document that does not reproduce counts as lacking all of them.
-}
missingFor :: Maybe ProfileDefinition -> Maybe [ProfileDefinition] -> [T.Text]
missingFor current catalogDefinitions =
  case (current, catalogDefinitions, mkClassTag bugClass) of
    (Just definition, Just catalog, Just tag) ->
      case mkWorkFacts Human Engineering [tag] [] BehaviourChanging of
        Left _ -> missingBugChecks []
        Right facts ->
          case resolveProfile sha256Hasher (ResolutionInput definition catalog [] facts) of
            Left _ -> missingBugChecks []
            Right effective -> missingBugChecks (L.filter (gateApplies facts) (effectiveGates effective))
    _ -> missingBugChecks []

-- | The repository's current checks: the default's id and its latest stored row.
currentChecks :: T.Text -> O.Orville (Maybe T.Text, Maybe Profiles.ProfileRow)
currentChecks repository = do
  currentId <- Profiles.repositoryDefault repository
  row <- maybe (pure Nothing) (`Profiles.findProfile` Nothing) currentId
  pure (currentId, row)

expectedText :: ExpectedChecks -> T.Text
expectedText expected =
  case expected of
    ExpectNothing -> T.pack "none"
    ExpectProfile p -> p

expectationMet :: Maybe T.Text -> ExpectedChecks -> Bool
expectationMet current expected =
  case (current, expected) of
    (Nothing, ExpectNothing) -> True
    (Just c, ExpectProfile e) -> c == e
    _ -> False

executionStatus :: DatabaseRuntime -> ProjectFolders -> T.Text -> IO (Either NotReadyReason (Maybe ExecutionStatus))
executionStatus runtime folders rawId =
  case canonicalId rawId of
    Nothing -> pure (Right Nothing)
    Just pid ->
      whenReady runtime . withDatabase runtime $ do
        found <- Projects.findProjectById pid
        case found of
          Nothing -> pure Nothing
          Just row -> do
            linked <- connection row
            enablement <- Store.findEnablementByProject pid
            case (linked, enablement) of
              (_, Just e) -> pure (Just (Enabled (enablementOf e)))
              (Nothing, Nothing) -> pure (Just NeedsFolder)
              (Just (_, _, repository), Nothing)
                | not (writable folders row) -> pure (Just FolderReadOnly)
                | otherwise -> Just . NotEnabled <$> Profiles.repositoryDefault repository

-- | X4, in its order; a refusal writes nothing.
enableExecution :: DatabaseRuntime -> ProjectFolders -> IdempotencyKey -> T.Text -> ExpectedChecks -> IO (Either NotReadyReason (Either T.Text Enablement))
enableExecution runtime folders key rawId expected =
  whenReady runtime $
    case canonicalId rawId of
      Nothing -> pure (Right (refuse "unknown-project"))
      Just pid ->
        withDatabase runtime . O.withTransaction $ do
          Profiles.lockProfiles
          found <- Projects.findProjectById pid
          case found of
            Nothing -> pure (refuse "unknown-project")
            Just row -> do
              linked <- connection row
              case linked of
                Nothing -> pure (refuse "project-has-no-folder")
                Just (folder, engineer, repository)
                  | not (writable folders row) -> pure (refuse "folder-read-only")
                  | otherwise -> do
                      let
                        keyText = idempotencyKeyText key
                        digest = sha256Text (enablementRequestText pid (expectedText expected))
                      byKey <- Store.findEnablementByKey keyText
                      existing <- Store.findEnablementByProject pid
                      case (byKey, existing) of
                        (Just e, _)
                          | Store.enablementRowProject e == pid && Store.enablementRowDigest e == digest -> pure (Right (enablementOf e))
                          | otherwise -> pure (refuse "key-conflict")
                        (Nothing, Just _) -> pure (refuse "already-enabled")
                        (Nothing, Nothing) -> do
                          owned <- ownershipHolds repository engineer (T.unpack folder)
                          case owned of
                            Left code -> pure (Left code)
                            Right () -> do
                              (currentId, currentRow) <- currentChecks repository
                              catalogRows <- Profiles.latestProfiles
                              if not (expectationMet currentId expected)
                                then pure (refuse "checks-changed")
                                else do
                                  chosen <- decideChecks currentRow catalogRows
                                  case chosen of
                                    Left code -> pure (Left code)
                                    Right (checksRow, switch) -> do
                                      when switch $ do
                                        Profiles.insertRepositoryProfile repository (Profiles.profileRowId checksRow)
                                        _ <- Profiles.insertProfileDecision (setDecision engineer repository checksRow)
                                        pure ()
                                      Store.insertEnablement
                                        Store.EnablementRow
                                          { Store.enablementRowKey = keyText
                                          , Store.enablementRowDigest = digest
                                          , Store.enablementRowProject = pid
                                          , Store.enablementRowRepository = repository
                                          , Store.enablementRowEngineer = engineer
                                          , Store.enablementRowFolder = folder
                                          , Store.enablementRowProfile = Profiles.profileRowId checksRow
                                          , Store.enablementRowProfileVersion = Profiles.profileRowVersion checksRow
                                          , Store.enablementRowProfileDigest = Profiles.profileRowDigest checksRow
                                          , Store.enablementRowActor = actor
                                          , Store.enablementRowAt = T.empty
                                          }
                                      stored <- Store.findEnablementByProject pid
                                      pure (maybe (refuse "unknown-project") (Right . enablementOf) stored)
 where
  setDecision engineer repository checksRow =
    Profiles.NewProfileDecision
      { Profiles.profileDecisionOperation = T.pack "repository-set-profile"
      , Profiles.profileDecisionProfile = Just (Profiles.profileRowId checksRow)
      , Profiles.profileDecisionVersion = Just (Profiles.profileRowVersion checksRow)
      , Profiles.profileDecisionDigest = Just (Profiles.profileRowDigest checksRow)
      , Profiles.profileDecisionEngineer = Just engineer
      , Profiles.profileDecisionRepository = Just repository
      , Profiles.profileDecisionOutcome = T.pack "accepted"
      , Profiles.profileDecisionRefusal = Nothing
      }

{- | X4's choice of checks: the current ones when they already hold every bug
check (no switch); else the Bug Profile, registered as version 1 if absent,
when switching to it loses no check and it holds every bug check; else
@bug-checks-missing@. The result is the row in force and whether to switch.
-}
decideChecks :: Maybe Profiles.ProfileRow -> [Profiles.ProfileRow] -> O.Orville (Either T.Text (Profiles.ProfileRow, Bool))
decideChecks currentRow catalogRows = do
  registered <- Profiles.findProfile bugFixProfileId Nothing
  let
    catalog = definitions catalogRows
    currentDefinition = currentRow >>= definitionOf
    -- The Bug Profile as it would be in force: the registered latest version, else the built-in one.
    candidate =
      case registered of
        Just row -> fmap (\d -> (Just row, d)) (definitionOf row)
        Nothing -> fmap (\d -> (Nothing, d)) bugFixStored
    losesNothing bugDefinition =
      isNothing currentRow || maybe False (\d -> L.null (checksLost (Just d) bugDefinition)) currentDefinition
  case (currentRow, currentDefinition) of
    (Just row, Just _)
      | L.null (missingFor currentDefinition catalog) -> pure (Right (row, False))
    _ ->
      case candidate of
        Just (stored, bugDefinition)
          | losesNothing bugDefinition
          , L.null (missingFor (Just bugDefinition) (fmap (bugDefinition :) catalog)) -> do
              -- Written only now, when the switch is certain: a refusal writes nothing.
              row <- maybe registerBugFix (pure . Just) stored
              pure (maybe (refuse "bug-checks-missing") (\r -> Right (r, True)) row)
        _ -> pure (refuse "bug-checks-missing")
 where
  definitionOf =
    either (const Nothing) Just . loadStoredDefinition
  definitions rows =
    either (const Nothing) Just (traverse loadStoredDefinition rows)

-- | Registers the built-in document as version 1, with its C-P2.3 decision row.
registerBugFix :: O.Orville (Maybe Profiles.ProfileRow)
registerBugFix =
  case bugFixStored of
    Nothing -> pure Nothing
    Just definition -> do
      let
        digest = contentDigestText (refDigest (profileRef sha256Hasher definition))
        row = Profiles.ProfileRow bugFixProfileId 1 digest (TE.decodeUtf8 (LBS.toStrict bugFixDocument))
      Profiles.insertProfile row
      _ <-
        Profiles.insertProfileDecision
          Profiles.NewProfileDecision
            { Profiles.profileDecisionOperation = T.pack "profile-add"
            , Profiles.profileDecisionProfile = Just bugFixProfileId
            , Profiles.profileDecisionVersion = Just 1
            , Profiles.profileDecisionDigest = Just digest
            , Profiles.profileDecisionEngineer = Nothing
            , Profiles.profileDecisionRepository = Nothing
            , Profiles.profileDecisionOutcome = T.pack "accepted"
            , Profiles.profileDecisionRefusal = Nothing
            }
      pure (Just row)

-- | X6, in its order; a refusal writes nothing.
admitBug :: DatabaseRuntime -> ProjectFolders -> IdempotencyKey -> T.Text -> Int -> IO (Either NotReadyReason (Either T.Text Admission))
admitBug runtime folders key rawId expected
  | expected < 0 || expected > 2147483647 = pure (Right (refuse "revision-out-of-range"))
  | otherwise =
      whenReady runtime $ do
        u <- newUuid
        let
          keyText = idempotencyKeyText key
          taskText = fromMaybe rawId (canonicalId rawId)
          digest = sha256Text (admissionRequestText taskText expected)
        withDatabase runtime . O.withTransaction $ do
          Tasks.lockTasks
          Profiles.lockProfiles
          byKey <- Store.findAdmissionByKey keyText
          case byKey of
            Just a
              | Store.admissionRowDigest a == digest -> pure (Right (admissionOf a))
              | otherwise -> pure (refuse "key-conflict")
            Nothing ->
              case (canonicalId rawId, parseUuid rawId) of
                (Just tid, Right ticketUuid) -> do
                  found <- findTaskIn tid
                  case found of
                    Nothing -> pure (refuse "unknown-task")
                    Just (Left code) -> pure (Left code)
                    Just (Right task) -> do
                      project <- Projects.findProjectById (taskProject task)
                      enablement <- Store.findEnablementByProject (taskProject task)
                      already <- Store.findAdmissionByTask tid
                      case (project, enablement, already) of
                        (Nothing, _, _) -> pure (refuse "unknown-task")
                        (_, Nothing, _) -> pure (refuse "execution-not-enabled")
                        (_, _, Just _) -> pure (refuse "already-admitted")
                        (Just row, Just e, Nothing)
                          | taskTicketRevision task /= expected -> pure (refuse "stale-revision")
                          | Just code <- admissionBlock (taskReadinessOf task) -> pure (Left code)
                          | not (writable folders row) -> pure (refuse "folder-read-only")
                          | otherwise -> handOver u keyText digest tid (TicketId ticketUuid) task (enablementOf e)
                _ -> pure (refuse "unknown-task")
 where
  handOver u keyText digest tid ticket task enablement = do
    owned <- ownershipHolds (enablementRepository enablement) (enablementEngineer enablement) (T.unpack (enablementFolder enablement))
    case owned of
      Left code -> pure (Left code)
      Right () -> do
        (_, currentRow) <- currentChecks (enablementRepository enablement)
        catalogRows <- Profiles.latestProfiles
        let
          currentDefinition = currentRow >>= either (const Nothing) Just . loadStoredDefinition
          catalog = either (const Nothing) Just (traverse loadStoredDefinition catalogRows)
        if not (L.null (missingFor currentDefinition catalog))
          then pure (refuse "bug-checks-missing")
          else do
            created <-
              createWorkOrderIn
                u
                NewWorkOrder
                  { newTicket = ticket
                  , newEngineer = enablementEngineer enablement
                  , newKind = Engineering
                  , newPriority = taskPriority task
                  , newDependencies = []
                  , newClasses = [bugClass]
                  , newPathClasses = []
                  , newNonBehavioural = Nothing
                  }
            case created of
              Left (LedgerRefused code _)
                | code == T.pack "ticket-not-ready" -> pure (refuse "task-not-ready")
                | code == T.pack "repository-default-profile-unset" -> pure (refuse "bug-checks-missing")
              Left _ -> pure (refuse "admission-refused")
              Right _ -> do
                let
                  workOrder = uuidText u
                -- The work order was created in this transaction with its digest; none is an integrity violation, and the creation rolls back.
                effective <- maybe (integrityViolation "a work order created in this transaction has no effective digest") pure =<< Store.workOrderEffectiveDigest workOrder
                Store.insertAdmission
                  Store.AdmissionRow
                    { Store.admissionRowKey = keyText
                    , Store.admissionRowDigest = digest
                    , Store.admissionRowTask = tid
                    , Store.admissionRowProject = enablementProject enablement
                    , Store.admissionRowWorkOrder = workOrder
                    , Store.admissionRowEffectiveDigest = effective
                    , Store.admissionRowActor = actor
                    , Store.admissionRowAt = T.empty
                    }
                stored <- Store.findAdmissionByTask tid
                pure (maybe (refuse "admission-refused") (Right . admissionOf) stored)

findAdmission :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Maybe Admission))
findAdmission runtime rawId =
  case canonicalId rawId of
    Nothing -> pure (Right Nothing)
    Just tid -> whenReady runtime (withDatabase runtime (fmap admissionOf <$> Store.findAdmissionByTask tid))
