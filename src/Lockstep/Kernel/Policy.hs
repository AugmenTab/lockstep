{- | Plain words for how work is checked and for what can start (contract
C-P3.7 L1, L2, L5): the always-on rules, a checklist row per check, what a
change of checks would lose, and why a piece of work cannot start yet. No
Profile, gate, invariant, Work Order, Ticket, Engineer, scheduler or digest
word reaches the person on the ordinary path (PRD FR-UX-07).
-}
module Lockstep.Kernel.Policy
  ( invariantWords
  , stageWords
  , artifactWords
  , verifierWords
  , approvalWords
  , kindWords
  , pathWords
  , CheckRow (..)
  , checkRow
  , Loss (..)
  , checksLost
  , lossWords
  , ineligibilityWords
  , checksRefusalWords
  ) where

import Data.List qualified as L
import Data.Maybe (catMaybes, fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Kernel.Profile
  ( Approval (..)
  , ArtifactKind (..)
  , Gate
  , GateBlock (..)
  , GateStage (..)
  , PathClass (..)
  , ProfileDefinition
  , UniversalInvariant (..)
  , VerifierKind (..)
  , definitionAllows
  , definitionGates
  , gateApproval
  , gateArtifacts
  , gateExceptionPath
  , gateId
  , gateIdText
  , gateScopes
  , gateStage
  , gateVerifiers
  , parsePathClass
  , profileIdText
  )
import Lockstep.Kernel.Scheduler (Ineligibility (..), resourceNameText)
import Lockstep.Kernel.WorkOrder (WorkOrderKind (..), parseWorkOrderKind)

invariantWords :: UniversalInvariant -> T.Text
invariantWords invariant =
  T.pack $
    case invariant of
      SingleImplementer -> "Only one worker changes a piece of work at a time."
      ScopeAndAuthorization -> "Work stays inside what a person authorized."
      DurableAttempts -> "Every attempt is recorded and kept."
      ProtectedFrozenTests -> "Agreed tests cannot be changed to make work pass."
      DeterministicVerification -> "Results are checked by repeatable automatic checks."
      IndependentReview -> "Work is reviewed by someone other than its author."
      BoundedRetries -> "Failed work is retried only a limited number of times."
      LegitimateCommits -> "Only checked, approved changes are saved into the project."
      HumanCompletion -> "Only a person can mark work as finished."

stageWords :: GateStage -> T.Text
stageWords stage =
  T.pack $
    case stage of
      BeforeExecution -> "Before work starts"
      BeforeAcceptance -> "Before the work is accepted"
      BeforeCompletion -> "Before the work is finished"

artifactWords :: ArtifactKind -> T.Text
artifactWords kind =
  T.pack $
    case kind of
      RequirementsBasis -> "what is required, written down"
      Reproduction -> "a way to show the problem happening"
      ImpactAssessment -> "what the change could affect"
      ThreatModel -> "the security risks"
      ArchitectureAssessment -> "how it fits the overall design"
      ClassificationRationale -> "why the work was classified as it was"
      HumanApprovalRecord -> "a person's recorded approval"
      FrozenTests -> "agreed tests that cannot be changed"
      VerificationRecord -> "a record of the automatic checks"
      ReviewRecord -> "a record of the independent review"
      RegressionEvidence -> "proof that what worked before still works"
      IntegrationRecord -> "a record of the change being combined into the project"
      Documentation -> "updated documentation"

verifierWords :: VerifierKind -> T.Text
verifierWords verifier =
  T.pack $
    case verifier of
      VerifyDigest -> "a fingerprint check"
      VerifyCommand -> "an automatic check"
      VerifyIndependentReview -> "an independent reviewer"
      VerifyHumanInspection -> "a person looking at it"

approvalWords :: Approval -> T.Text
approvalWords approval =
  T.pack $
    case approval of
      ApprovalNone -> "No approval needed"
      ApprovalSupervisor -> "Lockstep's supervisor must approve it"
      ApprovalHuman -> "A person must approve it"

kindWords :: WorkOrderKind -> T.Text
kindWords kind =
  T.pack $
    case kind of
      Engineering -> "code changes"
      Investigate -> "investigations"
      PrRework -> "rework after a review"
      Integrate -> "combining changes into the project"
      Plan -> "planning"
      PublishReport -> "publishing reports"
      SkillInstall -> "installing skills"

pathWords :: PathClass -> T.Text
pathWords path =
  T.pack $
    case path of
      PathDocs -> "documentation"
      PathSource -> "source code"
      PathTests -> "tests"
      PathBuild -> "build files"
      PathDependencies -> "dependencies"
      PathConfiguration -> "configuration"

-- | One check as a checklist row.
data CheckRow
  = CheckRow
  { rowCheck :: T.Text
  , rowWhen :: T.Text
  , rowNeeds :: [T.Text]
  , rowCheckedBy :: [T.Text]
  , rowApproval :: T.Text
  , rowWaivable :: T.Text
  , rowAppliesTo :: T.Text
  }
  deriving (Eq, Show)

checkRow :: Gate -> CheckRow
checkRow gate =
  CheckRow
    { rowCheck = gateIdText (gateId gate)
    , rowWhen = stageWords (gateStage gate)
    , rowNeeds = fmap artifactWords (gateArtifacts gate)
    , rowCheckedBy = fmap verifierWords (gateVerifiers gate)
    , rowApproval = approvalWords (gateApproval gate)
    , rowWaivable =
        T.pack $
          if gateExceptionPath gate
            then "A person may waive it for one piece of work, giving a reason"
            else "It cannot be waived"
    , rowAppliesTo = appliesTo (gateScopes gate)
    }

appliesTo :: (Maybe [T.Text], Maybe [T.Text], Maybe [T.Text]) -> T.Text
appliesTo (kinds, classes, paths) =
  let
    orList = T.intercalate (T.pack " or ")
    named parse plainWords name = maybe name plainWords (parse name)
    parts =
      catMaybes
        [ fmap (\ks -> T.pack "only " <> orList (fmap (named parseWorkOrderKind kindWords) ks)) kinds
        , fmap (\cs -> T.pack "only work marked " <> orList cs) classes
        , fmap (\ps -> T.pack "only when it changes " <> orList (fmap (named parsePathClass pathWords) ps)) paths
        ]
  in
    case parts of
      [] -> T.pack "All work"
      _ -> capitalized (T.intercalate (T.pack ", ") parts)

capitalized :: T.Text -> T.Text
capitalized text =
  T.toUpper (T.take 1 text) <> T.drop 1 text

-- | What a change from the current set of checks to the chosen one would stop requiring.
data Loss
  = LostCheck T.Text
  | LostDocsOnlyRule
  deriving (Eq, Show)

{- | L2: every current check the chosen set does not contain unchanged, then the
documents-only rule when the current set keeps it and the chosen one does not.
An absent setting reads as the installation baseline's (allowed).
-}
checksLost :: Maybe ProfileDefinition -> ProfileDefinition -> [Loss]
checksLost current chosen =
  case current of
    Nothing -> []
    Just c ->
      [LostCheck (gateIdText (gateId g)) | g <- definitionGates c, g `L.notElem` definitionGates chosen]
        <> [LostDocsOnlyRule | not (allows c), allows chosen]
 where
  allows =
    fromMaybe True . definitionAllows

lossWords :: Loss -> T.Text
lossWords loss =
  case loss of
    LostCheck check -> T.pack "the check " <> check
    LostDocsOnlyRule -> T.pack "the rule that work changing only documentation still needs agreed tests"

ineligibilityWords :: Ineligibility -> T.Text
ineligibilityWords reason =
  case reason of
    BindingMismatch -> T.pack "Its record of which checks apply does not match; a person needs to look at it."
    ProfileDefaultUnset -> T.pack "No checks are chosen for this project yet."
    ProfileChangedSince ids -> T.pack "The project's checks changed after it was prepared (" <> T.intercalate (T.pack ", ") (fmap profileIdText ids) <> T.pack "); a person needs to confirm them."
    PrerequisiteBlocked g block -> T.pack "A check that must pass before work starts is not done yet: " <> gateIdText g <> T.pack " (" <> blockWords block <> T.pack ")."
    DependencyUnknown _ -> T.pack "It needs other work that Lockstep cannot find."
    DependencyUnsatisfiable _ -> T.pack "Other work it needs was canceled or replaced."
    DependencyIncomplete _ -> T.pack "It needs other work to finish first."
    RepositoryNotOwned -> T.pack "Its folder is not set up for Lockstep to work in."
    RepositoryReserved _ -> T.pack "Other work in the same folder is in progress."
    ResourceUnknownReason r -> T.pack "Lockstep does not know whether " <> resourceNameText r <> T.pack " is available."
    ResourceUnavailableReason r -> resourceNameText r <> T.pack " is not available."
    SourceUnknown -> T.pack "The task it came from cannot be found."
    SourceStale -> T.pack "The task it came from changed after it was prepared."

blockWords :: GateBlock -> T.Text
blockWords block =
  case block of
    MissingArtifact a -> T.pack "missing: " <> artifactWords a
    AmbiguousEvidence a -> T.pack "more than one record of " <> artifactWords a
    Unverified a _ -> T.pack "not yet checked: " <> artifactWords a
    NeedsApproval a _ -> T.pack "needs approval: " <> artifactWords a

checksRefusalWords :: T.Text -> T.Text
checksRefusalWords code =
  T.pack $
    case T.unpack code of
      "unknown-project" -> "This project no longer exists."
      "project-has-no-folder" -> "This project has no folder yet, so there is nothing to check. Connect a folder on the project's page first."
      "checks-changed" -> "Someone changed this project's checks since this page was shown. Nothing was changed; this is what is chosen now."
      "profile-unknown" -> "That set of checks is not available."
      "profile-integrity" -> "That set of checks is damaged and cannot be used."
      "fewer-checks-unconfirmed" -> "This choice would stop requiring some checks. Nothing was changed. To go ahead, tick the box to confirm."
      _ -> "Lockstep could not do this. The exact reason is under Technical details."
