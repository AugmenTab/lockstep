{-# LANGUAGE OverloadedStrings #-}

{- | The application shell on the service (contract C-P3.4 A1–A7): the same
trust model as the control pane (T2–T7). Every page address returns one
content-free shell; the sections are server-rendered Brigid fragments fetched
by the page with the @X-Lockstep-Session@ header. The one-time token and the
session are those of C-P1.3, stored as digests; no cookie is read or set here.
Projects (contract C-P3.5 J9) add an overview, a new-project form and a page
per project.

Requests are recognised by the typed route tree of "Lockstep.Web.Routes.App"
(a path parameter that is not a canonical id is no route) and dispatched over
its union; form submissions are read by the validators below, keyed by the
field names of "Lockstep.Web.Fields" that the pages use.
-}
module Lockstep.Web.App
  ( Routes
  , matchAppRoute
  , appRouteClass
  , handleApp
  ) where

import Beeline.Routing qualified as R
import Brigid.HTML.Attributes qualified as A
import Brigid.HTML.Elements qualified as E
import Brigid.HTML.Types qualified as HTML
import Brigid.Types qualified as B
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe, isJust)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time qualified as Time
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTP
import Network.Wai qualified as Wai
import Shrubbery qualified
import System.IO (FilePath)
import Text.Read (readMaybe)
import Text.Show (show)

import Lockstep.Application.Activity (readActivity)
import Lockstep.Application.Command (IdempotencyKey, WorkspaceState (..), generateIdempotencyKey, idempotencyKeyText, mkIdempotencyKey, readWorkspace)
import Lockstep.Application.Conversation (Channel (..), Sender (..), StoredRequest (..), postMessage)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason (..), Readiness (..), checkReadiness, revisionNumber)
import Lockstep.Application.Decisions (DecisionReceipt (..), applyDecision, decidedReceipt, findDecision, listDecisions, receiptApplied)
import Lockstep.Application.Engine (TransactionView (..), decideCompletion, haltRequest, projectStarted, transactionForWorkOrder, transactionView)
import Lockstep.Application.Execution (Admission (..), admitBug, enableExecution, executionStatus, findAdmission)
import Lockstep.Application.LedgerView (EffectLine (..), LedgerProjection (..), OrderLine (..), projectLedger)
import Lockstep.Application.OperatorTrust (Session (..), exchangeSignIn, lookupSession, revokeSession)
import Lockstep.Application.ProjectChecks (ChecksOutcome (..), ChecksRefusal (FewerChecksUnconfirmed), ExpectedChecks (..), ProjectChecks (..), QueueEntry (..), checksRefusalCode, chooseChecksTyped, projectChecks)
import Lockstep.Application.Projects
  ( NewProject (..)
  , ProjectFolders (..)
  , ProjectView (..)
  , connectProject
  , createProject
  , findProject
  , listProjects
  , offeredFolders
  , projectFoldersFromEnvironment
  )
import Lockstep.Application.Tasks
  ( NewTask (..)
  , TaskDecision (..)
  , TaskEdit (..)
  , TaskView (..)
  , createTask
  , decideTask
  , editTask
  , findTask
  , findTaskById
  , listAllTasks
  , listTasks
  )
import Lockstep.Foundation.OperatorToken (RawToken, decodeToken, encodeToken)
import Lockstep.Kernel.Conversation (RequestInput (..))
import Lockstep.Kernel.Decision (decisionRefusalWords)
import Lockstep.Kernel.EffectView (EffectStatus (..))
import Lockstep.Kernel.Execution (executionRefusalWords)
import Lockstep.Kernel.Identity (ProjectId (..), TaskId (..), TransactionId (..), identityText)
import Lockstep.Kernel.Policy (checksRefusalWords, lossWords)
import Lockstep.Kernel.Project (FolderChoice, SetupState (..), parseFolderChoice, refusalWords, setupStateCode)
import Lockstep.Kernel.Task (Priority, parsePriority, taskRefusalWords)
import Lockstep.Web.ActivityPage (activityPage)
import Lockstep.Web.ChecksPages (checksPage, choiceLosses, projectChecksSection)
import Lockstep.Web.DecisionPages (DecisionChoice, choiceFits, decisionChoiceCode, decisionPage, decisionRequest, decisionsOverview, donePage)
import Lockstep.Web.ExecutionPages (projectExecutionSection, taskFixingSection)
import Lockstep.Web.Fields
  ( acceptanceField
  , acknowledgeField
  , actionField
  , choiceField
  , confirmFewerField
  , dependsOnField
  , expectedField
  , expectedSetField
  , folderField
  , keyField
  , nameField
  , outcomeField
  , pathField
  , priorityField
  , reasonField
  , requestField
  , revisionField
  , textField
  , ticketRevisionField
  , titleField
  )
import Lockstep.Web.Form (Form, FormField, readForm)
import Lockstep.Web.Fragment (attr, cls, elementId, fragment)
import Lockstep.Web.Json (SessionBody (..), sessionSchema)
import Lockstep.Web.RequestGuard (RouteClass (..))
import Lockstep.Web.Routes.App
  ( ActionRoutes
  , AdmitBug (..)
  , ChecksFragment (..)
  , ChooseChecks (..)
  , Completion (..)
  , ConnectProject (..)
  , CreateProject
  , CreateTask (..)
  , Decide (..)
  , DecideTask (..)
  , DecisionFragment (..)
  , EditTask (..)
  , EnableExecution (..)
  , ExchangeSession
  , FragmentRoutes
  , HaltDecision (..)
  , NewProjectFragment
  , NewTaskFragment (..)
  , ProjectFragment (..)
  , Routes
  , Section (..)
  , SectionFragment (..)
  , ShellRoutes
  , SignOut
  , TaskFragment (..)
  , checksLink
  , connectProjectAction
  , createProjectAction
  , decisionLink
  , newProjectLink
  , projectLink
  , routes
  , sectionLink
  , taskLink
  )
import Lockstep.Web.Routes.Operator (centerLink, ledgerLink)
import Lockstep.Web.Routes.Params (DecisionKey, decisionKeyText)
import Lockstep.Web.SecureResponse (errorJson, htmlResponse, jsonResponse, readBodyLimited, respondWith)
import Lockstep.Web.TaskPages (TaskAction (..), TaskForm (..), emptyTaskForm, newTaskPage, projectTasks, taskActionCode, taskPage, tasksOverview)
import Lockstep.Web.Validation (FormErrors, Validator, hasError)
import Lockstep.Web.Validation qualified as V

{- | The route for a request, if it is one of the application's. A HEAD is
answered as the GET of the same address, as before.
-}
matchAppRoute :: HTTP.StdMethod -> [T.Text] -> Maybe Routes
matchAppRoute method path =
  either (const Nothing) Just $
    R.recognizeRoute routes (if method == HTTP.HEAD then HTTP.GET else method) path

-- | The shell is public; everything that carries data or acts needs the exact Host (and Origin for POST).
appRouteClass :: Routes -> RouteClass
appRouteClass =
  Shrubbery.dissect
    . Shrubbery.branchBuild
    . Shrubbery.branch (\(_ :: ShellRoutes) -> PublicRead)
    . Shrubbery.branch (\(_ :: FragmentRoutes) -> OperatorRoute)
    . Shrubbery.branch (\(_ :: ActionRoutes) -> OperatorRoute)
    $ Shrubbery.branchEnd

shell :: Wai.Response
shell =
  -- Acceptable exception (stack-compliance audit W2): the frozen C-P3.4 shell test
  -- pins the htmx-config attribute as single-quoted raw JSON, which Brigid (always
  -- double quotes, values as given) cannot write. The control pane's shell is Brigid.
  htmlResponse HTTP.status200 . LBS.fromStrict . BS8.pack . L.unlines $
    [ "<!doctype html>"
    , "<html lang=\"en\">"
    , "<head>"
    , "<meta charset=\"utf-8\">"
    , "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
    , "<meta name=\"htmx-config\" content='{\"allowEval\":false,\"allowScriptTags\":false,\"includeIndicatorStyles\":false,\"selfRequestsOnly\":true}'>"
    , "<title>Lockstep</title>"
    , "<link rel=\"stylesheet\" href=\"/static/lockstep.css\">"
    , "</head>"
    , "<body class=\"app\">"
    , "<div id=\"app\" class=\"ls-app\" aria-live=\"polite\"><p>Opening Lockstep\226\128\166</p></div>"
    , "<noscript><p>Lockstep needs JavaScript turned on in this browser.</p></noscript>"
    , "<script src=\"/static/htmx.min.js\"></script>"
    , "<script src=\"/static/app.js\"></script>"
    , "</body>"
    , "</html>"
    ]

handleApp :: Maybe DatabaseRuntime -> Routes -> Wai.Request -> IO Wai.Response
handleApp mbDb route request =
  Shrubbery.dissect
    ( Shrubbery.branchBuild
        . Shrubbery.branch (\(_ :: ShellRoutes) -> pure shell)
        . Shrubbery.branch (withDatabase . fragmentRoute)
        . Shrubbery.branch (withDatabase . actionRoute)
        $ Shrubbery.branchEnd
    )
    route
 where
  withDatabase handle =
    case mbDb of
      Nothing -> pure (errorJson HTTP.status503 "no-database")
      Just db -> handle (Ctx db request)

-- | What every handler has: the database and the request.
data Ctx
  = Ctx
  { ctxDb :: DatabaseRuntime
  , ctxRequest :: Wai.Request
  }

sessionHeader :: Wai.Request -> Maybe T.Text
sessionHeader request =
  TE.decodeLatin1 <$> L.lookup "X-Lockstep-Session" (Wai.requestHeaders request)

notReady :: Wai.Response
notReady =
  errorJson HTTP.status503 "not-ready"

notFound :: Wai.Response
notFound =
  errorJson HTTP.status404 "not-found"

withSession :: Ctx -> (RawSession -> IO Wai.Response) -> IO Wai.Response
withSession ctx action =
  case sessionHeader (ctxRequest ctx) >>= decodeToken of
    Nothing -> pure (errorJson HTTP.status401 "signed-out")
    Just token -> do
      found <- lookupSession (ctxDb ctx) token
      case found of
        Nothing -> pure (errorJson HTTP.status401 "signed-out")
        Just session -> action (RawSession token session)

-- | A live session and the token that names it.
data RawSession
  = RawSession
  { rawToken :: RawToken
  , rawSession :: Session
  }

{- | A form of at most 16 KiB (else 413), then the session. A body that is not
an urlencoded UTF-8 form reads as an empty form, which every form below refuses
as unreadable.
-}
withForm :: Ctx -> (Form -> IO Wai.Response) -> IO Wai.Response
withForm ctx action = do
  body <- readBodyLimited (ctxRequest ctx) 16384
  case body of
    Nothing -> pure (errorJson HTTP.status413 "too-large")
    Just bytes -> withSession ctx $ \_ -> action (fromMaybe Map.empty (readForm bytes))

fragmentRoute :: FragmentRoutes -> Ctx -> IO Wai.Response
fragmentRoute route ctx =
  Shrubbery.dissect
    ( Shrubbery.branchBuild
        . Shrubbery.branch (\(SectionFragment s) -> sectionFragment ctx s)
        . Shrubbery.branch (\(_ :: NewProjectFragment) -> newProjectFragment ctx)
        . Shrubbery.branch (\(ProjectFragment pid) -> projectFragment ctx pid)
        . Shrubbery.branch (\(NewTaskFragment pid) -> newTaskFragment ctx pid)
        . Shrubbery.branch (\(TaskFragment tid) -> taskFragment ctx tid)
        . Shrubbery.branch (\(ChecksFragment pid) -> checksFragment ctx pid)
        . Shrubbery.branch (\(DecisionFragment key) -> withSession ctx $ \_ -> decisionAnswer (ctxDb ctx) key Nothing)
        $ Shrubbery.branchEnd
    )
    route

actionRoute :: ActionRoutes -> Ctx -> IO Wai.Response
actionRoute route ctx =
  Shrubbery.dissect
    ( Shrubbery.branchBuild
        . Shrubbery.branch (\(_ :: ExchangeSession) -> exchangeSession ctx)
        . Shrubbery.branch (\(_ :: SignOut) -> signOut ctx)
        . Shrubbery.branch (\(_ :: CreateProject) -> createProjectRoute ctx)
        . Shrubbery.branch (\(ConnectProject pid) -> connectProjectRoute ctx pid)
        . Shrubbery.branch (\(CreateTask pid) -> createTaskRoute ctx pid)
        . Shrubbery.branch (\(ChooseChecks pid) -> chooseChecksRoute ctx pid)
        . Shrubbery.branch (\(EnableExecution pid) -> enableExecutionRoute ctx pid)
        . Shrubbery.branch (\(EditTask tid) -> editTaskRoute ctx tid)
        . Shrubbery.branch (\(DecideTask tid) -> decideTaskRoute ctx tid)
        . Shrubbery.branch (\(AdmitBug tid) -> admitBugRoute ctx tid)
        . Shrubbery.branch (\(HaltDecision xid) -> haltDecisionRoute ctx xid)
        . Shrubbery.branch (\(Completion xid) -> completionRoute ctx xid)
        . Shrubbery.branch (\(Decide key) -> decideRoute ctx key)
        $ Shrubbery.branchEnd
    )
    route

-- * Form fields

-- | A field's one text value; absent reads as empty (the form shows what was sent).
textOr :: B.Name -> Validator Form T.Text
textOr name =
  V.withDefault "" (name `V.optional` V.text)

idempotencyKey :: Validator FormField IdempotencyKey
idempotencyKey =
  V.text `V.chain` V.eitherValidator (either (const (Left "Not a form key.")) Right . mkIdempotencyKey)

{- | A form's number: plain decimal digits only (no sign, space or other
spelling), at most the stored range's largest value (C-C.R1 R3).
-}
decimalUpTo :: Num a => Integer -> Validator FormField a
decimalUpTo limit =
  V.text `V.chain` V.maybeValidator parse "Not a number in range."
 where
  parse t
    | T.null t || T.length t > 19 || not (T.all Char.isDigit t) = Nothing
    | otherwise =
        case readMaybe (T.unpack t) :: Maybe Integer of
          Just n | n <= limit -> Just (fromInteger n)
          _ -> Nothing

-- | The largest PostgreSQL @integer@ (expected values and Ticket revisions).
integerMax :: Integer
integerMax =
  2147483647

-- | The largest PostgreSQL @bigint@ (project and task revisions).
bigintMax :: Integer
bigintMax =
  9223372036854775807

-- | The @folder@ choice and, for @existing@, its @path@; reported under @folder@.
folderChoice :: Validator Form FolderChoice
folderChoice =
  V.labelled folderField $
    ((,) <$> folderField `V.required` V.text <*> pathField `V.optional` V.text)
      `V.chain` V.maybeValidator (uncurry parseFolderChoice) "Choose where the project's files should live."

priority :: Validator FormField Priority
priority =
  V.text `V.chain` V.maybeValidator parsePriority "Not a priority."

{- | The checks expectation (C-C.R1 R10): with @expected_set@ the value is
taken literally; without it, the C-P3.7 text (@none@ is nothing chosen).
-}
checksExpectation :: Validator Form ExpectedChecks
checksExpectation =
  V.labelled expectedField $
    ((,) <$> expectedField `V.required` V.text <*> expectedSetField `V.optional` V.text)
      `V.chain` V.maybeValidator expectation "Not an expectation."
 where
  expectation (e, set) =
    case set of
      Nothing -> Just (if e == "none" then ExpectNothing else ExpectProfile e)
      Just "yes" -> Just (ExpectProfile e)
      Just "no" -> Just ExpectNothing
      Just _ -> Nothing

-- | The execution form's expectation: @expected_set@ is required (C-C.R1 R10).
executionExpectation :: Validator Form ExpectedChecks
executionExpectation =
  V.labelled expectedField $
    ((,) <$> expectedField `V.required` V.text <*> expectedSetField `V.required` V.text)
      `V.chain` V.maybeValidator expectation "Not an expectation."
 where
  expectation (e, set) =
    case T.unpack set of
      "yes" -> Just (ExpectProfile e)
      "no" -> Just ExpectNothing
      _ -> Nothing

-- | A box that is ticked sends @yes@.
ticked :: B.Name -> Validator Form Bool
ticked name =
  (== Just "yes") <$> name `V.optional` V.text

unreadableTryAgain :: T.Text
unreadableTryAgain =
  "Lockstep could not read this form. Try again."

-- * Fragments

sectionFragment :: Ctx -> Section -> IO Wai.Response
sectionFragment ctx section =
  withSession ctx $ \s -> htmlResponse HTTP.status200 <$> renderSection (ctxDb ctx) section (rawSession s)

newProjectFragment :: Ctx -> IO Wai.Response
newProjectFragment ctx =
  withSession ctx $ \_ -> do
    key <- idempotencyKeyText <$> generateIdempotencyKey
    htmlResponse HTTP.status200 <$> newProjectPage (ctxDb ctx) key emptyForm Nothing

projectFragment :: Ctx -> ProjectId -> IO Wai.Response
projectFragment ctx pid =
  withSession ctx $ \_ -> do
    found <- findProject (ctxDb ctx) (identityText pid)
    case found of
      Right (Just view) -> htmlResponse HTTP.status200 <$> projectPage (ctxDb ctx) view Nothing
      Right Nothing -> pure notFound
      Left _ -> pure notReady

newTaskFragment :: Ctx -> ProjectId -> IO Wai.Response
newTaskFragment ctx pid =
  withSession ctx $ \_ -> do
    found <- findProject (ctxDb ctx) (identityText pid)
    case found of
      Left _ -> pure notReady
      Right Nothing -> pure notFound
      Right (Just project) -> do
        key <- idempotencyKeyText <$> generateIdempotencyKey
        others <- fromRight [] <$> listTasks (ctxDb ctx) (identityText pid)
        pure (htmlResponse HTTP.status200 (newTaskPage project others (emptyTaskForm key) Nothing))

taskFragment :: Ctx -> TaskId -> IO Wai.Response
taskFragment ctx tid =
  withSession ctx $ \_ -> do
    found <- findTask (ctxDb ctx) (identityText tid)
    case found of
      Right (Just task) -> taskAnswer (ctxDb ctx) task Nothing
      Right Nothing -> pure notFound
      Left _ -> pure notReady

checksFragment :: Ctx -> ProjectId -> IO Wai.Response
checksFragment ctx pid =
  withSession ctx $ \_ -> do
    found <- projectChecks (ctxDb ctx) (identityText pid)
    case found of
      Right (Just pc) -> pure (htmlResponse HTTP.status200 (checksPage pc Nothing))
      Right Nothing -> pure notFound
      Left _ -> pure notReady

-- * Actions

exchangeSession :: Ctx -> IO Wai.Response
exchangeSession ctx = do
  body <- readBodyLimited (ctxRequest ctx) 4096
  case body of
    Nothing -> pure (errorJson HTTP.status413 "too-large")
    Just bytes ->
      -- The token is base64url text; bytes that are not UTF-8 are no token.
      case either (const Nothing) decodeToken (TE.decodeUtf8' bytes) of
        Nothing -> pure (errorJson HTTP.status403 "sign-in-refused")
        Just token -> do
          exchanged <- exchangeSignIn (ctxDb ctx) token
          pure $ case exchanged of
            Right session -> jsonResponse HTTP.status200 sessionSchema (SessionBody (encodeToken session))
            Left _ -> errorJson HTTP.status403 "sign-in-refused"

signOut :: Ctx -> IO Wai.Response
signOut ctx = do
  _ <- readBodyLimited (ctxRequest ctx) 4096
  withSession ctx $ \s -> do
    _ <- revokeSession (ctxDb ctx) (rawToken s)
    pure (respondWith HTTP.status204 [] "")

data ProjectForm
  = ProjectForm
  { formKey :: T.Text
  , formName :: T.Text
  , formOutcome :: T.Text
  , formFolder :: T.Text
  , formPath :: T.Text
  }

emptyForm :: ProjectForm
emptyForm =
  ProjectForm "" "" "" "new" ""

-- | What the new-project form shows again: the values sent.
projectFormValues :: Validator Form ProjectForm
projectFormValues =
  ProjectForm <$> textOr keyField <*> textOr nameField <*> textOr outcomeField <*> textOr folderField <*> textOr pathField

newProjectRequest :: Validator Form (IdempotencyKey, FolderChoice)
newProjectRequest =
  (,) <$> keyField `V.required` idempotencyKey <*> folderChoice

createProjectRoute :: Ctx -> IO Wai.Response
createProjectRoute ctx =
  withForm ctx $ \fields -> do
    let
      db = ctxDb ctx
      sent = V.runValidator projectFormValues fields
      form = fromRight (ProjectForm "" "" "" "" "") sent
      again notice = htmlResponse HTTP.status200 <$> newProjectPage db (formKey form) form (Just notice)
      unreadable = again "Lockstep could not read this form. Open New project again."
    case (sent, V.runValidator newProjectRequest fields) of
      (Left _, _) -> unreadable
      (_, Left errs)
        | hasError keyField errs -> unreadable
        | otherwise -> again "Choose where the project's files should live."
      (Right _, Right (key, choice)) -> do
        folders <- projectFoldersFromEnvironment
        created <- createProject db folders (NewProject key (formName form) (formOutcome form) choice)
        case created of
          Left _ -> pure notReady
          Right (Left code) -> again (refusalWords code)
          Right (Right view) -> projectAnswer db view Nothing

connectProjectRoute :: Ctx -> ProjectId -> IO Wai.Response
connectProjectRoute ctx pid =
  withForm ctx $ \fields -> do
    let
      db = ctxDb ctx
    folders <- projectFoldersFromEnvironment
    current <- findProject db (identityText pid)
    case current of
      Left _ -> pure notReady
      Right Nothing -> pure notFound
      Right (Just view) ->
        case V.runValidator ((,) <$> revisionField `V.required` decimalUpTo bigintMax <*> folderChoice) fields of
          Left errs
            | hasError revisionField errs -> projectAnswer db view (Just unreadableTryAgain)
            | otherwise -> projectAnswer db view (Just "Choose where the project's files should live.")
          Right (r, c) -> do
            connected <- connectProject db folders (identityText pid) r c
            case connected of
              Left _ -> pure notReady
              Right (Right updated) -> projectAnswer db updated Nothing
              Right (Left code) -> do
                latest <- findProject db (identityText pid)
                projectAnswer db (either (const view) (fromMaybe view) latest) (Just (refusalWords code))

-- | What a task form shows again: the values sent.
taskFormValues :: Validator Form TaskForm
taskFormValues =
  TaskForm
    <$> textOr keyField
    <*> textOr titleField
    <*> textOr acceptanceField
    <*> textOr priorityField
    <*> V.withDefault [] (dependsOnField `V.optional` V.list V.text)

createTaskRoute :: Ctx -> ProjectId -> IO Wai.Response
createTaskRoute ctx pid =
  withForm ctx $ \fields -> do
    let
      db = ctxDb ctx
      sent = V.runValidator taskFormValues fields
      form = fromRight (emptyTaskForm "") sent
    found <- findProject db (identityText pid)
    case found of
      Left _ -> pure notReady
      Right Nothing -> pure notFound
      Right (Just project) -> do
        others <- fromRight [] <$> listTasks db (identityText pid)
        let
          again notice = pure (htmlResponse HTTP.status200 (newTaskPage project others form (Just notice)))
        case (sent, V.runValidator ((,) <$> keyField `V.required` idempotencyKey <*> priorityField `V.required` priority) fields) of
          (Left _, _) -> again "Lockstep could not read this form. Open New task again."
          (_, Left errs)
            | hasError keyField errs -> again "Lockstep could not read this form. Open New task again."
            | otherwise -> again (taskRefusalWords "unknown-priority")
          (Right _, Right (key, p)) -> do
            created <- createTask db (NewTask key (identityText pid) (formTaskTitle form) (formTaskAcceptance form) p (formTaskDependencies form))
            case created of
              Left _ -> pure notReady
              Right (Left code) -> again (taskRefusalWords code)
              Right (Right task) -> taskAnswer db task Nothing

editTaskRoute :: Ctx -> TaskId -> IO Wai.Response
editTaskRoute ctx tid =
  withForm ctx $ \fields -> do
    let
      db = ctxDb ctx
    found <- findTask db (identityText tid)
    case found of
      Left _ -> pure notReady
      Right Nothing -> pure notFound
      Right (Just task) ->
        case (V.runValidator taskFormValues fields, V.runValidator ((,) <$> revisionField `V.required` decimalUpTo bigintMax <*> priorityField `V.required` priority) fields) of
          (Left _, _) -> taskAnswer db task (Just unreadableTryAgain)
          (_, Left errs)
            | hasError revisionField errs -> taskAnswer db task (Just unreadableTryAgain)
            | otherwise -> taskAnswer db task (Just (taskRefusalWords "unknown-priority"))
          (Right form, Right (r, p)) -> do
            edited <- editTask db (identityText tid) r (TaskEdit (formTaskTitle form) (formTaskAcceptance form) p (formTaskDependencies form))
            case edited of
              Left _ -> pure notReady
              Right (Right updated) -> taskAnswer db updated Nothing
              Right (Left code) -> do
                latest <- findTask db (identityText tid)
                taskAnswer db (either (const task) (fromMaybe task) latest) (Just (taskRefusalWords code))

-- | The task decision: the action (C-P3.6 K7) and, to block, the reason.
taskDecision :: Validator Form TaskDecision
taskDecision =
  decisionFor <$> actionField `V.required` V.boundedEnum taskActionCode <*> textOr reasonField
 where
  decisionFor action reason =
    case action of
      ActionReady -> MarkReady
      ActionBlock -> BlockTask reason
      ActionUnblock -> UnblockTask
      ActionCancel -> CancelTask

decideTaskRoute :: Ctx -> TaskId -> IO Wai.Response
decideTaskRoute ctx tid =
  withForm ctx $ \fields -> do
    let
      db = ctxDb ctx
    found <- findTask db (identityText tid)
    case found of
      Left _ -> pure notReady
      Right Nothing -> pure notFound
      Right (Just task) ->
        case V.runValidator ((,) <$> ticketRevisionField `V.required` decimalUpTo integerMax <*> taskDecision) fields of
          Left _ -> taskAnswer db task (Just unreadableTryAgain)
          Right (r, d) -> do
            decided <- decideTask db "application" (identityText tid) r d
            case decided of
              Left _ -> pure notReady
              Right (Right updated) -> taskAnswer db updated Nothing
              Right (Left code) -> do
                latest <- findTask db (identityText tid)
                taskAnswer db (either (const task) (fromMaybe task) latest) (Just (taskRefusalWords code))

chooseChecksRoute :: Ctx -> ProjectId -> IO Wai.Response
chooseChecksRoute ctx pid =
  withForm ctx $ \fields -> do
    let
      db = ctxDb ctx
    found <- projectChecks db (identityText pid)
    case found of
      Left _ -> pure notReady
      Right Nothing -> pure notFound
      Right (Just before) ->
        case V.runValidator ((,,) <$> checksExpectation <*> choiceField `V.required` V.text <*> ticked confirmFewerField) fields of
          Left _ -> checksAnswer db pid before (Just unreadableTryAgain)
          Right (expected, choice, confirmed) -> do
            chosen <- chooseChecksTyped db (identityText pid) expected choice confirmed
            case chosen of
              Left _ -> pure notReady
              Right (Right ChecksChosen) -> checksAnswer db pid before (Just "Saved.")
              Right (Right ChecksUnchanged) -> checksAnswer db pid before (Just "Saved. This was already the choice.")
              Right (Left refusal) -> do
                let
                  losses = choiceLosses before choice
                  lost =
                    case refusal of
                      FewerChecksUnconfirmed
                        | not (L.null losses) -> " It would stop requiring " <> T.intercalate "; " (fmap lossWords losses) <> "."
                      _ -> ""
                checksAnswer db pid before (Just (checksRefusalWords (checksRefusalCode refusal) <> lost))

enableExecutionRoute :: Ctx -> ProjectId -> IO Wai.Response
enableExecutionRoute ctx pid =
  withForm ctx $ \fields -> do
    let
      db = ctxDb ctx
    found <- findProject db (identityText pid)
    case found of
      Left _ -> pure notReady
      Right Nothing -> pure notFound
      Right (Just view) ->
        case V.runValidator ((,) <$> keyField `V.required` idempotencyKey <*> executionExpectation) fields of
          Left _ -> projectAnswer db view (Just unreadableTryAgain)
          Right (k, expected) -> do
            folders <- projectFoldersFromEnvironment
            enabled <- enableExecution db folders k (identityText pid) expected
            case enabled of
              Left _ -> pure notReady
              Right (Right _) -> projectAnswer db view Nothing
              Right (Left code) -> projectAnswer db view (Just (executionRefusalWords code))

admitBugRoute :: Ctx -> TaskId -> IO Wai.Response
admitBugRoute ctx tid =
  withForm ctx $ \fields -> do
    let
      db = ctxDb ctx
    found <- findTask db (identityText tid)
    case found of
      Left _ -> pure notReady
      Right Nothing -> pure notFound
      Right (Just task) ->
        case V.runValidator ((,) <$> keyField `V.required` idempotencyKey <*> ticketRevisionField `V.required` decimalUpTo integerMax) fields of
          Left _ -> taskAnswer db task (Just unreadableTryAgain)
          Right (k, r) -> do
            folders <- projectFoldersFromEnvironment
            admitted <- admitBug db folders k (identityText tid) r
            latest <- findTask db (identityText tid)
            let
              now = either (const task) (fromMaybe task) latest
            case admitted of
              Left _ -> pure notReady
              Right (Right _) -> taskAnswer db now Nothing
              Right (Left code) -> taskAnswer db now (Just (executionRefusalWords code))

-- | An answer to the question a halted fix asks (C-P4.16).
data HaltAnswer
  = HaltAnswer
  { haltKey :: IdempotencyKey
  , haltRevision :: Int
  , haltRequestId :: T.Text
  , haltChoice :: T.Text
  }

haltAnswer :: Validator Form HaltAnswer
haltAnswer =
  HaltAnswer
    <$> keyField `V.required` idempotencyKey
    <*> revisionField `V.required` decimalUpTo integerMax
    <*> requestField `V.required` V.text
    <*> choiceField `V.required` V.text

haltDecisionRoute :: Ctx -> TransactionId -> IO Wai.Response
haltDecisionRoute ctx xid =
  withForm ctx $ \fields -> do
    let
      db = ctxDb ctx
    found <- transactionView db (identityText xid)
    case found of
      Left _ -> pure notReady
      Right Nothing -> pure notFound
      Right (Just tx) -> do
        current <- haltRequest db (viewKey tx)
        case (current, V.runValidator haltAnswer fields) of
          (Left _, _) -> pure notReady
          (Right _, Left errs) -> transactionAnswer db tx (Just (haltFormWords errs))
          (Right (Just r), Right a)
            | haltRequestId a == storedRequestId r -> do
                posted <- postMessage db (haltKey a) (haltRequestId a) (SenderHuman ApplicationChannel) (HumanDecides (haltRevision a) (haltChoice a) "Answered on the task page.")
                case posted of
                  Left _ -> pure notReady
                  Right (Right _) -> transactionAnswer db tx Nothing
                  Right (Left code) -> transactionAnswer db tx (Just (haltAnswerWords code))
          (Right _, Right _) -> transactionAnswer db tx (Just "This is no longer the question Lockstep is waiting on. Here is the fix as it stands now.")

-- | A missing choice is asked for; anything else unreadable is said so.
haltFormWords :: FormErrors -> T.Text
haltFormWords errs
  | hasError choiceField errs = "Choose what should happen next."
  | otherwise = unreadableTryAgain

completionRoute :: Ctx -> TransactionId -> IO Wai.Response
completionRoute ctx xid =
  withForm ctx $ \fields -> do
    let
      db = ctxDb ctx
    found <- transactionView db (identityText xid)
    case (found, V.runValidator (choiceField `V.required` V.text) fields) of
      (Left _, _) -> pure notReady
      (Right Nothing, _) -> pure notFound
      (Right (Just tx), Left _) -> transactionAnswer db tx (Just "Choose whether this bug is fixed.")
      (Right (Just tx), Right c) -> do
        decided <- decideCompletion db (viewId tx) (SenderHuman ApplicationChannel) c
        case decided of
          Left _ -> pure notReady
          Right (Right updated) -> transactionAnswer db updated Nothing
          Right (Left code) -> transactionAnswer db tx (Just (completionWords code))

-- | A person's decision (C-P3.8 M6): the choice, typed, with what it needs.
data DecisionAnswer
  = DecisionAnswer
  { answerKey :: IdempotencyKey
  , answerExpected :: Int
  , answerChoice :: DecisionChoice
  , answerText :: T.Text
  , answerAcknowledged :: Bool
  }

decisionAnswerForm :: Validator Form DecisionAnswer
decisionAnswerForm =
  DecisionAnswer
    <$> keyField `V.required` idempotencyKey
    <*> expectedField `V.required` decimalUpTo integerMax
    <*> choiceField `V.required` V.boundedEnum decisionChoiceCode
    <*> textOr textField
    <*> ticked acknowledgeField

decideRoute :: Ctx -> DecisionKey -> IO Wai.Response
decideRoute ctx key =
  withForm ctx $ \fields -> do
    let
      db = ctxDb ctx
      subject = decisionKeyText key
    open <- findDecision db subject
    decided <- decidedReceipt db subject
    case (open, decided) of
      (Left _, _) -> pure notReady
      (_, Left _) -> pure notReady
      (Right Nothing, Right Nothing) -> pure notFound
      (Right current, _) ->
        case V.runValidator decisionAnswerForm fields of
          -- A choice belongs to its decision while it is open; once closed, the request is
          -- the choice's own and the Application answers it (replay or refusal).
          Right a
            | maybe True (choiceFits (answerChoice a)) current -> do
                result <- applyDecision db (answerKey a) (decisionRequest (answerChoice a) key (answerExpected a) (answerText a) (answerAcknowledged a))
                case result of
                  Left _ -> pure notReady
                  Right (Right receipt)
                    | receiptApplied receipt -> pure (pathAnswer (decisionLink key) (donePage receipt Nothing))
                    | otherwise -> decisionAnswer db key (Just (decisionRefusalWords (fromMaybe "" (receiptRefusal receipt))))
                  Right (Left code) -> decisionAnswer db key (Just (decisionRefusalWords code))
          _ -> decisionAnswer db key (Just unreadableTryAgain)

-- * Answers

-- | The project page, with its address for the page's history.
projectAnswer :: DatabaseRuntime -> ProjectView -> Maybe T.Text -> IO Wai.Response
projectAnswer db view notice =
  pathAnswer (projectLink (projectKey view)) <$> projectPage db view notice

-- | The task page, with its address for the page's history (C-P3.6 K6).
taskAnswer :: DatabaseRuntime -> TaskView -> Maybe T.Text -> IO Wai.Response
taskAnswer db task notice = do
  project <- findProject db (taskProject task)
  siblings <- fromRight [] <$> listTasks db (taskProject task)
  folders <- projectFoldersFromEnvironment
  status <- fromRight Nothing <$> executionStatus db folders (taskProject task)
  admission <- fromRight Nothing <$> findAdmission db (taskId task)
  standing <-
    case admission of
      Nothing -> pure Nothing
      Just a -> do
        checks <- projectChecks db (taskProject task)
        pure $ case checks of
          Right (Just pc) -> either (const Nothing) (fmap entryStanding . L.find ((== admissionWorkOrder a) . entryOrder)) (checksQueue pc)
          _ -> Nothing
  work <-
    case admission of
      Nothing -> pure Nothing
      Just a -> do
        tx <- transactionForWorkOrder db (admissionWorkOrder a)
        case tx of
          Right (Just v) -> do
            request <- haltRequest db (viewKey v)
            pure (Just (v, fromRight Nothing request))
          _ -> pure Nothing
  key <- idempotencyKeyText <$> generateIdempotencyKey
  case project of
    Right (Just p) ->
      pure (pathAnswer (taskLink (taskKey task)) (taskPage p siblings task (isJust work) (taskFixingSection task status admission standing work key) notice))
    Right Nothing -> pure notFound
    Left _ -> pure notReady

-- | The task page of a transaction's task, after a person's decision about it (C-P4.16).
transactionAnswer :: DatabaseRuntime -> TransactionView -> Maybe T.Text -> IO Wai.Response
transactionAnswer db tx notice = do
  found <- findTaskById db (viewTask tx)
  case found of
    Right (Just task) -> taskAnswer db task notice
    Right Nothing -> pure notFound
    Left _ -> pure notReady

{- | Words for the code of a refused halt answer and (below) completion: the
codes of the frozen @Either Text@ conversation and completion boundaries. A code
without its own words gets the one general sentence.
-}
haltAnswerWords :: T.Text -> T.Text
haltAnswerWords code =
  case T.unpack code of
    "request-closed" -> "This question was already answered."
    "stale-revision" -> "The question changed since this page was shown. Look at it again."
    "unknown-choice" -> "Choose one of the answers shown."
    "key-conflict" -> "This form was already used for a different answer. Look at the fix again."
    _ -> "Lockstep could not record this answer. Look at the fix again."

completionWords :: T.Text -> T.Text
completionWords code =
  case T.unpack code of
    "closed" -> "This fix is already decided."
    "illegal-input" -> "This fix is not ready for your decision yet."
    "unknown-choice" -> "Choose whether this bug is fixed."
    "stale-step" -> "The fix changed while you were looking. Here it is as it stands now."
    _ -> "Lockstep could not record this decision. Look at the fix again."

-- | An HTML answer with the address the page's history should show (generated from its route).
pathAnswer :: B.RelativeURL B.Get -> LBS.ByteString -> Wai.Response
pathAnswer path =
  respondWith HTTP.status200 [(HTTP.hContentType, "text/html; charset=utf-8"), ("X-Lockstep-Path", TE.encodeUtf8 (B.relativeURLToText path))]

-- | The decision as it stands now: its page while open, what was decided once closed, else 404 (C-P3.8 M6).
decisionAnswer :: DatabaseRuntime -> DecisionKey -> Maybe T.Text -> IO Wai.Response
decisionAnswer db key notice = do
  open <- findDecision db (decisionKeyText key)
  case open of
    Left _ -> pure notReady
    Right (Just decision) -> do
      formKey' <- idempotencyKeyText <$> generateIdempotencyKey
      pure (pathAnswer (decisionLink key) (decisionPage decision formKey' notice))
    Right Nothing -> do
      decided <- decidedReceipt db (decisionKeyText key)
      pure $
        case decided of
          Left _ -> notReady
          Right (Just receipt) -> pathAnswer (decisionLink key) (donePage receipt notice)
          Right Nothing -> notFound

-- | The checks page as it is now, with its address for the page's history (C-P3.7 L7).
checksAnswer :: DatabaseRuntime -> ProjectId -> ProjectChecks -> Maybe T.Text -> IO Wai.Response
checksAnswer db pid before notice = do
  latest <- projectChecks db (identityText pid)
  let
    pc = either (const before) (fromMaybe before) latest
  pure (pathAnswer (checksLink pid) (checksPage pc notice))

-- * Sections

renderSection :: DatabaseRuntime -> Section -> Session -> IO LBS.ByteString
renderSection db section session =
  case section of
    Home -> home db
    Projects -> projectsOverview db
    Tasks -> do
      projects <- listProjects db
      tasks <- listAllTasks db
      pure $ case (projects, tasks) of
        (Right ps, Right ts) -> tasksOverview [(p, [t | t <- ts, taskProjectKey t == projectKey p]) | p <- ps] True
        _ -> tasksOverview [] False
    Decisions -> decisionsOverview . either (const Nothing) Just <$> listDecisions db
    Activity -> activityPage <$> readActivity db
    Settings -> do
      projects <- fromRight [] <$> listProjects db
      pure . fragment $
        [ E.h1 [] [E.text "Settings"]
        , E.p [] [E.text "Installing, updating, starting and stopping Lockstep happen in the control pane, and so does choosing which folders on this computer Lockstep may see (Project folders). To open it, run lockstep on this computer."]
        , E.h2 [] [E.text "How work is checked"]
        , E.p [] [E.text "Each project chooses which checks its work must pass, on top of the rules that always apply."]
        ]
          <> [ E.ul [cls "ls-projects"] [E.li [] [E.a [A.href (checksLink (projectKey p))] [E.text (projectName p)]] | p <- projects]
             | not (L.null projects)
             ]
    Advanced -> advanced db session

statusWords :: ProjectView -> T.Text
statusWords view =
  case projectSetup view of
    Organized -> "Organized; no folder yet."
    Connected -> "Its folder is connected."
    SetupFailed -> "Setup did not finish."

projectsOverview :: DatabaseRuntime -> IO LBS.ByteString
projectsOverview db = do
  listed <- listProjects db
  let
    projects = fromRight [] listed
    item view =
      E.li
        []
        [ E.a [A.href (projectLink (projectKey view))] [E.text (projectName view)]
        , E.text (" \8212 " <> statusWords view)
        ]
  pure . fragment $
    [ E.h1 [] [E.text "Projects"]
    , E.p [] [E.text "A project is something you want to achieve, with the folder its work lives in."]
    , E.p [] [E.a [A.href newProjectLink, A.id (elementId 'n' "ew-project"), cls "ls-button-link"] [E.text "New project"]]
    , case listed of
        Left _ -> E.p [cls "ls-notice"] [E.text "Lockstep's database is not ready, so the projects cannot be shown. Run lockstep to see what to do."]
        Right [] -> E.p [] [E.text "There are no projects yet."]
        Right _ -> E.ul [cls "ls-projects"] (fmap item projects)
    , E.p [cls "ls-muted"] [E.text "Running the work inside a project arrives in a later update of Lockstep."]
    ]

folderOptions :: [FilePath] -> T.Text -> [E.ChildHTML E.Select grandparent]
folderOptions offered selected =
  [ E.option ([attr "value" p'] <> [attr "selected" "selected" | p' == selected]) [E.text p']
  | p <- offered
  , let
      p' = T.pack p
  ]

newProjectPage :: DatabaseRuntime -> T.Text -> ProjectForm -> Maybe T.Text -> IO LBS.ByteString
newProjectPage db key form notice = do
  folders <- projectFoldersFromEnvironment
  offered <- offeredFolders db folders
  let
    choice value label extra =
      let
        choiceId = elementId 'f' ("older-" <> value)
      in
        E.div
          [cls "ls-choice"]
          ( [ E.input
                ( [ A.type_ HTML.InputRadio
                  , A.id choiceId
                  , A.name folderField
                  , attr "value" value
                  ]
                    <> [attr "checked" "checked" | formFolder form == value]
                )
            , E.label [A.for choiceId] [E.text label]
            ]
              <> extra
          )
    nameId = elementId 'p' "roject-name"
    outcomeId = elementId 'p' "roject-outcome"
    folderChoiceId = elementId 'f' "older-choice"
    existingPart =
      if L.null offered
        then [E.p [cls "ls-muted"] [E.text "No folders are available yet. To use one already on this computer, add it in the control pane under Project folders (run lockstep to open it)."]]
        else
          [ E.label [A.for folderChoiceId, cls "ls-label"] [E.text "Folder"]
          , E.select [A.id folderChoiceId, A.name pathField] (folderOptions offered (formPath form))
          ]
  pure . fragment $
    [ E.h1 [] [E.text "New project"]
    ]
      <> [E.p [cls "ls-notice", attr "role" "alert"] [E.text n] | Just n <- [notice]]
      <> [ E.form
             [A.id (elementId 'p' "roject-form"), A.method B.FormPOST, A.action createProjectAction]
             [ E.input [A.type_ HTML.InputHidden, A.name keyField, attr "value" key]
             , E.div
                 [cls "ls-field"]
                 [ E.label [A.for nameId] [E.text "Name"]
                 , E.input [A.type_ HTML.InputText, A.id nameId, A.name nameField, attr "value" (formName form), attr "maxlength" "80", attr "required" "required"]
                 ]
             , E.div
                 [cls "ls-field"]
                 [ E.label [A.for outcomeId] [E.text "What should it achieve?"]
                 , E.textarea [A.id outcomeId, A.name outcomeField, attr "rows" "4", attr "maxlength" "2000"] (formOutcome form)
                 ]
             , E.fieldset
                 []
                 [ E.legend [] [E.text "Where should its files live?"]
                 , choice "new" "In a new folder Lockstep makes for it (recommended)" []
                 , choice "existing" "In a folder that is already on this computer" existingPart
                 , choice "later" "Decide later" []
                 ]
             , E.button [A.id (elementId 'c' "reate-project"), attr "type" "submit", cls "ls-primary"] [E.text "Create project"]
             ]
         , E.p [] [E.a [A.href (sectionLink Projects)] [E.text "Back to Projects"]]
         ]

projectPage :: DatabaseRuntime -> ProjectView -> Maybe T.Text -> IO LBS.ByteString
projectPage db view notice = do
  folders <- projectFoldersFromEnvironment
  offered <- offeredFolders db folders
  tasks <- fromRight [] <$> listTasks db (projectId view)
  checks <- projectChecks db (projectId view)
  execution <- fromRight Nothing <$> executionStatus db folders (projectId view)
  started <- projectStarted db (projectKey view)
  executionKey <- idempotencyKeyText <$> generateIdempotencyKey
  let
    connectNewId = elementId 'c' "onnect-new"
    connectExistingId = elementId 'c' "onnect-existing"
    status =
      case projectSetup view of
        Connected ->
          [ E.p [cls "ls-good-text"] [E.text ("Lockstep can see this folder: " <> fromMaybe "" (projectFolder view))]
          , case started of
              Right True -> E.p [] [E.text "Lockstep works in it only on bugs you hand it, and commits each fix only on its own branch there. It sends nothing anywhere."]
              Right False -> E.p [] [E.text "It cannot change it or run anything in it yet; that arrives in a later update of Lockstep."]
              -- Not read: said so, never shown as "not started".
              Left _ -> E.p [cls "ls-notice", A.id (elementId 'p' "roject-started-unknown")] [E.text "Lockstep could not read whether it has started work in this folder. Reload the page to try again."]
          ]
        Organized ->
          [ E.p [] [E.text "This project is organized but has no folder yet. Its files will live in a folder you choose below."]
          , connectForm "Connect a folder"
          ]
        SetupFailed ->
          [ E.p [cls "ls-notice"] [E.text ("Setup did not finish: " <> maybe "" refusalWords (projectRefusal view))]
          , E.p [] [E.text keptFolderWords]
          , connectForm "Try again"
          ]
    -- C-C.R1 R6-1: a folder an attempt made is kept; one no project uses is offered below.
    keptFolderWords =
      "If Lockstep made a new folder for this project, it was kept and nothing in it was removed. To use it, choose it under \"In this folder\" below."
    connectForm label =
      E.form
        [A.method B.FormPOST, A.action (connectProjectAction (projectKey view))]
        [ E.input [A.type_ HTML.InputHidden, A.name revisionField, attr "value" (T.pack (show (projectRevision view)))]
        , E.fieldset
            []
            ( [ E.legend [] [E.text "Where should its files live?"]
              , E.div
                  [cls "ls-choice"]
                  [ E.input [A.type_ HTML.InputRadio, A.id connectNewId, A.name folderField, attr "value" "new", attr "checked" "checked"]
                  , E.label [A.for connectNewId] [E.text "In a new folder Lockstep makes for it"]
                  ]
              ]
                <> [ E.div
                       [cls "ls-choice"]
                       [ E.input [A.type_ HTML.InputRadio, A.id connectExistingId, A.name folderField, attr "value" "existing"]
                       , E.label [A.for connectExistingId] [E.text "In this folder: "]
                       , E.select [A.id (elementId 'c' "onnect-choice"), A.name pathField, attr "aria-label" "Folder"] (folderOptions offered "")
                       ]
                   | not (L.null offered)
                   ]
            )
        , E.button [A.id (elementId 'c' "onnect-project"), attr "type" "submit", cls "ls-primary"] [E.text label]
        ]
    outcome =
      if T.null (projectOutcome view)
        then E.p [cls "ls-muted"] [E.text "What it should achieve is not written down yet."]
        else E.p [cls "ls-outcome"] [E.text (projectOutcome view)]
  pure . fragment $
    [ E.h1 [] [E.text (projectName view)]
    ]
      <> [E.p [cls "ls-notice", attr "role" "alert"] [E.text n] | Just n <- [notice]]
      <> [ E.h2 [] [E.text "What it should achieve"]
         , outcome
         ]
      <> projectTasks view tasks
      <> either (const []) (maybe [] projectChecksSection) checks
      <> projectExecutionSection view execution (started == Right True) executionKey
      <> [E.h2 [] [E.text "Its folder"]]
      <> status
      <> [ E.details
             []
             [ E.summary [] [E.text "Technical details"]
             , E.dl
                 [cls "ls-facts"]
                 [ E.dt [] [E.text "Project"]
                 , E.dd [] [E.code [] [E.text (projectId view)]]
                 , E.dt [] [E.text "Setup"]
                 , E.dd [] [E.code [] [E.text (setupStateCode (projectSetup view) <> maybe "" (" " <>) (projectRefusal view))]]
                 , E.dt [] [E.text "Engineer"]
                 , E.dd [] [E.code [] [E.text (fromMaybe "none yet" (projectEngineer view))]]
                 , E.dt [] [E.text "Revision"]
                 , E.dd [] [E.code [] [E.text (T.pack (show (projectRevision view)))]]
                 ]
             ]
         , E.p [] [E.a [A.href (sectionLink Projects)] [E.text "Back to Projects"]]
         ]

home :: DatabaseRuntime -> IO LBS.ByteString
home db = do
  readiness <- checkReadiness (Just db)
  workspace <- readWorkspace db
  projection <- projectLedger db
  projects <- listProjects db
  open <- fromRight [] <$> listDecisions db
  let
    name = either (const "Lockstep") workspaceName workspace
    orders = either (const []) projectionOrders projection
    tickets = either (const 0) (L.length . projectionTickets) projection
    projectCount = either (const 0) L.length projects
    failed = either (const 0) (L.length . L.filter ((== SetupFailed) . projectSetup)) projects
    waiting = L.length [() | o <- orders, e <- orderLineEffects o, effectLineStatus e `L.elem` [StatusReconciliationNeeded, StatusUnknown, StatusBlocked]]
    attention =
      [E.li [] [E.text ("Lockstep's database is not ready: " <> reasonText r <> ". Open the control pane (run lockstep) to see what to do.")] | NotReady r <- [readiness]]
        <> [E.li [] [E.text (T.pack (show (L.length open)) <> " decision(s) need you: "), E.a [A.href (sectionLink Decisions)] [E.text "Decisions"]] | not (L.null open)]
        <> [E.li [] [E.text (T.pack (show waiting) <> " piece(s) of work are waiting for a person to look at them.")] | waiting > 0]
        <> [E.li [] [E.text (T.pack (show failed) <> " project(s) did not finish setting up. Open Projects to try again.")] | failed > 0]
    stateLine =
      case readiness of
        Ready revision -> "Lockstep's database is ready (schema revision " <> T.pack (show (revisionNumber revision)) <> ")."
        NotReady r -> "Lockstep's database is not ready: " <> reasonText r <> "."
  pure . fragment $
    [ E.h1 [] [E.text "Home"]
    , E.p [cls "ls-muted"] [E.text ("Workspace: " <> name)]
    , E.h2 [] [E.text "What needs your attention"]
    , if L.null attention
        then E.p [] [E.text "Nothing needs your attention right now."]
        else E.ul [] attention
    , E.h2 [] [E.text "Where things stand"]
    , E.ul
        []
        [ E.li [] [E.text stateLine]
        , E.li [] [E.text (T.pack (show projectCount) <> " project(s), " <> T.pack (show tickets) <> " ticket(s) and " <> T.pack (show (L.length orders)) <> " work order(s) are recorded.")]
        ]
    , E.h2 [] [E.text "Next steps"]
    , E.p
        []
        [ E.text (if projectCount == 0 then "Start by creating a project: " else "See your projects: ")
        , E.a [A.href (sectionLink Projects)] [E.text "Projects"]
        , E.text ". Anything only you can decide is under Decisions."
        ]
    ]

reasonText :: NotReadyReason -> T.Text
reasonText reason =
  case reason of
    DatabaseNotConfigured -> "Lockstep has not been set up yet"
    DatabaseUnreachable -> "the database server cannot be reached"
    AuthenticationFailed -> "the database refused Lockstep's password"
    DatabaseMissing -> "the database does not exist yet"
    SchemaBehind _ -> "the database needs an upgrade before this version can use it"
    SchemaInvalid _ -> "the database belongs to a different version of Lockstep"
    DatabaseError -> "the database reported an error"
    DatabaseCorrupt _ -> "some stored data failed its integrity check"

advanced :: DatabaseRuntime -> Session -> IO LBS.ByteString
advanced db session = do
  readiness <- checkReadiness (Just db)
  folders <- projectFoldersFromEnvironment
  let
    revision =
      case readiness of
        Ready r -> T.pack (show (revisionNumber r))
        NotReady _ -> "not ready"
    expires = T.pack (Time.formatTime Time.defaultTimeLocale "%Y-%m-%d %H:%M UTC" (sessionExpiresAt session))
    seen = maybe [] (\r -> [T.pack r <> " (projects folder)"]) (foldersRoot folders) <> fmap T.pack (foldersAdded folders)
  pure . fragment $
    [ E.h1 [] [E.text "Advanced"]
    , E.p [] [E.text "The exact technical facts behind what the other sections show."]
    , E.dl
        [cls "ls-facts"]
        ( [ E.dt [] [E.text "Schema revision"]
          , E.dd [] [E.code [] [E.text revision]]
          , E.dt [] [E.text "Session expires"]
          , E.dd [] [E.text expires]
          , E.dt [] [E.text "Folders this service can see"]
          ]
            <> (if L.null seen then [E.dd [] [E.text "none"]] else fmap (\f -> E.dd [] [E.code [] [E.text f]]) seen)
        )
    , E.h2 [] [E.text "Earlier technical views"]
    , E.p
        []
        [ E.text "The Phase 1 and 2 operator pages still work, with their own sign-in: "
        , E.a [A.href centerLink] [E.text "command center"]
        , E.text " and "
        , E.a [A.href ledgerLink] [E.text "ledger"]
        , E.text "."
        ]
    ]
