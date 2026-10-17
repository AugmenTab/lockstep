{- | Storage for operator sign-in tokens and sessions (contract C-P1.3 E4, E5,
E9, E10). Only SHA-256 digests reach the database; they are sent as hex text
parameters and decoded by PostgreSQL.
-}
module Lockstep.Persistence.OperatorSessions
  ( insertSignInToken
  , consumeSignInToken
  , insertSession
  , liveSessionExpiry
  , revokeSession
  , revokeLiveSessions
  ) where

import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString qualified as BS
import Data.Text.Encoding qualified as TE
import Data.Time qualified as Time
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql
import Orville.PostgreSQL.Raw.SqlValue qualified as SqlValue

digestSql :: BS.ByteString -> RawSql.RawSql
digestSql digest =
  RawSql.fromString "decode("
    <> RawSql.parameter (SqlValue.fromText (TE.decodeLatin1 (convertToBase Base16 digest)))
    <> RawSql.fromString ", 'hex')"

-- | Stores a new sign-in token digest that expires 5 minutes from now.
insertSignInToken :: O.MonadOrville m => BS.ByteString -> m ()
insertSignInToken digest =
  O.executeVoid O.InsertQuery $
    RawSql.fromString "INSERT INTO lockstep_operator_sign_in_tokens (digest, expires_at) VALUES ("
      <> digestSql digest
      <> RawSql.fromString ", now() + interval '5 minutes')"

{- | Marks the token consumed if it is unconsumed and unexpired; 'True' when
this call consumed it. A concurrent consumer waits on the row lock and then
finds it consumed.
-}
consumeSignInToken :: O.MonadOrville m => BS.ByteString -> m Bool
consumeSignInToken digest = do
  rows <-
    O.executeAndDecode
      O.UpdateQuery
      ( RawSql.fromString "UPDATE lockstep_operator_sign_in_tokens SET consumed_at = now() WHERE digest = "
          <> digestSql digest
          <> RawSql.fromString " AND consumed_at IS NULL AND expires_at > now() RETURNING 1::integer AS v"
      )
      (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.integerField "v")))
  pure (not (null rows))

-- | Stores a new session digest with a 12-hour absolute expiry; returns it.
insertSession :: O.MonadOrville m => BS.ByteString -> m (Maybe Time.UTCTime)
insertSession digest = do
  rows <-
    O.executeAndDecode
      O.InsertQuery
      ( RawSql.fromString "INSERT INTO lockstep_operator_sessions (digest, expires_at) VALUES ("
          <> digestSql digest
          <> RawSql.fromString ", now() + interval '12 hours') RETURNING expires_at AS v"
      )
      (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.utcTimestampField "v")))
  pure (headMay rows)

-- | The expiry of an unrevoked, unexpired session.
liveSessionExpiry :: O.MonadOrville m => BS.ByteString -> m (Maybe Time.UTCTime)
liveSessionExpiry digest = do
  rows <-
    O.executeAndDecode
      O.SelectQuery
      ( RawSql.fromString "SELECT expires_at AS v FROM lockstep_operator_sessions WHERE digest = "
          <> digestSql digest
          <> RawSql.fromString " AND revoked_at IS NULL AND expires_at > now()"
      )
      (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.utcTimestampField "v")))
  pure (headMay rows)

revokeSession :: O.MonadOrville m => BS.ByteString -> m ()
revokeSession digest =
  O.executeVoid O.UpdateQuery $
    RawSql.fromString "UPDATE lockstep_operator_sessions SET revoked_at = now() WHERE digest = "
      <> digestSql digest
      <> RawSql.fromString " AND revoked_at IS NULL"

-- | Revokes every unrevoked, unexpired session; returns how many.
revokeLiveSessions :: O.MonadOrville m => m Int
revokeLiveSessions = do
  rows <-
    O.executeAndDecode
      O.UpdateQuery
      ( RawSql.fromString
          "WITH revoked AS (UPDATE lockstep_operator_sessions SET revoked_at = now() WHERE revoked_at IS NULL AND expires_at > now() RETURNING 1) SELECT count(*)::integer AS v FROM revoked"
      )
      (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.integerField "v")))
  pure (maybe 0 fromIntegral (headMay rows))

headMay :: [a] -> Maybe a
headMay xs =
  case xs of
    [] -> Nothing
    x : _ -> Just x
