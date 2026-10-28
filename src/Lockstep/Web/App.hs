{-# LANGUAGE OverloadedStrings #-}

{- | The application shell on the service (contract C-P3.4 A1–A7): the same
trust model as the control pane (T2–T7). Every page address returns one
content-free shell; the sections are server-rendered Brigid fragments fetched
by the page with the @X-Lockstep-Session@ header. The one-time token and the
session are those of C-P1.3, stored as digests; no cookie is read or set here.
Projects (contract C-P3.5 J9) add an overview, a new-project form and a page
per project.
-}
module Lockstep.Web.App
  ( AppRoute
  , matchAppRoute
  , appRouteClass
  , handleApp
  ) where

import Brigid.HTML.Attributes qualified as A
import Brigid.HTML.Elements qualified as E
import Brigid.HTML.Types qualified as HTML
import Brigid.Types qualified as B
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TEE
import Data.Time qualified as Time
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTP
import Network.Wai qualified as Wai
import System.IO (FilePath)
import Text.Read (readMaybe)
import Text.Show (show)

import Lockstep.Application.Activity (readActivity)
import Lockstep.Application.Command (WorkspaceState (..), generateIdempotencyKey, idempotencyKeyText, mkIdempotencyKey, readWorkspace)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason (..), Readiness (..), checkReadiness, revisionNumber)
import Lockstep.Application.Decisions (DecisionReceipt (..), OpenDecision (..), applyDecision, decidedReceipt, findDecision, listDecisions)
import Lockstep.Application.LedgerView (EffectLine (..), LedgerProjection (..), OrderLine (..), projectLedger)
import Lockstep.Application.OperatorTrust (Session (..), exchangeSignIn, lookupSession, revokeSession)
import Lockstep.Application.ProjectChecks (ChecksOutcome (..), ExpectedChecks (..), ProjectChecks, chooseChecksExpecting, projectChecks)
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
  , listAllTasks
  , listTasks
  )
import Lockstep.Foundation.OperatorToken (decodeToken, encodeToken)
import Lockstep.Kernel.Decision (DecisionRequest (..), decisionRefusalWords)
import Lockstep.Kernel.Effect (OperationId (..))
import Lockstep.Kernel.EffectView (EffectStatus (..))
import Lockstep.Kernel.Identity (WorkOrderId (..), parseUuid)
import Lockstep.Kernel.Policy (checksRefusalWords, lossWords)
import Lockstep.Kernel.Project (SetupState (..), parseFolderChoice, refusalWords, setupStateCode)
import Lockstep.Kernel.Task (parsePriority, taskRefusalWords)
import Lockstep.Web.ActivityPage (activityPage)
import Lockstep.Web.ChecksPages (checksPage, choiceLosses, projectChecksSection)
import Lockstep.Web.DecisionPages (decisionPage, decisionsOverview, donePage)
import Lockstep.Web.Fragment (attr, cls, fragment, href)
import Lockstep.Web.RequestGuard (RouteClass (..))
import Lockstep.Web.SecureResponse (errorJson, htmlResponse, jsonResponse, jsonString, readBodyLimited, respondWith)
import Lockstep.Web.TaskPages (TaskForm (..), emptyTaskForm, newTaskPage, projectTasks, taskPage, tasksOverview)

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

parseSection :: T.Text -> Maybe Section
parseSection t =
  L.find ((== t) . sectionPath) [minBound .. maxBound]

data AppRoute
  = Shell
  | Fragment Section
  | NewProjectFragment
  | ProjectFragment T.Text
  | CreateProject
  | ConnectProject T.Text
  | NewTaskFragment T.Text
  | TaskFragment T.Text
  | CreateTaskRoute T.Text
  | EditTaskRoute T.Text
  | DecideTaskRoute T.Text
  | ChecksFragment T.Text
  | ChooseChecksRoute T.Text
  | DecisionFragment T.Text
  | DecideRoute T.Text
  | ExchangeSession
  | SignOut

validId :: T.Text -> Bool
validId =
  either (const False) (const True) . parseUuid

matchAppRoute :: HTTP.Method -> [T.Text] -> Maybe AppRoute
matchAppRoute method path =
  let
    get = method == HTTP.methodGet || method == HTTP.methodHead
    post = method == HTTP.methodPost
  in
    case path of
      ["app"] | get -> Just Shell
      ["app", "sign-in"] | get -> Just Shell
      ["app", s] | get, Just _ <- parseSection s -> Just Shell
      ["app", "projects", "new"] | get -> Just Shell
      ["app", "projects", pid] | get, validId pid -> Just Shell
      ["app", "fragments", "project-new"] | get -> Just NewProjectFragment
      ["app", "projects", pid, "tasks", "new"] | get, validId pid -> Just Shell
      ["app", "tasks", tid] | get, validId tid -> Just Shell
      ["app", "projects", pid, "checks"] | get, validId pid -> Just Shell
      ["app", "fragments", "project-checks", pid] | get, validId pid -> Just (ChecksFragment pid)
      ["app", "api", "projects", pid, "checks"] | post, validId pid -> Just (ChooseChecksRoute pid)
      ["app", "decisions", did] | get, validId did -> Just Shell
      ["app", "fragments", "decision", did] | get, validId did -> Just (DecisionFragment did)
      ["app", "api", "decisions", did] | post, validId did -> Just (DecideRoute did)
      ["app", "fragments", "project", pid] | get, validId pid -> Just (ProjectFragment pid)
      ["app", "fragments", "task-new", pid] | get, validId pid -> Just (NewTaskFragment pid)
      ["app", "fragments", "task", tid] | get, validId tid -> Just (TaskFragment tid)
      ["app", "fragments", s] | get -> Fragment <$> parseSection s
      ["app", "api", "projects", pid, "tasks"] | post, validId pid -> Just (CreateTaskRoute pid)
      ["app", "api", "tasks", tid, "edit"] | post, validId tid -> Just (EditTaskRoute tid)
      ["app", "api", "tasks", tid, "decide"] | post, validId tid -> Just (DecideTaskRoute tid)
      ["app", "api", "session"] | post -> Just ExchangeSession
      ["app", "api", "sign-out"] | post -> Just SignOut
      ["app", "api", "projects"] | post -> Just CreateProject
      ["app", "api", "projects", pid, "connect"] | post, validId pid -> Just (ConnectProject pid)
      _ -> Nothing

-- | The shell is public; everything that carries data or acts needs the exact Host (and Origin for POST).
appRouteClass :: AppRoute -> RouteClass
appRouteClass route =
  case route of
    Shell -> PublicRead
    _ -> OperatorRoute

shell :: Wai.Response
shell =
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

handleApp :: Maybe DatabaseRuntime -> AppRoute -> Wai.Request -> IO Wai.Response
handleApp mbDb route request =
  case route of
    Shell -> pure shell
    _ ->
      case mbDb of
        Nothing -> pure (errorJson HTTP.status503 "no-database")
        Just db -> handleWithDatabase db route request

sessionHeader :: Wai.Request -> Maybe T.Text
sessionHeader request =
  TE.decodeLatin1 <$> L.lookup "X-Lockstep-Session" (Wai.requestHeaders request)

notReady :: Wai.Response
notReady =
  errorJson HTTP.status503 "not-ready"

handleWithDatabase :: DatabaseRuntime -> AppRoute -> Wai.Request -> IO Wai.Response
handleWithDatabase db route request =
  case route of
    Shell -> pure shell
    ExchangeSession -> do
      body <- readBodyLimited request 4096
      case body of
        Nothing -> pure (errorJson HTTP.status413 "too-large")
        Just bytes ->
          case decodeToken (TE.decodeUtf8With TEE.lenientDecode bytes) of
            Nothing -> pure (errorJson HTTP.status403 "sign-in-refused")
            Just token -> do
              exchanged <- exchangeSignIn db token
              pure $ case exchanged of
                Right session -> jsonResponse HTTP.status200 ("{\"session\":" <> jsonString (encodeToken session) <> "}")
                Left _ -> errorJson HTTP.status403 "sign-in-refused"
    SignOut -> do
      _ <- readBodyLimited request 4096
      withSession $ \token _ -> do
        _ <- revokeSession db token
        pure (respondWith HTTP.status204 [] "")
    Fragment section ->
      withSession $ \_ session -> do
        html <- renderSection db section session
        pure (htmlResponse HTTP.status200 html)
    NewProjectFragment ->
      withSession $ \_ _ -> do
        key <- idempotencyKeyText <$> generateIdempotencyKey
        page <- newProjectPage db key emptyForm Nothing
        pure (htmlResponse HTTP.status200 page)
    ProjectFragment pid ->
      withSession $ \_ _ -> do
        found <- findProject db pid
        case found of
          Right (Just view) -> htmlResponse HTTP.status200 <$> projectPage db view Nothing
          Right Nothing -> pure (errorJson HTTP.status404 "not-found")
          Left _ -> pure notReady
    CreateProject ->
      withForm $ \fields -> do
        let
          form = formFrom fields
        case (mkIdempotencyKey (formKey form), parseFolderChoice (formFolder form) (formPathMaybe form)) of
          (Left _, _) -> htmlResponse HTTP.status200 <$> newProjectPage db (formKey form) form (Just "Lockstep could not read this form. Open New project again.")
          (_, Nothing) -> htmlResponse HTTP.status200 <$> newProjectPage db (formKey form) form (Just "Choose where the project's files should live.")
          (Right key, Just choice) -> do
            folders <- projectFoldersFromEnvironment
            created <- createProject db folders (NewProject key (formName form) (formOutcome form) choice)
            case created of
              Left _ -> pure notReady
              Right (Left code) -> htmlResponse HTTP.status200 <$> newProjectPage db (formKey form) form (Just (refusalWords code))
              Right (Right view) -> projectAnswer db view Nothing
    ConnectProject pid ->
      withForm $ \fields -> do
        let
          value name = TE.decodeUtf8With TEE.lenientDecode <$> L.lookup name fields
          revision = value "revision" >>= decimalUpTo bigintMax
          choice = value "folder" >>= \f -> parseFolderChoice f (value "path")
        folders <- projectFoldersFromEnvironment
        current <- findProject db pid
        case (current, revision, choice) of
          (Left _, _, _) -> pure notReady
          (Right Nothing, _, _) -> pure (errorJson HTTP.status404 "not-found")
          (Right (Just view), Nothing, _) -> projectAnswer db view (Just "Lockstep could not read this form. Try again.")
          (Right (Just view), _, Nothing) -> projectAnswer db view (Just "Choose where the project's files should live.")
          (Right (Just view), Just r, Just c) -> do
            connected <- connectProject db folders pid r c
            case connected of
              Left _ -> pure notReady
              Right (Right updated) -> projectAnswer db updated Nothing
              Right (Left code) -> do
                latest <- findProject db pid
                projectAnswer db (either (const view) (fromMaybe view) latest) (Just (refusalWords code))
    NewTaskFragment pid ->
      withSession $ \_ _ -> do
        found <- findProject db pid
        case found of
          Left _ -> pure notReady
          Right Nothing -> pure (errorJson HTTP.status404 "not-found")
          Right (Just project) -> do
            key <- idempotencyKeyText <$> generateIdempotencyKey
            others <- fromRight [] <$> listTasks db pid
            pure (htmlResponse HTTP.status200 (newTaskPage project others (emptyTaskForm key) Nothing))
    TaskFragment tid ->
      withSession $ \_ _ -> do
        found <- findTask db tid
        case found of
          Right (Just task) -> taskAnswer db task Nothing
          Right Nothing -> pure (errorJson HTTP.status404 "not-found")
          Left _ -> pure notReady
    CreateTaskRoute pid ->
      withForm $ \fields -> do
        let
          form = taskFormFrom fields
        found <- findProject db pid
        case found of
          Left _ -> pure notReady
          Right Nothing -> pure (errorJson HTTP.status404 "not-found")
          Right (Just project) -> do
            others <- fromRight [] <$> listTasks db pid
            let
              again notice = pure (htmlResponse HTTP.status200 (newTaskPage project others form (Just notice)))
            case (mkIdempotencyKey (formTaskKey form), parsePriority (formTaskPriority form)) of
              (Left _, _) -> again "Lockstep could not read this form. Open New task again."
              (_, Nothing) -> again (taskRefusalWords "unknown-priority")
              (Right key, Just priority) -> do
                created <- createTask db (NewTask key pid (formTaskTitle form) (formTaskAcceptance form) priority (formTaskDependencies form))
                case created of
                  Left _ -> pure notReady
                  Right (Left code) -> again (taskRefusalWords code)
                  Right (Right task) -> taskAnswer db task Nothing
    EditTaskRoute tid ->
      withForm $ \fields -> do
        let
          form = taskFormFrom fields
          revision = L.lookup "revision" fields >>= decimalUpTo bigintMax . TE.decodeUtf8With TEE.lenientDecode
        found <- findTask db tid
        case found of
          Left _ -> pure notReady
          Right Nothing -> pure (errorJson HTTP.status404 "not-found")
          Right (Just task) ->
            case (revision, parsePriority (formTaskPriority form)) of
              (Nothing, _) -> taskAnswer db task (Just "Lockstep could not read this form. Try again.")
              (_, Nothing) -> taskAnswer db task (Just (taskRefusalWords "unknown-priority"))
              (Just r, Just priority) -> do
                edited <- editTask db tid r (TaskEdit (formTaskTitle form) (formTaskAcceptance form) priority (formTaskDependencies form))
                case edited of
                  Left _ -> pure notReady
                  Right (Right updated) -> taskAnswer db updated Nothing
                  Right (Left code) -> do
                    latest <- findTask db tid
                    taskAnswer db (either (const task) (fromMaybe task) latest) (Just (taskRefusalWords code))
    DecideTaskRoute tid ->
      withForm $ \fields -> do
        let
          value name = TE.decodeUtf8With TEE.lenientDecode <$> L.lookup name fields
          revision = L.lookup "ticket_revision" fields >>= decimalUpTo integerMax . TE.decodeUtf8With TEE.lenientDecode
          decision =
            case value "action" of
              Just "ready" -> Just MarkReady
              Just "block" -> Just (BlockTask (fromMaybe "" (value "reason")))
              Just "unblock" -> Just UnblockTask
              Just "cancel" -> Just CancelTask
              _ -> Nothing
        found <- findTask db tid
        case (found, revision, decision) of
          (Left _, _, _) -> pure notReady
          (Right Nothing, _, _) -> pure (errorJson HTTP.status404 "not-found")
          (Right (Just task), Just r, Just d) -> do
            decided <- decideTask db "application" tid r d
            case decided of
              Left _ -> pure notReady
              Right (Right updated) -> taskAnswer db updated Nothing
              Right (Left code) -> do
                latest <- findTask db tid
                taskAnswer db (either (const task) (fromMaybe task) latest) (Just (taskRefusalWords code))
          (Right (Just task), _, _) -> taskAnswer db task (Just "Lockstep could not read this form. Try again.")
    ChecksFragment pid ->
      withSession $ \_ _ -> do
        found <- projectChecks db pid
        case found of
          Right (Just pc) -> pure (htmlResponse HTTP.status200 (checksPage pc Nothing))
          Right Nothing -> pure (errorJson HTTP.status404 "not-found")
          Left _ -> pure notReady
    ChooseChecksRoute pid ->
      withForm $ \fields -> do
        let
          value name = TE.decodeUtf8With TEE.lenientDecode <$> L.lookup name fields
          confirmed = value "confirm_fewer" == Just "yes"
          -- C-C.R1 R10: with expected_set the value is taken literally; without it, the C-P3.7 text.
          expectation =
            case (value "expected", value "expected_set") of
              (Just e, Nothing) -> Just (if e == "none" then ExpectNothing else ExpectProfile e)
              (Just e, Just "yes") -> Just (ExpectProfile e)
              (Just _, Just "no") -> Just ExpectNothing
              _ -> Nothing
        found <- projectChecks db pid
        case (found, expectation, value "choice") of
          (Left _, _, _) -> pure notReady
          (Right Nothing, _, _) -> pure (errorJson HTTP.status404 "not-found")
          (Right (Just before), Just expected, Just choice) -> do
            chosen <- chooseChecksExpecting db pid expected choice confirmed
            case chosen of
              Left _ -> pure notReady
              Right (Right ChecksChosen) -> checksAnswer db pid before (Just "Saved.")
              Right (Right ChecksUnchanged) -> checksAnswer db pid before (Just "Saved. This was already the choice.")
              Right (Left code) -> do
                let
                  losses = choiceLosses before choice
                  lost =
                    if code == "fewer-checks-unconfirmed" && not (L.null losses)
                      then " It would stop requiring " <> T.intercalate "; " (fmap lossWords losses) <> "."
                      else ""
                checksAnswer db pid before (Just (checksRefusalWords code <> lost))
          (Right (Just before), _, _) -> checksAnswer db pid before (Just "Lockstep could not read this form. Try again.")
    DecisionFragment did ->
      withSession $ \_ _ -> decisionAnswer db did Nothing
    DecideRoute did ->
      withForm $ \fields -> do
        let
          value name = TE.decodeUtf8With TEE.lenientDecode <$> L.lookup name fields
          expected = value "expected" >>= decimalUpTo integerMax
          text = fromMaybe "" (value "text")
          acknowledged = value "acknowledge" == Just "yes"
          wanted =
            case (parseUuid did, value "choice", expected) of
              (Right u, Just choice, Just e) ->
                case choice of
                  "put-back" -> Just (PutBackInLine (WorkOrderId u) e)
                  "cancel" -> Just (CancelWork (WorkOrderId u) e)
                  "happened" -> Just (ItHappened (OperationId u) e text)
                  "did-not-happen" -> Just (ItDidNotHappen (OperationId u) e text)
                  "try-again" -> Just (TryAgain (OperationId u) e acknowledged)
                  "give-up" -> Just (GiveUp (OperationId u) e text acknowledged)
                  _ -> Nothing
              _ -> Nothing
        open <- findDecision db did
        decided <- decidedReceipt db did
        case (open, decided) of
          (Left _, _) -> pure notReady
          (_, Left _) -> pure notReady
          (Right Nothing, Right Nothing) -> pure (errorJson HTTP.status404 "not-found")
          (Right current, _) ->
            case (wanted, value "key" >>= either (const Nothing) Just . mkIdempotencyKey) of
              (Just r, Just k)
                | maybe True (fits r) current -> do
                    result <- applyDecision db k r
                    case result of
                      Left _ -> pure notReady
                      Right (Right receipt)
                        | receiptOutcome receipt == "applied" -> pure (pathAnswer ("/app/decisions/" <> did) (donePage receipt Nothing))
                        | otherwise -> decisionAnswer db did (Just (decisionRefusalWords (fromMaybe "" (receiptRefusal receipt))))
                      Right (Left code) -> decisionAnswer db did (Just (decisionRefusalWords code))
              _ -> decisionAnswer db did (Just "Lockstep could not read this form. Try again.")
 where
  withSession action =
    case sessionHeader request >>= decodeToken of
      Nothing -> pure (errorJson HTTP.status401 "signed-out")
      Just token -> do
        found <- lookupSession db token
        case found of
          Nothing -> pure (errorJson HTTP.status401 "signed-out")
          Just session -> action token session
  withForm action = do
    body <- readBodyLimited request 16384
    case body of
      Nothing -> pure (errorJson HTTP.status413 "too-large")
      Just bytes -> withSession $ \_ _ -> action (HTTP.parseSimpleQuery bytes)

{- | A form's number: plain decimal digits only (no sign, space or other
spelling), at most the stored range's largest value (C-C.R1 R3).
-}
decimalUpTo :: Num a => Integer -> T.Text -> Maybe a
decimalUpTo limit text
  | T.null text || T.length text > 19 || not (T.all Char.isDigit text) = Nothing
  | otherwise =
      case readMaybe (T.unpack text) :: Maybe Integer of
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

-- | The project page, with its address for the page's history.
projectAnswer :: DatabaseRuntime -> ProjectView -> Maybe T.Text -> IO Wai.Response
projectAnswer db view notice = do
  page <- projectPage db view notice
  pure (respondWith HTTP.status200 [(HTTP.hContentType, "text/html; charset=utf-8"), ("X-Lockstep-Path", TE.encodeUtf8 ("/app/projects/" <> projectId view))] page)

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

formFrom :: [(BS.ByteString, BS.ByteString)] -> ProjectForm
formFrom fields =
  let
    value name = maybe "" (TE.decodeUtf8With TEE.lenientDecode) (L.lookup name fields)
  in
    ProjectForm (value "key") (value "name") (value "outcome") (value "folder") (value "path")

formPathMaybe :: ProjectForm -> Maybe T.Text
formPathMaybe form =
  if T.null (formPath form) then Nothing else Just (formPath form)

-- | The task page, with its address for the page's history (C-P3.6 K6).
taskAnswer :: DatabaseRuntime -> TaskView -> Maybe T.Text -> IO Wai.Response
taskAnswer db task notice = do
  project <- findProject db (taskProject task)
  siblings <- fromRight [] <$> listTasks db (taskProject task)
  case project of
    Right (Just p) ->
      pure (respondWith HTTP.status200 [(HTTP.hContentType, "text/html; charset=utf-8"), ("X-Lockstep-Path", TE.encodeUtf8 ("/app/tasks/" <> taskId task))] (taskPage p siblings task notice))
    Right Nothing -> pure (errorJson HTTP.status404 "not-found")
    Left _ -> pure notReady

-- | An HTML answer with the address the page's history should show.
pathAnswer :: T.Text -> LBS.ByteString -> Wai.Response
pathAnswer path =
  respondWith HTTP.status200 [(HTTP.hContentType, "text/html; charset=utf-8"), ("X-Lockstep-Path", TE.encodeUtf8 path)]

-- | The decision as it stands now: its page while open, what was decided once closed, else 404 (C-P3.8 M6).
decisionAnswer :: DatabaseRuntime -> T.Text -> Maybe T.Text -> IO Wai.Response
decisionAnswer db did notice = do
  open <- findDecision db did
  case open of
    Left _ -> pure notReady
    Right (Just decision) -> do
      key <- idempotencyKeyText <$> generateIdempotencyKey
      pure (pathAnswer ("/app/decisions/" <> did) (decisionPage decision key notice))
    Right Nothing -> do
      decided <- decidedReceipt db did
      pure $
        case decided of
          Left _ -> notReady
          Right (Just receipt) -> pathAnswer ("/app/decisions/" <> did) (donePage receipt notice)
          Right Nothing -> errorJson HTTP.status404 "not-found"

-- | A choice belongs to its decision: stopped work is put back or canceled; an unknown outcome gets the other four.
fits :: DecisionRequest -> OpenDecision -> Bool
fits request decision =
  case (request, decision) of
    (PutBackInLine {}, StoppedWork _) -> True
    (CancelWork {}, StoppedWork _) -> True
    (_, UnknownOutcome _) -> case request of
      PutBackInLine {} -> False
      CancelWork {} -> False
      _ -> True
    _ -> False

-- | The checks page as it is now, with its address for the page's history (C-P3.7 L7).
checksAnswer :: DatabaseRuntime -> T.Text -> ProjectChecks -> Maybe T.Text -> IO Wai.Response
checksAnswer db pid before notice = do
  latest <- projectChecks db pid
  let
    pc = either (const before) (fromMaybe before) latest
  pure (respondWith HTTP.status200 [(HTTP.hContentType, "text/html; charset=utf-8"), ("X-Lockstep-Path", TE.encodeUtf8 ("/app/projects/" <> pid <> "/checks"))] (checksPage pc notice))

taskFormFrom :: [(BS.ByteString, BS.ByteString)] -> TaskForm
taskFormFrom fields =
  let
    value name = maybe "" (TE.decodeUtf8With TEE.lenientDecode) (L.lookup name fields)
  in
    TaskForm (value "key") (value "title") (value "acceptance") (value "priority") [TE.decodeUtf8With TEE.lenientDecode v | (k, v) <- fields, k == "depends_on"]

renderSection :: DatabaseRuntime -> Section -> Session -> IO LBS.ByteString
renderSection db section session =
  case section of
    Home -> home db
    Projects -> projectsOverview db
    Tasks -> do
      projects <- listProjects db
      tasks <- listAllTasks db
      pure $ case (projects, tasks) of
        (Right ps, Right ts) -> tasksOverview [(p, [t | t <- ts, taskProject t == projectId p]) | p <- ps] True
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
          <> [ E.ul [cls "ls-projects"] [E.li [] [E.a [href ("/app/projects/" <> projectId p <> "/checks")] [E.text (projectName p)]] | p <- projects]
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
        [ E.a [href ("/app/projects/" <> projectId view)] [E.text (projectName view)]
        , E.text (" \8212 " <> statusWords view)
        ]
  pure . fragment $
    [ E.h1 [] [E.text "Projects"]
    , E.p [] [E.text "A project is something you want to achieve, with the folder its work lives in."]
    , E.p [] [E.a [href "/app/projects/new", attr "id" "new-project", cls "ls-button-link"] [E.text "New project"]]
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
    choice name value label extra =
      E.div
        [cls "ls-choice"]
        ( [ E.input
              ( [ A.type_ HTML.InputRadio
                , attr "id" ("folder-" <> value)
                , attr "name" name
                , attr "value" value
                ]
                  <> [attr "checked" "checked" | formFolder form == value]
              )
          , E.label [attr "for" ("folder-" <> value)] [E.text label]
          ]
            <> extra
        )
    existingPart =
      if L.null offered
        then [E.p [cls "ls-muted"] [E.text "No folders are available yet. To use one already on this computer, add it in the control pane under Project folders (run lockstep to open it)."]]
        else
          [ E.label [attr "for" "folder-choice", cls "ls-label"] [E.text "Folder"]
          , E.select [attr "id" "folder-choice", attr "name" "path"] (folderOptions offered (formPath form))
          ]
  pure . fragment $
    [ E.h1 [] [E.text "New project"]
    ]
      <> [E.p [cls "ls-notice", attr "role" "alert"] [E.text n] | Just n <- [notice]]
      <> [ E.form
             [attr "id" "project-form", A.method B.FormPOST, A.action (B.mkRawURL "/app/api/projects")]
             [ E.input [A.type_ HTML.InputHidden, attr "name" "key", attr "value" key]
             , E.div
                 [cls "ls-field"]
                 [ E.label [attr "for" "project-name"] [E.text "Name"]
                 , E.input [A.type_ HTML.InputText, attr "id" "project-name", attr "name" "name", attr "value" (formName form), attr "maxlength" "80", attr "required" "required"]
                 ]
             , E.div
                 [cls "ls-field"]
                 [ E.label [attr "for" "project-outcome"] [E.text "What should it achieve?"]
                 , E.textarea [attr "id" "project-outcome", attr "name" "outcome", attr "rows" "4", attr "maxlength" "2000"] (formOutcome form)
                 ]
             , E.fieldset
                 []
                 [ E.legend [] [E.text "Where should its files live?"]
                 , choice "folder" "new" "In a new folder Lockstep makes for it (recommended)" []
                 , choice "folder" "existing" "In a folder that is already on this computer" existingPart
                 , choice "folder" "later" "Decide later" []
                 ]
             , E.button [attr "id" "create-project", attr "type" "submit", cls "ls-primary"] [E.text "Create project"]
             ]
         , E.p [] [E.a [href "/app/projects"] [E.text "Back to Projects"]]
         ]

projectPage :: DatabaseRuntime -> ProjectView -> Maybe T.Text -> IO LBS.ByteString
projectPage db view notice = do
  folders <- projectFoldersFromEnvironment
  offered <- offeredFolders db folders
  tasks <- fromRight [] <$> listTasks db (projectId view)
  checks <- projectChecks db (projectId view)
  let
    status =
      case projectSetup view of
        Connected ->
          [ E.p [cls "ls-good-text"] [E.text ("Lockstep can see this folder: " <> fromMaybe "" (projectFolder view))]
          , E.p [] [E.text "It cannot change it or run anything in it yet; that arrives in a later update of Lockstep."]
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
        [A.method B.FormPOST, A.action (B.mkRawURL ("/app/api/projects/" <> projectId view <> "/connect"))]
        [ E.input [A.type_ HTML.InputHidden, attr "name" "revision", attr "value" (T.pack (show (projectRevision view)))]
        , E.fieldset
            []
            ( [ E.legend [] [E.text "Where should its files live?"]
              , E.div
                  [cls "ls-choice"]
                  [ E.input [A.type_ HTML.InputRadio, attr "id" "connect-new", attr "name" "folder", attr "value" "new", attr "checked" "checked"]
                  , E.label [attr "for" "connect-new"] [E.text "In a new folder Lockstep makes for it"]
                  ]
              ]
                <> [ E.div
                       [cls "ls-choice"]
                       [ E.input [A.type_ HTML.InputRadio, attr "id" "connect-existing", attr "name" "folder", attr "value" "existing"]
                       , E.label [attr "for" "connect-existing"] [E.text "In this folder: "]
                       , E.select [attr "id" "connect-choice", attr "name" "path", attr "aria-label" "Folder"] (folderOptions offered "")
                       ]
                   | not (L.null offered)
                   ]
            )
        , E.button [attr "id" "connect-project", attr "type" "submit", cls "ls-primary"] [E.text label]
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
         , E.p [] [E.a [href "/app/projects"] [E.text "Back to Projects"]]
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
        <> [E.li [] [E.text (T.pack (show (L.length open)) <> " decision(s) need you: "), E.a [href "/app/decisions"] [E.text "Decisions"]] | not (L.null open)]
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
        , E.a [href "/app/projects"] [E.text "Projects"]
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
        , E.a [A.href (B.mkRawURL "/operator/center")] [E.text "command center"]
        , E.text " and "
        , E.a [A.href (B.mkRawURL "/operator/ledger")] [E.text "ledger"]
        , E.text "."
        ]
    ]
