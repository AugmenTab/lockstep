{-# LANGUAGE TypeFamilies #-}

{- | Typed keys for Lockstep's keyed tables: Artificer's and Launchpad's
@Database.Entity@ pattern (Launchpad 11886bf, BSD-3-Clause), adapted.

* 'EntityKey' ties each stored row type to exactly one key type, so a
  'Table' for one kind of row accepts only that kind's identity:
  @O.findEntity projectTable taskId@ is a type error.
* Keys are UUIDv4 identities ('Lockstep.Kernel.Identity'), stored in native
  @uuid@ columns through Orville's 'O.uuidField'. The owner-approved
  adaptation (2026-11-08): @Coercible UUID key@ where the references have
  @Coercible Int32 key@.
* A foreign-key column is derived from the table it references
  ('foreignKeyTo'), so the column's Haskell type, its SQL type and its
  constraint come from that table's definition, never written again.

Not adopted, by Lockstep's own contracts: the reference projects' shared
@inserted_at@ / @updated_at@ / @disabled_*@ columns and soft delete (the schema
is owned by the checksummed migrations, ADR-0002, and ledger rows are
append-only), and database-assigned keys (identities are generated at the
boundary, C-P2.1 I1, so a key is part of what is written). The definitions
describe existing tables for typed queries; they never create or migrate one.
-}
module Lockstep.Persistence.Entity
  ( EntityKey
  , Table
  , mkEntityTable
  , keyField
  , foreignKeyTo
  , nullableForeignKeyTo
  , identityField
  ) where

import Data.Coerce (Coercible)
import Data.UUID.Types (UUID)
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O

-- | The identity type of a stored row type.
type family EntityKey row

-- | A table whose key is its rows' identity type; written as @write@, read as @row@.
type Table write row =
  O.TableDefinition (O.HasKey (EntityKey row)) write row

-- | A keyed table: its name, its key column and its marshaller.
mkEntityTable :: String -> O.FieldDefinition O.NotNull (EntityKey row) -> O.SqlMarshaller write row -> Table write row
mkEntityTable name key =
  O.mkTableDefinition name (O.primaryKey key)

-- | A table's own key column (@id@ unless named otherwise), typed as its identity.
keyField :: Coercible UUID key => String -> O.FieldDefinition O.NotNull key
keyField =
  identityField

-- | A @uuid@ column holding one kind of identity.
identityField :: Coercible UUID key => String -> O.FieldDefinition O.NotNull key
identityField =
  O.coerceField . O.uuidField

{- | A column referencing another table's key: the referenced key's type, and
the foreign-key constraint to it, taken from that table's definition.
-}
foreignKeyTo :: O.TableDefinition (O.HasKey key) write row -> O.FieldDefinition O.NotNull key -> String -> O.FieldDefinition O.NotNull key
foreignKeyTo table referencedKey column =
  O.addForeignKeyConstraint (O.tableIdentifier table) (O.fieldName referencedKey) (O.setFieldName (O.stringToFieldName column) referencedKey)

-- | 'foreignKeyTo' for a column that may be empty.
nullableForeignKeyTo :: O.TableDefinition (O.HasKey key) write row -> O.FieldDefinition O.NotNull key -> String -> O.FieldDefinition O.Nullable (Maybe key)
nullableForeignKeyTo table referencedKey =
  O.nullableField . foreignKeyTo table referencedKey
