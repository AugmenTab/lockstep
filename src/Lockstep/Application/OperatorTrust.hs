{- | Local operator trust (contract C-P1.3): one-time sign-in tokens issued by
the CLI, exchanged by the browser for a server-side session, and revocation.
Used by both the CLI and Web.
-}
module Lockstep.Application.OperatorTrust
  ( SignInRefusal (..)
  , Session (..)
  , issueSignIn
  , exchangeSignIn
  , lookupSession
  , revokeSession
  , revokeAllSessions
  , signInUrl
  ) where

import Data.Text qualified as T
import Data.Time qualified as Time
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Text.Show (Show)

import Lockstep.Application.Database
  ( DatabaseRuntime
  , NotReadyReason
  , Readiness (..)
  , checkReadiness
  , withDatabase
  )
import Lockstep.Foundation.Config (Port, loopbackOrigin)
import Lockstep.Foundation.OperatorToken (RawToken, encodeToken, generateToken, tokenDigest)
import Lockstep.Persistence.OperatorSessions qualified as Store

data SignInRefusal
  = SignInTokenRefused
  | SignInNotReady NotReadyReason
  deriving (Eq, Show)

newtype Session
  = Session
  { sessionExpiresAt :: Time.UTCTime
  }
  deriving (Eq, Show)

whenReady :: DatabaseRuntime -> IO (Either NotReadyReason a) -> IO (Either NotReadyReason a)
whenReady runtime action = do
  readiness <- checkReadiness (Just runtime)
  case readiness of
    NotReady reason -> pure (Left reason)
    Ready _ -> action

-- | A new sign-in token (5-minute expiry); only its digest is stored.
issueSignIn :: DatabaseRuntime -> IO (Either NotReadyReason RawToken)
issueSignIn runtime =
  whenReady runtime $ do
    token <- generateToken
    stored <- withDatabase runtime (Store.insertSignInToken (tokenDigest token))
    pure (token <$ stored)

{- | Consumes the sign-in token and creates a session in one transaction;
returns the new session token.
-}
exchangeSignIn :: DatabaseRuntime -> RawToken -> IO (Either SignInRefusal RawToken)
exchangeSignIn runtime token = do
  session <- generateToken
  result <-
    withDatabase runtime . O.withTransaction $ do
      consumed <- Store.consumeSignInToken (tokenDigest token)
      if consumed
        then Store.insertSession (tokenDigest session)
        else pure Nothing
  pure $
    case result of
      Left reason -> Left (SignInNotReady reason)
      Right Nothing -> Left SignInTokenRefused
      Right (Just _) -> Right session

-- | The live session for a token; any failure counts as no session.
lookupSession :: DatabaseRuntime -> RawToken -> IO (Maybe Session)
lookupSession runtime token = do
  result <- withDatabase runtime (Store.liveSessionExpiry (tokenDigest token))
  pure (either (const Nothing) (fmap Session) result)

revokeSession :: DatabaseRuntime -> RawToken -> IO (Either NotReadyReason ())
revokeSession runtime token =
  withDatabase runtime (Store.revokeSession (tokenDigest token))

-- | Revokes every live session; returns how many.
revokeAllSessions :: DatabaseRuntime -> IO (Either NotReadyReason Int)
revokeAllSessions runtime =
  whenReady runtime (withDatabase runtime Store.revokeLiveSessions)

signInUrl :: Port -> RawToken -> T.Text
signInUrl port token =
  T.pack (loopbackOrigin port) <> T.pack "/operator/sign-in?token=" <> encodeToken token
