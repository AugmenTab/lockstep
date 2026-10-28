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
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (show)

import Lockstep.Application.Execution (Admission (..), Enablement (..), ExecutionStatus (..))
import Lockstep.Application.ProjectChecks (Standing (..))
import Lockstep.Application.Projects (ProjectView (..))
import Lockstep.Application.Tasks (TaskView (..))
import Lockstep.Kernel.Execution (executionRefusalWords)
import Lockstep.Kernel.Policy (ineligibilityWords)
import Lockstep.Kernel.Task (TaskReadiness (..))
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

-- | The project page's Fixing bugs section, with a fresh key for its form.
projectExecutionSection :: ProjectView -> Maybe ExecutionStatus -> T.Text -> [E.ChildHTML E.Division E.Body]
projectExecutionSection project status key =
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
          , hidden "expected" (fromMaybe "none" current)
          , hidden "expected_set" (maybe "no" (const "yes") current)
          , E.button [attr "id" "enable-execution", attr "type" "submit", cls "ls-primary"] [E.text "Let Lockstep fix bugs here"]
          ]
      ]
    Just (Enabled e) ->
      [ heading "execution" "Fixing bugs"
      , E.p [cls "ls-good-text"] [E.text "Lockstep may work on bugs in this project."]
      , E.p [cls "ls-muted"] [E.text "Nothing has run yet: the steps that do the work arrive in a later update of Lockstep. Hand it a bug from the bug's task page."]
      , E.details
          []
          [ E.summary [] [E.text "Technical details"]
          , E.dl
              [cls "ls-facts"]
              ( fact "Engineer" (enablementEngineer e)
                  <> fact "Repository" (enablementRepository e)
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
taskFixingSection :: TaskView -> Maybe ExecutionStatus -> Maybe Admission -> Maybe Standing -> T.Text -> [E.ChildHTML E.Division E.Body]
taskFixingSection task status admission standing key =
  case (status, admission) of
    (_, Just a) ->
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
    (Just (Enabled _), Nothing)
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
