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
import Brigid.HTML.Render.ByteString (renderLazyHTML)
import Brigid.HTML.Types qualified as HTML
import Brigid.Types qualified as B
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
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

import Lockstep.Application.Command (WorkspaceState (..), generateIdempotencyKey, idempotencyKeyText, mkIdempotencyKey, readWorkspace)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason (..), Readiness (..), checkReadiness, revisionNumber)
import Lockstep.Application.LedgerView (EffectLine (..), LedgerProjection (..), OrderLine (..), projectLedger)
import Lockstep.Application.OperatorTrust (Session (..), exchangeSignIn, lookupSession, revokeSession)
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
import Lockstep.Foundation.OperatorToken (decodeToken, encodeToken)
import Lockstep.Kernel.EffectView (EffectStatus (..))
import Lockstep.Kernel.Identity (parseUuid)
import Lockstep.Kernel.Project (SetupState (..), parseFolderChoice, refusalWords, setupStateCode)
import Lockstep.Web.RequestGuard (RouteClass (..))
import Lockstep.Web.SecureResponse (errorJson, htmlResponse, jsonResponse, jsonString, readBodyLimited, respondWith)

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
      ["app", "fragments", "project", pid] | get, validId pid -> Just (ProjectFragment pid)
      ["app", "fragments", s] | get -> Fragment <$> parseSection s
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
          revision = value "revision" >>= readMaybe . T.unpack
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

fragment :: [E.ChildHTML E.Division E.Body] -> LBS.ByteString
fragment children =
  namedEntities (renderLazyHTML (E.div [cls "ls-section"] children :: E.ChildHTML E.Body E.Html))

{- | Brigid escapes text as numeric references (@&#60;@); the same characters are
written here as the named references (@&lt;@), which mean exactly the same.
-}
namedEntities :: LBS.ByteString -> LBS.ByteString
namedEntities =
  LBS.fromStrict . go . LBS.toStrict
 where
  go bytes =
    case BS.breakSubstring "&#" bytes of
      (before, rest)
        | BS.null rest -> before
        | otherwise -> before <> replaceOne rest
  replaceOne rest =
    case L.find (\(numeric, _) -> numeric `BS.isPrefixOf` rest) table of
      Just (numeric, named) -> named <> go (BS.drop (BS.length numeric) rest)
      Nothing -> "&#" <> go (BS.drop 2 rest)
  table =
    [ ("&#60;", "&lt;")
    , ("&#62;", "&gt;")
    , ("&#38;", "&amp;")
    , ("&#34;", "&quot;")
    ]

cls :: T.Text -> A.Attribute tag
cls =
  A.class_ . HTML.Class

-- | An attribute whose value is escaped (Brigid escapes quotes in custom attributes; ampersands here).
attr :: T.Text -> T.Text -> A.Attribute tag
attr name =
  A.customAttribute name . T.replace "&" "&amp;"

href :: T.Text -> A.Attribute E.Anchor
href =
  A.href . B.mkRawURL

renderSection :: DatabaseRuntime -> Section -> Session -> IO LBS.ByteString
renderSection db section session =
  case section of
    Home -> home db
    Projects -> projectsOverview db
    Tasks ->
      pure . fragment $
        [ E.h1 [] [E.text "Tasks"]
        , E.p [] [E.text "Tasks arrive in a later update of Lockstep. You will write down what needs doing in your own words, set what matters most and see what is ready or blocked."]
        ]
    Decisions ->
      pure . fragment $
        [ E.h1 [] [E.text "Decisions"]
        , E.p [] [E.text "Decisions arrive in a later update of Lockstep. Questions and approvals that need you will collect here, with what each choice would do."]
        ]
    Activity ->
      pure . fragment $
        [ E.h1 [] [E.text "Activity"]
        , E.p [] [E.text "The history of what happened will be shown here in a later update of Lockstep. Nothing is shown yet, so nothing here is guessed."]
        ]
    Settings ->
      pure . fragment $
        [ E.h1 [] [E.text "Settings"]
        , E.p [] [E.text "Installing, updating, starting and stopping Lockstep happen in the control pane, and so does choosing which folders on this computer Lockstep may see (Project folders). To open it, run lockstep on this computer."]
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
    , E.p [cls "ls-muted"] [E.text "Tasks inside a project arrive in a later update of Lockstep."]
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
          , connectForm "Try again"
          ]
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
                       , E.select [attr "id" "connect-choice", attr "name" "path"] (folderOptions offered "")
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
         , E.h2 [] [E.text "Its folder"]
         ]
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
  let
    name = either (const "Lockstep") workspaceName workspace
    orders = either (const []) projectionOrders projection
    tickets = either (const 0) (L.length . projectionTickets) projection
    projectCount = either (const 0) L.length projects
    failed = either (const 0) (L.length . L.filter ((== SetupFailed) . projectSetup)) projects
    waiting = L.length [() | o <- orders, e <- orderLineEffects o, effectLineStatus e `L.elem` [StatusReconciliationNeeded, StatusUnknown, StatusBlocked]]
    attention =
      [E.li [] [E.text ("Lockstep's database is not ready: " <> reasonText r <> ". Open the control pane (run lockstep) to see what to do.")] | NotReady r <- [readiness]]
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
        , E.text ". Tasks and decisions arrive in later updates of this window."
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
