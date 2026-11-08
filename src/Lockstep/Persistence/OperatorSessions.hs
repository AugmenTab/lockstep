{- | Storage for operator sign-in tokens and sessions (contract C-P1.3 E4, E5,
E9, E10). Only SHA-256 digests reach the database, in @bytea@ columns.
Expiry times come from the database clock.
-}
module Lockstep.Persistence.OperatorSessions
  ( insertSignInToken
  , consumeSignInToken
  , insertSession
  , liveSessionExpiry
  , revokeSession
  , revokeLiveSessions
  ) where

import Data.ByteString qualified as BS
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Time qualified as Time
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Expr qualified as Expr

import Lockstep.Persistence.Fields (assignExpression, assignValue, digestField, headMay, insertComputed, minutes, setNow)

-- | A token or session row: (digest, expiry).
type Credential = (BS.ByteString, Time.UTCTime)

credentialTable :: String -> O.FieldDefinition O.Nullable (Maybe Time.UTCTime) -> O.TableDefinition (O.HasKey BS.ByteString) Credential Credential
credentialTable name endedField =
  O.mkTableDefinition name (O.primaryKey credentialDigestField) $
    (\digest expiresAt _ended -> (digest, expiresAt))
      <$> O.marshallField fst credentialDigestField
      <*> O.marshallField snd credentialExpiresAtField
      <*> O.marshallReadOnlyField endedField

credentialDigestField :: O.FieldDefinition O.NotNull BS.ByteString
credentialDigestField =
  digestField "digest"

credentialExpiresAtField :: O.FieldDefinition O.NotNull Time.UTCTime
credentialExpiresAtField =
  O.utcTimestampField "expires_at"

-- | The credential has not expired by the transaction's time.
unexpired :: Expr.BooleanExpr
unexpired =
  Expr.greaterThan (O.fieldColumnReference credentialExpiresAtField) Expr.now

-- | Inserts a credential that expires the given number of minutes after the transaction's time.
insertCredential :: O.MonadOrville m => O.TableDefinition (O.HasKey BS.ByteString) Credential Credential -> BS.ByteString -> Int32 -> m [Credential]
insertCredential table digest lifetime =
  insertComputed
    table
    ( assignValue credentialDigestField digest
        :| [assignExpression credentialExpiresAtField (Expr.plus Expr.now (minutes lifetime))]
    )

-- lockstep_operator_sign_in_tokens -------------------------------------------------

signInTokenTable :: O.TableDefinition (O.HasKey BS.ByteString) Credential Credential
signInTokenTable =
  credentialTable "lockstep_operator_sign_in_tokens" consumedAtField

consumedAtField :: O.FieldDefinition O.Nullable (Maybe Time.UTCTime)
consumedAtField =
  O.nullableField (O.utcTimestampField "consumed_at")

-- | Stores a new sign-in token digest that expires 5 minutes from now.
insertSignInToken :: O.MonadOrville m => BS.ByteString -> m ()
insertSignInToken digest =
  void (insertCredential signInTokenTable digest 5)

{- | Marks the token consumed if it is unconsumed and unexpired; 'True' when
this call consumed it. A concurrent consumer waits on the row lock and then
finds it consumed.
-}
consumeSignInToken :: O.MonadOrville m => BS.ByteString -> m Bool
consumeSignInToken digest =
  not . null
    <$> O.updateFieldsAndReturnEntities
      signInTokenTable
      (setNow consumedAtField :| [])
      (Just (O.fieldEquals credentialDigestField digest `O.andExpr` O.fieldIsNull consumedAtField `O.andExpr` unexpired))

-- lockstep_operator_sessions -------------------------------------------------------

sessionTable :: O.TableDefinition (O.HasKey BS.ByteString) Credential Credential
sessionTable =
  credentialTable "lockstep_operator_sessions" revokedAtField

revokedAtField :: O.FieldDefinition O.Nullable (Maybe Time.UTCTime)
revokedAtField =
  O.nullableField (O.utcTimestampField "revoked_at")

-- | Stores a new session digest with a 12-hour absolute expiry; returns it.
insertSession :: O.MonadOrville m => BS.ByteString -> m (Maybe Time.UTCTime)
insertSession digest =
  fmap snd . headMay <$> insertCredential sessionTable digest (12 * 60)

-- | The session is neither revoked nor expired.
live :: Expr.BooleanExpr
live =
  O.fieldIsNull revokedAtField `O.andExpr` unexpired

-- | The expiry of an unrevoked, unexpired session.
liveSessionExpiry :: O.MonadOrville m => BS.ByteString -> m (Maybe Time.UTCTime)
liveSessionExpiry digest =
  fmap snd <$> O.findFirstEntityBy sessionTable (O.where_ (O.fieldEquals credentialDigestField digest `O.andExpr` live))

revokeSession :: O.MonadOrville m => BS.ByteString -> m ()
revokeSession digest =
  O.updateFields
    sessionTable
    (setNow revokedAtField :| [])
    (Just (O.fieldEquals credentialDigestField digest `O.andExpr` O.fieldIsNull revokedAtField))

-- | Revokes every unrevoked, unexpired session; returns how many.
revokeLiveSessions :: O.MonadOrville m => m Int
revokeLiveSessions =
  O.updateFieldsAndReturnRowCount sessionTable (setNow revokedAtField :| []) (Just live)
