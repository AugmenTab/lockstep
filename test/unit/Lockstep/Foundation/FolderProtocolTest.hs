{-# LANGUAGE OverloadedStrings #-}

{- | The folder request kind for the control pane's Project folders (contract
C-P3.5 J6). The HMAC vector was computed with @openssl dgst -sha256 -mac HMAC@
and the list digest with @shasum -a 256@.
-}
module Lockstep.Foundation.FolderProtocolTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

import Lockstep.Foundation.ControlProtocol (ChannelKey, ProtocolError (..), decodeRequest, hmacHex, parseChannelKey, parseOp, parseRequestId)
import Lockstep.Foundation.FolderProtocol
  ( FolderOp (..)
  , FolderRequest (..)
  , decodeFolderRequest
  , encodeFolderRequest
  , folderOpName
  , foldersDigest
  , parseFolderOp
  , validFolderPath
  )
import Lockstep.Foundation.InstallProtocol (decodeInstallRequest, parseInstallOp)
import Lockstep.Foundation.LifecycleProtocol (decodeLifecycleRequest, parseLifecycleOp)
import Lockstep.Foundation.SessionProtocol (decodeSessionRequest, parseSessionOp)

keyHex :: BS.ByteString
keyHex =
  "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"

withKey :: (ChannelKey -> Assertion) -> Assertion
withKey action =
  maybe (assertFailure "parseChannelKey refused the test key") action (parseChannelKey keyHex)

body :: BS.ByteString
body =
  "lockstep-folder-request 1\nid 0123456789abcdef0123456789abcdef\nissued 1761400000\nop add-folder\nexpect folders-0123456789abcdef\npath /home/someone/code/my project\n"

file :: BS.ByteString
file =
  body <> "mac a5d84558df7e0f1cbe9cd7960f439dc9df01bfb8edb4a1d9ba07d63a4a99c3d6\n"

signed :: ChannelKey -> BS.ByteString -> BS.ByteString
signed key b =
  b <> "mac " <> BS8.pack (T.unpack (hmacHex key b)) <> "\n"

replaceLine :: BS.ByteString -> BS.ByteString -> BS.ByteString -> BS.ByteString
replaceLine prefix newLine bytes =
  BS8.unlines [if prefix `BS.isPrefixOf` l then newLine else l | l <- BS8.lines bytes]

tests :: TestTree
tests =
  testGroup
    "FolderProtocol (C-P3.5 J6)"
    [ testCase "the allowlist is exactly add-folder" $
        fmap folderOpName [minBound .. maxBound :: FolderOp] @?= ["add-folder"]
    , testCase "names are exact and the other kinds refuse it" $ do
        parseFolderOp "add-folder" @?= Just AddFolder
        parseFolderOp "add-folder " @?= Nothing
        parseFolderOp "remove-folder" @?= Nothing
        parseOp "add-folder" @?= Nothing
        parseLifecycleOp "add-folder" @?= Nothing
        parseInstallOp "add-folder" @?= Nothing
        parseSessionOp "add-folder" @?= Nothing
    , testCase "HMAC vector (computed with openssl)" $
        withKey $ \key ->
          hmacHex key body @?= "a5d84558df7e0f1cbe9cd7960f439dc9df01bfb8edb4a1d9ba07d63a4a99c3d6"
    , testCase "encoding is exactly the documented file, and it decodes back" $
        withKey $ \key ->
          case parseRequestId "0123456789abcdef0123456789abcdef" of
            Nothing -> assertFailure "id"
            Just rid -> do
              let
                r = FolderRequest rid 1761400000 AddFolder "folders-0123456789abcdef" "/home/someone/code/my project"
              encodeFolderRequest key r @?= file
              decodeFolderRequest key file @?= Right r
    , testCase "the list digest is folders- and the first 16 hex of its SHA-256 (computed with shasum)" $
        foldersDigest "/home/someone/lockstep-projects\n/home/someone/code/my project\n" @?= "folders-7fd4950609109939"
    , testCase "the expectation is folders- and 16 lower-case hex digits, nothing else" $
        withKey $ \key ->
          traverse_
            (\e -> decodeFolderRequest key (signed key (replaceLine "expect " ("expect " <> e) body)) @?= Left BadExpect)
            ["any", "folders-0123456789ABCDEF", "folders-0123456789abcde", "folders-0123456789abcdef0", "candidate-0123456789abcdef"]
    , testCase "a path is absolute, plain and without separators the list or the mount use" $ do
        traverse_
          (\p -> assertBool (T.unpack p <> " refused") (validFolderPath p))
          ["/home/someone/code/my project", "/Users/a/b", "/Users/a/b.c_d-e"]
        traverse_
          (\p -> assertBool (T.unpack p <> " accepted") (not (validFolderPath p)))
          [ ""
          , "/"
          , "relative/path"
          , "~/code"
          , "/home/a/"
          , "/home//a"
          , "/home/./a"
          , "/home/../a"
          , "/home/a:b"
          , "/home/a,b"
          , "/home/a\tb"
          , "/home/caf\233"
          , "/" <> T.replicate 600 "a"
          ]
    , testCase "an unusable path, unknown operation, bad MAC and other version are refused" $
        withKey $ \key -> do
          decodeFolderRequest key (signed key (replaceLine "path " "path relative" body)) @?= Left Malformed
          decodeFolderRequest key (signed key (replaceLine "path " "path /home/a:b" body)) @?= Left Malformed
          decodeFolderRequest key (signed key (replaceLine "op " "op remove-folder" body)) @?= Left UnknownOp
          decodeFolderRequest key (replaceLine "issued " "issued 1" file) @?= Left BadMac
          decodeFolderRequest key (signed key (replaceLine "lockstep-folder-request" "lockstep-folder-request 2" body)) @?= Left BadVersion
    , testCase "kinds do not mix" $
        withKey $ \key -> do
          decodeRequest key file @?= Left Malformed
          decodeLifecycleRequest key file @?= Left Malformed
          decodeInstallRequest key file @?= Left Malformed
          decodeSessionRequest key file @?= Left Malformed
    , testCase "malformed and oversized files are refused" $
        withKey $ \key -> do
          decodeFolderRequest key (signed key (body <> "path /home/b\n")) @?= Left Malformed
          decodeFolderRequest key body @?= Left Malformed
          decodeFolderRequest key (file <> BS.replicate 1100 0x20) @?= Left TooLarge
    ]
