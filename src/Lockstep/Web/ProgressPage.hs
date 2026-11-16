{-# LANGUAGE OverloadedStrings #-}

{- | The project's Progress page (contract C-P6.2 C2, C4, C5, C7): a read-only
fragment rendered from a 'ProgressView'. Plain words (FR-UX-06); the typed
standing appears only as each row's @data-standing@ code. Technical acceptance
is never called Done, and nothing is called published. C-P6.8: with the
project's evidence-linked summary, what happened and the evidence for it, and
the tokens helpers reported.
-}
module Lockstep.Web.ProgressPage
  ( progressPage
  , progressPageWith
  ) where

import Brigid.HTML.Attributes qualified as A
import Brigid.HTML.Elements qualified as E
import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (show)

import Lockstep.Application.Progress (Placement (..), ProgressRow (..), ProgressView (..), WhereItRuns (..))
import Lockstep.Application.Summary (InterventionItem (..), ProjectSummary (..), SummaryItem (..))
import Lockstep.Kernel.Identity (TaskId (..), parseIdentity)
import Lockstep.Kernel.Progress (Publication (..), Standing (..), standingCode)
import Lockstep.Kernel.Summary (Evidence (..), Usage (..), UsageStanding (..), categoryCode, checksCode, interventionCode, reviewOutcomeCode, usageKnown, usageStandingCode)
import Lockstep.Kernel.Transaction (haltCodeFromText)
import Lockstep.Web.ExecutionPages (haltWords, stepWords, stoppedWords)
import Lockstep.Web.Fragment (attr, cls, elementId, fragment)
import Lockstep.Web.Routes.App (progressLink, projectLink, taskLink)

progressPage :: ProgressView -> LBS.ByteString
progressPage view =
  progressPageWith view Nothing

-- | C-P6.8: the page with the project's evidence-linked summary.
progressPageWith :: ProgressView -> Maybe ProjectSummary -> LBS.ByteString
progressPageWith view summary =
  fragment $
    [ E.h1 [] [E.text ("Progress: " <> progressName view)]
    , E.p [] [E.text "Where every task of this project stands now, read from Lockstep's own records each time this page is shown."]
    , E.h2 [] [E.text "The plan"]
    , E.p [A.id (elementId 'n' "o-plan")] [E.text "No approved plan: work comes from tasks you mark ready and hand over. Approved plans arrive in a later update of Lockstep."]
    , E.h2 [] [E.text "Summary"]
    , E.ul [cls "ls-summary"] [E.li [] [E.text (T.pack (show n) <> " " <> label)] | (label, n) <- counts, n > 0]
    , E.p [A.id (elementId 'n' "ext-to-hand-over")] ([E.text "Next to hand over: ", nextWords] <> notAllowed)
    , E.section
        [A.id (elementId 'w' "aiting-for-you")]
        ( [E.h2 [] [E.text "Waiting for you"]]
            <> case waiting of
              [] -> [E.p [] [E.text "Nothing is waiting for your answer."]]
              _ -> [E.ul [] [E.li [] [E.a [A.href (taskLink (rowTask r))] [E.text (rowTitle r)], E.text (" \8212 " <> standingWords (rowStanding r))] | r <- waiting]]
        )
    , -- R-P6.2: an accepted fix waits for the person's Done (or not), so it is listed too, apart from the questions.
      E.section
        [A.id (elementId 'w' "aiting-for-your-done")]
        ( [E.h2 [] [E.text "Checked and committed, waiting for your Done"]]
            <> case verified of
              [] -> [E.p [] [E.text "No fix is waiting for you to say whether it is done."]]
              _ -> [E.ul [] [E.li [] [E.a [A.href (taskLink (rowTask r))] [E.text (rowTitle r)], E.text (" \8212 " <> standingWords (rowStanding r))] | r <- verified]]
        )
    , E.h2 [] [E.text "Every task"]
    , if L.null (progressRows view)
        then E.p [] [E.text "This project has no tasks yet."]
        else
          E.table
            [cls "ls-progress"]
            [ E.thead [] [E.tr [] [E.th [attr "scope" "col"] [E.text h] | h <- ["Task", "Came from", "Where it stands", "Published"]]]
            , E.tbody [] (fmap row (progressRows view))
            ]
    ]
      <> maybe [] evidenceSection summary
      <> [E.h2 [] [E.text "Who works on it, and where"]]
      <> whereWords (progressWhere view)
      <> [ E.h2 [] [E.text "Usage"]
         , usageWords
         , usageStandingWords
         , E.p [cls "ls-muted"] [E.text "Running capsules and their resources are shown on the project's page; this page does not count a stopped capsule as using anything."]
         , E.p [] [E.text "Nothing is published: Lockstep commits only on each fix's own work branch on this computer, and Lockstep never pushes."]
         , E.p [] [E.a [A.href (projectLink (progressProject view))] [E.text ("Back to " <> progressName view)]]
         ]
 where
  -- Update 2 R6.5: what the usage evidence establishes, so a partial total is never read as complete.
  usageStandingWords =
    case summary of
      Nothing -> E.p [] []
      Just s ->
        E.p
          [A.id (elementId 'u' "sage-standing"), attr "data-usage" (usageStandingCode (summaryUsageStanding s))]
          [ E.text $
              case summaryUsageStanding s of
                NoProviderInvocation -> "Usage: no helper has run for this project, so there is no usage to show (not zero)."
                UsageComplete _ -> "Usage is complete: every helper run reported every token class, and Lockstep kept its whole output."
                UsagePartial _ -> "Usage is partial: some runs reported nothing, left a class out, or were kept only in part, so the numbers above are what is known, not totals."
                UsageUnavailable -> "Usage is unavailable: helpers ran, and none reported its tokens."
          ]
  -- C-P6.8 E5: the tokens helpers reported, per class; never a cost.
  usageWords =
    case summary of
      Just s
        | usageKnown (summaryUsage s) ->
            E.p
              [A.id (elementId 'u' "sage")]
              [ E.text
                  ( "Tokens the helpers reported: "
                      <> T.intercalate
                        ", "
                        [ label <> " " <> maybe "not reported" (T.pack . show) n
                        | (label, n) <-
                            [ ("input", usageInput (summaryUsage s))
                            , ("output", usageOutput (summaryUsage s))
                            , ("cache written", usageCacheCreation (summaryUsage s))
                            , ("cache read", usageCacheRead (summaryUsage s))
                            ]
                        ]
                      <> ". "
                      <> T.pack (show (summaryRunsUnknown s))
                      <> " of "
                      <> T.pack (show (summaryRuns s))
                      <> " role runs reported nothing, so these totals leave them out. Lockstep shows no money: these are subscription tokens."
                  )
              ]
      -- R-P6.8-11: role runs counted, none of which reported its tokens.
      Just s
        | summaryRuns s > 0 ->
            E.p [A.id (elementId 'u' "sage")] [E.text ("Model usage: not reported. None of the " <> T.pack (show (summaryRuns s)) <> " role runs reported the tokens it used, so no figure is shown, and none is guessed.")]
      _ -> E.p [] [E.text "Model usage: not recorded. Lockstep does not yet record the tokens its helpers use for each project, so no figure is shown."]
  -- C-P6.8: what happened, task by task, from the records, with the evidence each line rests on.
  evidenceSection s =
    [ E.section
        [A.id (elementId 'e' "vidence")]
        ( [ E.h2 [] [E.text "What happened, with its evidence"]
          , E.p [] [E.text "Each line is chosen from Lockstep's own records by fixed rules, never from what a helper said. A check that never ran is not a pass; a review that did not finish is not an approval."]
          , E.ul
              []
              [ E.li
                  [attr "data-category" (categoryCode (summaryCategory i))]
                  ( [ E.a [A.href (taskLinkText (summaryTask i))] [E.text (summaryTitle i)]
                    , E.text
                        ( " \8212 "
                            <> categoryCode (summaryCategory i)
                            <> "; checks "
                            <> checksCode (summaryChecks i)
                            <> "; review "
                            <> reviewOutcomeCode (summaryReview i)
                            <> "; "
                            <> (if summaryPublication i == "local" then "committed on this computer only" else "no commit")
                            <> ". Evidence: "
                        )
                    ]
                      <> L.intersperse (E.text ", ") [E.code [] [E.text (evidenceText i e)] | e <- summaryEvidence i]
                      <> [E.text (if L.null (summaryEvidence i) then "none recorded." else ".")]
                  )
              | i <- summaryItems s
              ]
          , E.h3 [] [E.text "Decisions waiting for you"]
          ]
            <> case summaryPending s of
              [] -> [E.p [] [E.text "None."]]
              ps -> [E.ul [A.id (elementId 'p' "ending")] [E.li [] [E.text (title <> ": "), E.code [] [E.text (plainEvidence e)]] | (title, e) <- ps]]
            <> [E.h3 [] [E.text "Your interventions"]]
            <> case summaryInterventions s of
              [] -> [E.p [] [E.text "None recorded."]]
              xs -> [E.ul [] [E.li [attr "data-intervention" (interventionCode (interventionKind x))] [E.text (interventionTask x <> ": " <> interventionWhat x <> " (" <> interventionCode (interventionKind x) <> "), "), E.code [] [E.text (plainEvidence (interventionEvidence x))]] | x <- xs]]
            <> [ E.p
                   [cls "ls-muted"]
                   [E.text ("Made for the plan revision " <> fromMaybe "none (no approved plan)" (summaryRevision s) <> ", from the records as they are now.")]
               ]
        )
    ]
  taskLinkText t =
    maybe (progressLink (progressProject view)) taskLink (parseIdentity t)
  -- R-P6.8-12: each record says what it is.
  evidenceText i e =
    case e of
      OfRecord t n
        | Just n == summaryChecksRecord i -> "verification record " <> T.pack (show n) <> " of fix " <> t
        | Just n == summaryReviewRecord i -> "review record " <> T.pack (show n) <> " of fix " <> t
        | Just n == summaryHaltRecord i -> "halt record " <> T.pack (show n) <> " of fix " <> t
      _ -> plainEvidence e
  plainEvidence e =
    case e of
      OfFix t -> "fix " <> t
      OfRecord t n -> "record " <> T.pack (show n) <> " of fix " <> t
      OfCommit c -> "commit " <> c
      OfInvalidation t -> "invalidation of fix " <> t
      OfRequest r -> "request " <> r
  waiting = [r | r <- progressRows view, isWaitingForYou (rowStanding r)]
  verified = [r | r <- progressRows view, standingCode (rowStanding r) == "technically-verified"]
  notAllowed =
    case progressWhere view of
      RunsNowhere _ -> [E.text " (Lockstep may not work in this project yet, so a hand-over would be refused; see below.)"]
      RunsWith _ -> []
  nextWords =
    case progressNext view >>= \t -> L.find ((== t) . rowTask) (progressRows view) of
      Just r -> E.a [A.href (taskLink (rowTask r))] [E.text (rowTitle r)]
      Nothing -> E.text "nothing is ready to hand over."
  counts =
    [ (label, L.length (L.filter ((== code) . standingCode . rowStanding) (progressRows view)))
    | (code, label) <- summaryLabels
    ]
  row r =
    E.tr
      [attr "data-standing" (standingCode (rowStanding r))]
      [ E.td [] [E.a [A.href (taskLink (rowTask r))] [E.text (rowTitle r)]]
      , E.td [] [E.text (fromMaybe "Lockstep" (rowSource r))]
      , E.td [] [E.text (standingWords (rowStanding r))]
      , E.td [] [E.text (publicationWords (rowPublication r))]
      ]

isWaitingForYou :: Standing -> Bool
isWaitingForYou standing =
  case standing of
    StandingWaitingForYou _ _ -> True
    _ -> False

summaryLabels :: [(T.Text, T.Text)]
summaryLabels =
  [ ("active", "being worked on")
  , ("waiting-for-you", "waiting for you")
  , ("queued", "handed over, not started yet")
  , ("ready", "ready to hand over")
  , ("waiting", "waiting for other tasks")
  , ("blocked", "blocked")
  , ("cannot-start", "cannot start")
  , ("proposed", "not yet ready")
  , ("technically-verified", "checked and committed, not Done")
  , ("human-done", "Done")
  , ("stopped", "stopped")
  , ("canceled", "canceled")
  , ("unknown", "unknown")
  ]

-- | C2, C5: one sentence per standing.
standingWords :: Standing -> T.Text
standingWords standing =
  case standing of
    StandingProposed -> "Not yet ready: mark it ready when it is."
    StandingReady -> "Ready: you can hand it over."
    StandingWaiting titles -> "Waiting for: " <> T.intercalate ", " titles <> "."
    StandingBlocked reason -> "Blocked: " <> (if T.null reason then "no reason was given." else reason)
    StandingCannotStart titles -> "Cannot start: a task it needs was canceled (" <> T.intercalate ", " titles <> ")."
    StandingQueued -> "Handed over; Lockstep has not started it yet."
    StandingActive stage -> "Being worked on: " <> stepWords (Just stage) <> "."
    StandingWaitingForYou stage code -> "Stopped while " <> stepWords (Just stage) <> " and needs your answer: " <> haltWords (haltCodeFromText code)
    StandingTechnicallyVerified commit ->
      "Checked and committed on its own work branch"
        <> maybe "" (\c -> " (commit " <> T.take 12 c <> ")") commit
        <> ". Not Done: you decide that on the task's page."
    StandingHumanDone -> "Done: you accepted it."
    StandingStopped code -> "Stopped: " <> stoppedWords (haltCodeFromText code) <> " Nothing more runs."
    StandingCanceled -> "Canceled."
    StandingUnknown name -> "Lockstep cannot tell where this stands: it recorded a state it does not recognise (" <> name <> ")."

publicationWords :: Publication -> T.Text
publicationWords publication =
  case publication of
    NotPublished -> "Not published"

whereWords :: WhereItRuns -> [E.ChildHTML E.Division E.Body]
whereWords w =
  case w of
    RunsNowhere reason -> [E.p [] [E.text reason]]
    RunsWith p ->
      [ E.dl
          [cls "ls-facts"]
          [ E.dt [] [E.text "Engineer"]
          , E.dd [] [E.code [] [E.text (placementEngineer p)]]
          , E.dt [] [E.text "Folder"]
          , E.dd [] [E.code [] [E.text (placementFolder p)]]
          , E.dt [] [E.text "Checks"]
          , E.dd [] [E.code [] [E.text (placementChecks p <> " version " <> T.pack (show (placementChecksVersion p)) <> " (" <> T.take 12 (placementChecksDigest p) <> ")")]]
          ]
      ]
