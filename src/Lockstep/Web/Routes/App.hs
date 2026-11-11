{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

{- | The application's route tree (contracts C-P3.4 A1–A7, C-P3.5 J9 to
C-P4.16), as in Artificer's @Routes.App@: every endpoint is a route type, each
path is defined once as a builder polymorphic in the router, and the same
builder recognises requests (Beeline's 'R.RouteRecognizer') and generates the
URLs pages link to ('B.get' / 'B.post' over 'R.RouteGenerator'). The
addresses are the frozen ones.

Three subtrees: the page addresses (all the one content-free shell), the
fragments the shell fetches, and the actions.
-}
module Lockstep.Web.Routes.App
  ( Routes
  , routes

    -- * Sections
  , Section (..)
  , sectionPath

    -- * Pages
  , ShellRoutes
  , AppHome (..)
  , AppSignIn (..)
  , SectionPage (..)
  , NewProjectPage (..)
  , ProjectPage (..)
  , NewTaskPage (..)
  , TaskPage (..)
  , ChecksPage (..)
  , DecisionPage (..)
  , sectionLink
  , newProjectLink
  , projectLink
  , newTaskLink
  , taskLink
  , checksLink
  , decisionLink

    -- * Fragments
  , FragmentRoutes
  , SectionFragment (..)
  , NewProjectFragment (..)
  , ProjectFragment (..)
  , NewTaskFragment (..)
  , TaskFragment (..)
  , ChecksFragment (..)
  , DecisionFragment (..)

    -- * Actions
  , ActionRoutes
  , ExchangeSession (..)
  , SignOut (..)
  , CreateProject (..)
  , ConnectProject (..)
  , CreateTask (..)
  , ChooseChecks (..)
  , EnableExecution (..)
  , StopCapsuleRun (..)
  , EditTask (..)
  , DecideTask (..)
  , AdmitBug (..)
  , HaltDecision (..)
  , Completion (..)
  , Decide (..)
  , createProjectAction
  , connectProjectAction
  , createTaskAction
  , chooseChecksAction
  , enableExecutionAction
  , stopCapsuleRunAction
  , editTaskAction
  , decideTaskAction
  , admitBugAction
  , haltDecisionAction
  , completionAction
  , decideAction
  ) where

import Beeline.Routing ((/+), (/-), (/:), (/>))
import Beeline.Routing qualified as R
import Brigid.Types qualified as B
import Data.Text qualified as T
import Flipstone.Prelude
import Shrubbery qualified

import Lockstep.Kernel.Identity (ProjectId, TaskId, TransactionId)
import Lockstep.Web.Routes.Params (DecisionKey, decisionKeyParam, projectIdParam, taskIdParam, transactionIdParam)

type Routes =
  Shrubbery.Union
    [ ShellRoutes
    , FragmentRoutes
    , ActionRoutes
    ]

routes :: R.Router r => r Routes
routes =
  R.routeList $
    (R.make id /> R.Subrouter shellRoutes id)
      /: (R.make id /> R.Subrouter fragmentRoutes id)
      /: (R.make id /> R.Subrouter actionRoutes id)
      /: R.emptyRoutes

appRoot :: R.Router r => route -> R.Builder r route route
appRoot route =
  R.make route /- "app"

-- * Sections

-- | The application's sections, in the order of its navigation (C-P3.4 A4).
data Section
  = Home
  | Projects
  | Tasks
  | Decisions
  | Activity
  | Settings
  | Advanced
  deriving (Eq, Enum, Bounded)

sectionPath :: Section -> T.Text
sectionPath s =
  case s of
    Home -> "home"
    Projects -> "projects"
    Tasks -> "tasks"
    Decisions -> "decisions"
    Activity -> "activity"
    Settings -> "settings"
    Advanced -> "advanced"

sectionParam :: R.ParameterDefinition Section
sectionParam =
  R.boundedEnumParam sectionPath "section"

-- * Pages: every one is the shell

type ShellRoutes =
  Shrubbery.Union
    [ AppHome
    , AppSignIn
    , SectionPage
    , NewProjectPage
    , ProjectPage
    , NewTaskPage
    , TaskPage
    , ChecksPage
    , DecisionPage
    ]

shellRoutes :: R.Router r => r ShellRoutes
shellRoutes =
  R.routeList $
    R.get (appRoot AppHome)
      /: R.get (appRoot AppSignIn /- "sign-in")
      /: R.get sectionPage
      /: R.get newProjectPage
      /: R.get projectPage
      /: R.get newTaskPage
      /: R.get taskPage
      /: R.get checksPage
      /: R.get decisionPage
      /: R.emptyRoutes

data AppHome = AppHome

data AppSignIn = AppSignIn

newtype SectionPage = SectionPage {sectionPageSection :: Section}

sectionPage :: R.Router r => R.Builder r SectionPage SectionPage
sectionPage =
  R.make SectionPage /- "app" /+ R.Param sectionParam sectionPageSection

sectionLink :: Section -> B.RelativeURL B.Get
sectionLink s =
  B.get (SectionPage s) sectionPage

data NewProjectPage = NewProjectPage

newProjectPage :: R.Router r => R.Builder r NewProjectPage NewProjectPage
newProjectPage =
  appRoot NewProjectPage /- "projects" /- "new"

newProjectLink :: B.RelativeURL B.Get
newProjectLink =
  B.get NewProjectPage newProjectPage

newtype ProjectPage = ProjectPage {projectPageId :: ProjectId}

projectPage :: R.Router r => R.Builder r ProjectPage ProjectPage
projectPage =
  R.make ProjectPage /- "app" /- "projects" /+ R.Param projectIdParam projectPageId

projectLink :: ProjectId -> B.RelativeURL B.Get
projectLink pid =
  B.get (ProjectPage pid) projectPage

newtype NewTaskPage = NewTaskPage {newTaskPageProject :: ProjectId}

newTaskPage :: R.Router r => R.Builder r NewTaskPage NewTaskPage
newTaskPage =
  R.make NewTaskPage /- "app" /- "projects" /+ R.Param projectIdParam newTaskPageProject /- "tasks" /- "new"

newTaskLink :: ProjectId -> B.RelativeURL B.Get
newTaskLink pid =
  B.get (NewTaskPage pid) newTaskPage

newtype TaskPage = TaskPage {taskPageId :: TaskId}

taskPage :: R.Router r => R.Builder r TaskPage TaskPage
taskPage =
  R.make TaskPage /- "app" /- "tasks" /+ R.Param taskIdParam taskPageId

taskLink :: TaskId -> B.RelativeURL B.Get
taskLink tid =
  B.get (TaskPage tid) taskPage

newtype ChecksPage = ChecksPage {checksPageProject :: ProjectId}

checksPage :: R.Router r => R.Builder r ChecksPage ChecksPage
checksPage =
  R.make ChecksPage /- "app" /- "projects" /+ R.Param projectIdParam checksPageProject /- "checks"

checksLink :: ProjectId -> B.RelativeURL B.Get
checksLink pid =
  B.get (ChecksPage pid) checksPage

newtype DecisionPage = DecisionPage {decisionPageKey :: DecisionKey}

decisionPage :: R.Router r => R.Builder r DecisionPage DecisionPage
decisionPage =
  R.make DecisionPage /- "app" /- "decisions" /+ R.Param decisionKeyParam decisionPageKey

decisionLink :: DecisionKey -> B.RelativeURL B.Get
decisionLink key =
  B.get (DecisionPage key) decisionPage

-- * Fragments

type FragmentRoutes =
  Shrubbery.Union
    [ SectionFragment
    , NewProjectFragment
    , ProjectFragment
    , NewTaskFragment
    , TaskFragment
    , ChecksFragment
    , DecisionFragment
    ]

fragmentRoutes :: R.Router r => r FragmentRoutes
fragmentRoutes =
  R.routeList $
    R.get (fragments SectionFragment /+ R.Param sectionParam sectionFragmentSection)
      /: R.get (fragments NewProjectFragment /- "project-new")
      /: R.get (fragments ProjectFragment /- "project" /+ R.Param projectIdParam projectFragmentId)
      /: R.get (fragments NewTaskFragment /- "task-new" /+ R.Param projectIdParam newTaskFragmentProject)
      /: R.get (fragments TaskFragment /- "task" /+ R.Param taskIdParam taskFragmentId)
      /: R.get (fragments ChecksFragment /- "project-checks" /+ R.Param projectIdParam checksFragmentProject)
      /: R.get (fragments DecisionFragment /- "decision" /+ R.Param decisionKeyParam decisionFragmentKey)
      /: R.emptyRoutes

fragments :: R.Router r => a -> R.Builder r route a
fragments con =
  R.make con /- "app" /- "fragments"

newtype SectionFragment = SectionFragment {sectionFragmentSection :: Section}

data NewProjectFragment = NewProjectFragment

newtype ProjectFragment = ProjectFragment {projectFragmentId :: ProjectId}

newtype NewTaskFragment = NewTaskFragment {newTaskFragmentProject :: ProjectId}

newtype TaskFragment = TaskFragment {taskFragmentId :: TaskId}

newtype ChecksFragment = ChecksFragment {checksFragmentProject :: ProjectId}

newtype DecisionFragment = DecisionFragment {decisionFragmentKey :: DecisionKey}

-- * Actions

type ActionRoutes =
  Shrubbery.Union
    [ ExchangeSession
    , SignOut
    , CreateProject
    , ConnectProject
    , CreateTask
    , ChooseChecks
    , EnableExecution
    , StopCapsuleRun
    , EditTask
    , DecideTask
    , AdmitBug
    , HaltDecision
    , Completion
    , Decide
    ]

actionRoutes :: R.Router r => r ActionRoutes
actionRoutes =
  R.routeList $
    R.post (api ExchangeSession /- "session")
      /: R.post (api SignOut /- "sign-out")
      /: R.post createProject
      /: R.post connectProject
      /: R.post createTask
      /: R.post chooseChecks
      /: R.post enableExecution
      /: R.post stopCapsuleRun
      /: R.post editTask
      /: R.post decideTask
      /: R.post admitBug
      /: R.post haltDecision
      /: R.post completion
      /: R.post decide
      /: R.emptyRoutes

api :: R.Router r => a -> R.Builder r route a
api con =
  R.make con /- "app" /- "api"

data ExchangeSession = ExchangeSession

data SignOut = SignOut

data CreateProject = CreateProject

createProject :: R.Router r => R.Builder r CreateProject CreateProject
createProject =
  api CreateProject /- "projects"

createProjectAction :: B.RelativeURL B.Post
createProjectAction =
  B.post CreateProject createProject

newtype ConnectProject = ConnectProject {connectProjectId :: ProjectId}

connectProject :: R.Router r => R.Builder r ConnectProject ConnectProject
connectProject =
  api ConnectProject /- "projects" /+ R.Param projectIdParam connectProjectId /- "connect"

connectProjectAction :: ProjectId -> B.RelativeURL B.Post
connectProjectAction pid =
  B.post (ConnectProject pid) connectProject

newtype CreateTask = CreateTask {createTaskProject :: ProjectId}

createTask :: R.Router r => R.Builder r CreateTask CreateTask
createTask =
  api CreateTask /- "projects" /+ R.Param projectIdParam createTaskProject /- "tasks"

createTaskAction :: ProjectId -> B.RelativeURL B.Post
createTaskAction pid =
  B.post (CreateTask pid) createTask

newtype ChooseChecks = ChooseChecks {chooseChecksProject :: ProjectId}

chooseChecks :: R.Router r => R.Builder r ChooseChecks ChooseChecks
chooseChecks =
  api ChooseChecks /- "projects" /+ R.Param projectIdParam chooseChecksProject /- "checks"

chooseChecksAction :: ProjectId -> B.RelativeURL B.Post
chooseChecksAction pid =
  B.post (ChooseChecks pid) chooseChecks

newtype EnableExecution = EnableExecution {enableExecutionProject :: ProjectId}

enableExecution :: R.Router r => R.Builder r EnableExecution EnableExecution
enableExecution =
  api EnableExecution /- "projects" /+ R.Param projectIdParam enableExecutionProject /- "execution"

enableExecutionAction :: ProjectId -> B.RelativeURL B.Post
enableExecutionAction pid =
  B.post (EnableExecution pid) enableExecution

-- | Phase 5 (P5.10): stop the step running in the project's Dev Capsule.
newtype StopCapsuleRun = StopCapsuleRun {stopCapsuleRunProject :: ProjectId}

stopCapsuleRun :: R.Router r => R.Builder r StopCapsuleRun StopCapsuleRun
stopCapsuleRun =
  api StopCapsuleRun /- "projects" /+ R.Param projectIdParam stopCapsuleRunProject /- "capsule" /- "stop"

stopCapsuleRunAction :: ProjectId -> B.RelativeURL B.Post
stopCapsuleRunAction pid =
  B.post (StopCapsuleRun pid) stopCapsuleRun

newtype EditTask = EditTask {editTaskId :: TaskId}

editTask :: R.Router r => R.Builder r EditTask EditTask
editTask =
  api EditTask /- "tasks" /+ R.Param taskIdParam editTaskId /- "edit"

editTaskAction :: TaskId -> B.RelativeURL B.Post
editTaskAction tid =
  B.post (EditTask tid) editTask

newtype DecideTask = DecideTask {decideTaskId :: TaskId}

decideTask :: R.Router r => R.Builder r DecideTask DecideTask
decideTask =
  api DecideTask /- "tasks" /+ R.Param taskIdParam decideTaskId /- "decide"

decideTaskAction :: TaskId -> B.RelativeURL B.Post
decideTaskAction tid =
  B.post (DecideTask tid) decideTask

newtype AdmitBug = AdmitBug {admitBugTask :: TaskId}

admitBug :: R.Router r => R.Builder r AdmitBug AdmitBug
admitBug =
  api AdmitBug /- "tasks" /+ R.Param taskIdParam admitBugTask /- "bug"

admitBugAction :: TaskId -> B.RelativeURL B.Post
admitBugAction tid =
  B.post (AdmitBug tid) admitBug

newtype HaltDecision = HaltDecision {haltDecisionTransaction :: TransactionId}

haltDecision :: R.Router r => R.Builder r HaltDecision HaltDecision
haltDecision =
  api HaltDecision /- "transactions" /+ R.Param transactionIdParam haltDecisionTransaction /- "decision"

haltDecisionAction :: TransactionId -> B.RelativeURL B.Post
haltDecisionAction xid =
  B.post (HaltDecision xid) haltDecision

newtype Completion = Completion {completionTransaction :: TransactionId}

completion :: R.Router r => R.Builder r Completion Completion
completion =
  api Completion /- "transactions" /+ R.Param transactionIdParam completionTransaction /- "completion"

completionAction :: TransactionId -> B.RelativeURL B.Post
completionAction xid =
  B.post (Completion xid) completion

newtype Decide = Decide {decideKey :: DecisionKey}

decide :: R.Router r => R.Builder r Decide Decide
decide =
  api Decide /- "decisions" /+ R.Param decisionKeyParam decideKey

decideAction :: DecisionKey -> B.RelativeURL B.Post
decideAction key =
  B.post (Decide key) decide
