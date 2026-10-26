{-# LANGUAGE OverloadedStrings #-}

{- | The task pages (contract C-P3.6 K6, K7): the new-task form, one task's page
with its edit form and the actions its state allows, a project's task list, and
the Tasks overview. No Ticket, Work Order, Engineer or scheduler word on the
ordinary path; the exact ids, states and revisions are under Technical details.
-}
module Lockstep.Web.TaskPages
  ( TaskForm (..)
  , emptyTaskForm
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
import Lockstep.Kernel.Task (Priority (..), TaskReadiness (..), priorityCode, priorityOf, priorityWords, readinessWords)
import Lockstep.Web.Fragment (attr, cls, fragment, href)

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
                    , attr "id" ("priority-" <> priorityCode p)
                    , attr "name" "priority"
                    , attr "value" (priorityCode p)
                    ]
                      <> [attr "checked" "checked" | priorityCode p == selected]
                  )
              , E.label [attr "for" ("priority-" <> priorityCode p)] [E.text (priorityWords p)]
              ]
          | p <- [High, Normal, Low]
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
                      , attr "id" ("depends-" <> taskId t)
                      , attr "name" "depends_on"
                      , attr "value" (taskId t)
                      ]
                        <> [attr "checked" "checked" | taskId t `L.elem` selected]
                    )
                , E.label [attr "for" ("depends-" <> taskId t)] [E.text (taskTitle t)]
                ]
            | t <- candidates
            ]
    )

taskFields :: TaskForm -> [TaskView] -> [E.ChildHTML E.Form E.Division]
taskFields form candidates =
  [ E.div
      [cls "ls-field"]
      [ E.label [attr "for" "task-title"] [E.text "What needs doing"]
      , E.input [A.type_ HTML.InputText, attr "id" "task-title", attr "name" "title", attr "value" (formTaskTitle form), attr "maxlength" "200", attr "required" "required"]
      ]
  , E.div
      [cls "ls-field"]
      [ E.label [attr "for" "task-acceptance"] [E.text "What does done look like?"]
      , E.textarea [attr "id" "task-acceptance", attr "name" "acceptance", attr "rows" "4", attr "maxlength" "4000"] (formTaskAcceptance form)
      ]
  , priorityChoices (formTaskPriority form)
  , dependencyChoices candidates (formTaskDependencies form)
  ]

newTaskPage :: ProjectView -> [TaskView] -> TaskForm -> Maybe T.Text -> LBS.ByteString
newTaskPage project others form notice =
  fragment $
    [ E.h1 [] [E.text "New task"]
    , E.p [cls "ls-muted"] [E.text ("In the project " <> projectName project)]
    ]
      <> notices notice
      <> [ E.form
             [attr "id" "task-form", A.method B.FormPOST, A.action (B.mkRawURL ("/app/api/projects/" <> projectId project <> "/tasks"))]
             ( [E.input [A.type_ HTML.InputHidden, attr "name" "key", attr "value" (formTaskKey form)]]
                 <> taskFields form others
                 <> [E.button [attr "id" "create-task", attr "type" "submit", cls "ls-primary"] [E.text "Add task"]]
             )
         , E.p [] [E.a [href ("/app/projects/" <> projectId project), attr "id" "back-to-project"] [E.text ("Back to " <> projectName project)]]
         ]

-- | The forms for the actions the task's state allows.
actions :: TaskView -> [E.ChildHTML E.Division E.Division]
actions task =
  let
    decide extra label buttonId =
      E.form
        [A.method B.FormPOST, A.action (B.mkRawURL ("/app/api/tasks/" <> taskId task <> "/decide")), cls "ls-inline-form"]
        ( [E.input [A.type_ HTML.InputHidden, attr "name" "ticket_revision", attr "value" (T.pack (show (taskTicketRevision task)))]]
            <> extra
            <> [E.button [attr "id" buttonId, attr "type" "submit"] [E.text label]]
        )
    action value = E.input [A.type_ HTML.InputHidden, attr "name" "action", attr "value" value]
    ready = decide [action "ready"] "Mark as ready to work on" "task-ready"
    block =
      decide
        [ action "block"
        , E.label [attr "for" "block-reason", cls "ls-label"] [E.text "Why is it blocked?"]
        , E.input [A.type_ HTML.InputText, attr "id" "block-reason", attr "name" "reason", attr "maxlength" "200"]
        ]
        "Block…"
        "task-block"
    unblock = decide [action "unblock"] "Unblock" "task-unblock"
    cancel = decide [action "cancel"] "Cancel task…" "task-cancel"
  in
    case T.unpack (taskState task) of
      "proposed" -> [ready, block, cancel]
      "blocked" -> [unblock, cancel]
      "canceled" -> []
      "done" -> []
      _ -> [block, cancel]

taskPage :: ProjectView -> [TaskView] -> TaskView -> Maybe T.Text -> LBS.ByteString
taskPage project siblings task notice =
  let
    others = [t | t <- siblings, taskId t /= taskId task]
    priority = priorityOf (taskPriority task)
    editable = taskState task `L.notElem` ["canceled", "done"]
    form = TaskForm "" (taskTitle task) (taskAcceptance task) (priorityCode priority) (taskDependencies task)
  in
    fragment $
      [ E.h1 [] [E.text (taskTitle task)]
      , E.p [cls "ls-muted"] [E.text ("In the project " <> projectName project <> " \8212 Priority: " <> priorityWords priority)]
      ]
        <> notices notice
        <> [ E.p [cls (readinessClass (taskReadinessOf task))] [E.text (readinessWords (taskReadinessOf task))]
           , E.p [cls "ls-muted"] [E.text "Lockstep keeps track of this task. Nothing runs it yet; that arrives in a later update of Lockstep."]
           , E.h2 [] [E.text "What done looks like"]
           , if T.null (taskAcceptance task)
               then E.p [cls "ls-muted"] [E.text "Not written down yet."]
               else E.p [cls "ls-outcome"] [E.text (taskAcceptance task)]
           ]
        <> (if L.null (actions task) then [] else [E.h2 [] [E.text "What you can do"], E.div [cls "ls-task-actions"] (actions task)])
        <> ( if editable
               then
                 [ E.h2 [] [E.text "Change it"]
                 , E.form
                     [attr "id" "edit-task", A.method B.FormPOST, A.action (B.mkRawURL ("/app/api/tasks/" <> taskId task <> "/edit"))]
                     ( [E.input [A.type_ HTML.InputHidden, attr "name" "revision", attr "value" (T.pack (show (taskRevision task)))]]
                         <> taskFields form others
                         <> [E.button [attr "id" "save-task", attr "type" "submit"] [E.text "Save changes"]]
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
           , E.p [] [E.a [href ("/app/projects/" <> projectId project), attr "id" "back-to-project"] [E.text ("Back to " <> projectName project)]]
           ]

readinessClass :: TaskReadiness -> T.Text
readinessClass readiness =
  case readiness of
    ReadyToWork -> "ls-good-text"
    BlockedBecause _ -> "ls-notice"
    CannotStart _ -> "ls-notice"
    _ -> "ls-state-line"

-- | The project page's task section.
projectTasks :: ProjectView -> [TaskView] -> [E.ChildHTML E.Division E.Body]
projectTasks project tasks =
  [ E.h2 [] [E.text "Tasks"]
  , E.p [] [E.a [href ("/app/projects/" <> projectId project <> "/tasks/new"), attr "id" "new-task", cls "ls-button-link"] [E.text "New task"]]
  ]
    <> [ E.ul
           [cls "ls-projects"]
           [ E.li
               []
               [ E.a [href ("/app/tasks/" <> taskId t)] [E.text (taskTitle t)]
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
                 then [E.p [] [E.text "There are no tasks yet. Open a project to add one: ", E.a [href "/app/projects"] [E.text "Projects"], E.text "."]]
                 else
                   L.concat
                     [ [ E.h2 [] [E.text (projectName p)]
                       , E.p [] [E.a [href ("/app/projects/" <> projectId p)] [E.text ("Open " <> projectName p)]]
                       , E.ul
                           [cls "ls-projects"]
                           [ E.li [] [E.a [href ("/app/tasks/" <> taskId t)] [E.text (taskTitle t)], E.text (" \8212 " <> readinessWords (taskReadinessOf t))]
                           | t <- ts
                           ]
                       ]
                     | (p, ts) <- groups
                     , not (L.null ts)
                     ]
         )
      <> [E.p [cls "ls-muted"] [E.text "Running the work in a task arrives in a later update of Lockstep."]]
