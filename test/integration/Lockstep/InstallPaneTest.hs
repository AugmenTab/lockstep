{-# LANGUAGE OverloadedStrings #-}

-- | The pane's install endpoint (contract C-P3.3 U1): the real pane binary, no helper.
module Lockstep.InstallPaneTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTPTypes
import System.Directory (listDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Foundation.InstallProtocol (InstallExpect (..), InstallOp (..), InstallRequest (..), decodeInstallRequest)
import Lockstep.Support.Control (Env (..), issueSignIn, paneDir, withEnv, withPaneOn)
import Lockstep.Support.Http (HttpResponse (..), httpRequest)

origin :: Int -> BS.ByteString
origin port =
  "http://127.0.0.1:" <> BS8.pack (show port)

signIn :: Env -> Int -> IO BS.ByteString
signIn env port = do
  token <- issueSignIn (paneDir env) 300
  resp <- httpRequest port "POST" "/api/session" [("Origin", origin port)] (TE.encodeUtf8 token)
  responseStatus resp @?= 200
  pure (BS.take 43 (BS.drop 11 (snd (BS.breakSubstring "\"session\":\"" (responseBody resp)))))

headers :: Int -> BS.ByteString -> [HTTPTypes.Header]
headers port session =
  [("Origin", origin port), ("X-Lockstep-Session", session)]

files :: Env -> String -> IO [String]
files env suffix =
  L.filter (suffix `L.isSuffixOf`) <$> listDirectory (paneDir env <> "/requests")

tests :: TestTree
tests =
  testGroup
    "pane install endpoint (C-P3.3 U1)"
    [ testCase "needs a session and this pane's origin" $
        withEnv $ \env -> withPaneOn (paneDir env) [] $ \port -> do
          session <- signIn env port
          a <- httpRequest port "POST" "/api/install" [("Origin", origin port)] "prepare-candidate candidate-none"
          responseStatus a @?= 401
          b <- httpRequest port "POST" "/api/install" [("Origin", "http://127.0.0.1:1"), ("X-Lockstep-Session", session)] "prepare-candidate candidate-none"
          responseStatus b @?= 403
          files env ".ireq" >>= (@?= [])
    , testCase "a valid request becomes one signed install request" $
        withEnv $ \env -> withPaneOn (paneDir env) [] $ \port -> do
          session <- signIn env port
          resp <- httpRequest port "POST" "/api/install" (headers port session) "apply-candidate candidate-0011223344556677"
          responseStatus resp @?= 202
          names <- files env ".ireq"
          case names of
            [name] -> do
              bytes <- BS.readFile (paneDir env <> "/requests/" <> name)
              case decodeInstallRequest (envKey env) bytes of
                Right r -> do
                  installOp r @?= ApplyCandidate
                  installExpect r @?= CandidateDigest "0011223344556677"
                Left e -> assertFailure ("does not verify: " <> show e)
            other -> assertFailure ("expected one install request, found " <> show other)
    , testCase "paths, unknown operations and mismatched expectations are 400 and write nothing" $
        withEnv $ \env -> withPaneOn (paneDir env) [] $ \port -> do
          session <- signIn env port
          traverse_
            ( \b -> do
                resp <- httpRequest port "POST" "/api/install" (headers port session) b
                assertBool (show b <> " gave " <> show (responseStatus resp)) (responseStatus resp == 400)
            )
            [ "apply-candidate /Users/someone/other-checkout"
            , "apply-candidate candidate-none"
            , "install candidate-none"
            , "restore-previous candidate-0011223344556677"
            , "prepare-candidate candidate-none extra"
            , "service-stop running"
            , ""
            ]
          files env ".ireq" >>= (@?= [])
    , testCase "an install request while a lifecycle request is pending is 409, and the reverse" $
        withEnv $ \env -> withPaneOn (paneDir env) [] $ \port -> do
          session <- signIn env port
          first <- httpRequest port "POST" "/api/lifecycle" (headers port session) "service-stop running"
          responseStatus first @?= 202
          second <- httpRequest port "POST" "/api/install" (headers port session) "prepare-candidate candidate-none"
          responseStatus second @?= 409
    , testCase "a lifecycle request while an install request is pending is 409" $
        withEnv $ \env -> withPaneOn (paneDir env) [] $ \port -> do
          session <- signIn env port
          first <- httpRequest port "POST" "/api/install" (headers port session) "prepare-candidate candidate-none"
          responseStatus first @?= 202
          second <- httpRequest port "POST" "/api/lifecycle" (headers port session) "service-stop running"
          responseStatus second @?= 409
    , testCase "the other kinds still refuse install names" $
        withEnv $ \env -> withPaneOn (paneDir env) [] $ \port -> do
          session <- signIn env port
          a <- httpRequest port "POST" "/api/requests" (headers port session) "prepare-candidate"
          responseStatus a @?= 400
          b <- httpRequest port "POST" "/api/lifecycle" (headers port session) "apply-candidate candidate-0011223344556677"
          responseStatus b @?= 400
    ]
