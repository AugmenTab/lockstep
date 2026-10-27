{- | How a project's work is checked, and what can start (contract C-P3.7 L3,
L4, L6). A project's checks are the C-P2.3 default Profile of its repository:
reading them resolves the effective Profile for every kind of work exactly as
C-P2.5 @createWorkOrder@ would; choosing them is one transaction under the
C-P2.3 profile lock that leaves a decision row; the queue is the read-only
C-P2.4 preview. Nothing here creates, schedules or runs work.
-}
module Lockstep.Application.ProjectChecks
  ( basicChecksId
  , basicChecksDocument
  , ChecksChoice (..)
  , EffectiveRules (..)
  , KindRules (..)
  , Standing (..)
  , QueueEntry (..)
  , ProjectChecks (..)
  , ChecksOutcome (..)
  , ExpectedChecks (..)
  , projectChecks
  , chooseChecks
  , chooseChecksExpecting
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Maybe (catMaybes, isJust, mapMaybe)
import Data.Ord (Down (..))
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Text.Show (Show)

import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason, withDatabase)
import Lockstep.Application.Ledger (SchedulePreview (..), ledgerFailureCode, previewSchedule)
import Lockstep.Application.ProfileDocument (decodeProfileDocument)
import Lockstep.Application.Profiles (loadStoredDefinition, sha256Hasher)
import Lockstep.Application.Projects (ProjectView (..), findProject)
import Lockstep.Kernel.Identity (WorkOrderId (..), uuidText)
import Lockstep.Kernel.Policy (checksLost)
import Lockstep.Kernel.Profile
  ( Behaviour (..)
  , Gate
  , LayerLevel (..)
  , ProfileDefinition
  , ProfileRef (..)
  , ResolutionInput (..)
  , contentDigestText
  , effectiveDigest
  , effectiveGates
  , effectiveSources
  , gateApplies
  , mkProfileDefinition
  , mkWorkFacts
  , profileIdText
  , profileRef
  , profileRefusalCode
  , resolveProfile
  )
import Lockstep.Kernel.Scheduler (Ineligibility, decisionEligible, decisionIneligible)
import Lockstep.Kernel.Transition (Principal (Human))
import Lockstep.Kernel.WorkOrder (WorkOrderKind)
import Lockstep.Persistence.Profiles qualified as Store

-- | The built-in starting choice: the always-on rules and no extra checks.
basicChecksId :: T.Text
basicChecksId =
  T.pack "lockstep-basic"

basicChecksDocument :: LBS.ByteString
basicChecksDocument =
  LBS.fromStrict (TE.encodeUtf8 basicChecksText)

basicChecksText :: T.Text
basicChecksText =
  T.pack "{\"id\":\"lockstep-basic\",\"version\":1,\"gates\":[]}"

basicDefinition :: Maybe ProfileDefinition
basicDefinition =
  either (const Nothing) Just (decodeProfileDocument basicChecksDocument)
    >>= either (const Nothing) Just . mkProfileDefinition

-- | A set of checks a person can choose; 'Nothing' as its definition when its stored digest does not reproduce.
data ChecksChoice
  = ChecksChoice
  { choiceId :: T.Text
  , choiceVersion :: Int
  , choiceDigest :: T.Text
  , choiceDefinition :: Maybe ProfileDefinition
  , choiceBuiltIn :: Bool
  }
  deriving (Eq, Show)

-- | The effective Profile for one kind of work: its digest, its sources (level, id, version, digest) and the checks that apply.
data EffectiveRules
  = EffectiveRules
  { rulesDigest :: T.Text
  , rulesSources :: [(T.Text, T.Text, Int, T.Text)]
  , rulesChecks :: [Gate]
  }
  deriving (Eq, Show)

data KindRules
  = KindRules
  { rulesKind :: WorkOrderKind
  , rulesOutcome :: Either T.Text EffectiveRules
  }
  deriving (Eq, Show)

data Standing
  = FirstInLine
  | InLine Int
  | CannotStartYet [Ineligibility]
  deriving (Eq, Show)

data QueueEntry
  = QueueEntry
  { entryOrder :: T.Text
  , entryTitle :: T.Text
  , entryPriority :: Int
  , entryStanding :: Standing
  }
  deriving (Eq, Show)

data ProjectChecks
  = ProjectChecks
  { checksProject :: ProjectView
  , checksSettable :: Bool
  , checksCurrent :: Maybe ChecksChoice
  , checksChoices :: [ChecksChoice]
  , checksRules :: [KindRules]
  , checksQueue :: Either T.Text [QueueEntry]
  }
  deriving (Eq, Show)

data ChecksOutcome
  = ChecksChosen
  | ChecksUnchanged
  deriving (Eq, Show)

-- | What the page showed as the current choice (C-C.R1 R10): nothing, or one set of checks.
data ExpectedChecks
  = ExpectNothing
  | ExpectProfile T.Text
  deriving (Eq, Show)

-- | Whether the page's choice is the current one; nothing chosen is never a set of checks.
expectationMet :: Maybe T.Text -> ExpectedChecks -> Bool
expectationMet current expected =
  case (current, expected) of
    (Nothing, ExpectNothing) -> True
    (Just c, ExpectProfile e) -> c == e
    _ -> False

choiceOf :: Store.ProfileRow -> ChecksChoice
choiceOf row =
  ChecksChoice
    { choiceId = Store.profileRowId row
    , choiceVersion = fromIntegral (Store.profileRowVersion row)
    , choiceDigest = Store.profileRowDigest row
    , choiceDefinition = either (const Nothing) Just (loadStoredDefinition row)
    , choiceBuiltIn = False
    }

builtInChoice :: Maybe ChecksChoice
builtInChoice =
  fmap
    ( \d ->
        let
          ref = profileRef sha256Hasher d
        in
          ChecksChoice basicChecksId (refVersion ref) (contentDigestText (refDigest ref)) (Just d) True
    )
    basicDefinition

-- | The project's repository, through its Engineer (C-P3.5): only a project with a folder has one.
repositoryOf :: ProjectView -> O.Orville (Maybe T.Text)
repositoryOf view =
  case projectEngineer view of
    Nothing -> pure Nothing
    Just engineer -> do
      owner <- Store.engineerRepository engineer
      pure (owner >>= Store.engineerRowRepository)

levelText :: LayerLevel -> T.Text
levelText level =
  T.pack $
    case level of
      LayerBaseline -> "baseline"
      LayerRepositoryDefault -> "repository-default"
      LayerSpecialization -> "specialization"
      LayerOverride -> "override"

-- | L3: the effective Profile per kind, resolved as C-P2.5 @createWorkOrder@ does (no classes or path classes, behaviour-changing).
rulesFor :: ProfileDefinition -> [Store.ProfileRow] -> WorkOrderKind -> KindRules
rulesFor current catalogRows kind =
  KindRules kind $
    case traverse loadStoredDefinition catalogRows of
      Left _ -> Left (T.pack "profile-integrity")
      Right catalog ->
        case mkWorkFacts Human kind [] [] BehaviourChanging of
          Left refusal -> Left (profileRefusalCode refusal)
          Right facts ->
            case resolveProfile sha256Hasher (ResolutionInput current catalog [] facts) of
              Left refusal -> Left (profileRefusalCode refusal)
              Right effective ->
                Right
                  EffectiveRules
                    { rulesDigest = contentDigestText (effectiveDigest effective)
                    , rulesSources =
                        [ (levelText level, profileIdText (refId ref), refVersion ref, contentDigestText (refDigest ref))
                        | (level, ref) <- effectiveSources effective
                        ]
                    , rulesChecks = L.filter (gateApplies facts) (effectiveGates effective)
                    }

-- | L6: the project's queued orders, those that can start first in line order, then the others by priority and id.
queueOf :: T.Text -> SchedulePreview -> [QueueEntry]
queueOf repository preview =
  let
    decision = previewDecision preview
    mine = [(o, (title, priority)) | (o, r, priority, title) <- previewOrders preview, r == repository]
    eligible = [o | o <- decisionEligible decision, isJust (L.lookup o mine)]
    blocked = [(o, reasons) | (o, reasons) <- decisionIneligible decision, isJust (L.lookup o mine)]
    entry o standing =
      fmap (\(title, priority) -> QueueEntry (orderText o) title priority standing) (L.lookup o mine)
    first = catMaybes (L.zipWith (\n o -> entry o (if n == 1 then FirstInLine else InLine n)) [1 :: Int ..] eligible)
    rest = mapMaybe (\(o, reasons) -> entry o (CannotStartYet reasons)) blocked
  in
    first <> L.sortOn (\e -> (Down (entryPriority e), entryOrder e)) rest

orderText :: WorkOrderId -> T.Text
orderText (WorkOrderId u) =
  uuidText u

projectChecks :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Maybe ProjectChecks))
projectChecks runtime pid = do
  found <- findProject runtime pid
  case found of
    Left reason -> pure (Left reason)
    Right Nothing -> pure (Right Nothing)
    Right (Just view) -> do
      stored <-
        withDatabase runtime $ do
          repository <- repositoryOf view
          currentId <- maybe (pure Nothing) Store.repositoryDefault repository
          currentRow <- maybe (pure Nothing) (`Store.findProfile` Nothing) currentId
          latest <- Store.latestProfiles
          pure (repository, currentRow, latest)
      case stored of
        Left reason -> pure (Left reason)
        Right (repository, currentRow, latest) -> do
          queue <-
            case repository of
              Nothing -> pure (Right [])
              Just r -> fmap (either (Left . ledgerFailureCode) (Right . queueOf r)) (previewSchedule runtime)
          let
            registered = fmap choiceOf (L.sortOn Store.profileRowId latest)
            builtIn = [c | L.all ((/= basicChecksId) . choiceId) registered, Just c <- [builtInChoice]]
            current = fmap choiceOf currentRow
            rules =
              case current of
                Nothing -> []
                Just c ->
                  case choiceDefinition c of
                    Nothing -> fmap (\k -> KindRules k (Left (T.pack "profile-integrity"))) [minBound .. maxBound]
                    Just d -> fmap (rulesFor d latest) [minBound .. maxBound]
          pure . Right . Just $
            ProjectChecks
              { checksProject = view
              , checksSettable = isJust repository
              , checksCurrent = current
              , checksChoices = builtIn <> registered
              , checksRules = rules
              , checksQueue = queue
              }

{- | L4 with the C-P3.7 text for what the page showed: @none@ is "nothing
chosen" and only that (C-C.R1 R10), so when a set of checks called @none@ is
the current one the request cannot be told apart and is refused
@checks-changed@.
-}
chooseChecks :: DatabaseRuntime -> T.Text -> T.Text -> T.Text -> Bool -> IO (Either NotReadyReason (Either T.Text ChecksOutcome))
chooseChecks runtime pid expected =
  chooseChecksExpecting runtime pid (if expected == T.pack "none" then ExpectNothing else ExpectProfile expected)

-- | L4, in its order; every refusal from @checks-changed@ on leaves a decision row.
chooseChecksExpecting :: DatabaseRuntime -> T.Text -> ExpectedChecks -> T.Text -> Bool -> IO (Either NotReadyReason (Either T.Text ChecksOutcome))
chooseChecksExpecting runtime pid expected choice confirmed = do
  found <- findProject runtime pid
  case found of
    Left reason -> pure (Left reason)
    Right Nothing -> pure (Right (Left (T.pack "unknown-project")))
    Right (Just view) ->
      withDatabase runtime . O.withTransaction $ do
        repository <- repositoryOf view
        case (repository, projectEngineer view) of
          (Just repositoryId, Just engineer) -> do
            Store.lockProfiles
            currentId <- Store.repositoryDefault repositoryId
            let
              decision =
                Store.NewProfileDecision
                  { Store.profileDecisionOperation = T.pack "repository-set-profile"
                  , Store.profileDecisionProfile = Just choice
                  , Store.profileDecisionVersion = Nothing
                  , Store.profileDecisionDigest = Nothing
                  , Store.profileDecisionEngineer = Just engineer
                  , Store.profileDecisionRepository = Just repositoryId
                  , Store.profileDecisionOutcome = T.pack "accepted"
                  , Store.profileDecisionRefusal = Nothing
                  }
              refuse d code = do
                _ <- Store.insertProfileDecision d {Store.profileDecisionOutcome = T.pack "refused", Store.profileDecisionRefusal = Just code}
                pure (Left code)
            if not (expectationMet currentId expected)
              then refuse decision (T.pack "checks-changed")
              else do
                when (choice == basicChecksId) registerBasic
                row <- Store.findProfile choice Nothing
                case row of
                  Nothing -> refuse decision (T.pack "profile-unknown")
                  Just r ->
                    let
                      known = decision {Store.profileDecisionVersion = Just (Store.profileRowVersion r), Store.profileDecisionDigest = Just (Store.profileRowDigest r)}
                    in
                      case loadStoredDefinition r of
                        Left _ -> refuse known (T.pack "profile-integrity")
                        Right chosen
                          | currentId == Just choice -> do
                              _ <- Store.insertProfileDecision known {Store.profileDecisionOutcome = T.pack "unchanged"}
                              pure (Right ChecksUnchanged)
                          | otherwise -> do
                              currentRow <- maybe (pure Nothing) (`Store.findProfile` Nothing) currentId
                              let
                                -- A current set that fails its digest cannot be compared: the change needs confirming.
                                losing =
                                  case fmap loadStoredDefinition currentRow of
                                    Nothing -> False
                                    Just (Left _) -> True
                                    Just (Right currentDefinition) -> not (L.null (checksLost (Just currentDefinition) chosen))
                              if losing && not confirmed
                                then refuse known (T.pack "fewer-checks-unconfirmed")
                                else do
                                  Store.insertRepositoryProfile repositoryId choice
                                  _ <- Store.insertProfileDecision known
                                  pure (Right ChecksChosen)
          _ -> pure (Left (T.pack "project-has-no-folder"))

-- | Registers the built-in document as version 1 when no @lockstep-basic@ exists, with its C-P2.3 decision row.
registerBasic :: O.Orville ()
registerBasic = do
  existing <- Store.findProfile basicChecksId Nothing
  case (existing, basicDefinition) of
    (Nothing, Just d) -> do
      let
        digest = contentDigestText (refDigest (profileRef sha256Hasher d))
      Store.insertProfile (Store.ProfileRow basicChecksId 1 digest basicChecksText)
      _ <-
        Store.insertProfileDecision
          Store.NewProfileDecision
            { Store.profileDecisionOperation = T.pack "profile-add"
            , Store.profileDecisionProfile = Just basicChecksId
            , Store.profileDecisionVersion = Just 1
            , Store.profileDecisionDigest = Just digest
            , Store.profileDecisionEngineer = Nothing
            , Store.profileDecisionRepository = Nothing
            , Store.profileDecisionOutcome = T.pack "accepted"
            , Store.profileDecisionRefusal = Nothing
            }
      pure ()
    _ -> pure ()
