{- | Pure rules for letting Lockstep work in a project and handing it a bug
(contract C-P4.1 X1–X3, X6, X7, X10): the built-in Bug Profile, which of its
checks a set of checks lacks, which folders Lockstep may write, why a task
cannot be handed over yet, the canonical request texts behind each record, and
the plain words for every refusal. Nothing here runs anything.
-}
module Lockstep.Kernel.Execution
  ( bugClass
  , bugFixProfileId
  , bugFixRaw
  , bugFixDefinition
  , bugCheckIds
  , missingBugChecks
  , insideProjectsFolder
  , admissionBlock
  , enablementRequestText
  , admissionRequestText
  , executionRefusalCodes
  , executionRefusalWords
  ) where

import Data.Bifunctor (bimap)
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (show)

import Lockstep.Kernel.Profile
  ( Gate
  , ProfileDefinition
  , ProfileRefusal
  , RawGate (..)
  , RawProfile (..)
  , definitionGates
  , gateId
  , gateIdText
  , mkProfileDefinition
  )
import Lockstep.Kernel.Task (TaskReadiness (..))

-- | The class tag of work that fixes a bug.
bugClass :: T.Text
bugClass =
  T.pack "bug"

bugFixProfileId :: T.Text
bugFixProfileId =
  T.pack "lockstep-bug-fix"

-- | One X1 check: engineering work classed @bug@, before acceptance, approved by the Supervisor.
bugGate :: String -> [String] -> [String] -> Bool -> RawGate
bugGate name artifacts verifiers exceptionPath =
  RawGate
    { rawGateId = T.pack name
    , rawGateStage = T.pack "before-acceptance"
    , rawGateArtifacts = fmap T.pack artifacts
    , rawGateKinds = Just [T.pack "engineering"]
    , rawGateClasses = Just [bugClass]
    , rawGatePathClasses = Nothing
    , rawGateVerifiers = fmap T.pack verifiers
    , rawGateApproval = T.pack "supervisor"
    , rawGateExceptionPath = exceptionPath
    }

{- | The built-in Bug Profile, version 1 (Bible §31.1): reproduction (a person
may except it with evidence, and only a person), impact and requirements,
failing regression tests frozen, verification and regression evidence, and an
independent review, all before the work is accepted.
-}
bugFixRaw :: RawProfile
bugFixRaw =
  RawProfile
    { rawProfileId = bugFixProfileId
    , rawProfileVersion = 1
    , rawAllowsNonBehavioural = Nothing
    , rawInvariantExceptions = []
    , rawGates =
        [ bugGate "bug-reproduction" ["reproduction"] ["deterministic-command"] True
        , bugGate "bug-requirements" ["impact-assessment", "requirements-basis"] ["digest-check"] False
        , bugGate "bug-regression-test" ["frozen-tests"] ["deterministic-command", "digest-check"] False
        , bugGate "bug-verification" ["regression-evidence", "verification-record"] ["deterministic-command"] False
        , bugGate "bug-review" ["review-record"] ["independent-review"] False
        ]
    , rawSpecializations = []
    }

bugFixDefinition :: Either ProfileRefusal ProfileDefinition
bugFixDefinition =
  mkProfileDefinition bugFixRaw

-- | The ids of the Bug Profile's checks, sorted.
bugCheckIds :: [T.Text]
bugCheckIds =
  L.sort (fmap rawGateId (rawGates bugFixRaw))

{- | X2: the Bug Profile's checks that are not among these gates unchanged,
sorted by id. A stricter variant of a check counts as missing.
-}
missingBugChecks :: [Gate] -> [T.Text]
missingBugChecks gates =
  case bugFixDefinition of
    Left _ -> bugCheckIds
    Right definition -> L.sort [gateIdText (gateId g) | g <- definitionGates definition, g `L.notElem` gates]

{- | X3: whether a folder is directly inside the projects folder: the root, a
slash, and one segment that has no slash and is not @.@ or @..@.
-}
insideProjectsFolder :: T.Text -> T.Text -> Bool
insideProjectsFolder root path =
  not (T.null root)
    && not (T.pack "/" `T.isSuffixOf` root)
    && case T.stripPrefix (root <> T.pack "/") path of
      Just segment ->
        not (T.null segment)
          && not (T.any (== '/') segment)
          && segment `L.notElem` [T.pack ".", T.pack ".."]
      Nothing -> False

-- | X6: why a task cannot be handed over yet, from its readiness (C-P3.6 K4); nothing when it can.
admissionBlock :: TaskReadiness -> Maybe T.Text
admissionBlock readiness =
  T.pack
    <$> case readiness of
      ReadyToWork -> Nothing
      NotYetReady -> Just "task-not-ready"
      BeingWorkedOn -> Just "task-not-ready"
      WaitingFor _ -> Just "task-waiting"
      BlockedBecause _ -> Just "task-blocked"
      CannotStart _ -> Just "task-cannot-start"
      Finished -> Just "task-closed"
      TaskCanceled -> Just "task-closed"

-- | X7: the canonical text of a request to let Lockstep work in a project.
enablementRequestText :: T.Text -> T.Text -> T.Text
enablementRequestText project expected =
  T.unlines
    [ T.pack "lockstep-execution-enable-v1"
    , T.pack "project " <> project
    , T.pack "expected " <> expected
    ]

-- | X7: the canonical text of a request to hand a task to Lockstep as a bug.
admissionRequestText :: T.Text -> Int -> T.Text
admissionRequestText task expected =
  T.unlines
    [ T.pack "lockstep-bug-admission-v1"
    , T.pack "task " <> task
    , T.pack "expected " <> T.pack (show expected)
    ]

refusals :: [(T.Text, T.Text)]
refusals =
  fmap
    (bimap T.pack T.pack)
    [ ("unknown-project", "Lockstep has no such project.")
    , ("unknown-task", "Lockstep has no such task.")
    , ("project-has-no-folder", "This project has no folder yet. Connect one on the project's page first.")
    , ("folder-read-only", "Lockstep can only work in projects kept in its own projects folder. This project's folder was added from elsewhere on this computer, so Lockstep only reads it.")
    , ("ownership-invalid", "Lockstep's record of which project this folder belongs to does not match any more. Nothing was changed.")
    , ("repository-changed", "This project's folder is not the one Lockstep connected any more. Nothing was changed.")
    , ("checks-changed", "How work is checked in this project changed since this page was shown. Nothing was changed; the page now shows it as it is.")
    , ("bug-checks-missing", "The checks chosen for this project do not include the checks every bug fix needs, and Lockstep never removes checks a person chose. Nothing was changed.")
    , ("already-enabled", "Lockstep may already work on bugs in this project.")
    , ("execution-not-enabled", "Lockstep may not work on bugs in this project yet. Allow it on the project's page first.")
    , ("already-admitted", "Lockstep already has this bug in line.")
    , ("stale-revision", "This task changed since this page was shown. Nothing was changed; the page now shows it as it is.")
    , ("task-not-ready", "Mark the task as ready to work on first.")
    , ("task-waiting", "This task is waiting for other tasks to finish first.")
    , ("task-blocked", "This task is blocked. Unblock it first.")
    , ("task-cannot-start", "A task this one needs was canceled, so it cannot start.")
    , ("task-closed", "This task is finished or canceled.")
    , ("key-conflict", "This form was already used for something else. Nothing was changed. Open the page again.")
    , ("revision-out-of-range", "Lockstep could not read this form. Try again.")
    , ("admission-refused", "Lockstep could not take this bug. The exact reason is under Technical details.")
    ]

executionRefusalCodes :: [T.Text]
executionRefusalCodes =
  fmap fst refusals

executionRefusalWords :: T.Text -> T.Text
executionRefusalWords code =
  fromMaybe (T.pack "Something went wrong. The exact reason is under Technical details.") (L.lookup code refusals)
