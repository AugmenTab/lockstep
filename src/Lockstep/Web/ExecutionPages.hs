{-# LANGUAGE OverloadedStrings #-}

{- | The pages' parts for letting Lockstep work in a project and handing it a
bug (contract C-P4.1 X10, X11): the project page's Fixing bugs section and the
task page's Fixing it section. Ordinary text uses plain words only; exact ids,
checks and digests are under Technical details.
-}
module Lockstep.Web.ExecutionPages
  ( projectExecutionSection
  , taskFixingSection
  ) where

import Brigid.HTML.Attributes qualified as A
import Brigid.HTML.Elements qualified as E
import Brigid.HTML.Types qualified as HTML
import Brigid.Types qualified as B
import Data.List qualified as L
import Data.Maybe (fromMaybe, isJust)
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (show)

import Lockstep.Application.Conversation (StoredRequest (..))
import Lockstep.Application.Engine (InvocationView (..), TransactionView (..))
import Lockstep.Application.EngineEvidence (CheckRun (..), Evidence (..), FindingTime (..), FindingView (..), ReviewView (..), transactionEvidence)
import Lockstep.Application.Execution (Admission (..), Enablement (..), ExecutionStatus (..))
import Lockstep.Application.ProjectChecks (Standing (..))
import Lockstep.Application.Projects (ProjectView (..))
import Lockstep.Application.Tasks (TaskView (..))
import Lockstep.Kernel.Execution (executionRefusalWords)
import Lockstep.Kernel.Identity (InvocationId (..), RepositoryId (..), identityText)
import Lockstep.Kernel.Policy (ineligibilityWords)
import Lockstep.Kernel.Profile (profileIdText)
import Lockstep.Kernel.Roles (CandidateTest (..), Criterion (..), Verdict (..))
import Lockstep.Kernel.Runner (OutcomeKind (..))
import Lockstep.Kernel.Task (TaskReadiness (..))
import Lockstep.Kernel.Transaction (Disposition (..), FixedHalt (..), HaltCode (..), Stage (..), StateName (..), haltCodeFromText, noCodingAgent, parseStage, parseStateName)
import Lockstep.Web.Fragment (attr, cls)

heading :: T.Text -> T.Text -> E.ChildHTML E.Division E.Body
heading sectionId title =
  E.h2 [attr "id" sectionId] [E.text title]

hidden :: T.Text -> T.Text -> E.ChildHTML E.Form E.Division
hidden name value =
  E.input [A.type_ HTML.InputHidden, attr "name" name, attr "value" value]

fact :: T.Text -> T.Text -> [E.ChildHTML E.DescriptionList E.Details]
fact name value =
  [E.dt [] [E.text name], E.dd [] [E.code [] [E.text value]]]

{- | The project page's Fixing bugs section, with a fresh key for its form;
@started@: Lockstep has started on a bug here (C-P4.16).
-}
projectExecutionSection :: ProjectView -> Maybe ExecutionStatus -> Bool -> T.Text -> [E.ChildHTML E.Division E.Body]
projectExecutionSection project status started key =
  case status of
    Nothing -> []
    Just NeedsFolder ->
      [ heading "execution" "Fixing bugs"
      , E.p [] [E.text "Lockstep can fix bugs in a project once the project has a folder. Connect a folder first, below."]
      ]
    Just FolderReadOnly ->
      [ heading "execution" "Fixing bugs"
      , E.p [] [E.text (executionRefusalWords "folder-read-only")]
      ]
    Just (NotEnabled current) ->
      [ heading "execution" "Fixing bugs"
      , E.p [] [E.text "You can let Lockstep work on bugs you hand it in this project. Before it changes anything, each fix must reproduce the bug and have its tests agreed and frozen; then it must pass the automatic checks and an independent review, and only you decide when it is finished."]
      , E.p [cls "ls-muted"] [E.text "Allowing it changes nothing in the folder. The steps that do the work arrive in a later update of Lockstep."]
      , E.form
          [attr "id" "enable-form", A.method B.FormPOST, A.action (B.mkRawURL ("/app/api/projects/" <> projectId project <> "/execution"))]
          [ hidden "key" key
          , hidden "expected" (maybe "none" profileIdText current)
          , hidden "expected_set" (maybe "no" (const "yes") current)
          , E.button [attr "id" "enable-execution", attr "type" "submit", cls "ls-primary"] [E.text "Let Lockstep fix bugs here"]
          ]
      ]
    Just (Enabled e) ->
      [ heading "execution" "Fixing bugs"
      , E.p [cls "ls-good-text"] [E.text "Lockstep may work on bugs in this project."]
      , if started
          then E.p [cls "ls-muted"] [E.text "Each bug you hand it shows on its task page where its fix stands, and asks you when only you can decide."]
          else E.p [cls "ls-muted"] [E.text "Nothing has run yet: the steps that do the work arrive in a later update of Lockstep. Hand it a bug from the bug's task page."]
      , E.details
          []
          [ E.summary [] [E.text "Technical details"]
          , E.dl
              [cls "ls-facts"]
              ( fact "Engineer" (enablementEngineer e)
                  <> fact "Repository" (identityText (enablementRepository e))
                  <> fact "Checks in force" (enablementChecks e <> " version " <> T.pack (show (enablementChecksVersion e)) <> " " <> enablementChecksDigest e)
                  <> fact "Allowed" (enablementAt e <> " by " <> enablementActor e)
              )
          ]
      ]

standingWords :: Maybe Standing -> T.Text
standingWords standing =
  case standing of
    Just FirstInLine -> "It is first in line."
    Just (InLine n) -> "It is number " <> T.pack (show n) <> " in line."
    Just (CannotStartYet reasons) -> "It cannot start yet: " <> T.unwords (fmap ineligibilityWords reasons)
    Nothing -> "Its place in line is not known right now."

-- | The task page's Fixing it section: only for a task of a project Lockstep may work in.
taskFixingSection :: TaskView -> Maybe ExecutionStatus -> Maybe Admission -> Maybe Standing -> Maybe (TransactionView, Maybe StoredRequest) -> T.Text -> [E.ChildHTML E.Division E.Body]
taskFixingSection task status admission standing work key =
  case (status, admission, work) of
    (_, Just a, Just (tx, request)) -> transactionSection a tx request key
    (_, Just a, Nothing) ->
      [ heading "fixing" "Fixing it"
      , E.p [cls "ls-good-text"] [E.text "Lockstep has this bug in line to fix."]
      , E.p [] [E.text (standingWords standing)]
      , E.details
          []
          [ E.summary [] [E.text "Technical details"]
          , E.dl
              [cls "ls-facts"]
              ( fact "Work order" (admissionWorkOrder a)
                  <> fact "Effective profile digest" (admissionEffectiveDigest a)
                  <> fact "Handed over" (admissionAt a <> " by " <> admissionActor a)
              )
          ]
      ]
    (Just (Enabled _), Nothing, _)
      | taskReadinessOf task == ReadyToWork ->
          [ heading "fixing" "Fixing it"
          , E.p [] [E.text "Lockstep may work on bugs in this project. Hand this task to it as a bug: before changing anything it must reproduce the bug and have its tests agreed."]
          , E.form
              [attr "id" "admit-form", A.method B.FormPOST, A.action (B.mkRawURL ("/app/api/tasks/" <> taskId task <> "/bug"))]
              [ hidden "key" key
              , hidden "ticket_revision" (T.pack (show (taskTicketRevision task)))
              , E.button [attr "id" "admit-bug", attr "type" "submit", cls "ls-primary"] [E.text "Ask Lockstep to fix this bug"]
              ]
          ]
      | otherwise ->
          [ heading "fixing" "Fixing it"
          , E.p [cls "ls-muted"] [E.text "When this task is ready to work on, you can ask Lockstep to fix it as a bug."]
          ]
    _ -> []

-- The fix under way (C-P4.16) --------------------------------------------------------------

{- | U1–U4: where the fix stands, what it must do, how it is checked, what the
checks showed, what was found and the review; what Lockstep could not tell;
a person's decision when it stopped; Done or not when it is committed.
-}
transactionSection :: Admission -> TransactionView -> Maybe StoredRequest -> T.Text -> [E.ChildHTML E.Division E.Body]
transactionSection a tx request key =
  [heading "fixing" "Fixing it"]
    <> standingNow
    <> earlier
    <> [E.h3 [] [E.text "What the fix must do"]]
    <> criteria
    <> [E.h3 [] [E.text "How it is checked"]]
    <> method
    <> [E.h3 [] [E.text "What the checks showed"]]
    <> results
    <> [E.h3 [] [E.text "Looking for flaws"]]
    <> findings
    <> [E.h3 [] [E.text "Independent review"]]
    <> review
    <> notKnown
    <> [technical]
 where
  ev = transactionEvidence tx
  -- The view carries the stored names as text; they are read into the Kernel's types once, here.
  -- A name this page does not know is shown as such, never taken for another.
  state = parseStateName (viewState tx)
  stage = parseStage (viewStage tx)
  -- A halted or stopped transaction always has its code (the stored state does not read without
  -- it); a view without one says so rather than show another code's words.
  haltLine words' = maybe "Lockstep did not record why." (words' . haltCodeFromText) (viewHalt tx)
  standingNow =
    case state of
      Just StateRunning -> [E.p [] [E.text ("Lockstep is working on this bug: " <> stepWords stage <> ".")]]
      Just StateHalted ->
        [ E.p [cls "ls-notice", attr "id" "fix-halted"] [E.text ("Lockstep stopped while " <> stepWords stage <> " and needs your decision.")]
        , E.p [] [E.text (haltLine haltWords)]
        ]
          <> decisionForm
      Just StateAccepted ->
        [ E.p [cls "ls-good-text", attr "id" "fix-committed"] [E.text "The fix passed its checks and an independent review, and Lockstep committed it on its own branch in the project's folder. Nothing was sent anywhere."]
        , E.p [] [E.text "Only you decide whether this bug is fixed. Look at what was checked below first."]
        , completionForm
        ]
      Just StateDone -> [E.p [cls "ls-good-text", attr "id" "fix-done"] [E.text "You marked this bug fixed."]]
      Just StateStopped -> [E.p [cls "ls-muted", attr "id" "fix-stopped"] [E.text ("Lockstep stopped fixing this bug: " <> haltLine stoppedWords)]]
      Nothing -> [E.p [cls "ls-notice", attr "id" "fix-state-unrecognised"] [E.text ("Lockstep cannot show where this fix stands: it recorded a state this page does not recognise (" <> viewState tx <> ").")]]
  decisionForm =
    case request of
      Just r
        | storedState r == "open" ->
            [ E.form
                [attr "id" "halt-form", A.method B.FormPOST, A.action (B.mkRawURL ("/app/api/transactions/" <> viewId tx <> "/decision"))]
                [ hidden "key" key
                , hidden "request" (storedRequestId r)
                , hidden "revision" (T.pack (show (storedRevision r)))
                , E.fieldset [] (E.legend [] [E.text "What should happen next?"] : fmap choice (storedChoices r))
                , E.button [attr "id" "answer-halt", attr "type" "submit", cls "ls-primary"] [E.text "Record my decision"]
                ]
            ]
        | otherwise -> [E.p [cls "ls-muted"] [E.text "Your decision is recorded; Lockstep acts on it shortly."]]
      Nothing -> [E.p [cls "ls-muted"] [E.text "Lockstep is preparing the question for you. Look again shortly."]]
  choice name =
    E.div
      [cls "ls-choice"]
      [ E.input [A.type_ HTML.InputRadio, attr "id" ("halt-" <> name), attr "name" "choice", attr "value" name]
      , E.label [attr "for" ("halt-" <> name)] [E.text (choiceWords name)]
      ]
  completionForm =
    E.form
      [attr "id" "completion-form", A.method B.FormPOST, A.action (B.mkRawURL ("/app/api/transactions/" <> viewId tx <> "/completion"))]
      [ E.fieldset
          []
          [ E.legend [] [E.text "Is this bug fixed?"]
          , E.div
              [cls "ls-choice"]
              [ E.input [A.type_ HTML.InputRadio, attr "id" "completion-done", attr "name" "choice", attr "value" "done"]
              , E.label [attr "for" "completion-done"] [E.text "Yes, it is fixed: mark it done"]
              ]
          , E.div
              [cls "ls-choice"]
              [ E.input [A.type_ HTML.InputRadio, attr "id" "completion-not-done", attr "name" "choice", attr "value" "not-done"]
              , E.label [attr "for" "completion-not-done"] [E.text "No, it is not fixed: stop here"]
              ]
          ]
      , E.button [attr "id" "decide-completion", attr "type" "submit", cls "ls-primary"] [E.text "Record my decision"]
      ]
  criteria =
    case evidenceCriteria ev of
      [] -> [E.p [cls "ls-muted"] [E.text "Not written yet."]]
      cs ->
        [ E.ul
            [attr "id" "fix-criteria"]
            [E.li [] [E.text (criterionText c), E.text (" (from the task: \8220" <> criterionTicketQuote c <> "\8221)")] | c <- cs]
        ]
  method =
    case (evidenceTests ev, evidenceCommands ev) of
      ([], []) -> [E.p [cls "ls-muted"] [E.text "Not written yet."]]
      (ts, cs) ->
        [ E.ul
            [attr "id" "fix-method"]
            ( [E.li [] [E.text ("The test in " <> testPath t <> ", run with "), E.code [] [E.text (T.unwords (testArgv t))]] | t <- ts]
                <> [E.li [] [E.text "The project's check ", E.code [] [E.text (T.unwords c)]] | c <- cs]
            )
        , E.p [cls "ls-muted"] [E.text (if L.null ts then "" else "Once fixed in place, these tests cannot be changed by the helper that changes the code.")]
        ]
  -- C-P4.R1 R-A1: what follows is the latest attempt's; a commit is "committed" only once accepted.
  earlier =
    [ E.p [cls "ls-muted", attr "id" "fix-earlier"] [E.text "Earlier attempts at this change were not accepted. What follows is the latest attempt."]
    | evidenceAttempts ev > 1
    ]
  results =
    case evidencePassed ev of
      Nothing
        | evidenceAttempts ev > 0 -> [E.p [cls "ls-muted", attr "id" "fix-not-run"] [E.text "The checks have not run on the latest change yet."]]
        | otherwise -> [E.p [cls "ls-muted", attr "id" "fix-not-run"] [E.text "The checks have not run yet."]]
      Just (_, passed) ->
        [ E.p [attr "id" "fix-result"] [E.text (resultWords passed)]
        , E.ul
            [attr "id" "fix-runs"]
            [ E.li [] [E.code [] [E.text (T.unwords (checkCommand r))], E.text (": " <> outcomeWords (checkOutcome r) (checkExit r))]
            | r <- evidenceRuns ev
            ]
        , E.details
            []
            ( E.summary [] [E.text "What the checks printed"]
                : [E.p [] [E.code [] [E.text (T.unwords (checkCommand r) <> "\n" <> checkStdout r <> checkStderr r)]] | r <- evidenceRuns ev]
            )
        ]
  resultWords passed
    | not passed = "Not every check passed on the latest change."
    | state `L.elem` [Just StateAccepted, Just StateDone] = "Every check passed on the committed change."
    | otherwise = "Every check passed on the latest change."
  findings =
    case evidenceFindings ev of
      []
        | L.elem stage (fmap Just [StageBasis, StageDiscovery, StageReproduction, StageCandidate, StageChallengePre]) && L.elem state [Just StateRunning, Just StateHalted] ->
            [E.p [cls "ls-muted"] [E.text "Not challenged yet."]]
        | otherwise -> [E.p [] [E.text "Nothing was found."]]
      fs ->
        [ E.ul
            [attr "id" "fix-findings"]
            [E.li [] [E.text (findingTimeWords (findingWhen f) <> findingClaimText f <> " \8212 " <> dispositionWords (findingDisposition f))] | f <- fs]
        ]
  review =
    case evidenceReview ev of
      Nothing -> [E.p [cls "ls-muted"] [E.text "Not reviewed yet."]]
      Just r ->
        [ E.p [attr "id" "fix-review"] [E.text (verdictWords (reviewVerdict r))]
        , E.ul [] [E.li [] [E.text reason] | reason <- reviewReasons r]
        ]
  notKnown =
    [ E.p [cls "ls-notice", attr "id" "fix-uncertain"] [E.text "Lockstep could not tell whether one of its helpers finished its work. It will not run that helper again by itself."]
    | L.any (isJust . invocationOutcome) (evidenceUncertain ev)
    ]
      <> [ E.p [cls "ls-notice", attr "id" "fix-unreadable"] [E.text "Some of what Lockstep recorded about this fix could not be read back, so it is not shown here."]
         | not (L.null (evidenceUnreadable ev))
         ]
  technical =
    E.details
      []
      [ E.summary [] [E.text "Technical details"]
      , E.dl
          [cls "ls-facts"]
          ( fact "Transaction" (viewId tx)
              <> fact "Work order" (viewWorkOrder tx)
              <> fact "State" (viewState tx <> " at " <> viewStage tx <> maybe "" (" " <>) (viewHalt tx))
              <> fact "Effective profile digest" (admissionEffectiveDigest a)
              <> fact "Basis commit" (fromMaybe "none" (viewBasis tx))
              <> fact "Work branch" (fromMaybe "none" (viewBranch tx))
              <> fact "Implementation attempts" (T.pack (show (viewAttempts tx)))
              <> fact "Candidates" (T.pack (show (viewCandidates tx)))
              <> fact "Verified commit" (maybe "none" fst (evidencePassed ev))
              <> fact "Reviewed commit" (maybe "none" reviewCommit (evidenceReview ev))
              <> fact "Unreadable records" (if L.null (evidenceUnreadable ev) then "none" else T.unwords (fmap (T.pack . show) (evidenceUnreadable ev)))
              <> L.concat [fact ("Run " <> invocationWhat i) (invocationStage i <> " " <> fromMaybe "unfinished" (invocationOutcome i) <> " " <> identityText (invocationId i)) | i <- viewInvocations tx]
          )
      ]

-- | What a step is doing, in plain words; a stage this page could not read is said to be unknown.
stepWords :: Maybe Stage -> T.Text
stepWords stage =
  case stage of
    Just StageBasis -> "looking at the project's files"
    Just StageDiscovery -> "finding the cause"
    Just StageReproduction -> "reproducing the bug"
    Just StageCandidate -> "writing tests that show the bug"
    Just StageChallengePre -> "checking those tests"
    Just StageFreeze -> "fixing the tests in place"
    Just StageImplement -> "changing the code"
    Just StageVerify -> "running the checks"
    Just StageChallengePost -> "challenging the change"
    Just StageReview -> "having the change reviewed"
    Just StageAccept -> "committing the fix"
    Nothing -> "at a step this page does not know"

haltWords :: HaltCode -> T.Text
haltWords code =
  case code of
    HaltRoleFailed c
      | c == noCodingAgent -> "No coding helper is set up for Lockstep."
      | otherwise -> "One of Lockstep's helpers failed."
    HaltUncertainInvocation _ -> "Lockstep could not tell whether one of its helpers finished. It will not run it again by itself."
    HaltSupervisorFailed _ -> couldNotFinish
    HaltFixed fixed ->
      case fixed of
        FixedRepositoryDirty -> "The project's folder has changes that are not committed. Commit or remove them, then try again."
        FixedRepositoryMissing -> "The project's folder is not there any more."
        FixedNotARepository -> "The project's folder is not a Git folder."
        FixedReproductionMissing -> "Lockstep could not make the bug happen. You can go on without reproducing it, try again, or stop."
        FixedVerificationEnvironmentMissing -> "A program the checks need is not installed where the checks run."
        FixedVerificationRunFailed -> "The checks did not finish normally."
        FixedProtectedTestChanged -> "A test that was fixed in place was changed."
        FixedBaselineRunFailed -> couldNotFinish
        FixedCandidatesExhausted -> couldNotFinish
        FixedGreenRegressionFailed -> couldNotFinish
        FixedFindingNeedsHuman -> couldNotFinish
        FixedAttemptsExhausted -> couldNotFinish
        FixedReviewNeedsHuman -> couldNotFinish
        FixedStoppedByPerson -> couldNotFinish
        FixedNotAcceptedByPerson -> couldNotFinish
    -- Any other refusal: its exact code is under Technical details.
    HaltRefused _ -> couldNotFinish
 where
  couldNotFinish = "Lockstep could not finish this step. The exact reason is under Technical details."

stoppedWords :: HaltCode -> T.Text
stoppedWords code =
  case code of
    HaltFixed FixedNotAcceptedByPerson -> "you said it is not fixed."
    HaltFixed FixedStoppedByPerson -> "you stopped it."
    -- A stop from a halt keeps the halt's code (the Kernel's 'Stopped' after 'Halted').
    _ -> "you stopped it when it could not go on. " <> haltWords code

findingTimeWords :: FindingTime -> T.Text
findingTimeWords time =
  case time of
    BeforeChange -> "Before the change: "
    AfterChange -> "After the change: "

choiceWords :: T.Text -> T.Text
choiceWords name =
  case T.unpack name of
    "retry" -> "Try this step again"
    "stop" -> "Stop fixing this bug"
    "accept-non-reproduction" -> "Go on without reproducing it"
    _ -> name

outcomeWords :: OutcomeKind -> Maybe Integer -> T.Text
outcomeWords outcome exit =
  case (outcome, exit) of
    (KindExited, Just 0) -> "passed"
    (KindExited, Just n) -> "failed (exit status " <> T.pack (show n) <> ")"
    (KindExited, Nothing) -> "finished; whether it passed was not recorded"
    (KindTimedOut, _) -> "did not finish in time"
    (KindOutputLimit, _) -> notNormally
    (KindOutputHeld, _) -> notNormally
    (KindCancelled, _) -> notNormally
    (KindLaunchFailed, _) -> notNormally
    (KindProviderStopped, _) -> notNormally
 where
  notNormally = "did not finish normally"

dispositionWords :: Disposition -> T.Text
dispositionWords disposition =
  case disposition of
    Confirmed -> "confirmed; it had to be dealt with"
    Disproved -> "shown not to hold"
    NeedsHumanFinding -> "needs a person to look at it"
    Inconclusive -> "not confirmed"

verdictWords :: Verdict -> T.Text
verdictWords verdict =
  case verdict of
    Approve -> "The reviewer approved the change."
    Reject -> "The reviewer rejected the change."
    NeedsHuman -> "The reviewer asked for a person to look at the change."
