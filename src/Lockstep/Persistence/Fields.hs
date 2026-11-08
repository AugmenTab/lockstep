{- | Shared Orville building blocks for Lockstep's typed table definitions.

The schema is owned by the append-only, checksummed migrations in
"Lockstep.Persistence.Migrations". The table definitions built from these
pieces describe those existing tables for Orville's typed queries; they are
never used to create or migrate a table.

Patterned on Launchpad 11886bf (@Launchpad.Database.Entity@,
@Util.Orville.Fleece@): field types live beside the persistence layer, and the
few SQL expressions Orville has no typed constructor for are named here once.
-}
module Lockstep.Persistence.Fields
  ( -- * Field types
    uuidField
  , digestField
  , hexDigest
  , codeField

    -- * Marshalling
  , marshal
  , headMay

    -- * Values computed by the server
  , clockTimestamp
  , setExpression
  , setNow
  , increment

    -- * Selecting
  , forUpdate
  , forUpdateOf
  , forUpdateSkipLocked
  , qualified
  , qualifiedEquals
  , qualifiedReference
  , qualifiedOrder
  , joinedOn
  , tableReference
  , selectJoined
  , selectValue
  , countOf

    -- * Writing
  , insertIgnoringConflict
  , ConflictTarget (..)
  , Assignment
  , assignValue
  , assignExpression
  , insertComputed
  , minutes
  , returnedAny
  ) where

import Control.Monad ((<=<))
import Data.ByteArray.Encoding (Base (Base16), convertFromBase, convertToBase)
import Data.ByteString qualified as BS
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Database.PostgreSQL.LibPQ qualified as LibPQ
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Orville.PostgreSQL.Execution.Insert qualified as Insert
import Orville.PostgreSQL.Execution.ReturningOption qualified as Returning
import Orville.PostgreSQL.Execution.Select qualified as Select
import Orville.PostgreSQL.Execution.SelectOptions qualified as SelectOptions
import Orville.PostgreSQL.Expr qualified as Expr
import Orville.PostgreSQL.Marshall.SqlMarshaller qualified as SqlMarshaller
import Orville.PostgreSQL.Raw.RawSql qualified as RawSql
import Orville.PostgreSQL.Raw.SqlValue qualified as SqlValue
import Orville.PostgreSQL.Schema.TableDefinition qualified as TableDefinition

{- | A @uuid@ column whose values Lockstep carries as their canonical text
(lowercase, hyphenated). Parameters are sent as untyped text, so PostgreSQL
parses them as @uuid@ (a malformed value is refused by the server, as the
former @CAST(... AS uuid)@ was), and values come back in the same text form
@id::text@ produced.
-}
uuidField :: String -> O.FieldDefinition O.NotNull T.Text
uuidField =
  O.fieldOfType
    O.unboundedText
      { O.sqlTypeExpr = Expr.uuid
      , O.sqlTypeOid = O.sqlTypeOid O.uuid
      }

{- | A @bytea@ column holding a digest. Orville 1.1 has no @bytea@ type, so it
is defined here over PostgreSQL's text format: values are sent as @\\x@ hex
input and read from the server's default @bytea_output = hex@.
-}
digestField :: String -> O.FieldDefinition O.NotNull BS.ByteString
digestField =
  O.fieldOfType byteaType

byteaType :: O.SqlType BS.ByteString
byteaType =
  O.SqlType
    { O.sqlTypeExpr = RawSql.unsafeSqlExpression "bytea"
    , O.sqlTypeReferenceExpr = Nothing
    , O.sqlTypeOid = LibPQ.Oid 17
    , O.sqlTypeMaximumLength = Nothing
    , O.sqlTypeToSql = \bytes -> SqlValue.fromText (T.pack "\\x" <> hexDigest bytes)
    , O.sqlTypeFromSql = fromByteaText <=< SqlValue.toText
    , O.sqlTypeDontDropImplicitDefaultDuringMigrate = False
    }

fromByteaText :: T.Text -> Either String BS.ByteString
fromByteaText value =
  case T.stripPrefix (T.pack "\\x") value of
    Nothing -> Left "lockstep: a bytea value is not in hex output format"
    Just hex -> convertFromBase Base16 (TE.encodeUtf8 hex)

{- | A text column holding one code of a closed set, read and written as its
Haskell type (Launchpad's @convertField@ / @tryConvertSqlType@ pattern). A
stored code the type does not know is a decoding failure, never a default.
-}
codeField :: String -> (a -> T.Text) -> (T.Text -> Maybe a) -> String -> O.FieldDefinition O.NotNull a
codeField what toCode fromCode name =
  O.convertField (O.tryConvertSqlType toCode decode) (O.unboundedTextField name)
 where
  decode code =
    maybe (Left ("lockstep: column " <> name <> " holds an unknown " <> what <> " code: " <> T.unpack code)) Right (fromCode code)

-- | Lowercase hex, as PostgreSQL's @encode(..., 'hex')@ gives it.
hexDigest :: BS.ByteString -> T.Text
hexDigest =
  TE.decodeLatin1 . convertToBase Base16

marshal :: O.SqlMarshaller a b -> O.AnnotatedSqlMarshaller a b
marshal =
  O.annotateSqlMarshallerEmptyAnnotation

headMay :: [a] -> Maybe a
headMay xs =
  case xs of
    [] -> Nothing
    x : _ -> Just x

-- | PostgreSQL's @clock_timestamp()@: the statement's own time, not the transaction's.
clockTimestamp :: Expr.ValueExpression
clockTimestamp =
  Expr.functionCall (Expr.functionName "clock_timestamp") []

-- | @column = expression@, for values the server computes.
setExpression :: O.FieldDefinition nullability a -> Expr.ValueExpression -> Expr.SetClause
setExpression field =
  Expr.setColumnExpression (Expr.unqualified (O.fieldColumnName field) :| [])

-- | @column = now()@: the transaction's time.
setNow :: O.FieldDefinition nullability a -> Expr.SetClause
setNow field =
  setExpression field Expr.now

-- | @column = column + 1@.
increment :: O.FieldDefinition nullability a -> Expr.SetClause
increment field =
  setExpression field (Expr.plus (O.fieldColumnReference field) (Expr.valueExpression (SqlValue.fromInt32 1)))

-- | @FOR UPDATE@: the selected rows stay locked until the transaction ends.
forUpdate :: O.SelectOptions
forUpdate =
  O.forRowLock (O.rowLockingClause Expr.updateStrength Nothing Nothing)

-- | @FOR UPDATE SKIP LOCKED@: rows another transaction holds are passed over.
forUpdateSkipLocked :: O.SelectOptions
forUpdateSkipLocked =
  O.forRowLock (O.rowLockingClause Expr.updateStrength Nothing (Just Expr.skipLockedRowLockingOption))

-- | @FOR UPDATE OF table@: in a join, only the named table's rows are locked.
forUpdateOf :: O.TableDefinition key w r -> O.SelectOptions
forUpdateOf table =
  O.forRowLock
    ( O.rowLockingClause
        Expr.updateStrength
        (Just (Expr.tableName (O.tableIdUnqualifiedNameString (O.tableIdentifier table)) :| []))
        Nothing
    )

-- | A field qualified by its table, for statements that join tables.
qualified :: O.TableDefinition key w r -> O.FieldDefinition nullability a -> O.QualifiedFieldDefinition O.TableIdentifier nullability a
qualified table =
  O.qualifyField (O.tableIdentifier table)

qualifiedReference :: O.QualifiedFieldDefinition O.TableIdentifier nullability a -> Expr.ValueExpression
qualifiedReference =
  O.referenceValueExpression

qualifiedEquals :: O.QualifiedFieldDefinition O.TableIdentifier nullability a -> a -> Expr.BooleanExpr
qualifiedEquals field value =
  Expr.equals (O.referenceValueExpression field) (Expr.valueExpression (O.toComparableSqlValue field value))

qualifiedOrder :: O.QualifiedFieldDefinition O.TableIdentifier nullability a -> O.OrderByDirection -> Expr.OrderByExpr
qualifiedOrder =
  O.orderBySqlComparable

{- | @base JOIN other ON condition@ (inner or left, by the join type given),
starting from a table definition.
-}
joinedOn :: O.TableDefinition key w r -> [(Expr.JoinType, Expr.TableReference, Expr.BooleanExpr)] -> Expr.TableReference
joinedOn base joins =
  Expr.joining
    (tableReference base)
    [Expr.join joinType other (Expr.joinOnConstraint condition) | (joinType, other, condition) <- joins]

tableReference :: O.TableDefinition key w r -> Expr.TableReference
tableReference table =
  Expr.tableNameReference (O.tableName table) Nothing

{- | Selects the marshaller's (qualified) columns from a join. Orville's entity
operations read one table; this is the same select built over a join.
-}
selectJoined :: O.MonadOrville m => O.SqlMarshaller w r -> Expr.TableReference -> O.SelectOptions -> m [r]
selectJoined marshaller from options =
  Select.executeSelect
    ( Select.rawSelectQueryExpr
        (marshal marshaller)
        ( SelectOptions.selectOptionsQueryExpr
            (Expr.selectDerivedColumns (SqlMarshaller.marshallerDerivedColumns marshaller))
            (Expr.tableReferenceList [from])
            options
        )
    )

-- | @SELECT expression AS column@: a value the server computes, read through the field.
selectValue :: O.MonadOrville m => Expr.ValueExpression -> O.FieldDefinition nullability a -> m [a]
selectValue expression field =
  Select.executeSelect
    ( Select.rawSelectQueryExpr
        (marshal (O.marshallReadOnlyField field))
        ( Expr.queryExpr
            (Expr.selectClause (Expr.selectExpr Nothing))
            (Expr.selectDerivedColumns [Expr.deriveColumnAs expression (O.fieldColumnName field)])
            Nothing
        )
    )

-- | @count(1)::integer AS alias@, for a grouped select.
countOf :: String -> O.SqlMarshaller w Int32
countOf alias =
  O.marshallSyntheticField (O.syntheticField (Expr.cast Expr.count1AggregateFunction Expr.int) alias O.integer)

-- | Which uniqueness an insert may run into without failing.
data ConflictTarget
  = -- | any unique constraint (@ON CONFLICT DO NOTHING@)
    AnyConflict
  | -- | the unique index on one column (@ON CONFLICT (column) DO NOTHING@)
    ConflictOn String

{- | Inserts one row unless it conflicts; True when this call inserted it.
Orville's entity operations have no @ON CONFLICT@, so the insert is built from
the table definition with 'TableDefinition.mkInsertExpr'.
-}
insertIgnoringConflict :: O.MonadOrville m => ConflictTarget -> O.TableDefinition key w r -> w -> m Bool
insertIgnoringConflict target table row =
  let
    onConflict =
      case target of
        AnyConflict -> Expr.onConflictDoNothing
        ConflictOn column ->
          -- Orville 1.1 exports DO NOTHING only for the target-less form.
          Expr.onConflict
            (Just (Expr.conflictTargetForIndexColumn (Expr.unqualified (Expr.columnName column)) Nothing))
            (RawSql.unsafeSqlExpression "DO NOTHING")
  in
    returnedAny
      <$> Insert.executeInsertReturnEntities
        ( Insert.rawInsertExpr
            Returning.WithReturning
            (O.tableMarshaller table)
            (TableDefinition.mkInsertExpr Returning.WithReturning table (Just onConflict) (row :| []))
        )

-- | One column of an insert whose value is an expression.
data Assignment
  = Assignment Expr.ColumnName Expr.ValueExpression

-- | The column gets this Haskell value, encoded by the field's type.
assignValue :: O.FieldDefinition nullability a -> a -> Assignment
assignValue field value =
  Assignment (O.fieldColumnName field) (Expr.valueExpression (O.sqlTypeToSql (O.fieldType field) value))

-- | The column gets a value the server computes (for example from @now()@).
assignExpression :: O.FieldDefinition nullability a -> Expr.ValueExpression -> Assignment
assignExpression field =
  Assignment (O.fieldColumnName field)

{- | Inserts one row whose values may be computed by the server, and returns
it through the table's marshaller. Orville's entity inserts take Haskell
values only; this is the same insert built from 'Expr.valuesExprFromValueExpressions'.
-}
insertComputed :: O.MonadOrville m => O.TableDefinition key w r -> NonEmpty Assignment -> m [r]
insertComputed table assignments =
  let
    columns = [Expr.unqualified column | Assignment column _ <- toList assignments]
    values = fmap (\(Assignment _ value) -> value) assignments
  in
    Insert.executeInsertReturnEntities
      ( Insert.rawInsertExpr
          Returning.WithReturning
          (O.tableMarshaller table)
          ( Expr.insertExpr
              (O.tableName table)
              (Just (Expr.insertColumnList columns))
              (Expr.valuesExprInsertSource (Expr.valuesExprFromValueExpressions (values :| [])))
              Nothing
              (TableDefinition.mkTableReturningClause Returning.WithReturning table)
          )
      )

-- | @make_interval@ of whole minutes (the server adds it to its own clock).
minutes :: Int32 -> Expr.ValueExpression
minutes count =
  Expr.functionCall
    (Expr.functionName "make_interval")
    [Expr.valueExpression (SqlValue.fromInt32 n) | n <- [0, 0, 0, 0, 0, count]]

returnedAny :: [a] -> Bool
returnedAny =
  not . null
