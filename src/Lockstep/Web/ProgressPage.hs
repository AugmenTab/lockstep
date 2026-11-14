{-# LANGUAGE OverloadedStrings #-}

{- | The project's Progress page (contract C-P6.2 C2, C4, C5, C7): a read-only
fragment rendered from a 'ProgressView'. Plain words (FR-UX-06); the typed
standing appears only as each row's @data-standing@ code. Technical acceptance
is never called Done, and nothing is called published.
-}
module Lockstep.Web.ProgressPage
  ( progressPage
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
import Lockstep.Kernel.Progress (Publication (..), Standing (..), standingCode)
import Lockstep.Web.ExecutionPages (stepWords)
import Lockstep.Web.Fragment (attr, cls, elementId, fragment)
import Lockstep.Web.Routes.App (projectLink, taskLink)

progressPage :: ProgressView -> LBS.ByteString
progressPage view =
  fragment $
    [ E.h1 [] [E.text ("Progress: " <> progressName view)]
    , E.p [] [E.text "Where every task of this project stands now, read from Lockstep's own records each time this page is shown."]
    , E.h2 [] [E.text "The plan"]
    , E.p [A.id (elementId 'n' "o-plan")] [E.text "No approved plan: work comes from tasks you mark ready and hand over. Approved plans arrive in a later update of Lockstep."]
    , E.h2 [] [E.text "Summary"]
    , E.ul [cls "ls-summary"] [E.li [] [E.text (T.pack (show n) <> " " <> label)] | (label, n) <- counts, n > 0]
    , E.p [A.id (elementId 'n' "ext-to-hand-over")] [E.text "Next to hand over: ", nextWords]
    , E.section
        [A.id (elementId 'w' "aiting-for-you")]
        ( [E.h2 [] [E.text "Waiting for you"]]
            <> case waiting of
              [] -> [E.p [] [E.text "Nothing is waiting for your answer."]]
              _ -> [E.ul [] [E.li [] [E.a [A.href (taskLink (rowTask r))] [E.text (rowTitle r)], E.text (" \8212 " <> standingWords (rowStanding r))] | r <- waiting]]
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
    , E.h2 [] [E.text "Who works on it, and where"]
    ]
      <> whereWords (progressWhere view)
      <> [ E.h2 [] [E.text "Usage"]
         , E.p [] [E.text "Model usage: not recorded. Lockstep does not yet record the tokens its helpers use for each project, so no figure is shown."]
         , E.p [cls "ls-muted"] [E.text "Running capsules and their resources are shown on the project's page; this page does not count a stopped capsule as using anything."]
         , E.p [] [E.text "Nothing is published: Lockstep commits only on each fix's own work branch on this computer, and Lockstep never pushes."]
         , E.p [] [E.a [A.href (projectLink (progressProject view))] [E.text ("Back to " <> progressName view)]]
         ]
 where
  waiting = [r | r <- progressRows view, isWaitingForYou (rowStanding r)]
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
    StandingWaitingForYou stage code -> "Stopped while " <> stepWords (Just stage) <> " and needs your answer (" <> code <> ")."
    StandingTechnicallyVerified commit ->
      "Checked and committed on its own work branch"
        <> maybe "" (\c -> " (commit " <> T.take 12 c <> ")") commit
        <> ". Not Done: you decide that on the task's page."
    StandingHumanDone -> "Done: you accepted it."
    StandingStopped code -> "Stopped (" <> code <> "); nothing more runs."
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
