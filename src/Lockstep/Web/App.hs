{-# LANGUAGE OverloadedStrings #-}

{- | The application shell on the service (contract C-P3.4 A1–A7): the same
trust model as the control pane (T2–T7). Every page address returns one
content-free shell; the sections are server-rendered Brigid fragments fetched
by the page with the @X-Lockstep-Session@ header. The one-time token and the
session are those of C-P1.3, stored as digests; no cookie is read or set here.
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
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.Encoding.Error qualified as TEE
import Data.Time qualified as Time
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTP
import Network.Wai qualified as Wai
import Text.Show (show)

import Lockstep.Application.Command (WorkspaceState (..), readWorkspace)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason (..), Readiness (..), checkReadiness, revisionNumber)
import Lockstep.Application.LedgerView (EffectLine (..), LedgerProjection (..), OrderLine (..), projectLedger)
import Lockstep.Application.OperatorTrust (Session (..), exchangeSignIn, lookupSession, revokeSession)
import Lockstep.Foundation.OperatorToken (decodeToken, encodeToken)
import Lockstep.Kernel.EffectView (EffectStatus (..))
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
  | ExchangeSession
  | SignOut

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
      ["app", "fragments", s] | get -> Fragment <$> parseSection s
      ["app", "api", "session"] | post -> Just ExchangeSession
      ["app", "api", "sign-out"] | post -> Just SignOut
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
 where
  withSession action =
    case sessionHeader request >>= decodeToken of
      Nothing -> pure (errorJson HTTP.status401 "signed-out")
      Just token -> do
        found <- lookupSession db token
        case found of
          Nothing -> pure (errorJson HTTP.status401 "signed-out")
          Just session -> action token session

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

renderSection :: DatabaseRuntime -> Section -> Session -> IO LBS.ByteString
renderSection db section session =
  case section of
    Home -> home db
    Projects ->
      pure . fragment $
        [ E.h1 [] [E.text "Projects"]
        , E.p [] [E.text "Projects arrive in a later update of Lockstep. A project will hold what you want to achieve, the work that gets you there and the folder it lives in."]
        ]
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
        , E.p [] [E.text "Installing, updating, starting and stopping Lockstep happen in the control pane. To open it, run lockstep on this computer."]
        ]
    Advanced -> advanced db session

home :: DatabaseRuntime -> IO LBS.ByteString
home db = do
  readiness <- checkReadiness (Just db)
  workspace <- readWorkspace db
  projection <- projectLedger db
  let
    name = either (const "Lockstep") workspaceName workspace
    orders = either (const []) projectionOrders projection
    tickets = either (const 0) (L.length . projectionTickets) projection
    waiting = L.length [() | o <- orders, e <- orderLineEffects o, effectLineStatus e `L.elem` [StatusReconciliationNeeded, StatusUnknown, StatusBlocked]]
    attention =
      [E.li [] [E.text ("Lockstep's database is not ready: " <> reasonText r <> ". Open the control pane (run lockstep) to see what to do.")] | NotReady r <- [readiness]]
        <> [E.li [] [E.text (T.pack (show waiting) <> " piece(s) of work are waiting for a person to look at them.")] | waiting > 0]
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
        , E.li [] [E.text (T.pack (show tickets) <> " ticket(s) and " <> T.pack (show (L.length orders)) <> " work order(s) are recorded.")]
        ]
    , E.h2 [] [E.text "Next steps"]
    , E.p [] [E.text "Projects, tasks and decisions arrive in later updates of this window. Until then, the control pane manages this computer: run lockstep to open it."]
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
  let
    revision =
      case readiness of
        Ready r -> T.pack (show (revisionNumber r))
        NotReady _ -> "not ready"
    expires = T.pack (Time.formatTime Time.defaultTimeLocale "%Y-%m-%d %H:%M UTC" (sessionExpiresAt session))
  pure . fragment $
    [ E.h1 [] [E.text "Advanced"]
    , E.p [] [E.text "The exact technical facts behind what the other sections show."]
    , E.dl
        [cls "ls-facts"]
        [ E.dt [] [E.text "Schema revision"]
        , E.dd [] [E.code [] [E.text revision]]
        , E.dt [] [E.text "Session expires"]
        , E.dd [] [E.text expires]
        ]
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
