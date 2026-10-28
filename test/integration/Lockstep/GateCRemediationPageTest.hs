{-# LANGUAGE OverloadedStrings #-}

{- | The Gate C review remediation over real HTTP (contract C-C.R1 R3, R4, R8,
R10): the real service on a 'Lockstep.Support.Ledger.withLedger' database; the
projects, tasks and decisions are made in this process through the Application
layer; the session comes from the real CLI as in C-P3.4.
-}
module Lockstep.GateCRemediationPageTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTPTypes
import System.Directory (createDirectory)
import System.Exit (ExitCode (ExitSuccess))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Ledger (decideWorkOrder, noFaults)
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks (NewTask (..), TaskView (..), createTask, findTask)
import Lockstep.Kernel.Identity (WorkOrderId (..), uuidText)
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Kernel.Transition (Command (..), Principal (..))
import Lockstep.Kernel.WorkOrder (WorkOrderInput (..))
import Lockstep.Support.Decisions (ok, stoppedWork)
import Lockstep.Support.Http (HttpResponse (..), httpRequest)
import Lockstep.Support.Ledger (Ledger (..), count, withLedger)
import Lockstep.Support.Process (freePort, runLockstep, withService)

data Svc
  = Svc
  { svcPort :: Int
  , svcSession :: BS.ByteString
  , svcLedger :: Ledger
  }

withSvc :: (Svc -> IO ()) -> IO ()
withSvc action =
  withLedger $ \lg -> do
    port <- freePort
    (result, _) <-
      withService (lgEnv lg) port (lgDir lg <> "/serve.log") $ do
        session <- signIn port (lgEnv lg)
        action (Svc port session lg)
    pure result

origin :: Int -> BS.ByteString
origin port =
  "http://127.0.0.1:" <> BS8.pack (show port)

signIn :: Int -> [(String, String)] -> IO BS.ByteString
signIn port env = do
  (code, out, err) <- runLockstep env ["operator", "sign-in", "--port", show port]
  code @?= ExitSuccess
  token <-
    case L.stripPrefix "=" (L.dropWhile (/= '=') (L.filter (/= '\n') out)) of
      Just t | L.length t == 43 -> pure (BS8.pack t)
      _ -> assertFailure ("unexpected sign-in output: " <> out <> err)
  resp <- httpRequest port "POST" "/app/api/session" [("Origin", origin port)] token
  responseStatus resp @?= 200
  pure (BS.take 43 (BS.drop 11 (snd (BS.breakSubstring "\"session\":\"" (responseBody resp)))))

fragment :: Svc -> String -> IO HttpResponse
fragment svc path =
  httpRequest (svcPort svc) "GET" ("/app/fragments/" <> path) [("X-Lockstep-Session", svcSession svc)] ""

post :: Svc -> String -> [(BS.ByteString, BS.ByteString)] -> IO HttpResponse
post svc path fields =
  httpRequest
    (svcPort svc)
    "POST"
    path
    [("Content-Type", "application/x-www-form-urlencoded"), ("Origin", origin (svcPort svc)), ("X-Lockstep-Session", svcSession svc)]
    (HTTPTypes.renderSimpleQuery False fields)

contains :: BS.ByteString -> BS.ByteString -> Bool
contains needle haystack =
  not (BS.null (snd (BS.breakSubstring needle haystack)))

has :: BS.ByteString -> [BS.ByteString] -> IO ()
has body =
  traverse_ (\needle -> assertBool ("missing " <> show needle <> ": " <> show body) (contains needle body))

lacks :: BS.ByteString -> [BS.ByteString] -> IO ()
lacks body =
  traverse_ (\needle -> assertBool ("present " <> show needle <> ": " <> show body) (not (contains needle body)))

inputValue :: BS.ByteString -> BS.ByteString -> Maybe BS.ByteString
inputValue name page =
  let
    after = snd (BS.breakSubstring ("name=\"" <> name <> "\" value=\"") page)
  in
    if BS.null after
      then Nothing
      else Just (BS.takeWhile (/= 0x22) (BS.drop (BS.length name + 15) after))

woId :: WorkOrderId -> String
woId (WorkOrderId u) =
  T.unpack (uuidText u)

unreadable :: BS.ByteString
unreadable =
  "Lockstep could not read this form"

creationKey :: T.Text -> IO IdempotencyKey
creationKey text =
  either (const (assertFailure ("creation key " <> T.unpack text))) pure (mkIdempotencyKey ("test-remedy-page-" <> text))

ready :: Show e => IO (Either e a) -> IO a
ready action =
  action >>= either (\e -> assertFailure ("not ready: " <> show e)) pure

project :: Svc -> T.Text -> FolderChoice -> IO ProjectView
project svc name choice = do
  let
    root = lgDir (svcLedger svc) <> "/projects"
  when (choice == NewFolder) (createDirectory root)
  k <- creationKey ("project-" <> T.filter (/= ' ') name)
  made <- ready (createProject (lgRuntime (svcLedger svc)) (ProjectFolders (Just root) []) (NewProject k name "" choice))
  either (\c -> assertFailure ("project refused: " <> T.unpack c)) pure made

task :: Svc -> ProjectView -> T.Text -> T.Text -> IO TaskView
task svc view k title = do
  ik <- creationKey ("task-" <> k)
  made <- ready (createTask (lgRuntime (svcLedger svc)) (NewTask ik (projectId view) title "" Normal []))
  either (\c -> assertFailure ("task refused: " <> T.unpack c)) pure made

hostile :: T.Text
hostile =
  "\" autofocus onfocus=alert(1) x=\""

tests :: TestTree
tests =
  testGroup
    "Gate C review remediation over HTTP (C-C.R1)"
    [ testCase "out-of-range or non-decimal expected values are a form error and record nothing (R3)" $
        withSvc $ \svc -> do
          wo <- stoppedWork (svcLedger svc) "Print the menu" "the printer jammed"
          page <- fragment svc ("decision/" <> woId wo)
          k <- maybe (assertFailure "no key") pure (inputValue "key" (responseBody page))
          traverse_
            ( \bad -> do
                resp <- post svc ("/app/api/decisions/" <> woId wo) [("key", k), ("expected", bad), ("choice", "put-back")]
                responseStatus resp @?= 200
                has (responseBody resp) [unreadable]
            )
            ["-1", "2147483648", "99999999999999999999", "4x", " 4", "+4", ""]
          count (svcLedger svc) "lockstep_decision_receipts" >>= (@?= 0)
          count (svcLedger svc) ("lockstep_decision_refusals WHERE subject_id = '" <> woId wo <> "'") >>= (@?= 0)
    , testCase "out-of-range task and project revisions are a form error and change nothing (R3)" $
        withSvc $ \svc -> do
          p <- project svc "Kitchen" DecideLater
          t <- task svc p "1" "Buy bread"
          let
            tid = T.unpack (taskId t)
            pid = T.unpack (projectId p)
          traverse_
            ( \bad -> do
                decided <- post svc ("/app/api/tasks/" <> tid <> "/decide") [("ticket_revision", bad), ("action", "ready")]
                has (responseBody decided) [unreadable]
            )
            ["4294967297", "2147483648", "18446744073709551617", " 1", "1x", "-1"]
          traverse_
            ( \bad -> do
                edited <- post svc ("/app/api/tasks/" <> tid <> "/edit") [("revision", bad), ("title", "Buy rye bread"), ("acceptance", ""), ("priority", "normal")]
                has (responseBody edited) [unreadable]
                connected <- post svc ("/app/api/projects/" <> pid <> "/connect") [("revision", bad), ("folder", "later")]
                has (responseBody connected) [unreadable]
            )
            ["9223372036854775808", "18446744073709551617", " 1", "1x", "-1"]
          count (svcLedger svc) ("lockstep_decision_refusals WHERE subject_id = '" <> tid <> "'") >>= (@?= 0)
          after <- ready (findTask (lgRuntime (svcLedger svc)) (taskId t))
          fmap (\v -> (taskTitle v, taskRevision v, taskTicketRevision v)) after @?= Just ("Buy bread", 1, 1)
    , testCase "a closed decision that changed elsewhere does not show the earlier answer as how it stands (R4)" $
        withSvc $ \svc -> do
          wo <- stoppedWork (svcLedger svc) "Print the menu" "the printer jammed"
          page <- fragment svc ("decision/" <> woId wo)
          k <- maybe (assertFailure "no key") pure (inputValue "key" (responseBody page))
          done <- post svc ("/app/api/decisions/" <> woId wo) [("key", k), ("expected", "4"), ("choice", "put-back")]
          has (responseBody done) ["Done", "Recorded: Put it back in line."]
          reloaded <- fragment svc ("decision/" <> woId wo)
          has (responseBody reloaded) ["Recorded: Put it back in line."]
          _ <- ok "cancel elsewhere" (decideWorkOrder (lgRuntime (svcLedger svc)) noFaults wo 5 (Command Human WoCancel) [])
          later <- fragment svc ("decision/" <> woId wo)
          responseStatus later @?= 200
          has (responseBody later) ["no longer waiting"]
          lacks (fst (BS.breakSubstring "<details" (responseBody later))) ["Recorded: Put it back in line."]
          replay <- post svc ("/app/api/decisions/" <> woId wo) [("key", k), ("expected", "4"), ("choice", "put-back")]
          has (responseBody replay) ["no longer waiting"]
    , testCase "a title made to look like markup stays text inside the attribute (R8)" $
        withSvc $ \svc -> do
          p <- project svc "Kitchen" DecideLater
          t <- task svc p "1" hostile
          page <- fragment svc ("task/" <> T.unpack (taskId t))
          responseStatus page @?= 200
          has (responseBody page) ["value=\"&quot; autofocus onfocus=alert(1) x=&quot;\""]
          lacks (responseBody page) ["value=\"\" autofocus", "x=\"\" maxlength"]
    , testCase "the checks form says whether anything is chosen, apart from the chosen ID (R10)" $
        withSvc $ \svc -> do
          p <- project svc "Website" NewFolder
          let
            pid = T.unpack (projectId p)
          before <- fragment svc ("project-checks/" <> pid)
          responseStatus before @?= 200
          has (responseBody before) ["name=\"expected\" value=\"none\"", "name=\"expected_set\" value=\"no\""]
          saved <- post svc ("/app/api/projects/" <> pid <> "/checks") [("expected", "none"), ("expected_set", "no"), ("choice", "lockstep-basic")]
          has (responseBody saved) ["Saved.", "name=\"expected\" value=\"lockstep-basic\"", "name=\"expected_set\" value=\"yes\""]
          stale <- post svc ("/app/api/projects/" <> pid <> "/checks") [("expected", "none"), ("expected_set", "no"), ("choice", "lockstep-basic")]
          has (responseBody stale) ["since this page was shown"]
          unchanged <- post svc ("/app/api/projects/" <> pid <> "/checks") [("expected", "lockstep-basic"), ("expected_set", "yes"), ("choice", "lockstep-basic")]
          has (responseBody unchanged) ["Saved. This was already the choice."]
          odd <- post svc ("/app/api/projects/" <> pid <> "/checks") [("expected", "lockstep-basic"), ("expected_set", "maybe"), ("choice", "lockstep-basic")]
          has (responseBody odd) [unreadable]
    ]
