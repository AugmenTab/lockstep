{-# LANGUAGE OverloadedStrings #-}

module Lockstep.Kernel.IdentityTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Lockstep.Kernel.Identity
  ( IdentityError (..)
  , RepositoryId (..)
  , parseUuid
  , uuidFromBytes
  , uuidFromWords
  , uuidText
  )

tests :: TestTree
tests =
  testGroup
    "Kernel identity (C-P2.1 I1)"
    [ testCase "a canonical lowercase UUID parses and round-trips" $
        fmap uuidText (parseUuid sample) @?= Right sample
    , testCase "an all-zero UUID is canonical" $
        fmap uuidText (parseUuid "00000000-0000-0000-0000-000000000000")
          @?= Right "00000000-0000-0000-0000-000000000000"
    , testCase "uppercase hex is refused (one canonical spelling)" $
        refused (T.toUpper sample)
    , testCase "missing hyphens are refused" $
        refused (T.filter (/= '-') sample)
    , testCase "wrong group lengths are refused" $ do
        refused "0123456-89ab-4def-8123-456789abcdef0"
        refused "01234567-89ab-4def-8123-456789abcde"
        refused "01234567-89ab-4def-8123-456789abcdef0"
    , testCase "non-hex characters are refused" $
        refused "0123456g-89ab-4def-8123-456789abcdef"
    , testCase "empty and surrounding whitespace are refused" $ do
        refused ""
        refused (" " <> sample)
        refused (sample <> "\n")
    , testCase "16 bytes render as 36 characters and parse back" $ do
        let
          bytes = BS.pack [0 .. 15]
        fmap uuidText (uuidFromBytes bytes) @?= Right "00010203-0405-0607-0809-0a0b0c0d0e0f"
        fmap (fmap uuidText . parseUuid . uuidText) (uuidFromBytes bytes)
          @?= Right (Right "00010203-0405-0607-0809-0a0b0c0d0e0f")
    , testCase "15 and 17 bytes are UuidWrongLength" $ do
        fmap uuidText (uuidFromBytes (BS.replicate 15 0)) @?= Left UuidWrongLength
        fmap uuidText (uuidFromBytes (BS.replicate 17 0)) @?= Left UuidWrongLength
    , testCase "uuidFromWords is total and big-endian" $ do
        uuidText (uuidFromWords 0 0) @?= "00000000-0000-0000-0000-000000000000"
        uuidText (uuidFromWords 0x0123456789abcdef 0xfedcba9876543210) @?= "01234567-89ab-cdef-fedc-ba9876543210"
    , testCase "identities of one kind compare by their UUID" $
        fmap RepositoryId (parseUuid sample) @?= fmap RepositoryId (parseUuid sample)
    ]

sample :: T.Text
sample =
  "0123abcd-89ab-4def-8123-456789abcdef"

refused :: T.Text -> IO ()
refused value =
  fmap uuidText (parseUuid value) @?= Left UuidMalformed
