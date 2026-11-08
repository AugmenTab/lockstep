{-# LANGUAGE OverloadedStrings #-}

{- | The task page's view of a coding transaction, over HTTP from the real
service (contract C-P4.16), while the test moves the transaction with the
engine in-process against the same database (scripted roles, real Git and
processes): where the fix stands, what it must do, how it is checked, what
the checks showed, findings and review; what Lockstep could not tell; a
person's decision on a halt and their Done or not, from the page only with
the session and this origin.
-}
module Lockstep.EnginePageTest
  ( tests
  ) where

import Control.Concurrent (forkIO, killThread, threadDelay)
import Control.Exception (SomeException, try)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTPTypes
import System.Directory (createDirectory, doesFileExist, removeFile)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath, writeFile)
import System.IO.Temp (withSystemTempDirectory)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason)
import Lockstep.Application.Engine (Engine (..), StepReport (..), TransactionView (..), advance, startTransaction, transactionView)
import Lockstep.Application.Execution (Admission (..), admitBug, enableExecution)
import Lockstep.Application.ProjectChecks (ExpectedChecks (..))
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Application.Tasks (NewTask (..), TaskDecision (..), TaskView (..), createTask, decideTask)
import Lockstep.Effects.Process (newCancel)
import Lockstep.Effects.Roles (Adapter, directRunner, scriptedAdapter)
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Roles (Role (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Support.Http (HttpResponse (..), httpRequest, responseHeader)
import Lockstep.Support.Postgres (AdminSettings (..), databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime, writeConfigFile)
import Lockstep.Support.Process (freePort, runLockstep, withService)

tests :: TestTree
tests =
  testGroup
    "C-P4.16 the task page shows a coding transaction and takes a person's decisions (real service, Git, processes, PostgreSQL)"
    [ testCase "a fix under way shows its step, what it must do and how it is checked; nothing not yet done is claimed" underWay
    , testCase "a stopped fix asks the person; their answer from the page is recorded and resumes it; an old form changes nothing" halted
    , testCase "a committed fix shows the checks, findings and review, and only the person's Done marks it done" committed
    , testCase "not done stops it; Done before the fix is committed is refused in words; both need the session and this origin" notDone
    , testCase "a helper whose run was cut short is shown as not known, and not run again" uncertain
    , testCase "typed text is escaped, and the section has no internal words outside Technical details" plainWords
    ]

-- Fixture ----------------------------------------------------------------------------------

data Fx
  = Fx
  { fxRuntime :: DatabaseRuntime
  , fxTmp :: FilePath
  , fxPort :: Int
  , fxSession :: BS.ByteString
  , fxCount :: String -> IO Int
  }

-- | A migrated database, the service over it with the projects folder, a signed-in session and an in-process runtime.
withFx :: (Fx -> IO a) -> IO a
withFx action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-p416" $ \tmp -> do
      path <- writeConfigFile tmp admin db (adminPassword admin)
      createDirectory (tmp <> "/projects")
      createDirectory (tmp <> "/work")
      let
        env = [("LOCKSTEP_CONFIG", path), ("LOCKSTEP_PROJECT_FOLDERS", tmp <> "/projects")]
        counter query = do
          rows <- queryInts admin db query
          case rows of
            [n] -> pure n
            _ -> assertFailure ("count " <> query)
      (code, _, err) <- runLockstep env ["db", "migrate"]
      assertBool ("db migrate failed: " <> err) (code == ExitSuccess)
      config <- databaseConfigFor admin db
      port <- freePort
      (outcome, _) <-
        withService env port (tmp <> "/serve.log") $ do
          session <- signIn port env
          withRuntime config $ \runtime -> action (Fx runtime tmp port session counter)
      pure outcome

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

taskPage :: Fx -> T.Text -> IO BS.ByteString
taskPage fx tid = do
  resp <- httpRequest (fxPort fx) "GET" ("/app/fragments/task/" <> T.unpack tid) [("X-Lockstep-Session", fxSession fx)] ""
  responseStatus resp @?= 200
  pure (responseBody resp)

post :: Fx -> [HTTPTypes.Header] -> String -> [(BS.ByteString, BS.ByteString)] -> IO HttpResponse
post fx headers path fields =
  httpRequest (fxPort fx) "POST" path (("Content-Type", "application/x-www-form-urlencoded") : headers) (HTTPTypes.renderSimpleQuery False fields)

asOperator :: Fx -> [HTTPTypes.Header]
asOperator fx =
  [("Origin", origin (fxPort fx)), ("X-Lockstep-Session", fxSession fx)]

contains :: BS.ByteString -> BS.ByteString -> Bool
contains needle haystack =
  not (BS.null (snd (BS.breakSubstring needle haystack)))

has :: BS.ByteString -> [BS.ByteString] -> IO ()
has body =
  traverse_ (\needle -> assertBool ("missing " <> show needle <> ": " <> show body) (contains needle body))

lacks :: BS.ByteString -> [BS.ByteString] -> IO ()
lacks body =
  traverse_ (\needle -> assertBool ("unexpected " <> show needle <> ": " <> show body) (not (contains needle body)))

inputValue :: BS.ByteString -> BS.ByteString -> Maybe BS.ByteString
inputValue name page =
  let
    after = snd (BS.breakSubstring ("name=\"" <> name <> "\" value=\"") page)
  in
    if BS.null after
      then Nothing
      else Just (BS.takeWhile (/= 0x22) (BS.drop (BS.length name + 15) after))

formFields :: BS.ByteString -> BS.ByteString -> [BS.ByteString] -> IO [(BS.ByteString, BS.ByteString)]
formFields formId page names = do
  let
    form = fst (BS.breakSubstring "</form>" (snd (BS.breakSubstring ("id=\"" <> formId <> "\"") page)))
  assertBool ("no form " <> show formId <> ": " <> show page) (not (BS.null form))
  traverse (\n -> maybe (assertFailure ("no field " <> show n <> " in " <> show form)) (\v -> pure (n, v)) (inputValue n form)) names

-- | The Fixing it section: from its heading to the next second-level heading.
fixing :: BS.ByteString -> BS.ByteString
fixing body =
  let
    start = snd (BS.breakSubstring "id=\"fixing\"" body)
  in
    BS.take 1 start <> fst (BS.breakSubstring "<h2" (BS.drop 1 start))

ordinary :: BS.ByteString -> BS.ByteString
ordinary =
  BS8.map Char.toLower . fst . BS.breakSubstring "<details"

internalWords :: [BS.ByteString]
internalWords =
  ["profile", "gate", "invariant", "work order", "ticket", "engineer", "scheduler", "digest", "supervisor", "repositor", "phase", "work unit", "contract", "invocation", "planner", "challenger", "implementer"]

key :: T.Text -> IO IdempotencyKey
key text =
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-page-key-" <> text))

accepted :: Show e => IO (Either e a) -> IO a
accepted action =
  action >>= either (\e -> assertFailure ("refused: " <> show e)) pure

ready :: Show e => IO (Either e a) -> IO a
ready action =
  action >>= either (\e -> assertFailure ("not ready: " <> show e)) pure

gitIn :: FilePath -> [String] -> IO ()
gitIn dir args = do
  base <- getEnvironment
  let
    identity = ["-c", "user.name=Person", "-c", "user.email=person@example.invalid", "-c", "init.defaultBranch=main"]
    env = ("GIT_CONFIG_NOSYSTEM", "1") : L.filter ((/= "GIT_CONFIG_NOSYSTEM") . fst) base
  finished <-
    timeout 30000000 $
      Process.readCreateProcessWithExitCode ((Process.proc "git" (identity <> args)) {Process.cwd = Just dir, Process.env = Just env}) ""
  case finished of
    Just (ExitSuccess, _, _) -> pure ()
    other -> assertFailure ("git " <> show args <> ": " <> show other)

data Bug
  = Bug
  { bugFolder :: FilePath
  , bugProject :: T.Text
  , bugTask :: T.Text
  , bugWorkOrder :: T.Text
  }

-- | A project with a buggy calc.py, Lockstep allowed in it, a ready task handed over as a bug.
admittedBug :: Fx -> T.Text -> T.Text -> IO Bug
admittedBug fx name title = do
  let
    folders = ProjectFolders (Just (fxTmp fx <> "/projects")) []
  pk <- key ("project-" <> name)
  view <- accepted (ready (createProject (fxRuntime fx) folders (NewProject pk name "" NewFolder)))
  folder <- maybe (assertFailure "no folder") (pure . T.unpack) (projectFolder view)
  writeFile (folder <> "/calc.py") "def add(a, b):\n    return a - b\n"
  gitIn folder ["add", "calc.py"]
  gitIn folder ["commit", "-q", "-m", "calc"]
  ek <- key ("enable-" <> name)
  _ <- accepted (ready (enableExecution (fxRuntime fx) folders ek (projectId view) ExpectNothing))
  tk <- key ("task-" <> name)
  t <- accepted (ready (createTask (fxRuntime fx) (NewTask tk (projectId view) title "add(2, 2) is 4" Normal [])))
  readied <- accepted (ready (decideTask (fxRuntime fx) "test-session" (taskId t) (taskTicketRevision t) MarkReady))
  ak <- key ("admit-" <> name)
  admission <- accepted (ready (admitBug (fxRuntime fx) folders ak (taskId readied) (taskTicketRevision readied)))
  pure (Bug folder (projectId view) (taskId readied) (admissionWorkOrder admission))

-- Scripted roles ------------------------------------------------------------------------------

jsonString :: T.Text -> T.Text
jsonString text =
  "\"" <> T.concatMap escape text <> "\""
 where
  escape c =
    case c of
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\n' -> "\\n"
      _ -> T.singleton c

result :: T.Text -> T.Text
result roleAnswer =
  "{\"result\":" <> roleAnswer <> "}"

discovery :: T.Text
discovery =
  result
    ( "{\"kind\":\"discovery\",\"summary\":\"add subtracts\",\"hypothesis\":\"calc.add uses minus\","
        <> "\"citations\":[{\"path\":\"calc.py\",\"first\":1,\"last\":2}],"
        <> "\"reproduction\":{\"argv\":[\"python3\",\"-c\",\"import calc; assert calc.add(2, 2) == 4, 'add is wrong'\"],\"signature\":\"add is wrong\"},"
        <> "\"allowed_paths\":[\"calc.py\"]}"
    )

candidateWith :: T.Text -> T.Text
candidateWith criterion =
  result
    ( "{\"kind\":\"candidate\",\"criteria\":[{\"id\":\"add-adds\",\"text\":"
        <> jsonString criterion
        <> ",\"ticket_quote\":\"add(2, 2) is 4\","
        <> "\"citations\":[{\"path\":\"calc.py\",\"first\":1,\"last\":2}]}],\"allowed_paths\":[\"calc.py\"],"
        <> "\"verification\":[[\"python3\",\"-m\",\"unittest\",\"test_calc\"]],\"tests\":[{\"path\":\"test_calc.py\",\"content\":"
        <> jsonString "import unittest\nimport calc\n\n\nclass TestAdd(unittest.TestCase):\n    def test_add(self):\n        self.assertEqual(calc.add(2, 2), 4, 'add is wrong')\n"
        <> ",\"expect\":\"red\",\"argv\":[\"python3\",\"-m\",\"unittest\",\"test_calc\"],\"signature\":\"add is wrong\"}]}"
    )

noFindings :: T.Text
noFindings =
  result "{\"kind\":\"challenge\",\"findings\":[]}"

fixes :: T.Text
fixes =
  "{\"write\":{\"path\":\"calc.py\",\"content\":" <> jsonString "def add(a, b):\n    return a + b\n" <> "}}," <> result "{\"kind\":\"implementation\",\"summary\":\"add now adds\"}"

approve :: T.Text
approve =
  result "{\"kind\":\"review\",\"verdict\":\"approve\",\"reasons\":[\"the change is the one line\"]}"

engineWith :: Fx -> [T.Text] -> T.Text -> IO Engine
engineWith fx planner criterion = do
  cancel <- newCancel
  runner <- directRunner cancel (fxTmp fx <> "/work")
  let
    pick answers n = scriptedAdapter "scripts/runner/scripted-role" . script <$> L.lookup n (L.zip [0 ..] answers)
    adapter :: Role -> Int -> Maybe Adapter
    adapter role =
      case role of
        Planner -> pick (planner <> [candidateWith criterion])
        Challenger -> pick [noFindings, noFindings]
        Implementer -> pick [fixes]
        Reviewer -> pick [approve]
  pure (Engine runner adapter)

happy :: Fx -> IO Engine
happy fx =
  engineWith fx [discovery] "add returns the sum"

script :: T.Text -> BS.ByteString
script steps =
  TE.encodeUtf8 ("{\"steps\":[" <> steps <> "]}")

begin :: Fx -> Bug -> IO TransactionView
begin fx bug =
  accepted (ready (startTransaction (fxRuntime fx) (bugWorkOrder bug)))

stepTimes :: Fx -> Engine -> TransactionView -> Int -> IO StepReport
stepTimes fx engine view n = do
  report <- accepted (ready (advance (fxRuntime fx) engine (viewId view)))
  if n <= 1 then pure report else stepTimes fx engine view (n - 1)

inputOf :: StepReport -> T.Text
inputOf report =
  case report of
    Stepped i _ -> i
    Idle why _ -> "idle " <> why

stateNow :: Fx -> TransactionView -> IO T.Text
stateNow fx view =
  maybe "missing" viewState <$> ready (transactionView (fxRuntime fx) (viewId view))

-- Cases ---------------------------------------------------------------------------------------

underWay :: Assertion
underWay =
  withFx $ \fx -> do
    bug <- admittedBug fx "under-way" "add subtracts"
    engine <- happy fx
    let
      projectPage = do
        resp <- httpRequest (fxPort fx) "GET" ("/app/fragments/project/" <> T.unpack (bugProject bug)) [("X-Lockstep-Session", fxSession fx)] ""
        pure (responseBody resp)
    before <- projectPage
    has before ["Nothing has run yet", "cannot change it or run anything in it yet"]
    view <- begin fx bug
    project <- projectPage
    lacks project ["Nothing has run yet", "cannot change it or run anything in it yet"]
    has project ["shows on its task page where its fix stands", "only on its own branch"]
    whole <- taskPage fx (bugTask bug)
    lacks whole ["Nothing runs it yet"]
    let
      early = fixing whole
    has early ["Lockstep is working on this bug: looking at the project", "Not written yet.", "The checks have not run yet.", "Not challenged yet.", "Not reviewed yet."]
    lacks early ["Lockstep has this bug in line to fix.", "id=\"completion-form\"", "id=\"halt-form\""]
    _ <- stepTimes fx engine view 4
    page <- fixing <$> taskPage fx (bugTask bug)
    has
      page
      [ "Lockstep is working on this bug: checking those tests."
      , "add returns the sum"
      , "from the task: \226\128\156add(2, 2) is 4\226\128\157"
      , "The test in test_calc.py, run with"
      , "python3 -m unittest test_calc"
      , "The checks have not run yet."
      , "Not challenged yet."
      , "Not reviewed yet."
      , "Technical details"
      , TE.encodeUtf8 (viewId view)
      ]
    lacks page ["Every check passed", "approved", "id=\"completion-form\""]

halted :: Assertion
halted =
  withFx $ \fx -> do
    bug <- admittedBug fx "halted" "add subtracts"
    writeFile (bugFolder bug <> "/notes.txt") "uncommitted\n"
    engine <- happy fx
    view <- begin fx bug
    _ <- stepTimes fx engine view 2
    page <- fixing <$> taskPage fx (bugTask bug)
    has
      page
      [ "Lockstep stopped while looking at the project"
      , "needs your decision"
      , "has changes that are not committed"
      , "id=\"halt-form\""
      , "action=\"/app/api/transactions/" <> TE.encodeUtf8 (viewId view) <> "/decision\""
      , "name=\"choice\" value=\"retry\""
      , "name=\"choice\" value=\"stop\""
      , "Try this step again"
      , "Stop fixing this bug"
      ]
    lacks page ["value=\"accept-non-reproduction\""]
    fields <- formFields "halt-form" page ["key", "request", "revision"]
    let
      path = "/app/api/transactions/" <> T.unpack (viewId view) <> "/decision"
      answer = fields <> [("choice", "retry")]
    none <- post fx [("Origin", origin (fxPort fx))] path answer
    responseStatus none @?= 401
    elsewhere <- post fx [("Origin", "http://127.0.0.1:1"), ("X-Lockstep-Session", fxSession fx)] path answer
    responseStatus elsewhere @?= 403
    fxCount fx "SELECT count(*)::integer AS v FROM lockstep_conversation_messages WHERE choice IS NOT NULL" >>= (@?= 0)
    unchosen <- post fx (asOperator fx) path fields
    has (responseBody unchosen) ["Choose what should happen next."]
    removeFile (bugFolder bug <> "/notes.txt")
    resp <- post fx (asOperator fx) path answer
    responseStatus resp @?= 200
    responseHeader "X-Lockstep-Path" resp @?= Just ("/app/tasks/" <> TE.encodeUtf8 (bugTask bug))
    has (fixing (responseBody resp)) ["Your decision is recorded"]
    stateNow fx view >>= (@?= "halted")
    resumed <- stepTimes fx engine view 1
    inputOf resumed @?= "human-retry"
    after <- fixing <$> taskPage fx (bugTask bug)
    has after ["Lockstep is working on this bug: looking at the project"]
    lacks after ["id=\"halt-form\""]
    -- the old form, sent again with another answer, changes nothing
    stale <- post fx (asOperator fx) path (fields <> [("choice", "stop")])
    has (responseBody stale) ["no longer the question Lockstep is waiting on"]
    stateNow fx view >>= (@?= "running")

committed :: Assertion
committed =
  withFx $ \fx -> do
    bug <- admittedBug fx "committed" "add subtracts"
    engine <- happy fx
    view <- begin fx bug
    _ <- stepTimes fx engine view 11
    stateNow fx view >>= (@?= "accepted")
    page <- fixing <$> taskPage fx (bugTask bug)
    has
      page
      [ "id=\"fix-committed\""
      , "committed it on its own branch"
      , "Only you decide whether this bug is fixed."
      , "Every check passed on the committed change."
      , "python3 -m unittest test_calc</code>: passed"
      , "Nothing was found."
      , "The reviewer approved the change."
      , "the change is the one line"
      , "id=\"completion-form\""
      , "action=\"/app/api/transactions/" <> TE.encodeUtf8 (viewId view) <> "/completion\""
      , "name=\"choice\" value=\"done\""
      , "name=\"choice\" value=\"not-done\""
      ]
    lacks page ["You marked this bug fixed.", "The checks have not run yet."]
    let
      path = "/app/api/transactions/" <> T.unpack (viewId view) <> "/completion"
    resp <- post fx (asOperator fx) path [("choice", "done")]
    responseStatus resp @?= 200
    responseHeader "X-Lockstep-Path" resp @?= Just ("/app/tasks/" <> TE.encodeUtf8 (bugTask bug))
    has (fixing (responseBody resp)) ["You marked this bug fixed."]
    lacks (fixing (responseBody resp)) ["id=\"completion-form\""]
    stateNow fx view >>= (@?= "done")
    again <- post fx (asOperator fx) path [("choice", "done")]
    has (responseBody again) ["This fix is already decided."]
    fxCount fx "SELECT count(*)::integer AS v FROM lockstep_transaction_records WHERE kind = 'completion' AND principal = 'human'" >>= (@?= 1)

notDone :: Assertion
notDone =
  withFx $ \fx -> do
    bug <- admittedBug fx "not-done" "add subtracts"
    engine <- happy fx
    view <- begin fx bug
    let
      path = "/app/api/transactions/" <> T.unpack (viewId view) <> "/completion"
    early <- post fx (asOperator fx) path [("choice", "done")]
    has (responseBody early) ["This fix is not ready for your decision yet."]
    stateNow fx view >>= (@?= "running")
    _ <- stepTimes fx engine view 11
    none <- post fx [("Origin", origin (fxPort fx))] path [("choice", "not-done")]
    responseStatus none @?= 401
    elsewhere <- post fx [("Origin", "http://127.0.0.1:1"), ("X-Lockstep-Session", fxSession fx)] path [("choice", "not-done")]
    responseStatus elsewhere @?= 403
    unknown <- post fx (asOperator fx) path [("choice", "finished")]
    has (responseBody unknown) ["Choose whether this bug is fixed."]
    stateNow fx view >>= (@?= "accepted")
    resp <- post fx (asOperator fx) path [("choice", "not-done")]
    has (fixing (responseBody resp)) ["Lockstep stopped fixing this bug: you said it is not fixed."]
    stateNow fx view >>= (@?= "stopped")
    missing <- post fx (asOperator fx) "/app/api/transactions/00000000-0000-4000-8000-000000000000/completion" [("choice", "done")]
    responseStatus missing @?= 404

uncertain :: Assertion
uncertain =
  withFx $ \fx -> do
    bug <- admittedBug fx "uncertain" "add subtracts"
    let
      marker = fxTmp fx <> "/ran"
    engine <- engineWith fx ["{\"append\":{\"path\":\"" <> T.pack marker <> "\",\"content\":\"ran\\n\"}},{\"sleep\":30}", discovery] "add returns the sum"
    view <- begin fx bug
    _ <- stepTimes fx engine view 1
    thread <- forkIO (void (try (advance (fxRuntime fx) engine (viewId view)) :: IO (Either SomeException (Either NotReadyReason (Either T.Text StepReport)))))
    waitFor 100 (doesFileExist marker)
    killThread thread
    threadDelay 500000
    running <- fixing <$> taskPage fx (bugTask bug)
    has running ["Lockstep is working on this bug: finding the cause."]
    report <- stepTimes fx engine view 1
    viewHalt (viewAfter report) @?= Just "uncertain-invocation unfinished-invocation"
    page <- fixing <$> taskPage fx (bugTask bug)
    has
      page
      [ "id=\"fix-uncertain\""
      , "could not tell whether one of its helpers finished"
      , "will not run that helper again by itself"
      , "id=\"halt-form\""
      ]
    fxCount fx "SELECT count(*)::integer AS v FROM lockstep_invocations" >>= (@?= 1)

viewAfter :: StepReport -> TransactionView
viewAfter report =
  case report of
    Stepped _ v -> v
    Idle _ v -> v

waitFor :: Int -> IO Bool -> IO ()
waitFor remaining check = do
  ok <- check
  if ok || remaining <= 0
    then assertBool "the role never started" ok
    else threadDelay 100000 >> waitFor (remaining - 1) check

plainWords :: Assertion
plainWords =
  withFx $ \fx -> do
    bug <- admittedBug fx "plain" "<script>alert(1)</script>"
    engine <- engineWith fx [discovery] "add returns <b>the sum</b>"
    view <- begin fx bug
    let
      clean label body =
        traverse_ (\word -> assertBool ("internal word " <> show word <> " " <> label) (not (contains word (ordinary (fixing body))))) internalWords
    taskPage fx (bugTask bug) >>= clean "at the start"
    _ <- stepTimes fx engine view 4
    running <- taskPage fx (bugTask bug)
    clean "under way" running
    lacks running ["<b>the sum</b>", "<script>alert(1)"]
    has running ["add returns &lt;b&gt;the sum&lt;/b&gt;"]
    _ <- stepTimes fx engine view 7
    taskPage fx (bugTask bug) >>= clean "when committed"
    bug2 <- admittedBug fx "plain-halted" "add subtracts"
    writeFile (bugFolder bug2 <> "/notes.txt") "uncommitted\n"
    view2 <- begin fx bug2
    _ <- stepTimes fx engine view2 2
    taskPage fx (bugTask bug2) >>= clean "when stopped"
    resp <- post fx (asOperator fx) ("/app/api/transactions/" <> T.unpack (viewId view) <> "/completion") [("choice", "done")]
    clean "when done" (responseBody resp)
    lacks (responseBody resp) ["<script>alert(1)"]
