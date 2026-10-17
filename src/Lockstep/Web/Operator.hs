{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}

{- | The operator routes (contract C-P1.3 E3–E8): the sign-in confirm page and
exchange, the protected operator page and sign-out. Served at the WAI level,
after route recognition and the request guard ("Lockstep.Web.Application").
The raw sign-in token appears only in the confirm page's hidden field.
-}
module Lockstep.Web.Operator
  ( OperatorRoute (..)
  , matchOperatorRoute
  , handleOperator
  , guardRefusalResponse
  ) where

import Brigid.HTML.Attributes qualified as A
import Brigid.HTML.Elements qualified as E
import Brigid.HTML.Render.ByteString (renderLazyHTML)
import Brigid.HTML.Types qualified as HTML
import Brigid.Types qualified as B
import Control.Monad (unless)
import Data.ByteString qualified as BS
import Data.Function ((&))
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.String.Interpolate qualified as Interpolate
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time qualified as Time
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTP
import Network.Wai qualified as Wai
import Text.Show (Show)
import Web.Cookie qualified as Cookie

import Lockstep.Application.Database (DatabaseRuntime)
import Lockstep.Application.OperatorTrust
  ( Session (..)
  , SignInRefusal (..)
  , exchangeSignIn
  , lookupSession
  , revokeSession
  )
import Lockstep.Foundation.OperatorToken (RawToken, csrfFor, csrfMatches, decodeToken, encodeToken)
import Lockstep.Web.Components.Page (page)
import Lockstep.Web.RequestGuard (GuardRefusal (..))

data OperatorRoute
  = SignInConfirm
  | SignInExchange
  | OperatorHome
  | SignOut
  deriving (Eq, Show)

matchOperatorRoute :: HTTP.Method -> [T.Text] -> Maybe OperatorRoute
matchOperatorRoute method path =
  case (path, method == HTTP.methodGet, method == HTTP.methodPost) of
    (["operator", "sign-in"], True, _) -> Just SignInConfirm
    (["operator", "sign-in"], _, True) -> Just SignInExchange
    (["operator"], True, _) -> Just OperatorHome
    (["operator", "sign-out"], _, True) -> Just SignOut
    _ -> Nothing

handleOperator :: Maybe DatabaseRuntime -> OperatorRoute -> Wai.Request -> IO Wai.Response
handleOperator db route request =
  case route of
    SignInConfirm ->
      pure $
        case singleValue (queryValues "token" request) >>= decodeText of
          Just token -> confirmResponse token
          Nothing -> refusal HTTP.status400 badLinkPage
    SignInExchange ->
      withForm request $ \form ->
        case singleValue (formValues "token" form) >>= decodeText of
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
    OperatorHome ->
      withSession db request $ \_ token session ->
        pure (operatorResponse HTTP.status200 noReferrer (operatorPage token session))
    SignOut ->
      withSession db request $ \runtime token _ ->
        withForm request $ \form ->
          case singleValue (formValues "csrf" form) of
            Just csrf | csrfMatches token (TE.decodeLatin1 csrf) -> do
              _ <- revokeSession runtime token
              pure (redirect "/" [(hSetCookie, clearCookie)])
            _ ->
              pure (refusal HTTP.status403 csrfPage)

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

noStore :: HTTP.Header
noStore =
  ("Cache-Control", "no-store")

htmlType :: HTTP.Header
htmlType =
  (HTTP.hContentType, "text/html; charset=utf-8")

-- | Every operator response is no-store; the policy header is the caller's.
operatorResponse :: HTTP.Status -> HTTP.Header -> E.HTML -> Wai.Response
operatorResponse status policy html =
  Wai.responseLBS status [htmlType, noStore, policy] (renderLazyHTML html)

refusal :: HTTP.Status -> E.HTML -> Wai.Response
refusal status =
  operatorResponse status noReferrer

redirect :: BS.ByteString -> [HTTP.Header] -> Wai.Response
redirect location extra =
  Wai.responseLBS HTTP.status303 ([(HTTP.hLocation, location), noStore, noReferrer] <> extra) ""

-- | E3: the only response that carries the raw sign-in token, once.
confirmResponse :: RawToken -> Wai.Response
confirmResponse token =
  operatorResponse
    HTTP.status200
    ("Referrer-Policy", "origin")
    (confirmPage token)
    & addHeader
      ( "Content-Security-Policy"
      , "default-src 'none'; style-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'"
      )

addHeader :: HTTP.Header -> Wai.Response -> Wai.Response
addHeader header =
  Wai.mapResponseHeaders (<> [header])

signedInResponse :: RawToken -> Wai.Response
signedInResponse session =
  redirect
    "/operator"
    [
      ( hSetCookie
      , sessionCookieName
          <> "="
          <> TE.encodeUtf8 (encodeToken session)
          <> "; Path=/; HttpOnly; SameSite=Strict; Max-Age=43200"
      )
    ]

clearCookie :: BS.ByteString
clearCookie =
  sessionCookieName <> "=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0"

guardRefusalResponse :: GuardRefusal -> Wai.Response
guardRefusalResponse reason =
  refusal HTTP.status403 . messagePage [Interpolate.i|Request refused|] $
    case reason of
      HostRefused -> [Interpolate.i|This service answers only requests addressed to its loopback address and port.|]
      OriginRefused -> [Interpolate.i|This request did not come from a page of this service.|]

-- * Request parsing

decodeText :: BS.ByteString -> Maybe RawToken
decodeText bytes =
  either (const Nothing) decodeToken (TE.decodeUtf8' bytes)

singleValue :: [a] -> Maybe a
singleValue values =
  case values of
    [value] -> Just value
    _ -> Nothing

queryValues :: BS.ByteString -> Wai.Request -> [BS.ByteString]
queryValues name request =
  [fromMaybe "" value | (key, value) <- Wai.queryString request, key == name]

formValues :: BS.ByteString -> [(BS.ByteString, BS.ByteString)] -> [BS.ByteString]
formValues name form =
  [value | (key, value) <- form, key == name]

formLimit :: Int
formLimit =
  16384

drainLimit :: Int
drainLimit =
  1048576

{- | Reads an urlencoded form of at most 16 KiB; a larger body answers 413
after being drained up to 1 MiB so the client can read the response.
-}
withForm :: Wai.Request -> ([(BS.ByteString, BS.ByteString)] -> IO Wai.Response) -> IO Wai.Response
withForm request action =
  let
    collect size chunks = do
      chunk <- Wai.getRequestBodyChunk request
      if BS.null chunk
        then action (HTTP.parseSimpleQuery (BS.concat (L.reverse chunks)))
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
  in
    case (db, singleValue cookies >>= decodeText) of
      (Just runtime, Just token) -> do
        found <- lookupSession runtime token
        case found of
          Just session -> action runtime token session
          Nothing -> pure (refusal HTTP.status401 signedOutPage)
      _ ->
        pure (refusal HTTP.status401 signedOutPage)

-- * Pages

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
            [A.method B.FormPOST, A.action (B.mkRawURL [Interpolate.i|/operator/sign-in|])]
            [ E.input
                [ A.type_ HTML.InputHidden
                , A.customAttribute [Interpolate.i|name|] [Interpolate.i|token|]
                , A.value (encodeToken token)
                ]
            , E.button [] [E.text [Interpolate.i|Sign in|]]
            ]
        ]
    ]

operatorPage :: RawToken -> Session -> E.HTML
operatorPage token session =
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
            [A.method B.FormPOST, A.action (B.mkRawURL [Interpolate.i|/operator/sign-out|])]
            [ E.input
                [ A.type_ HTML.InputHidden
                , A.customAttribute [Interpolate.i|name|] [Interpolate.i|csrf|]
                , A.value (csrfFor token)
                ]
            , E.button [] [E.text [Interpolate.i|Sign out|]]
            ]
        ]
    ]

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

tooLargePage :: E.HTML
tooLargePage =
  messagePage [Interpolate.i|Request refused|] [Interpolate.i|The request body is too large.|]
