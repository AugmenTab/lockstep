{-# LANGUAGE OverloadedStrings #-}

{- | The task pages (contract C-P3.6 K6, K7): the new-task form, one task's page
with its edit form and the actions its state allows, a project's task list, and
the Tasks overview. No Ticket, Work Order, Engineer or scheduler word on the
ordinary path; the exact ids, states and revisions are under Technical details.
-}
module Lockstep.Web.TaskPages
  ( TaskForm (..)
  , emptyTaskForm
  , TaskAction (..)
  , taskActionCode
  , newTaskPage
  , taskPage
  , projectTasks
  , tasksOverview
  ) where

import Brigid.HTML.Attributes qualified as A
import Brigid.HTML.Elements qualified as E
import Brigid.HTML.Types qualified as HTML
import Brigid.Types qualified as B
import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (show)

import Lockstep.Application.Projects (ProjectView (..))
import Lockstep.Application.Tasks (TaskView (..), mostImportantReadyTask)
import Lockstep.Kernel.Task (Priority (..), TaskReadiness (..), TaskState (..), parseTaskState, priorityCode, priorityOf, priorityWords, readinessWords)
import Lockstep.Web.Fields (acceptanceField, actionField, dependsOnField, keyField, priorityField, reasonField, revisionField, ticketRevisionField, titleField)
import Lockstep.Web.Fragment (attr, cls, elementId, fragment)
import Lockstep.Web.Routes.App (Section (Projects), createTaskAction, decideTaskAction, editTaskAction, newTaskLink, projectLink, sectionLink, taskLink)

-- | What a task's state lets a person do (C-P3.6 K7), spelled as the form's @action@ value.
data TaskAction
  = ActionReady
  | ActionBlock
  | ActionUnblock
  | ActionCancel
  deriving (Eq, Enum, Bounded)

taskActionCode :: TaskAction -> T.Text
taskActionCode action =
  case action of
    ActionReady -> "ready"
    ActionBlock -> "block"
    ActionUnblock -> "unblock"
    ActionCancel -> "cancel"

backToProject :: ProjectView -> E.ChildHTML E.Division E.Body
backToProject project =
  E.p [] [E.a [A.href (projectLink (projectKey project)), A.id (elementId 'b' "ack-to-project")] [E.text ("Back to " <> projectName project)]]

-- | What a task form shows: the values typed (or stored) and the creation key.
data TaskForm
  = TaskForm
  { formTaskKey :: T.Text
  , formTaskTitle :: T.Text
  , formTaskAcceptance :: T.Text
  , formTaskPriority :: T.Text
  , formTaskDependencies :: [T.Text]
  }

emptyTaskForm :: T.Text -> TaskForm
emptyTaskForm key =
  TaskForm key "" "" "normal" []

notices :: Maybe T.Text -> [E.ChildHTML E.Division E.Body]
notices notice =
  [E.p [cls "ls-notice", attr "role" "alert"] [E.text n] | Just n <- [notice]]

priorityChoices :: T.Text -> E.ChildHTML E.Form E.Division
priorityChoices selected =
  E.fieldset
    []
    ( E.legend [] [E.text "How much does it matter?"]
        : [ E.div
              [cls "ls-choice"]
              [ E.input
                  ( [ A.type_ HTML.InputRadio
                    , A.id choiceId
                    , A.name priorityField
                    , attr "value" (priorityCode p)
                    ]
                      <> [attr "checked" "checked" | priorityCode p == selected]
                  )
              , E.label [A.for choiceId] [E.text (priorityWords p)]
              ]
          | p <- [High, Normal, Low]
          , let
              choiceId = elementId 'p' ("riority-" <> priorityCode p)
          ]
    )

dependencyChoices :: [TaskView] -> [T.Text] -> E.ChildHTML E.Form E.Division
dependencyChoices candidates selected =
  E.fieldset
    []
    ( E.legend [] [E.text "What must be finished first?"]
        : if L.null candidates
          then [E.p [cls "ls-muted"] [E.text "There are no other tasks in this project yet."]]
          else
            [ E.div
                [cls "ls-choice"]
                [ E.input
                    ( [ A.type_ HTML.InputCheckbox
                      , A.id dependencyId
                      , A.name dependsOnField
                      , attr "value" (taskId t)
                      ]
                        <> [attr "checked" "checked" | taskId t `L.elem` selected]
                    )
                , E.label [A.for dependencyId] [E.text (taskTitle t)]
                ]
            | t <- candidates
            , let
                -- A task id is a canonical UUID: nothing in it needs escaping.
                dependencyId = elementId 'd' ("epends-" <> taskId t)
            ]
    )

taskFields :: TaskForm -> [TaskView] -> [E.ChildHTML E.Form E.Division]
taskFields form candidates =
  [ E.div
      [cls "ls-field"]
      [ E.label [A.for titleId] [E.text "What needs doing"]
      , E.input [A.type_ HTML.InputText, A.id titleId, A.name titleField, attr "value" (formTaskTitle form), attr "maxlength" "200", attr "required" "required"]
      ]
  , E.div
      [cls "ls-field"]
      [ E.label [A.for acceptanceId] [E.text "What does done look like?"]
      , E.textarea [A.id acceptanceId, A.name acceptanceField, attr "rows" "4", attr "maxlength" "4000"] (formTaskAcceptance form)
      ]
  , priorityChoices (formTaskPriority form)
  , dependencyChoices candidates (formTaskDependencies form)
  ]
 where
  titleId = elementId 't' "ask-title"
  acceptanceId = elementId 't' "ask-acceptance"

newTaskPage :: ProjectView -> [TaskView] -> TaskForm -> Maybe T.Text -> LBS.ByteString
newTaskPage project others form notice =
  fragment $
    [ E.h1 [] [E.text "New task"]
    , E.p [cls "ls-muted"] [E.text ("In the project " <> projectName project)]
    ]
      <> notices notice
      <> [ E.form
             [A.id (elementId 't' "ask-form"), A.method B.FormPOST, A.action (createTaskAction (projectKey project))]
             ( [E.input [A.type_ HTML.InputHidden, A.name keyField, attr "value" (formTaskKey form)]]
                 <> taskFields form others
                 <> [E.button [A.id (elementId 'c' "reate-task"), attr "type" "submit", cls "ls-primary"] [E.text "Add task"]]
             )
         , backToProject project
         ]

-- | The forms for the actions the task's state allows.
actions :: TaskView -> [E.ChildHTML E.Division E.Division]
actions task =
  let
    decide extra label buttonId =
      E.form
        [A.method B.FormPOST, A.action (decideTaskAction (taskKey task)), cls "ls-inline-form"]
        ( [E.input [A.type_ HTML.InputHidden, A.name ticketRevisionField, attr "value" (T.pack (show (taskTicketRevision task)))]]
            <> extra
            <> [E.button [A.id buttonId, attr "type" "submit"] [E.text label]]
        )
    action value = E.input [A.type_ HTML.InputHidden, A.name actionField, attr "value" (taskActionCode value)]
    reasonId = elementId 'b' "lock-reason"
    ready = decide [action ActionReady] "Mark as ready to work on" (elementId 't' "ask-ready")
    block =
      decide
        [ action ActionBlock
        , E.label [A.for reasonId, cls "ls-label"] [E.text "Why is it blocked?"]
        , E.input [A.type_ HTML.InputText, A.id reasonId, A.name reasonField, attr "maxlength" "200"]
        ]
        "Block…"
        (elementId 't' "ask-block")
    unblock = decide [action ActionUnblock] "Unblock" (elementId 't' "ask-unblock")
    cancel = decide [action ActionCancel] "Cancel task…" (elementId 't' "ask-cancel")
  in
    -- The view carries the state's name; it is read once here. A name no state has offers nothing.
    case parseTaskState (taskState task) of
      Just TaskProposed -> [ready, block, cancel]
      Just TaskBlocked -> [unblock, cancel]
      Just TaskCanceledState -> []
      Just TaskDone -> []
      Just TaskReady -> [block, cancel]
      Just TaskInProgress -> [block, cancel]
      Just TaskCodeComplete -> [block, cancel]
      Just TaskAwaitingReview -> [block, cancel]
      Just TaskReadyForSignoff -> [block, cancel]
      Nothing -> []

{- | One task's page; @fixing@ is the C-P4.1 Fixing it section (empty when the
project does not allow it); @underWay@: Lockstep has started on it (C-P4.16).
-}
taskPage :: ProjectView -> [TaskView] -> TaskView -> Bool -> [E.ChildHTML E.Division E.Body] -> Maybe T.Text -> LBS.ByteString
taskPage project siblings task underWay fixing notice =
  let
    others = [t | t <- siblings, taskId t /= taskId task]
    priority = priorityOf (taskPriority task)
    editable = parseTaskState (taskState task) `L.notElem` [Nothing, Just TaskCanceledState, Just TaskDone]
    form = TaskForm "" (taskTitle task) (taskAcceptance task) (priorityCode priority) (taskDependencies task)
  in
    fragment $
      [ E.h1 [] [E.text (taskTitle task)]
      , E.p [cls "ls-muted"] [E.text ("In the project " <> projectName project <> " \8212 Priority: " <> priorityWords priority)]
      ]
        <> notices notice
        <> [E.p [cls (readinessClass (taskReadinessOf task))] [E.text (readinessWords (taskReadinessOf task))]]
        <> [E.p [cls "ls-muted"] [E.text "Lockstep keeps track of this task. Nothing runs it yet; that arrives in a later update of Lockstep."] | not underWay]
        <> fixing
        <> [ E.h2 [] [E.text "What done looks like"]
           , if T.null (taskAcceptance task)
               then E.p [cls "ls-muted"] [E.text "Not written down yet."]
               else E.p [cls "ls-outcome"] [E.text (taskAcceptance task)]
           ]
        <> (if L.null (actions task) then [] else [E.h2 [] [E.text "What you can do"], E.div [cls "ls-task-actions"] (actions task)])
        <> ( if editable
               then
                 [ E.h2 [] [E.text "Change it"]
                 , E.form
                     [A.id (elementId 'e' "dit-task"), A.method B.FormPOST, A.action (editTaskAction (taskKey task))]
                     ( [E.input [A.type_ HTML.InputHidden, A.name revisionField, attr "value" (T.pack (show (taskRevision task)))]]
                         <> taskFields form others
                         <> [E.button [A.id (elementId 's' "ave-task"), attr "type" "submit"] [E.text "Save changes"]]
                     )
                 ]
               else []
           )
        <> [ E.details
               []
               [ E.summary [] [E.text "Technical details"]
               , E.dl
                   [cls "ls-facts"]
                   [ E.dt [] [E.text "Task"]
                   , E.dd [] [E.code [] [E.text (taskId task)]]
                   , E.dt [] [E.text "State"]
                   , E.dd [] [E.code [] [E.text (taskState task)]]
                   , E.dt [] [E.text "Revisions"]
                   , E.dd [] [E.code [] [E.text ("task " <> T.pack (show (taskRevision task)) <> ", record " <> T.pack (show (taskTicketRevision task)))]]
                   , E.dt [] [E.text "Priority value"]
                   , E.dd [] [E.code [] [E.text (T.pack (show (taskPriority task)))]]
                   ]
               ]
           , backToProject project
           ]

readinessClass :: TaskReadiness -> T.Text
readinessClass readiness =
  case readiness of
    ReadyToWork -> "ls-good-text"
    BlockedBecause _ -> "ls-notice"
    CannotStart _ -> "ls-notice"
    StateUnrecognised _ -> "ls-notice"
    NotYetReady -> "ls-state-line"
    WaitingFor _ -> "ls-state-line"
    Finished -> "ls-state-line"
    TaskCanceled -> "ls-state-line"
    BeingWorkedOn -> "ls-state-line"

-- | The project page's task section.
projectTasks :: ProjectView -> [TaskView] -> [E.ChildHTML E.Division E.Body]
projectTasks project tasks =
  [ E.h2 [] [E.text "Tasks"]
  , E.p [] [E.a [A.href (newTaskLink (projectKey project)), A.id (elementId 'n' "ew-task"), cls "ls-button-link"] [E.text "New task"]]
  ]
    <> [ E.ul
           [cls "ls-projects"]
           [ E.li
               []
               [ E.a [A.href (taskLink (taskKey t))] [E.text (taskTitle t)]
               , E.text (" \8212 " <> priorityWords (priorityOf (taskPriority t)) <> " \8212 " <> readinessWords (taskReadinessOf t))
               ]
           | t <- tasks
           ]
       | not (L.null tasks)
       ]
    <> case mostImportantReadyTask tasks of
      Just t -> [E.p [cls "ls-good-text"] [E.text ("Most important task ready to work on: " <> taskTitle t)]]
      Nothing -> [E.p [cls "ls-muted"] [E.text (if L.null tasks then "No tasks yet." else "No task is ready to work on right now.")]]

tasksOverview :: [(ProjectView, [TaskView])] -> Bool -> LBS.ByteString
tasksOverview groups ready =
  fragment $
    [ E.h1 [] [E.text "Tasks"]
    , E.p [] [E.text "Tasks are added on a project's page. Here are all of them, most important first in each project."]
    ]
      <> ( if not ready
             then [E.p [cls "ls-notice"] [E.text "Lockstep's database is not ready, so the tasks cannot be shown. Run lockstep to see what to do."]]
             else
               if L.all (L.null . snd) groups
                 then [E.p [] [E.text "There are no tasks yet. Open a project to add one: ", E.a [A.href (sectionLink Projects)] [E.text "Projects"], E.text "."]]
                 else
                   L.concat
                     [ [ E.h2 [] [E.text (projectName p)]
                       , E.p [] [E.a [A.href (projectLink (projectKey p))] [E.text ("Open " <> projectName p)]]
                       , E.ul
                           [cls "ls-projects"]
                           [ E.li [] [E.a [A.href (taskLink (taskKey t))] [E.text (taskTitle t)], E.text (" \8212 " <> readinessWords (taskReadinessOf t))]
                           | t <- ts
                           ]
                       ]
                     | (p, ts) <- groups
                     , not (L.null ts)
                     ]
         )
      <> [E.p [cls "ls-muted"] [E.text "Running the work in a task arrives in a later update of Lockstep."]]
