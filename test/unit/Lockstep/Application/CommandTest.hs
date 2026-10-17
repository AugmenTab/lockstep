{-# LANGUAGE OverloadedStrings #-}

module Lockstep.Application.CommandTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Text qualified as T
import Data.Time qualified as Time
import Flipstone.Prelude
import Numeric (showHex)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Command
  ( Actor (..)
  , CommandEnvelope (..)
  , Decision (..)
  , IdempotencyKey
  , InvalidReason (..)
  , OperatorCommand (..)
  , Outcome (..)
  , PriorReceipt (..)
  , Receipt (..)
  , Revision (..)
  , WorkspaceName
  , WorkspaceState (..)
  , decide
  , generateIdempotencyKey
  , idempotencyKeyText
  , mkEnvelope
  , mkIdempotencyKey
  , mkWorkspaceName
  , payloadDigest
  , workspaceNameText
  )

tests :: TestTree
tests =
  testGroup
    "Command"
    [ testGroup
        "validation"
        [ testCase "a workspace name is trimmed" $
            fmap workspaceNameText (mkWorkspaceName "  Lockstep Two \n") @?= Right "Lockstep Two"
        , testCase "an empty or whitespace-only name is NameEmpty" $ do
            nameError "" @?= Just NameEmpty
            nameError "   \t " @?= Just NameEmpty
        , testCase "80 characters are accepted, 81 are NameTooLong (characters, not bytes)" $ do
            nameError (T.replicate 80 "\233") @?= Nothing
            nameError (T.replicate 81 "a") @?= Just NameTooLong
        , testCase "control characters inside the name are NameHasControl" $ do
            nameError "a\tb" @?= Just NameHasControl
            nameError "a\nb" @?= Just NameHasControl
            nameError "a\DELb" @?= Just NameHasControl
        , testCase "keys of 16 and 64 base64url characters are accepted" $ do
            keyError (T.replicate 16 "a") @?= Nothing
            keyError (T.replicate 64 "Z") @?= Nothing
            keyError "abc-DEF_0123456789" @?= Nothing
        , testCase "malformed keys are KeyMalformed" $
            traverse_
              (\k -> keyError k @?= Just KeyMalformed)
              ["", T.replicate 15 "a", T.replicate 65 "a", T.replicate 15 "a" <> "+", T.replicate 15 "a" <> " ", T.replicate 15 "a" <> "="]
        , testCase "a generated key is valid, 22 characters, and two differ" $ do
            a <- generateIdempotencyKey
            b <- generateIdempotencyKey
            T.length (idempotencyKeyText a) @?= 22
            keyError (idempotencyKeyText a) @?= Nothing
            assertBool "two generated keys are equal" (idempotencyKeyText a /= idempotencyKeyText b)
        ]
    , testGroup
        "payload digest"
        [ testCase "matches the known vector" $ do
            e <- envelope ActorCli keyA 0 "Lockstep Two"
            hex (payloadDigest e) @?= "d75b9bba0bd08222f14e00cd4b2ea269f3d806c37a3a60c151660d4e829b7888"
        , testCase "is 32 bytes and ignores the actor and the key" $ do
            a <- envelope ActorCli keyA 0 "Lockstep Two"
            b <- envelope ActorBrowserSession keyB 0 "Lockstep Two"
            BS.length (payloadDigest a) @?= 32
            payloadDigest a @?= payloadDigest b
        , testCase "differs by name and by expected revision" $ do
            a <- envelope ActorCli keyA 0 "Lockstep Two"
            b <- envelope ActorCli keyA 0 "Lockstep Three"
            c <- envelope ActorCli keyA 1 "Lockstep Two"
            assertBool "name ignored" (payloadDigest a /= payloadDigest b)
            assertBool "expected revision ignored" (payloadDigest a /= payloadDigest c)
        , testCase "the envelope version is 1" $ do
            a <- envelope ActorCli keyA 0 "Lockstep Two"
            envelopeVersion a @?= 1
        ]
    , testGroup
        "decide"
        [ testCase "a fresh command at the current revision applies and returns current + 1" $ do
            e <- envelope ActorCli keyA 3 "New"
            assertDecision (Apply (Revision 4)) (decide (state 3) Nothing e)
        , testCase "a fresh command at another revision is refused as stale with the current one" $ do
            e <- envelope ActorCli keyA 2 "New"
            assertDecision (RefuseStale (Revision 3)) (decide (state 3) Nothing e)
        , testCase "the same key and payload replays the prior receipt" $ do
            e <- envelope ActorCli keyA 3 "New"
            let
              prior = PriorReceipt (payloadDigest e) (receipt Applied 3 4)
            assertDecision (Replay (receipt Applied 3 4)) (decide (state 4) (Just prior) e)
        , testCase "a replay wins over a now-stale revision" $ do
            e <- envelope ActorCli keyA 0 "New"
            let
              prior = PriorReceipt (payloadDigest e) (receipt RefusedStale 0 7)
            assertDecision (Replay (receipt RefusedStale 0 7)) (decide (state 9) (Just prior) e)
        , testCase "the same key with another payload is a key conflict, even at the current revision" $ do
            e <- envelope ActorCli keyA 3 "New"
            other <- envelope ActorCli keyA 3 "Other"
            let
              prior = PriorReceipt (payloadDigest other) (receipt Applied 2 3)
            assertDecision KeyConflict (decide (state 3) (Just prior) e)
        ]
    ]

nameError :: T.Text -> Maybe InvalidReason
nameError =
  either Just (const Nothing) . mkWorkspaceName

keyError :: T.Text -> Maybe InvalidReason
keyError =
  either Just (const Nothing) . mkIdempotencyKey

keyA :: T.Text
keyA =
  "key-aaaaaaaaaaaaaaaa"

keyB :: T.Text
keyB =
  "key-bbbbbbbbbbbbbbbb"

envelope :: Actor -> T.Text -> Int64 -> T.Text -> IO CommandEnvelope
envelope actor keyText expected nameText = do
  key <- either (\r -> assertFailure ("key: " <> show r)) pure (mkIdempotencyKey keyText) :: IO IdempotencyKey
  name <- either (\r -> assertFailure ("name: " <> show r)) pure (mkWorkspaceName nameText) :: IO WorkspaceName
  pure (mkEnvelope actor key (Revision expected) (RenameWorkspace name))

state :: Int64 -> WorkspaceState
state n =
  WorkspaceState "Lockstep" (Revision n)

receipt :: Outcome -> Int64 -> Int64 -> Receipt
receipt outcome expected resulting =
  Receipt
    { receiptId = 1
    , receiptKey = keyA
    , receiptKind = "rename-workspace"
    , receiptOutcome = outcome
    , receiptExpected = Revision expected
    , receiptRevision = Revision resulting
    , receiptActor = ActorCli
    , receiptAcceptedAt = Time.UTCTime (Time.fromGregorian 2026 10 17) 0
    , receiptReplayed = False
    }

assertDecision :: Decision -> Decision -> Assertion
assertDecision expected actual =
  assertBool ("expected " <> show expected <> ", got " <> show actual) (expected == actual)

hex :: BS.ByteString -> String
hex =
  L.concatMap byte . BS.unpack
 where
  byte w =
    let
      digits = showHex w ""
    in
      if L.length digits < 2 then '0' : digits else fmap Char.toLower digits
