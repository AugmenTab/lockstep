{- | Stable typed identities (contract C-P2.1 I1, DG-03 D-3.1a). Each kind is
its own newtype over 'Data.UUID.Types.UUID' (the @uuid-types@ library), so one
kind cannot be passed where another is expected. Identities are generated at
the boundary ('Lockstep.Application.Identity', @Data.UUID.V4@) and enter the
Kernel as values; none is derived from a path, remote or commit.

Text is a boundary representation only. 'parseUuid' is the library's parser
with Lockstep's one extra rule, the canonical spelling (C-P2.1 I1: lowercase,
hyphenated): a value is accepted only when the library renders it back
exactly as given.
-}
module Lockstep.Kernel.Identity
  ( -- * UUIDs
    Uuid
  , IdentityError (..)
  , parseUuid
  , uuidText
  , uuidFromBytes
  , uuidFromWords

    -- * Identities of the Kernel's subjects
  , RepositoryId (..)
  , EngineerId (..)
  , TicketId (..)
  , WorkOrderId (..)
  , WorkUnitId (..)
  , ContractId (..)
  , AttemptId (..)

    -- * Identities of the application's records
  , ProjectId (..)
  , TaskId (..)
  , TransactionId (..)
  , InvocationId (..)
  , HumanRequestId (..)

    -- * Parsing and rendering any of them
  , parseIdentity
  , identityText
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Coerce (Coercible, coerce)
import Data.Text qualified as T
import Data.UUID.Types qualified as UUID
import Flipstone.Prelude
import Text.Show (Show)

-- | A 128-bit identifier: the library's type.
type Uuid = UUID.UUID

data IdentityError
  = UuidMalformed
  | UuidWrongLength
  deriving (Eq, Show)

newtype RepositoryId
  = RepositoryId Uuid
  deriving (Eq, Ord, Show)

newtype EngineerId
  = EngineerId Uuid
  deriving (Eq, Ord, Show)

newtype TicketId
  = TicketId Uuid
  deriving (Eq, Ord, Show)

newtype WorkOrderId
  = WorkOrderId Uuid
  deriving (Eq, Ord, Show)

newtype WorkUnitId
  = WorkUnitId Uuid
  deriving (Eq, Ord, Show)

newtype ContractId
  = ContractId Uuid
  deriving (Eq, Ord, Show)

newtype AttemptId
  = AttemptId Uuid
  deriving (Eq, Ord, Show)

-- | A project (C-P3.5).
newtype ProjectId
  = ProjectId Uuid
  deriving (Eq, Ord, Show)

-- | A task (C-P3.6); its Ticket has the same UUID.
newtype TaskId
  = TaskId Uuid
  deriving (Eq, Ord, Show)

-- | A coding transaction (C-P4.6).
newtype TransactionId
  = TransactionId Uuid
  deriving (Eq, Ord, Show)

-- | One recorded role or check invocation of a transaction (C-P4.6 T5).
newtype InvocationId
  = InvocationId Uuid
  deriving (Eq, Ord, Show)

-- | A Human Request and its conversation (C-P3.9).
newtype HumanRequestId
  = HumanRequestId Uuid
  deriving (Eq, Ord, Show)

-- | The big-endian halves, as 'UUID.fromWords64'.
uuidFromWords :: Word64 -> Word64 -> Uuid
uuidFromWords =
  UUID.fromWords64

-- | Exactly 16 bytes, big-endian ('UUID.fromByteString').
uuidFromBytes :: BS.ByteString -> Either IdentityError Uuid
uuidFromBytes =
  maybe (Left UuidWrongLength) Right . UUID.fromByteString . LBS.fromStrict

{- | The canonical form only: lowercase hex in 8-4-4-4-12 groups. The library
parses ('UUID.fromText' also accepts uppercase); the value is kept only when
'UUID.toText' gives back exactly the input.
-}
parseUuid :: T.Text -> Either IdentityError Uuid
parseUuid text =
  case UUID.fromText text of
    Just uuid | UUID.toText uuid == text -> Right uuid
    _ -> Left UuidMalformed

-- | The canonical text: lowercase, hyphenated ('UUID.toText').
uuidText :: Uuid -> T.Text
uuidText =
  UUID.toText

{- | Any identity from its canonical text. Each kind is a newtype over 'Uuid'
(the @Coercible Uuid@ constraint, as Launchpad's keys are @Coercible Int32@),
so the text form, the Orville column, the Fleece schema and the route
parameter of every kind are the same library code.
-}
parseIdentity :: Coercible Uuid identity => T.Text -> Maybe identity
parseIdentity =
  either (const Nothing) (Just . coerce) . parseUuid

-- | Any identity's canonical text.
identityText :: Coercible identity Uuid => identity -> T.Text
identityText =
  uuidText . coerce
