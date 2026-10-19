{- | Storage for the sandbox destination (contract C-P2.8 V5, V6): the
simulated external world of the sandbox effects. Statements only; the
adapters in "Lockstep.Application.Sandbox" run each in its own transaction,
never in the ledger's.
-}
module Lockstep.Persistence.Sandbox
  ( recordApplication
  , insertKey
  , keyParameters
  , settleQueryable
  , queryableOutcome
  , applicationCounts
  ) where

import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql
import Orville.PostgreSQL.Raw.SqlValue qualified as SqlValue

sql :: String -> RawSql.RawSql
sql =
  RawSql.fromString

text :: T.Text -> RawSql.RawSql
text =
  RawSql.parameter . SqlValue.fromText

uuid :: T.Text -> RawSql.RawSql
uuid value =
  sql "CAST(" <> text value <> sql " AS uuid)"

marshal :: O.SqlMarshaller a a -> O.AnnotatedSqlMarshaller a a
marshal =
  O.annotateSqlMarshallerEmptyAnnotation

recordApplication :: O.MonadOrville m => T.Text -> T.Text -> T.Text -> m ()
recordApplication operation effect parameters =
  O.executeVoid O.InsertQuery $
    sql "INSERT INTO lockstep_sandbox_applications (operation_id, effect, parameters) VALUES ("
      <> uuid operation
      <> sql ", "
      <> text effect
      <> sql ", "
      <> text parameters
      <> sql ")"

-- | Inserts an idempotency key; True when it was new.
insertKey :: O.MonadOrville m => T.Text -> T.Text -> m Bool
insertKey operation parameters = do
  rows <-
    O.executeAndDecode
      O.InsertQuery
      ( sql "INSERT INTO lockstep_sandbox_keys (operation_id, parameters) VALUES ("
          <> uuid operation
          <> sql ", "
          <> text parameters
          <> sql ") ON CONFLICT DO NOTHING RETURNING operation_id::text AS v"
      )
      (marshal (O.marshallField id (O.unboundedTextField "v")))
  pure (not (null rows))

-- | The parameters an operation id was first applied with, if any.
keyParameters :: O.MonadOrville m => T.Text -> m (Maybe T.Text)
keyParameters operation =
  firstOf
    <$> O.executeAndDecode
      O.SelectQuery
      (sql "SELECT parameters AS v FROM lockstep_sandbox_keys WHERE operation_id = " <> uuid operation)
      (marshal (O.marshallField id (O.unboundedTextField "v")))

{- | The queryable destination's one row per operation id: inserts the outcome
unless a row exists, then returns the row's outcome and whether this call
inserted it. An application inserts @applied@ and a lookup @fenced@; the first
wins.
-}
settleQueryable :: O.MonadOrville m => T.Text -> T.Text -> m (T.Text, Bool)
settleQueryable operation outcome = do
  inserted <-
    O.executeAndDecode
      O.InsertQuery
      ( sql "INSERT INTO lockstep_sandbox_queryable (operation_id, outcome) VALUES ("
          <> uuid operation
          <> sql ", "
          <> text outcome
          <> sql ") ON CONFLICT DO NOTHING RETURNING outcome AS v"
      )
      (marshal (O.marshallField id (O.unboundedTextField "v")))
  current <-
    O.executeAndDecode
      O.SelectQuery
      (sql "SELECT outcome AS v FROM lockstep_sandbox_queryable WHERE operation_id = " <> uuid operation)
      (marshal (O.marshallField id (O.unboundedTextField "v")))
  pure (fromMaybe outcome (firstOf current), not (null inserted))

-- | The queryable destination's outcome for an operation id, if it has one.
queryableOutcome :: O.MonadOrville m => T.Text -> m (Maybe T.Text)
queryableOutcome operation =
  firstOf
    <$> O.executeAndDecode
      O.SelectQuery
      (sql "SELECT outcome AS v FROM lockstep_sandbox_queryable WHERE operation_id = " <> uuid operation)
      (marshal (O.marshallField id (O.unboundedTextField "v")))

-- | (operation, effect, applications), in first-application order.
applicationCounts :: O.MonadOrville m => m [(T.Text, T.Text, Int32)]
applicationCounts =
  O.executeAndDecode
    O.SelectQuery
    (sql "SELECT operation_id::text AS operation_id, effect, count(*)::integer AS n FROM lockstep_sandbox_applications GROUP BY operation_id, effect ORDER BY min(id)")
    ( marshal $
        (,,)
          <$> O.marshallField (\(a, _, _) -> a) (O.unboundedTextField "operation_id")
          <*> O.marshallField (\(_, b, _) -> b) (O.unboundedTextField "effect")
          <*> O.marshallField (\(_, _, c) -> c) (O.integerField "n")
    )

firstOf :: [a] -> Maybe a
firstOf xs =
  case xs of
    x : _ -> Just x
    [] -> Nothing
