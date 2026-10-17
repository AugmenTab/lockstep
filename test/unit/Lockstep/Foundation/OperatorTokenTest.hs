{-# LANGUAGE OverloadedStrings #-}

module Lockstep.Foundation.OperatorTokenTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Maybe (isNothing)
import Data.Text qualified as T
import Flipstone.Prelude
import Numeric (showHex)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Foundation.OperatorToken
  ( RawToken
  , csrfFor
  , csrfMatches
  , decodeToken
  , encodeToken
  , generateToken
  , tokenDigest
  )

tests :: TestTree
tests =
  testGroup
    "OperatorToken"
    [ testGroup
        "token"
        [ testCase "a generated token encodes as 43 base64url characters and decodes back" $ do
            token <- generateToken
            let
              text = encodeToken token
            T.length text @?= 43
            assertBool ("not base64url: " <> T.unpack text) (T.all isBase64Url text)
            decodeToken text @?= Just token
        , testCase "two generated tokens differ" $ do
            a <- generateToken
            b <- generateToken
            assertBool "two tokens were equal" (a /= b)
        , testCase "decoding a known token gives its 32 bytes (digest vector)" $ do
            token <- known "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
            hex (tokenDigest token) @?= "630dcd2966c4336691125448bbb25b4ff412a49c732db2c8abc1b8581bd710dd"
        , testCase "the digest is SHA-256 of the raw bytes (all-zero vector)" $ do
            token <- known zeroText
            BS.length (tokenDigest token) @?= 32
            hex (tokenDigest token) @?= "66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925"
        , testCase "encode is the inverse of decode for a known token" $ do
            token <- known "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
            encodeToken token @?= "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
        , testGroup "malformed text is refused" (fmap refused malformed)
        , testCase "show never reveals the token" $ do
            token <- known "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
            show token @?= "<redacted>"
            show (Just token) @?= "Just <redacted>"
        ]
    , testGroup
        "csrf"
        [ testCase "matches a known HMAC-SHA256 vector (all-zero session)" $ do
            token <- known zeroText
            csrfFor token @?= "0qaHzxn_v8Upc4bffhI6afA_xIAGTDTqTqbLRVQjALU"
        , testCase "matches a known HMAC-SHA256 vector (counting session)" $ do
            token <- known "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
            csrfFor token @?= "OpxaRSOCQ1FTJbw5mk60Jtdt0k_1KbwLy5AkAyfeiZ8"
        , testCase "is deterministic per session and accepted for it" $ do
            token <- generateToken
            csrfFor token @?= csrfFor token
            assertBool "own csrf refused" (csrfMatches token (csrfFor token))
        , testCase "differs between sessions; another session's value is refused" $ do
            a <- generateToken
            b <- generateToken
            assertBool "csrf equal across sessions" (csrfFor a /= csrfFor b)
            assertBool "other session's csrf accepted" (not (csrfMatches a (csrfFor b)))
        , testCase "a wrong, empty, truncated or extended value is refused" $ do
            token <- generateToken
            let
              good = csrfFor token
            assertBool "empty accepted" (not (csrfMatches token ""))
            assertBool "truncated accepted" (not (csrfMatches token (T.dropEnd 1 good)))
            assertBool "extended accepted" (not (csrfMatches token (good <> "A")))
            assertBool "wrong accepted" (not (csrfMatches token (T.map flipChar good)))
        ]
    ]

zeroText :: T.Text
zeroText =
  T.replicate 43 "A"

malformed :: [(String, T.Text)]
malformed =
  [ ("empty", "")
  , ("42 characters", T.replicate 42 "A")
  , ("44 characters", T.replicate 44 "A")
  , ("padded", T.replicate 43 "A" <> "=")
  , ("standard base64 '+'", "+" <> T.replicate 42 "A")
  , ("standard base64 '/'", "/" <> T.replicate 42 "A")
  , ("non-ASCII", "\233" <> T.replicate 42 "A")
  , ("space", " " <> T.replicate 42 "A")
  , ("non-canonical final character", T.replicate 42 "A" <> "B")
  ]

refused :: (String, T.Text) -> TestTree
refused (name, text) =
  testCase name $
    assertBool ("decoded: " <> name) (isNothing (decodeToken text))

known :: T.Text -> IO RawToken
known text =
  maybe (assertFailure ("known token did not decode: " <> T.unpack text)) pure (decodeToken text)

isBase64Url :: Char -> Bool
isBase64Url c =
  Char.isAsciiUpper c || Char.isAsciiLower c || Char.isDigit c || c == '-' || c == '_'

flipChar :: Char -> Char
flipChar c =
  if c == 'A' then 'B' else 'A'

hex :: BS.ByteString -> String
hex =
  L.concatMap byte . BS.unpack
 where
  byte w =
    let
      digits = showHex w ""
    in
      if L.length digits < 2 then '0' : digits else digits
