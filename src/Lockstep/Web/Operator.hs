{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

{- | The operator routes (contract C-P1.3 E3–E8): the sign-in confirm page and
exchange, the protected operator page and sign-out; and the typed command
routes of C-P1.4 E9, which only parse input and call
"Lockstep.Application.Command". Served at the WAI level,
after route recognition (the typed tree of "Lockstep.Web.Routes.Operator") and
the request guard ("Lockstep.Web.Application").
The raw sign-in token appears only in the confirm page's hidden field.
-}
module Lockstep.Web.Operator
  ( Routes
  , matchOperatorRoute
  , handleOperator
  , guardRefusalResponse
  ) where

import Beeline.Routing qualified as R
import Brigid.HTML.Attributes qualified as A
import Brigid.HTML.Elements qualified as E
import Brigid.HTML.Render.ByteString (renderLazyHTML)
import Brigid.HTML.Types qualified as HTML
import Brigid.Types qualified as B
import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.List qualified as L
import Data.String.Interpolate qualified as Interpolate
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time qualified as Time
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTP
import Network.Wai qualified as Wai
import Shrubbery qualified
import Text.Show (show)
import Web.Cookie qualified as Cookie

import Lockstep.Application.Command
  ( Actor (ActorBrowserSession)
  , CommandRefusal (..)
  , IdempotencyKey
  , Outcome (..)
  , Receipt (..)
  , WorkspaceState (..)
  , actorCode
  , buildQueue
  , buildRename
  , findReceipt
  , generateIdempotencyKey
  , idempotencyKeyText
  , outcomeCode
  , readWorkspace
  , revisionInt
  , submitCommand
  )
import Lockstep.Application.CommandCenter (loadCommandCenter)
import Lockstep.Application.Database (DatabaseRuntime)
import Lockstep.Application.Dispatcher (Job (..), findJobForReceipt, jobStateCode)
import Lockstep.Application.LedgerView (projectLedger)
import Lockstep.Application.OperatorTrust
  ( Session (..)
  , SignInRefusal (..)
  , exchangeSignIn
  , lookupSession
  , revokeSession
  )
import Lockstep.Foundation.OperatorToken (RawToken, csrfFor, csrfMatches, decodeToken, encodeToken)
import Lockstep.Kernel.Identity (ReceiptId (..), jobIdNumber)
import Lockstep.Web.CommandCenter (commandCenterPage)
import Lockstep.Web.Components.Page (page)
import Lockstep.Web.Fields (csrfField, expectedRevisionField, failAtStepField, idempotencyKeyField, nameField, stepMsField, stepsField, tokenField)
import Lockstep.Web.Form (Form, FormField, queryForm, readForm)
import Lockstep.Web.Fragment (attr)
import Lockstep.Web.LedgerPage (ledgerFailurePage, ledgerPage)
import Lockstep.Web.RequestGuard (GuardRefusal (..))
import Lockstep.Web.Routes.Operator
  ( CenterView
  , LedgerView
  , OperatorHome
  , QueueCommand
  , QueueForm
  , ReceiptView (..)
  , RenameCommand
  , Routes
  , SignInConfirm
  , SignInExchange
  , SignOut
  , centerLink
  , operatorHomeLink
  , queueAction
  , queueFormLink
  , receiptLink
  , renameAction
  , routes
  , signInAction
  , signOutAction
  )
import Lockstep.Web.Validation (Validator)
import Lockstep.Web.Validation qualified as V

-- | The route for a request, if it is an operator route (GET and POST only, as before).
matchOperatorRoute :: HTTP.StdMethod -> [T.Text] -> Maybe Routes
matchOperatorRoute method path =
  either (const Nothing) Just (R.recognizeRoute routes method path)

handleOperator :: Maybe DatabaseRuntime -> Routes -> Wai.Request -> IO Wai.Response
handleOperator db route request =
  Shrubbery.dissect
    ( Shrubbery.branchBuild
        . Shrubbery.branch (\(_ :: SignInConfirm) -> signInConfirm request)
        . Shrubbery.branch (\(_ :: SignInExchange) -> signInExchange db request)
        . Shrubbery.branch (\(_ :: OperatorHome) -> operatorHome db request)
        . Shrubbery.branch (\(_ :: SignOut) -> signOut db request)
        . Shrubbery.branch (\(_ :: RenameCommand) -> renameCommand db request)
        . Shrubbery.branch (\(ReceiptView rid) -> receiptView db request rid)
        . Shrubbery.branch (\(_ :: QueueCommand) -> queueCommand db request)
        . Shrubbery.branch (\(_ :: QueueForm) -> queueForm db request)
        . Shrubbery.branch (\(_ :: CenterView) -> centerView db request)
        . Shrubbery.branch (\(_ :: LedgerView) -> ledgerView db request)
        $ Shrubbery.branchEnd
    )
    route

-- * Handlers

-- | The sign-in link's token: exactly one, well formed.
signInToken :: Validator Form RawToken
signInToken =
  tokenField `V.required` (V.text `V.chain` V.maybeValidator decodeToken "Not a sign-in token.")

signInConfirm :: Wai.Request -> IO Wai.Response
signInConfirm request =
  pure $
    case queryForm request >>= either (const Nothing) Just . V.runValidator signInToken of
      Just token -> confirmResponse token
      Nothing -> refusal HTTP.status400 badLinkPage

signInExchange :: Maybe DatabaseRuntime -> Wai.Request -> IO Wai.Response
signInExchange db request =
  withForm request $ \sent ->
    case sent >>= either (const Nothing) Just . V.runValidator signInToken of
      Nothing -> pure (refusal HTTP.status400 badLinkPage)
      Just token ->
        case db of
          Nothing -> pure (refusal HTTP.status503 notReadyPage)
          Just runtime -> do
            result <- exchangeSignIn runtime token
            pure $
              case result of
                Right session -> signedInResponse session
                Left SignInTokenRefused -> refusal HTTP.status403 refusedLinkPage
                Left (SignInNotReady _) -> refusal HTTP.status503 notReadyPage

operatorHome :: Maybe DatabaseRuntime -> Wai.Request -> IO Wai.Response
operatorHome db request =
  withSession db request $ \runtime token session -> do
    workspace <- readWorkspace runtime
    operatorResponse HTTP.status200 formPagePolicy . operatorPage token session (either (const Nothing) Just workspace)
      <$> generateIdempotencyKey

{- | A state-changing form: the session, then the form (a body that is not an
UTF-8 form is an invalid command, 400, never reported as a forgery), then its
CSRF field (else 403).
-}
withCsrfForm :: Maybe DatabaseRuntime -> Wai.Request -> (DatabaseRuntime -> RawToken -> Form -> IO Wai.Response) -> IO Wai.Response
withCsrfForm db request action =
  withSession db request $ \runtime token _ ->
    withForm request $ \sent ->
      case sent of
        Nothing -> pure (refusal HTTP.status400 invalidCommandPage)
        Just form ->
          case V.runValidator (csrfField `V.required` V.text) form of
            Right csrf | csrfMatches token csrf -> action runtime token form
            _ -> pure (refusal HTTP.status403 csrfPage)

renameCommand :: Maybe DatabaseRuntime -> Wai.Request -> IO Wai.Response
renameCommand db request =
  withCsrfForm db request $ \runtime _ form ->
    case V.runValidator renameFields form of
      Left _ -> pure (refusal HTTP.status400 invalidCommandPage)
      Right (key, expected, name) ->
        case buildRename ActorBrowserSession key expected name of
          Left _ -> pure (refusal HTTP.status400 invalidCommandPage)
          Right envelope -> commandResponse <$> submitCommand runtime envelope

receiptView :: Maybe DatabaseRuntime -> Wai.Request -> ReceiptId -> IO Wai.Response
receiptView db request receiptId =
  withSession db request $ \runtime _ _ -> do
    found <- findReceipt runtime receiptId
    case found of
      Nothing -> pure notFoundPage
      Just receipt -> do
        job <- findJobForReceipt runtime receiptId
        pure $ case job of
          Left _ -> refusal HTTP.status503 notReadyPage
          Right found' -> operatorResponse HTTP.status200 noReferrer (receiptPage receipt found')

queueCommand :: Maybe DatabaseRuntime -> Wai.Request -> IO Wai.Response
queueCommand db request =
  withCsrfForm db request $ \runtime _ form ->
    case V.runValidator queueFields form of
      Left _ -> pure (refusal HTTP.status400 invalidCommandPage)
      Right (key, expected, steps, millis, failAt) ->
        case buildQueue ActorBrowserSession key expected steps millis failAt of
          Left _ -> pure (refusal HTTP.status400 invalidCommandPage)
          Right envelope -> commandResponse <$> submitCommand runtime envelope

centerView :: Maybe DatabaseRuntime -> Wai.Request -> IO Wai.Response
centerView db request =
  withSession db request $ \runtime _ _ ->
    operatorResponse HTTP.status200 noReferrer . commandCenterPage <$> loadCommandCenter runtime

ledgerView :: Maybe DatabaseRuntime -> Wai.Request -> IO Wai.Response
ledgerView db request =
  withSession db request $ \runtime _ _ -> do
    projected <- projectLedger runtime
    pure $
      case projected of
        Right projection -> operatorResponse HTTP.status200 noReferrer (ledgerPage projection)
        -- C-P2.8 V3: a failure to project is said, never a partial page.
        Left _ -> operatorResponse HTTP.status500 noReferrer ledgerFailurePage

queueForm :: Maybe DatabaseRuntime -> Wai.Request -> IO Wai.Response
queueForm db request =
  withSession db request $ \runtime token _ -> do
    workspace <- readWorkspace runtime
    operatorResponse HTTP.status200 formPagePolicy . queuePage token (either (const Nothing) Just workspace)
      <$> generateIdempotencyKey

signOut :: Maybe DatabaseRuntime -> Wai.Request -> IO Wai.Response
signOut db request =
  withCsrfForm db request $ \runtime token _ -> do
    revoked <- revokeSession runtime token
    pure $
      case revoked of
        Right () -> redirect "/" [(hSetCookie, clearCookie)]
        -- Never claim a sign-out the database did not record (review finding 13).
        Left _ -> refusal HTTP.status503 notReadyPage

-- * Responses

hSetCookie :: HTTP.HeaderName
hSetCookie =
  "Set-Cookie"

sessionCookieName :: BS.ByteString
sessionCookieName =
  "lockstep_session"

noReferrer :: HTTP.Header
noReferrer =
  ("Referrer-Policy", "no-referrer")

{- | Pages whose forms change state (C-P1.3 §9.1, R-P1.3-1; C-P1.7-R1 R1). With
@no-referrer@ a browser sends @Origin: null@ for their submissions, which the
strict guard refuses. @origin@ sends the exact Origin and only the bare origin
as Referer. These pages' URLs carry no secrets.
-}
formPagePolicy :: HTTP.Header
formPagePolicy =
  ("Referrer-Policy", "origin")

noStore :: HTTP.Header
noStore =
  ("Cache-Control", "no-store")

htmlType :: HTTP.Header
htmlType =
  (HTTP.hContentType, "text/html; charset=utf-8")

{- | Every operator page is no-store and may not be framed (Gate A review
finding 2: another 127.0.0.1 port is the same site); the referrer policy is
the caller's.
-}
operatorResponse :: HTTP.Status -> HTTP.Header -> E.HTML -> Wai.Response
operatorResponse status policy =
  operatorPageResponse status policy ("Content-Security-Policy", "frame-ancestors 'none'")

operatorPageResponse :: HTTP.Status -> HTTP.Header -> HTTP.Header -> E.HTML -> Wai.Response
operatorPageResponse status policy csp html =
  Wai.responseLBS status [htmlType, noStore, policy, csp, ("X-Frame-Options", "DENY")] (renderLazyHTML html)

refusal :: HTTP.Status -> E.HTML -> Wai.Response
refusal status =
  operatorResponse status noReferrer

redirect :: BS.ByteString -> [HTTP.Header] -> Wai.Response
redirect location extra =
  Wai.responseLBS HTTP.status303 ([(HTTP.hLocation, location), noStore, noReferrer] <> extra) ""

-- | E3: the only response that carries the raw sign-in token, once.
confirmResponse :: RawToken -> Wai.Response
confirmResponse token =
  operatorPageResponse
    HTTP.status200
    ("Referrer-Policy", "origin")
    ( "Content-Security-Policy"
    , "default-src 'none'; style-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
    )
    (confirmPage token)

-- | The session cookie (C-P1.3 E4): host-only, every path, HttpOnly, SameSite=Strict, 12 hours.
sessionCookie :: BS.ByteString -> Time.DiffTime -> BS.ByteString
sessionCookie value maxAge =
  Cookie.renderSetCookieBS
    Cookie.defaultSetCookie
      { Cookie.setCookieName = sessionCookieName
      , Cookie.setCookieValue = value
      , Cookie.setCookiePath = Just "/"
      , Cookie.setCookieMaxAge = Just maxAge
      , Cookie.setCookieHttpOnly = True
      , Cookie.setCookieSameSite = Just Cookie.sameSiteStrict
      }

signedInResponse :: RawToken -> Wai.Response
signedInResponse session =
  redirect
    (TE.encodeUtf8 (B.relativeURLToText operatorHomeLink))
    [(hSetCookie, sessionCookie (TE.encodeUtf8 (encodeToken session)) 43200)]

clearCookie :: BS.ByteString
clearCookie =
  sessionCookie "" 0

guardRefusalResponse :: GuardRefusal -> Wai.Response
guardRefusalResponse reason =
  refusal HTTP.status403 . messagePage [Interpolate.i|Request refused|] $
    case reason of
      HostRefused -> [Interpolate.i|This service answers only requests addressed to its loopback address and port.|]
      OriginRefused -> [Interpolate.i|This request did not come from a page of this service.|]

commandResponse :: Either CommandRefusal Receipt -> Wai.Response
commandResponse result =
  case result of
    Right receipt
      | receiptOutcome receipt == RefusedStale ->
          refusal HTTP.status409 (receiptPage receipt Nothing)
      | otherwise ->
          redirect (TE.encodeUtf8 (B.relativeURLToText (receiptLink (ReceiptId (receiptId receipt))))) []
    Left CommandKeyConflict -> refusal HTTP.status409 keyConflictPage
    Left (CommandInvalid _) -> refusal HTTP.status400 invalidCommandPage
    Left (CommandNotReady _) -> refusal HTTP.status503 notReadyPage

notFoundPage :: Wai.Response
notFoundPage =
  refusal HTTP.status404 (messagePage [Interpolate.i|Not found|] [Interpolate.i|There is no such receipt.|])

-- * Request parsing

-- | The operator forms' numbers: at most 18 digits' worth (C-P1.4 E9; the commands check their own ranges).
operatorNumberMax :: Integer
operatorNumberMax =
  999999999999999999

decimal :: Validator FormField Integer
decimal =
  V.decimalUpTo operatorNumberMax

renameFields :: Validator Form (T.Text, Integer, T.Text)
renameFields =
  (,,)
    <$> idempotencyKeyField `V.required` V.text
    <*> expectedRevisionField `V.required` decimal
    <*> nameField `V.required` V.text

-- | The queue form; an empty @fail_at_step@ is no failure step.
queueFields :: Validator Form (T.Text, Integer, Integer, Integer, Maybe Integer)
queueFields =
  (,,,,)
    <$> idempotencyKeyField `V.required` V.text
    <*> expectedRevisionField `V.required` decimal
    <*> stepsField `V.required` decimal
    <*> stepMsField `V.required` decimal
    <*> failAtStepField `V.required` (V.text `V.chain` V.maybeValidator failAt "Not a step.")
 where
  failAt t =
    if T.null t
      then Just Nothing
      else Just <$> V.digitsUpTo operatorNumberMax t

formLimit :: Int
formLimit =
  16384

drainLimit :: Int
drainLimit =
  1048576

{- | Reads an urlencoded form of at most 16 KiB; a larger body answers 413
after being drained up to 1 MiB so the client can read the response. A body that
is not an UTF-8 form is 'Nothing'.
-}
withForm :: Wai.Request -> (Maybe Form -> IO Wai.Response) -> IO Wai.Response
withForm request action =
  let
    collect size chunks = do
      chunk <- Wai.getRequestBodyChunk request
      if BS.null chunk
        then action (readForm (BS.concat (L.reverse chunks)))
        else
          let
            size' = size + BS.length chunk
          in
            if size' > formLimit
              then drain size' >> pure (refusal HTTP.status413 tooLargePage)
              else collect size' (chunk : chunks)
    drain size =
      when (size < drainLimit) $ do
        chunk <- Wai.getRequestBodyChunk request
        unless (BS.null chunk) (drain (size + BS.length chunk))
  in
    collect 0 []

-- | E5: exactly one well-formed session cookie with a live session, else 401.
withSession ::
  Maybe DatabaseRuntime ->
  Wai.Request ->
  (DatabaseRuntime -> RawToken -> Session -> IO Wai.Response) ->
  IO Wai.Response
withSession db request action =
  let
    cookies =
      [ value
      | (key, header) <- Wai.requestHeaders request
      , key == HTTP.hCookie
      , (name, value) <- Cookie.parseCookies header
      , name == sessionCookieName
      ]
    token =
      case cookies of
        [value] -> either (const Nothing) decodeToken (TE.decodeUtf8' value)
        _ -> Nothing
  in
    case (db, token) of
      (Just runtime, Just t) -> do
        found <- lookupSession runtime t
        case found of
          Just session -> action runtime t session
          Nothing -> pure (refusal HTTP.status401 signedOutPage)
      _ ->
        pure (refusal HTTP.status401 signedOutPage)

-- * Pages

{- | A @value@ attribute, HTML-escaped by the one escaper ("Lockstep.Web.Fragment"
'attr'): a workspace name containing a double quote cannot break out of the
attribute (Gate A, A1-12b).
-}
escapedValue :: T.Text -> A.Attribute tag
escapedValue =
  attr (T.pack "value")

hiddenField :: B.Name -> T.Text -> E.ChildHTML E.Form grandparent
hiddenField name value =
  E.input [A.type_ HTML.InputHidden, A.name name, escapedValue value]

confirmPage :: RawToken -> E.HTML
confirmPage token =
  page
    [Interpolate.i|Lockstep sign-in|]
    [ E.main
        []
        [ E.h1 [] [E.text [Interpolate.i|Sign in to Lockstep|]]
        , E.p
            []
            [ E.text [Interpolate.i|This one-time link was printed by |]
            , E.code [] [E.text [Interpolate.i|lockstep operator sign-in|]]
            , E.text [Interpolate.i|. Confirm to start an operator session in this browser. If you did not run that command, close this page.|]
            ]
        , E.form
            [A.method B.FormPOST, A.action signInAction]
            [ hiddenField tokenField (encodeToken token)
            , E.button [] [E.text [Interpolate.i|Sign in|]]
            ]
        ]
    ]

operatorPage :: RawToken -> Session -> Maybe WorkspaceState -> IdempotencyKey -> E.HTML
operatorPage token session workspace key =
  page
    [Interpolate.i|Lockstep operator|]
    [ E.main
        []
        [ E.h1 [] [E.text [Interpolate.i|Operator session|]]
        , E.p
            []
            [ E.text [Interpolate.i|Signed in. This session expires at |]
            , E.text (T.pack (Time.formatTime Time.defaultTimeLocale "%Y-%m-%d %H:%M:%S UTC" (sessionExpiresAt session)))
            , E.text [Interpolate.i|.|]
            ]
        , E.form
            [A.method B.FormPOST, A.action signOutAction]
            [ hiddenField csrfField (csrfFor token)
            , E.button [] [E.text [Interpolate.i|Sign out|]]
            ]
        , E.h2 [] [E.text [Interpolate.i|Workspace|]]
        , workspaceSection token workspace key
        , E.p [] [E.a [A.href centerLink] [E.text [Interpolate.i|Command center: status, activity and evidence|]]]
        , E.h2 [] [E.text [Interpolate.i|Background jobs|]]
        , E.p [] [E.a [A.href queueFormLink] [E.text [Interpolate.i|Queue a no-op job|]]]
        ]
    ]

-- | C-P1.5 E7: the queue form (its own page; see the P1.5 acceptance record).
queuePage :: RawToken -> Maybe WorkspaceState -> IdempotencyKey -> E.HTML
queuePage token workspace key =
  page
    [Interpolate.i|Lockstep: queue a job|]
    [ E.main
        []
        [ E.h1 [] [E.text [Interpolate.i|Queue a no-op job|]]
        , E.p [] [E.text [Interpolate.i|The job does nothing but advance through its steps; the running service executes it in the background.|]]
        , case workspace of
            Nothing ->
              E.p [] [E.text [Interpolate.i|Unavailable: the database is not ready.|]]
            Just current ->
              E.form
                [A.method B.FormPOST, A.action queueAction]
                [ numberField (T.pack "Steps (1-20) ") stepsField (T.pack "3")
                , numberField (T.pack "Milliseconds per step (0-5000) ") stepMsField (T.pack "100")
                , numberField (T.pack "Fail at step (empty for none) ") failAtStepField T.empty
                , hiddenField expectedRevisionField (T.pack (show (revisionInt (workspaceRevision current))))
                , hiddenField idempotencyKeyField (idempotencyKeyText key)
                , hiddenField csrfField (csrfFor token)
                , E.button [] [E.text [Interpolate.i|Queue|]]
                ]
        , E.p [] [E.a [A.href operatorHomeLink] [E.text [Interpolate.i|Back to the operator page|]]]
        ]
    ]
 where
  numberField label name value =
    E.label
      []
      [ E.text label
      , E.input [A.type_ HTML.InputText, A.name name, escapedValue value]
      ]

workspaceSection :: RawToken -> Maybe WorkspaceState -> IdempotencyKey -> E.ChildHTML E.Main grandparent
workspaceSection token workspace key =
  case workspace of
    Nothing ->
      E.p [] [E.text [Interpolate.i|The workspace is unavailable: the database is not ready.|]]
    Just current ->
      E.form
        [A.method B.FormPOST, A.action renameAction]
        [ E.p
            []
            [ E.text [Interpolate.i|Name: |]
            , E.strong [] [E.text (workspaceName current)]
            , E.text [Interpolate.i| (revision |]
            , E.text (T.pack (show (revisionInt (workspaceRevision current))))
            , E.text [Interpolate.i|)|]
            ]
        , E.label
            []
            [ E.text [Interpolate.i|New name |]
            , E.input
                [ A.type_ HTML.InputText
                , A.name nameField
                , escapedValue (workspaceName current)
                ]
            ]
        , hiddenField expectedRevisionField (T.pack (show (revisionInt (workspaceRevision current))))
        , hiddenField idempotencyKeyField (idempotencyKeyText key)
        , hiddenField csrfField (csrfFor token)
        , E.button [] [E.text [Interpolate.i|Rename|]]
        ]

receiptPage :: Receipt -> Maybe Job -> E.HTML
receiptPage receipt job =
  let
    fact label value =
      [E.dt [] [E.text label], E.dd [] [E.code [] [E.text value]]]
  in
    page
      [Interpolate.i|Lockstep receipt|]
      [ E.main
          []
          [ E.h1 [] [E.text ("Receipt " <> T.pack (show (receiptId receipt)))]
          , E.dl
              [A.class_ (HTML.Class [Interpolate.i|ls-facts|])]
              ( fact "Command" (receiptKind receipt)
                  <> fact "Outcome" (outcomeCode (receiptOutcome receipt))
                  <> fact "Expected revision" (T.pack (show (revisionInt (receiptExpected receipt))))
                  <> fact "Revision" (T.pack (show (revisionInt (receiptRevision receipt))))
                  <> fact "Actor" (actorCode (receiptActor receipt))
                  <> fact "Accepted" (T.pack (Time.formatTime Time.defaultTimeLocale "%Y-%m-%d %H:%M:%S UTC" (receiptAcceptedAt receipt)))
                  <> fact "Idempotency key" (receiptKey receipt)
                  <> foldMap jobFacts job
              )
          , E.p [] [E.a [A.href operatorHomeLink] [E.text [Interpolate.i|Back to the operator page|]]]
          ]
      ]
 where
  jobFacts j =
    [ E.dt [] [E.text [Interpolate.i|Job|]]
    , E.dd [] [E.code [] [E.text (T.pack (show (jobIdNumber (jobId j))))]]
    , E.dt [] [E.text [Interpolate.i|Job state|]]
    , E.dd [] [E.code [] [E.text (jobStateCode (jobState j))]]
    , E.dt [] [E.text [Interpolate.i|Steps|]]
    , E.dd [] [E.code [] [E.text (T.pack (show (jobStepsDone j) <> "/" <> show (jobStepsTotal j)))]]
    , E.dt [] [E.text [Interpolate.i|Attempts|]]
    , E.dd [] [E.code [] [E.text (T.pack (show (jobAttempts j)))]]
    ]
      <> foldMap (\err -> [E.dt [] [E.text [Interpolate.i|Error|]], E.dd [] [E.text err]]) (jobError j)

messagePage :: T.Text -> T.Text -> E.HTML
messagePage title message =
  page title [E.main [] [E.h1 [] [E.text title], E.p [] [E.text message]]]

signInHint :: T.Text -> E.HTML
signInHint message =
  page
    [Interpolate.i|Lockstep sign-in|]
    [ E.main
        []
        [ E.h1 [] [E.text [Interpolate.i|Not signed in|]]
        , E.p
            []
            [ E.text message
            , E.text [Interpolate.i| Run |]
            , E.code [] [E.text [Interpolate.i|lockstep operator sign-in|]]
            , E.text [Interpolate.i| in a terminal and open the link it prints.|]
            ]
        ]
    ]

signedOutPage :: E.HTML
signedOutPage =
  signInHint [Interpolate.i|This page needs an operator session.|]

badLinkPage :: E.HTML
badLinkPage =
  signInHint [Interpolate.i|This sign-in link is malformed.|]

refusedLinkPage :: E.HTML
refusedLinkPage =
  signInHint [Interpolate.i|This sign-in link is invalid, already used or expired.|]

notReadyPage :: E.HTML
notReadyPage =
  messagePage
    [Interpolate.i|Not ready|]
    [Interpolate.i|Sign-in needs a ready database; see the status page and lockstep db status.|]

csrfPage :: E.HTML
csrfPage =
  messagePage
    [Interpolate.i|Request refused|]
    [Interpolate.i|The form was stale or not from this session. Reload the operator page and try again.|]

keyConflictPage :: E.HTML
keyConflictPage =
  messagePage
    [Interpolate.i|Command refused|]
    [Interpolate.i|This idempotency key was already used for a different command. Reload the operator page and try again.|]

invalidCommandPage :: E.HTML
invalidCommandPage =
  messagePage
    [Interpolate.i|Command refused|]
    [Interpolate.i|The command is invalid: the name must be 1-80 characters without control characters.|]

tooLargePage :: E.HTML
tooLargePage =
  messagePage [Interpolate.i|Request refused|] [Interpolate.i|The request body is too large.|]
