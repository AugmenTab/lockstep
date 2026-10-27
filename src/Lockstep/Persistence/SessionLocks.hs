{- | PostgreSQL session-level advisory locks (contract C-C.R1 R1, R5). A lock is
named by a namespace (a fixed number per kind of work) and a text key, hashed
by the server. The caller keeps one connection pinned for the lock's whole
life; these statements must all run on that connection.
-}
module Lockstep.Persistence.SessionLocks
  ( acquire
  , held
  , release
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql
import Orville.PostgreSQL.Raw.SqlValue qualified as SqlValue
import Text.Show (show)

sql :: String -> RawSql.RawSql
sql =
  RawSql.fromString

text :: T.Text -> RawSql.RawSql
text =
  RawSql.parameter . SqlValue.fromText

{- | Waits at most the given number of seconds for the lock. A lock not granted
in time raises PostgreSQL's @lock_not_available@ (SQLSTATE 55P03).
-}
acquire :: O.MonadOrville m => Int32 -> Int -> T.Text -> m ()
acquire namespace seconds key = do
  O.executeVoid O.OtherQuery (sql ("SET lock_timeout = '" <> show seconds <> "s'"))
  O.executeVoid O.OtherQuery (sql ("SELECT pg_advisory_lock(" <> show namespace <> ", hashtext(") <> text key <> sql "))")

-- | Whether this connection's session holds the lock now.
held :: O.MonadOrville m => Int32 -> T.Text -> m Bool
held namespace key = do
  rows <-
    O.executeAndDecode
      O.SelectQuery
      ( sql
          ( "SELECT EXISTS (SELECT 1 FROM pg_locks WHERE locktype = 'advisory' AND granted AND pid = pg_backend_pid() AND objsubid = 2 AND classid = "
              <> show namespace
              <> " AND objid = CAST(hashtext("
          )
          <> text key
          <> sql ") AS oid)) AS v"
      )
      (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.booleanField "v")))
  pure (rows == [True])

-- | Releases the lock; True when this session held it.
release :: O.MonadOrville m => Int32 -> T.Text -> m Bool
release namespace key = do
  rows <-
    O.executeAndDecode
      O.SelectQuery
      (sql ("SELECT pg_advisory_unlock(" <> show namespace <> ", hashtext(") <> text key <> sql ")) AS v")
      (O.annotateSqlMarshallerEmptyAnnotation (O.marshallField id (O.booleanField "v")))
  pure (rows == [True])
