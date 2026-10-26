{-# LANGUAGE OverloadedStrings #-}

{- | Project folders decided on the host (contract C-P3.5 J5, J6): the real
helper and the real @scripts/service@ in a throwaway checkout inside a temporary
home folder, a @docker@ stub that records every call, and the real pane.
-}
module Lockstep.FolderHelperTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import System.Directory (canonicalizePath, createDirectory, createDirectoryIfMissing, doesDirectoryExist)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath, writeFile)
import System.Posix.Files (createSymbolicLink)
import System.Posix.User (getRealGroupID, getRealUserID)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, testCase, (@?=))
import Text.Show (show)

import Lockstep.Foundation.ControlProtocol (ControlResult (..), Outcome (..))
import Lockstep.Support.Control (issueSignIn, withPaneOn)
import Lockstep.Support.Folders
  ( FEnv (..)
  , awaitFolderResult
  , currentDigest
  , currentList
  , runServiceScript
  , stubLog
  , submitFolder
  , withFolderEnv
  , withFolderHelper
  )
import Lockstep.Support.Http (HttpResponse (..), httpRequest)

-- | Submits add-folder for the path against the current list; returns the result.
addFolder :: FEnv -> FilePath -> IO ControlResult
addFolder env path = do
  digest <- currentDigest env
  rid <- submitFolder env digest (T.pack path)
  awaitFolderResult env rid

refusedWith :: FEnv -> FilePath -> T.Text -> Assertion
refusedWith env path reason = do
  before <- currentList env
  r <- addFolder env path
  (resultOutcome r, resultReason r) @?= (OutcomeRefused, Just reason)
  after <- currentList env
  assertBool (path <> ": the list changed") (after == before)

okWith :: FEnv -> FilePath -> IO ControlResult
okWith env path = do
  r <- addFolder env path
  (resultOutcome r, resultReason r, resultDetail r) @?= (OutcomeOk, Nothing, "")
  pure r

field :: T.Text -> ControlResult -> Maybe T.Text
field name =
  L.lookup name . resultFields

-- | The last @docker run@ line the stub recorded.
lastRun :: FEnv -> IO String
lastRun env = do
  logText <- stubLog env
  pure (lastOr "" [l | l <- L.lines logText, "docker run " `L.isPrefixOf` l])

lastOr :: a -> [a] -> a
lastOr fallback xs =
  case L.reverse xs of
    x : _ -> x
    [] -> fallback

contains :: String -> String -> Bool
contains =
  L.isInfixOf

bcontains :: BS.ByteString -> BS.ByteString -> Bool
bcontains needle haystack =
  not (BS.null (snd (BS.breakSubstring needle haystack)))

hostUser :: IO String
hostUser = do
  u <- getRealUserID
  g <- getRealGroupID
  pure (show u <> ":" <> show g)

tests :: TestTree
tests =
  testGroup
    "Project folders on the host (C-P3.5 J5, J6)"
    [ testCase "the helper keeps the folder list, makes the projects folder, and gives the pane a copy" $
        withFolderEnv False $ \env -> withFolderHelper env Nothing $ do
          made <- doesDirectoryExist (fProjects env)
          assertBool "the projects folder was not made" made
          projects <- canonicalizePath (fProjects env)
          currentList env >>= (@?= BS8.pack ("rw " <> projects <> "\n"))
          copy <- BS.readFile (fState env <> "/pane/folders")
          copy @?= BS8.pack ("rw " <> projects <> "\n")
    , testCase "without --projects there is no projects folder and nothing is made in the home folder" $
        withFolderEnv False $ \env -> withFolderHelper env (Just []) $ do
          currentList env >>= (@?= "")
          made <- doesDirectoryExist (fProjects env)
          assertBool "a projects folder was made" (not made)
    , testCase "add-folder records the folder's real path; a stopped service is not restarted" $
        withFolderEnv False $ \env -> withFolderHelper env Nothing $ do
          createSymbolicLink (fHome env <> "/code/site") (fHome env <> "/site-link")
          r <- okWith env (fHome env <> "/site-link")
          field "service.restart" r @?= Just "not-needed"
          projects <- canonicalizePath (fProjects env)
          site <- canonicalizePath (fHome env <> "/code/site")
          currentList env >>= (@?= BS8.pack ("rw " <> projects <> "\nro " <> site <> "\n"))
          copy <- BS.readFile (fState env <> "/pane/folders")
          copy @?= BS8.pack ("rw " <> projects <> "\nro " <> site <> "\n")
          logText <- stubLog env
          assertBool "the service was started" (not (contains " --detach " logText))
    , testCase "while the service runs, adding a folder restarts it with the new mounts" $
        withFolderEnv False $ \env -> withFolderHelper env Nothing $ do
          (code, _, err) <- runServiceScript env [("LOCKSTEP_SERVICE_FOLDERS", fState env <> "/helper/folders")] ["start", "--port", show (fServicePort env)]
          assertBool ("start failed: " <> err) (code == ExitSuccess)
          r <- okWith env (fHome env <> "/code/site")
          field "service.restart" r @?= Just "ok"
          site <- canonicalizePath (fHome env <> "/code/site")
          run <- lastRun env
          assertBool ("not restarted with the folder: " <> run) (contains " --detach " run && contains ("--volume " <> site <> ":" <> site <> ":ro ") run)
          health <- httpRequest (fServicePort env) "GET" "/api/health_check" [] ""
          responseStatus health @?= 204
    , testCase "a stale review is refused and changes nothing" $
        withFolderEnv False $ \env -> withFolderHelper env Nothing $ do
          before <- currentList env
          rid <- submitFolder env "folders-0000000000000000" (T.pack (fHome env <> "/code/site"))
          r <- awaitFolderResult env rid
          (resultOutcome r, resultReason r) @?= (OutcomeRefused, Just "state-changed")
          currentList env >>= (@?= before)
    , testCase "every folder Lockstep must not use is refused with its reason" $
        withFolderEnv False $ \env -> withFolderHelper env Nothing $ do
          writeFile (fHome env <> "/file.txt") "x"
          createDirectoryIfMissing True (fProjects env <> "/inner")
          createDirectory (fHome env <> "/odd:name")
          createSymbolicLink (fHome env <> "/odd:name") (fHome env <> "/odd-link")
          createDirectory (fHome env <> "/a,b")
          refusedWith env (fHome env <> "/missing") "folder-missing"
          refusedWith env (fHome env <> "/file.txt") "not-a-folder"
          refusedWith env (fBase env <> "/outside") "outside-home"
          refusedWith env (fHome env) "home-folder"
          refusedWith env (fRoot env) "inside-lockstep"
          refusedWith env (fRoot env <> "/scripts") "inside-lockstep"
          refusedWith env (fProjects env) "already-listed"
          refusedWith env (fProjects env <> "/inner") "overlaps-listed"
          refusedWith env (fHome env <> "/odd-link") "unusable-path"
          refusedWith env (fHome env <> "/a,b") "unusable-path"
          refusedWith env "relative/path" "unusable-path"
          _ <- okWith env (fHome env <> "/code/site")
          refusedWith env (fHome env <> "/code/site") "already-listed"
          refusedWith env (fHome env <> "/code") "overlaps-listed"
          createDirectory (fHome env <> "/code/site/sub")
          refusedWith env (fHome env <> "/code/site/sub") "overlaps-listed"
    , testCase "the list holds at most 15 added folders" $
        withFolderEnv False $ \env -> withFolderHelper env Nothing $ do
          let
            dirs = [fHome env <> "/many/d" <> show n | n <- [1 :: Int .. 16]]
          traverse_ (createDirectoryIfMissing True) dirs
          traverse_ (void . okWith env) (L.take 15 dirs)
          refusedWith env (lastOr "" dirs) "list-full"
    , testCase "scripts/service mounts exactly the listed folders at their own paths, as the host user" $
        withFolderEnv False $ \env -> do
          projects <- canonicalizePath (fHome env) >>= \h -> pure (h <> "/lockstep-projects")
          createDirectoryIfMissing True projects
          site <- canonicalizePath (fHome env <> "/code/site")
          other <- canonicalizePath (fHome env <> "/code/other")
          let
            list = fBase env <> "/list"
          writeFile list (L.unlines ["rw " <> projects, "ro " <> site, "ro /no/such/folder", "ro relative", "rw " <> other, "xx /y"])
          (code, _, err) <- runServiceScript env [("LOCKSTEP_SERVICE_FOLDERS", list)] ["cli", "db", "status"]
          assertBool ("cli failed: " <> err) (code == ExitSuccess)
          run <- lastRun env
          user <- hostUser
          traverse_
            (\needle -> assertBool ("missing " <> needle <> " in: " <> run) (contains needle run))
            [ "--volume " <> projects <> ":" <> projects <> " "
            , "--volume " <> site <> ":" <> site <> ":ro "
            , "--user " <> user <> " "
            , "--env LOCKSTEP_PROJECT_FOLDERS=" <> projects <> ":" <> site <> " "
            ]
          traverse_
            (\needle -> assertBool ("mounted " <> needle <> ": " <> run) (not (contains needle run)))
            ["/no/such/folder", "relative", other, "/y"]
          writeFile list ("ro " <> site <> "\n")
          _ <- runServiceScript env [("LOCKSTEP_SERVICE_FOLDERS", list)] ["cli", "db", "status"]
          onlyAdded <- lastRun env
          assertBool ("no empty projects entry: " <> onlyAdded) (contains ("--env LOCKSTEP_PROJECT_FOLDERS=:" <> site <> " ") onlyAdded)
    , testCase "without a folder list, scripts/service runs the container exactly as before" $
        withFolderEnv False $ \env -> do
          (code, _, err) <- runServiceScript env [] ["cli", "db", "status"]
          assertBool ("cli failed: " <> err) (code == ExitSuccess)
          run <- lastRun env
          assertBool ("a folder setting: " <> run) (not (contains "--user" run) && not (contains "LOCKSTEP_PROJECT_FOLDERS" run))
          L.length (L.filter (== "--volume") (L.words run)) @?= 2
    , testCase "the pane shows the list and sends add-folder for its own session only" $
        withFolderEnv False $ \env -> withFolderHelper env Nothing $ withPaneOn (fState env <> "/pane") [] $ \port -> do
          token <- issueSignIn (fState env <> "/pane") 300
          let
            origin = "http://127.0.0.1:" <> BS8.pack (show port)
          signed <- httpRequest port "POST" "/api/session" [("Origin", origin)] (TE.encodeUtf8 token)
          responseStatus signed @?= 200
          let
            session = BS.take 43 (BS.drop 11 (snd (BS.breakSubstring "\"session\":\"" (responseBody signed))))
            asPane = [("Origin", origin), ("X-Lockstep-Session", session)]
          none <- httpRequest port "GET" "/api/folders" [] ""
          responseStatus none @?= 401
          listed <- httpRequest port "GET" "/api/folders" [("X-Lockstep-Session", session)] ""
          responseStatus listed @?= 200
          digest <- currentDigest env
          projects <- canonicalizePath (fProjects env)
          assertBool ("no digest: " <> show (responseBody listed)) (bcontains ("\"digest\":\"" <> TE.encodeUtf8 digest <> "\"") (responseBody listed))
          assertBool ("no projects folder: " <> show (responseBody listed)) (bcontains ("{\"mode\":\"rw\",\"path\":\"" <> BS8.pack projects <> "\"}") (responseBody listed))
          let
            body = "add-folder " <> TE.encodeUtf8 digest <> " " <> BS8.pack (fHome env <> "/code/site")
          anonymous <- httpRequest port "POST" "/api/folders" [("Origin", origin)] body
          responseStatus anonymous @?= 401
          elsewhere <- httpRequest port "POST" "/api/folders" [("Origin", "http://127.0.0.1:1"), ("X-Lockstep-Session", session)] body
          responseStatus elsewhere @?= 403
          traverse_
            ( \bad -> do
                resp <- httpRequest port "POST" "/api/folders" asPane bad
                assertBool (show bad <> " gave " <> show (responseStatus resp)) (responseStatus resp == 400)
            )
            [ "remove-folder " <> TE.encodeUtf8 digest <> " /x"
            , "add-folder any /x"
            , "add-folder " <> TE.encodeUtf8 digest <> " relative"
            , "add-folder " <> TE.encodeUtf8 digest
            ]
          started <- httpRequest port "POST" "/api/folders" asPane body
          responseStatus started @?= 202
          let
            rid = T.pack (BS8.unpack (BS.take 32 (BS.drop 6 (snd (BS.breakSubstring "\"id\":\"" (responseBody started))))))
          r <- awaitFolderResult env rid
          resultOutcome r @?= OutcomeOk
          site <- canonicalizePath (fHome env <> "/code/site")
          after <- httpRequest port "GET" "/api/folders" [("X-Lockstep-Session", session)] ""
          assertBool ("the added folder is not listed: " <> show (responseBody after)) (bcontains ("{\"mode\":\"ro\",\"path\":\"" <> BS8.pack site <> "\"}") (responseBody after))
    ]
