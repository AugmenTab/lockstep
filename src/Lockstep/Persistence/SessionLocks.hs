{- | PostgreSQL session-level advisory locks (contract C-C.R1 R1, R5). A lock is
named by a namespace (a fixed number per kind of work) and a text key, hashed
by the server. The caller keeps one connection pinned for the lock's whole
life; these statements must all run on that connection.

Orville does not model advisory locks or session settings. The lock and unlock
are typed function calls; @SET lock_timeout@ (a @SET@ takes no parameters) and
the @pg_locks@ probe stay as SQL, with every value either a parameter or an
integer.
-}
module Lockstep.Persistence.SessionLocks
  ( acquire
  , held
  , release
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Expr qualified as Expr
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql
import Orville.PostgreSQL.Raw.SqlValue qualified as SqlValue
import Text.Show (show)

import Lockstep.Persistence.Fields (selectValue)

-- | The lock's two keys: the namespace and @hashtext(key)@.
lockKeys :: Int32 -> T.Text -> [Expr.ValueExpression]
lockKeys namespace key =
  [ Expr.valueExpression (SqlValue.fromInt32 namespace)
  , Expr.functionCall (Expr.functionName "hashtext") [Expr.cast (Expr.valueExpression (SqlValue.fromText key)) Expr.text]
  ]

{- | Waits at most the given number of seconds for the lock. A lock not granted
in time raises PostgreSQL's @lock_not_available@ (SQLSTATE 55P03).
-}
acquire :: O.MonadOrville m => Int32 -> Int -> T.Text -> m ()
acquire namespace seconds key = do
  O.executeVoid O.OtherQuery (RawSql.fromString ("SET lock_timeout = '" <> show seconds <> "s'"))
  -- pg_advisory_lock returns void, read as its (empty) text.
  void (selectValue (Expr.functionCall (Expr.functionName "pg_advisory_lock") (lockKeys namespace key)) (O.unboundedTextField "v"))

-- | Whether this connection's session holds the lock now.
held :: O.MonadOrville m => Int32 -> T.Text -> m Bool
held namespace key = do
  rows <-
    O.executeAndDecode
      O.SelectQuery
      ( RawSql.fromString
          ( "SELECT EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND granted AND pid = pg_backend_pid() AND objsubid = 2 AND classid = "
              <> show namespace
              <> " AND objid = CAST(hashtext("
          )
          <> RawSql.parameter (SqlValue.fromText key)
          <> RawSql.fromString ") AS oid)) AS v"
      )
      (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.booleanField "v")))
  pure (rows == [True])

-- | Releases the lock; True when this session held it.
release :: O.MonadOrville m => Int32 -> T.Text -> m Bool
release namespace key = do
  rows <- selectValue (Expr.functionCall (Expr.functionName "pg_advisory_unlock") (lockKeys namespace key)) (O.booleanField "v")
  pure (rows == [True])
