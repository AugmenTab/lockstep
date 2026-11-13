{-# LANGUAGE OverloadedStrings #-}

{- | Increment B of the type-discipline remediation (2026-11-08): the typed
identities. Every kind parses from and renders to the same canonical text
(lowercase, hyphenated, through @Data.UUID.Types@), anything else is refused,
generated identities are version 4, and a typed key goes through a table on a
real PostgreSQL and back as the same identity and the same text. The database
check needs LOCKSTEP_TEST_PG_*.
-}
module Lockstep.Compliance.IdentityTest
  ( tests
  ) where

import Data.Coerce (Coercible)
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, testCase, (@?=))
import Text.Show (Show)

import Lockstep.Application.Decisions (DecisionReceipt (..), decidedReceipt)
import Lockstep.Application.Identity (newIdentity)
import Lockstep.Compliance.Support (identity, textQuery, withMigrated, withMigratedRuntime)
import Lockstep.Kernel.Effect (OperationId (..))
import Lockstep.Kernel.Identity
  ( AttemptId (..)
  , ContractId (..)
  , EngineerId (..)
  , HumanRequestId (..)
  , InvocationId (..)
  , ProjectId (..)
  , RepositoryId (..)
  , TaskId (..)
  , TicketId (..)
  , TransactionId (..)
  , Uuid
  , WorkOrderId (..)
  , WorkUnitId (..)
  , identityText
  , parseIdentity
  , parseUuid
  , uuidText
  )
import Lockstep.Persistence.DecisionReceipts qualified as Receipts
import Lockstep.Persistence.Ledger (SubjectKind (..), TicketRow (..), findTicket, insertSubject, insertTicket)
import Lockstep.Persistence.Projects (ProjectRow (..), findProjectById, insertProject)

canonical :: T.Text
canonical =
  "3f2504e0-4f89-41d3-9a0c-0305e82c3301"

-- | Not the canonical spelling of a UUID, or not a UUID at all.
refusedTexts :: [T.Text]
refusedTexts =
  [ "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
  , "3f2504e0-4f89-41d3-9a0c-0305E82C3301"
  , "{3f2504e0-4f89-41d3-9a0c-0305e82c3301}"
  , "3f2504e04f8941d39a0c0305e82c3301"
  , " 3f2504e0-4f89-41d3-9a0c-0305e82c3301"
  , "3f2504e0-4f89-41d3-9a0c-0305e82c3301 "
  , "3f2504e0-4f89-41d3-9a0c-0305e82c330"
  , "not-a-uuid"
  , ""
  ]

-- | One kind: its canonical text round-trips; every other text is refused.
roundTrips :: forall identity. (Coercible Uuid identity, Eq identity, Show identity) => (Maybe identity -> Maybe identity) -> Assertion
roundTrips _ = do
  fmap identityText (parseIdentity canonical :: Maybe identity) @?= Just canonical
  traverse_ (\t -> (parseIdentity t :: Maybe identity) @?= Nothing) refusedTexts

-- | The version nibble (the 13th hex digit) and the variant (the 17th: 8, 9, a or b) of a canonical text.
versionAndVariant :: T.Text -> (T.Text, Bool)
versionAndVariant text =
  (T.take 1 (T.drop 14 text), T.take 1 (T.drop 19 text) `elem` ["8", "9", "a", "b"])

tests :: TestTree
tests =
  testGroup
    "type-discipline Increment B: typed identities"
    [ testCase "every identity kind parses its canonical text and renders it back unchanged" $ do
        roundTrips (id :: Maybe RepositoryId -> Maybe RepositoryId)
        roundTrips (id :: Maybe EngineerId -> Maybe EngineerId)
        roundTrips (id :: Maybe TicketId -> Maybe TicketId)
        roundTrips (id :: Maybe WorkOrderId -> Maybe WorkOrderId)
        roundTrips (id :: Maybe WorkUnitId -> Maybe WorkUnitId)
        roundTrips (id :: Maybe ContractId -> Maybe ContractId)
        roundTrips (id :: Maybe AttemptId -> Maybe AttemptId)
        roundTrips (id :: Maybe ProjectId -> Maybe ProjectId)
        roundTrips (id :: Maybe TaskId -> Maybe TaskId)
        roundTrips (id :: Maybe TransactionId -> Maybe TransactionId)
        roundTrips (id :: Maybe InvocationId -> Maybe InvocationId)
        roundTrips (id :: Maybe HumanRequestId -> Maybe HumanRequestId)
        roundTrips (id :: Maybe OperationId -> Maybe OperationId)
    , testCase "upper case and other non-canonical spellings are refused by the UUID parser too" $ do
        fmap uuidText (parseUuid canonical) @?= Right canonical
        traverse_ (\t -> assertBool ("refused: " <> T.unpack t) (isLeft (parseUuid t))) refusedTexts
    , testCase "generated identities are version 4 (RFC 4122 variant) and render canonically" $ do
        generated <- traverse (const newIdentity) [1 :: Int .. 64] :: IO [ProjectId]
        traverse_ (\p -> versionAndVariant (identityText p) @?= ("4", True)) generated
        traverse_ (\p -> parseIdentity (identityText p) @?= Just p) generated
        assertBool "64 draws are 64 identities" (length (foldr (\p seen -> if p `elem` seen then seen else p : seen) [] generated) == 64)
    , testCase "a typed key goes through its table on PostgreSQL and back: the same identity, stored as the same text" $
        withMigrated $ \run -> do
          projectId <- identity "44444444-4444-4444-8444-444444444444" :: IO ProjectId
          run (insertProject projectId "compliance-identity-0001" "Identity" "outcome" (T.replicate 64 "a"))
          found <- run (findProjectById projectId)
          fmap rowId found @?= Just projectId
          stored <- run (textQuery "SELECT id::text AS v FROM lockstep_projects")
          stored @?= [identityText projectId]
          -- The same UUID as another kind of key finds nothing in another table.
          ticket <- identity "44444444-4444-4444-8444-444444444444" :: IO TicketId
          missing <- run (findTicket ticket)
          fmap ticketRowId missing @?= Nothing
          let
            TicketId subject = ticket
          run (insertSubject subject TicketSubject "proposed")
          run (insertTicket ticket "A ticket")
          stored' <- run (findTicket ticket)
          fmap ticketRowId stored' @?= Just ticket
    , testCase "a decision receipt asked for by non-canonical text is no receipt (not 'unavailable'); by its canonical id it is found" $
        withMigratedRuntime $ \runtime run -> do
          subject <- identity "0b1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d"
          inserted <-
            run
              ( Receipts.insertReceipt
                  Receipts.ReceiptRow
                    { Receipts.receiptRowKey = "compliance-receipt-0001"
                    , Receipts.receiptRowDigest = T.replicate 64 "a"
                    , Receipts.receiptRowSubject = subject
                    , Receipts.receiptRowChoice = "cancel"
                    , Receipts.receiptRowExpected = 1
                    , Receipts.receiptRowOutcome = "applied"
                    , Receipts.receiptRowRefusal = Nothing
                    , Receipts.receiptRowActor = "application-session"
                    , Receipts.receiptRowBasis = Nothing
                    }
              )
          assertBool "the receipt was inserted" inserted
          found <- decidedReceipt runtime (uuidText subject)
          fmap (fmap receiptSubject) found @?= Right (Just (uuidText subject))
          upper <- decidedReceipt runtime (T.toUpper (uuidText subject))
          fmap (fmap receiptSubject) upper @?= Right Nothing
          malformed <- decidedReceipt runtime "not-a-uuid"
          fmap (fmap receiptSubject) malformed @?= Right Nothing
    ]
