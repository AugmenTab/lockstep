{- | Role invocation (contract C-P4.5 A3–A6; DG-17 D-17.1, D-17.6–D-17.8). A
role runs as one program in a workspace given by a 'Runner': the tree (the
snapshot the caller wrote), its input (the context document and, for the
scripted adapter, its script) and its output. The role's only answer is the
file @result.json@ in its output; its standard output and error are evidence,
never instructions.

Every way an invocation can end is typed: answered (a checked answer),
failed (a known failure, safe to report), or uncertain (no result, or the
runner was interrupted: the caller must not run it again by itself, C-P2.6).

The runner decides the tree's access (read-only for every role but the
Implementer), the limits (D-17.7) and the environment; the adapter decides
only the program and its arguments, and no adapter can choose another runner
profile, limit, mount or network.
-}
module Lockstep.Effects.Roles
  ( View (..)
  , Workspace (..)
  , Runner (..)
  , RunnerFailure (..)
  , directRunner
  , helperRunner
  , liveRunner
  , liveProfile
  , Adapter (..)
  , scriptedAdapter
  , RoleOutcome (..)
  , roleOutcomeCode
  , roleEndingOf
  , invokeRole
  , prepareRole
  , runPrepared
  , decodeAnswer
  , encodeDiscovery
  , encodeCandidate
  , readAnswer
  ) where

import Control.Exception (IOException, finally, onException, try)
import Crypto.Random (getRandomBytes)
import Data.Bits ((.|.))
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Fleece.Aeson qualified as FA
import Fleece.Core ((#+))
import Fleece.Core qualified as FC
import Flipstone.Prelude
import System.Directory (createDirectory, getPermissions, listDirectory, removePathForcibly, setOwnerWritable, setPermissions)
import System.IO (FilePath, hClose)
import System.Posix.Files (fileMode, getFdStatus, getSymbolicLinkStatus, isDirectory, isRegularFile, isSymbolicLink, setFdMode)
import System.Posix.IO (OpenFileFlags (directory, nofollow, nonBlock), OpenMode (ReadOnly), closeFd, defaultFileFlags, fdToHandle, openFd)
import Text.Show (Show)

import Lockstep.Effects.HelperRunner (HelperFailure (..), PreparedRun (..), RunnerChannel, prepareRun, runnerDirectory, sendCancel, submitRun)
import Lockstep.Effects.Process (Cancel, RunResult (..), runDirect)
import Lockstep.Foundation.Fleece (encodeText)
import Lockstep.Foundation.RunnerProtocol (RunProfile (..), isRunName)
import Lockstep.Kernel.Roles
  ( Candidate (..)
  , CandidateTest (..)
  , Challenge (..)
  , Check (..)
  , Citation (..)
  , Criterion (..)
  , Discovery (..)
  , Expectation (..)
  , FileContent (..)
  , Finding (..)
  , FindingHint (..)
  , Implementation (..)
  , Review (..)
  , Role (..)
  , RoleAnswer (..)
  , Verdict (..)
  , checkAnswer
  , expectationName
  )
import Lockstep.Kernel.Runner (Limits, RoleEnding (..), RoleKind (..), RunOutcome (..), RunSpec (..), roleEndingText, roleLimits, runnerEnvironment)

-- Runners -------------------------------------------------------------------------

-- | The workspace's directories as the program sees them.
data View
  = View
  { viewTree :: T.Text
  , viewInput :: T.Text
  , viewOutput :: T.Text
  }
  deriving (Eq, Show)

-- | The workspace's directories as Lockstep sees them, and the program's view.
data Workspace
  = Workspace
  { workspaceTree :: FilePath
  , workspaceInput :: FilePath
  , workspaceOutput :: FilePath
  , workspaceView :: View
  , workspaceName :: T.Text
  }
  deriving (Eq, Show)

data RunnerFailure
  = RunnerRefused T.Text
  | RunnerUncertain T.Text
  deriving (Eq, Show)

data Runner
  = Runner
  { runnerName :: T.Text
  , runnerPrepare :: IO (Either T.Text Workspace)
  , runnerRun :: Workspace -> RunProfile -> Limits -> [T.Text] -> [T.Text] -> IO (Either RunnerFailure RunResult)
  , runnerRelease :: Workspace -> IO ()
  -- ^ C-P4.R1 R-K1: removes a finished workspace, only one of this runner's own.
  }

{- | The direct runner (C-P4.2 R2) on workspaces under a root directory. It is
not a filesystem boundary: a read-only role's tree and every protected file are
made read-only, and the caller must still compare the tree afterwards.
-}
directRunner :: Cancel -> FilePath -> IO Runner
directRunner cancel root =
  pure
    Runner
      { runnerName = T.pack "direct"
      , runnerPrepare = prepare
      , runnerRun = run
      , runnerRelease = releaseUnder root
      }
 where
  prepare = do
    made <- try (nextWorkspace root) :: IO (Either IOException Workspace)
    pure (either (const (Left (T.pack "workspace-unavailable"))) Right made)
  run workspace profile limits argv protected = do
    case profile of
      ProfileWrite -> traverse_ (readOnlyFile . ((workspaceTree workspace <> "/") <>) . T.unpack) protected
      _ -> readOnlyTree (workspaceTree workspace)
    result <-
      runDirect
        cancel
        RunSpec
          { runArgv = argv
          , runDirectory = T.pack (workspaceTree workspace)
          , runEnvironment = runnerEnvironment (T.pack (workspaceInput workspace <> "/../home"))
          , runLimits = limits
          }
    pure (either (Left . RunnerRefused) Right result)

nextWorkspace :: FilePath -> IO Workspace
nextWorkspace root = do
  name <- TE.decodeLatin1 . convertToBase Base16 <$> (getRandomBytes 16 :: IO BS.ByteString)
  let
    dir = root <> "/" <> T.unpack name
  createDirectory dir
  traverse_ (\d -> createDirectory (dir <> "/" <> d)) ["tree", "input", "output", "home"]
  pure
    Workspace
      { workspaceTree = dir <> "/tree"
      , workspaceInput = dir <> "/input"
      , workspaceOutput = dir <> "/output"
      , workspaceView = View (T.pack (dir <> "/tree")) (T.pack (dir <> "/input")) (T.pack (dir <> "/output"))
      , workspaceName = name
      }

{- | C-P4.R1 R-K1: removes a workspace only when it is this runner's own: a
directory (not a link) directly under the root, named by 32 hexadecimal
characters, whose tree is the workspace's. Its contents are made writable
first (a read-only role's tree is read-only); links inside are removed, never
followed. Anything else is left alone.
-}
releaseUnder :: FilePath -> Workspace -> IO ()
releaseUnder root workspace = do
  let
    dir = root <> "/" <> T.unpack (workspaceName workspace)
  status <- try (getSymbolicLinkStatus dir)
  case status of
    Right s
      | isRunName (workspaceName workspace) && workspaceTree workspace == dir <> "/tree" && isDirectory s ->
          void (try (writableTree dir >> removePathForcibly dir) :: IO (Either IOException ()))
    Right _ -> pure ()
    Left (_ :: IOException) -> pure ()

{- | Makes a directory and the directories below it writable and searchable by
their owner. C-P4.R2 R2-K: the mode is changed on the directory opened without
following a link, so a link put in its place is never followed.
-}
writableTree :: FilePath -> IO ()
writableTree dir = do
  _ <-
    try
      ( do
          fd <- openFd dir ReadOnly defaultFileFlags {nofollow = True, directory = True}
          ( do
              status <- getFdStatus fd
              when (isDirectory status) (setFdMode fd (fileMode status .|. 0o700))
            )
            `finally` closeFd fd
      ) ::
      IO (Either IOException ())
  names <- fromRight [] <$> (try (listDirectory dir) :: IO (Either IOException [FilePath]))
  traverse_
    ( \n -> do
        let
          path = dir <> "/" <> n
        status <- try (getSymbolicLinkStatus path)
        case status of
          Right s | isDirectory s -> writableTree path
          Right _ -> pure ()
          Left (_ :: IOException) -> pure ()
    )
    names

readOnlyFile :: FilePath -> IO ()
readOnlyFile path = do
  _ <- try (getPermissions path >>= setPermissions path . setOwnerWritable False) :: IO (Either IOException ())
  pure ()

readOnlyTree :: FilePath -> IO ()
readOnlyTree dir = do
  names <- listDirectory dir
  traverse_
    ( \n -> do
        let
          path = dir <> "/" <> n
        status <- getSymbolicLinkStatus path
        when (isDirectory status) (readOnlyTree path)
        when (isRegularFile status || isDirectory status) (readOnlyFile path)
    )
    names
  readOnlyFile dir

-- | The container runner (C-P4.2 R3, R4) through the host helper's channel.
helperRunner :: RunnerChannel -> Runner
helperRunner =
  containerRunner (T.pack "container") id

{- | C-P4.L L2: the container runner for a live provider's roles. A role runs
with the helper's live profile (the provider image and the run's own network
to the egress proxy, nothing else); every command, verification included,
still runs with no network. It is the same container runner on the record
(the invocation's adapter and argument vector say the role ran live).
-}
liveRunner :: RunnerChannel -> Runner
liveRunner =
  containerRunner (T.pack "container") liveProfile

-- | The live profile for a role's profile; any other profile is unchanged.
liveProfile :: RunProfile -> RunProfile
liveProfile profile =
  case profile of
    ProfileReadOnly -> ProfileLiveReadOnly
    ProfileWrite -> ProfileLiveWrite
    other -> other

containerRunner :: T.Text -> (RunProfile -> RunProfile) -> RunnerChannel -> Runner
containerRunner name choose channel =
  Runner
    { runnerName = name
    , runnerPrepare = prepare
    , runnerRun = run
    , runnerRelease = releaseUnder (runnerDirectory channel <> "/work")
    }
 where
  prepare = do
    made <- try (prepareRun channel) :: IO (Either IOException PreparedRun)
    pure $ case made of
      Left _ -> Left (T.pack "workspace-unavailable")
      Right p ->
        Right
          Workspace
            { workspaceTree = preparedTree p
            , workspaceInput = preparedInput p
            , workspaceOutput = preparedOutput p
            , workspaceView = View (T.pack "/work/tree") (T.pack "/input") (T.pack "/output")
            , workspaceName = preparedName p
            }
  run workspace requested _ argv protected = do
    let
      profile = choose requested
      prepared = PreparedRun (workspaceName workspace) (workspaceTree workspace) (workspaceInput workspace) (workspaceOutput workspace)
      -- The helper's wall clock, and for a live run its admission, proxy and clean-up.
      waitSeconds =
        case profile of
          ProfileWrite -> 1260
          ProfileLiveWrite -> 1320
          ProfileLiveReadOnly -> 720
          _ -> 660
    -- C-P4.R1 R-W2, C-P4.R2 R2-W: a run whose caller is stopped is cancelled through the helper, not left
    -- running; the cancel is sent, never waited for.
    result <- submitRun channel prepared profile argv protected waitSeconds `onException` sendCancel channel (workspaceName workspace)
    pure $ case result of
      Right r -> Right r
      Left HelperNoResult -> Left (RunnerUncertain (T.pack "helper-no-result"))
      Left HelperInterrupted -> Left (RunnerUncertain (T.pack "helper-interrupted"))
      Left (HelperResultInvalid code) -> Left (RunnerUncertain (T.pack "helper-result-invalid " <> code))
      Left (HelperRefused reason) -> Left (RunnerRefused (T.pack "helper-refused " <> reason))
      Left (HelperRequestInvalid code) -> Left (RunnerRefused (T.pack "request-invalid " <> code))

-- Adapters ------------------------------------------------------------------------

{- | An adapter writes what its program needs into the input directory and
names the program and its arguments, in the program's view of the workspace.
-}
data Adapter
  = Adapter
  { adapterName :: T.Text
  , adapterPrepare :: Workspace -> IO [T.Text]
  }

{- | The model-free scripted adapter (A4): the fixed scripted-role program and
the script for this invocation, both copied into the input.
-}
scriptedAdapter :: FilePath -> BS.ByteString -> Adapter
scriptedAdapter program script =
  Adapter
    { adapterName = T.pack "scripted"
    , adapterPrepare = \workspace -> do
        bytes <- BS.readFile program
        BS.writeFile (workspaceInput workspace <> "/scripted-role") bytes
        BS.writeFile (workspaceInput workspace <> "/script.json") script
        let
          view = workspaceView workspace
        pure
          [ T.pack "python3"
          , viewInput view <> T.pack "/scripted-role"
          , viewInput view <> T.pack "/script.json"
          , viewTree view
          , viewOutput view
          ]
    }

-- Invocation -------------------------------------------------------------------------

data RoleOutcome
  = RoleAnswered RoleAnswer RunResult
  | RoleFailed T.Text (Maybe RunResult)
  | RoleUncertain T.Text
  deriving (Eq, Show)

-- | The stored ending of an outcome ('roleEndingText').
roleOutcomeCode :: RoleOutcome -> T.Text
roleOutcomeCode =
  roleEndingText . roleEndingOf

roleEndingOf :: RoleOutcome -> RoleEnding
roleEndingOf outcome =
  case outcome of
    RoleAnswered _ _ -> RoleEndedAnswered
    RoleFailed code _ -> RoleEndedFailed code
    RoleUncertain code -> RoleEndedUncertain code

{- | A5: runs the role once in the prepared workspace (its tree already
written), with the context document as @context.json@ in its input.
-}
invokeRole :: Runner -> Adapter -> Role -> Workspace -> T.Text -> [T.Text] -> IO RoleOutcome
invokeRole runner adapter role workspace context protected = do
  prepared <- prepareRole adapter workspace context
  case prepared of
    Left code -> pure (RoleFailed code Nothing)
    Right argv -> runPrepared runner role workspace argv protected

{- | The first half of 'invokeRole': writes the context and the adapter's
input and names the program, so a caller can record exactly what will run
before it runs. A failure here is a known failure: nothing ran.
-}
prepareRole :: Adapter -> Workspace -> T.Text -> IO (Either T.Text [T.Text])
prepareRole adapter workspace context = do
  prepared <-
    try $ do
      BS.writeFile (workspaceInput workspace <> "/context.json") (TE.encodeUtf8 context)
      adapterPrepare adapter workspace
  pure $ case prepared of
    Left (_ :: IOException) -> Left (T.pack "workspace-unwritable")
    Right argv -> Right argv

-- | The second half of 'invokeRole': the run and its typed ending.
runPrepared :: Runner -> Role -> Workspace -> [T.Text] -> [T.Text] -> IO RoleOutcome
runPrepared runner role workspace argv protected = do
  let
    profile = if role == Implementer then ProfileWrite else ProfileReadOnly
    limits = roleLimits (kindOf role)
  -- After this point the run may have happened: an exception is an unknown outcome, never lost.
  attempted <- try (runnerRun runner workspace profile limits argv protected)
  let
    ran =
      case attempted of
        Left (_ :: IOException) -> Left (RunnerUncertain (T.pack "runner-exception"))
        Right r -> r
  case ran of
    Left (RunnerUncertain code) -> pure (RoleUncertain code)
    Left (RunnerRefused code) -> pure (RoleFailed (T.pack "runner-refused " <> code) Nothing)
    Right result ->
      case resultOutcome result of
        Exited 0 -> do
          answer <- readAnswer (workspaceOutput workspace <> "/result.json")
          pure $ case answer >>= decodeAnswer >>= checkAnswerCode role of
            Left code -> RoleFailed code (Just result)
            Right a -> RoleAnswered a result
        Exited 75 -> pure (RoleFailed (T.pack "provider-refused") (Just result))
        Exited _ -> pure (RoleFailed (T.pack "role-crashed") (Just result))
        TimedOut -> pure (RoleFailed (T.pack "role-timed-out") (Just result))
        OutputLimit _ -> pure (RoleFailed (T.pack "role-output-limit") (Just result))
        OutputHeld _ -> pure (RoleFailed (T.pack "role-output-held") (Just result))
        Cancelled -> pure (RoleFailed (T.pack "role-cancelled") (Just result))
        LaunchFailed _ -> pure (RoleFailed (T.pack "role-launch-failed") (Just result))
        -- C-P4.L L3: whatever the role wrote, a run the egress boundary stopped is not an answer.
        ProviderStopped code -> pure (RoleFailed (T.pack "provider-stopped " <> code) (Just result))
 where
  checkAnswerCode r a =
    either (\c -> Left (T.pack "answer-invalid " <> c)) Right (checkAnswer r a)

kindOf :: Role -> RoleKind
kindOf r =
  case r of
    Planner -> RolePlanner
    Challenger -> RoleChallenger
    Implementer -> RoleImplementer
    Reviewer -> RoleReviewer

{- | The answer file: a regular file of at most 256 KiB, opened without
following a link and checked on the open descriptor, so a file swapped after a
check cannot be read instead.
-}
readAnswer :: FilePath -> IO (Either T.Text BS.ByteString)
readAnswer path = do
  opened <- try (openFd path ReadOnly defaultFileFlags {nofollow = True, nonBlock = True})
  case opened of
    Left (_ :: IOException) -> do
      -- Missing, or a link (which nofollow refuses): tell the two apart for the record.
      link <- try (getSymbolicLinkStatus path)
      pure $ case link of
        Right s | isSymbolicLink s -> Left (T.pack "output-not-a-file")
        Right _ -> Left (T.pack "output-unreadable")
        Left (_ :: IOException) -> Left (T.pack "output-missing")
    Right fd -> do
      read' <-
        try $ do
          status <- getFdStatus fd
          if not (isRegularFile status)
            then closeFd fd >> pure (Left (T.pack "output-not-a-file"))
            else do
              h <- fdToHandle fd
              bytes <- BS.hGet h 262145 `finally` hClose h
              pure (if BS.length bytes > 262144 then Left (T.pack "output-too-large") else Right bytes)
      pure (either (\(_ :: IOException) -> Left (T.pack "output-unreadable")) id read')

-- Answer documents (A1) ----------------------------------------------------------------

{- | Decodes an answer: a JSON object whose @kind@ selects its exact shape;
unknown keys at any level are refused (@malformed-output@).
-}
decodeAnswer :: BS.ByteString -> Either T.Text RoleAnswer
decodeAnswer bytes = do
  let
    lazy = LBS.fromStrict bytes
    malformed reason = Left (T.pack "malformed-output " <> T.take 200 (T.pack reason))
  kind <- either malformed Right (FA.decode kindSchema lazy)
  case kindValue kind of
    k
      | k == T.pack "discovery" -> either malformed (fmap AnswerDiscovery . fromDiscovery) (FA.decode discoverySchema lazy)
      | k == T.pack "candidate" -> either malformed (fmap AnswerCandidate . fromCandidate) (FA.decode candidateSchema lazy)
      | k == T.pack "challenge" -> either malformed (fmap AnswerChallenge . fromChallenge) (FA.decode challengeSchema lazy)
      | k == T.pack "implementation" -> either malformed (fmap AnswerImplementation . fromImplementation) (FA.decode implementationSchema lazy)
      | k == T.pack "review" -> either malformed (fmap AnswerReview . fromReview) (FA.decode reviewSchema lazy)
      | otherwise -> Left (T.pack "malformed-output unknown kind")

type Extra =
  Map.Map T.Text FC.AnyJSON

known :: Extra -> Either T.Text ()
known extra =
  if Map.null extra
    then Right ()
    else Left (T.pack "malformed-output unknown keys: " <> T.intercalate (T.pack ", ") (Map.keys extra))

data DocKind
  = DocKind
  { kindValue :: T.Text
  , kindRest :: Extra
  }

kindSchema :: FC.Fleece t => FC.Schema t DocKind
kindSchema =
  FC.object $
    FC.additional
      (FC.constructor DocKind #+ FC.required "kind" kindValue FC.text)
      (FC.additionalFields kindRest FC.anyJSON)

data DocCitation
  = DocCitation T.Text Integer Integer Extra

citationSchema :: FC.Fleece t => FC.Schema t DocCitation
citationSchema =
  FC.object $
    FC.additional
      ( FC.constructor DocCitation
          #+ FC.required "path" (\(DocCitation p _ _ _) -> p) FC.text
          #+ FC.required "first" (\(DocCitation _ f _ _) -> f) FC.integer
          #+ FC.required "last" (\(DocCitation _ _ l _) -> l) FC.integer
      )
      (FC.additionalFields (\(DocCitation _ _ _ e) -> e) FC.anyJSON)

toCitation :: Citation -> DocCitation
toCitation c =
  DocCitation (citationPath c) (toInteger (citationFirst c)) (toInteger (citationLast c)) Map.empty

fromCitation :: DocCitation -> Either T.Text Citation
fromCitation (DocCitation p f l extra) = do
  known extra
  if f < 1 || l < 1 || f > 1000000 || l > 1000000
    then Left (T.pack "malformed-output citation range")
    else Right (Citation p (fromInteger f) (fromInteger l))

data DocCheck
  = DocCheck [T.Text] T.Text Extra

checkSchema :: FC.Fleece t => FC.Schema t DocCheck
checkSchema =
  FC.object $
    FC.additional
      ( FC.constructor DocCheck
          #+ FC.required "argv" (\(DocCheck a _ _) -> a) (FC.list FC.text)
          #+ FC.required "signature" (\(DocCheck _ s _) -> s) FC.text
      )
      (FC.additionalFields (\(DocCheck _ _ e) -> e) FC.anyJSON)

fromCheck :: DocCheck -> Either T.Text Check
fromCheck (DocCheck a s extra) =
  known extra >> Right (Check a s)

data DocDiscovery
  = DocDiscovery
  { dKind :: T.Text
  , dSummary :: T.Text
  , dHypothesis :: T.Text
  , dCitations :: [DocCitation]
  , dReproduction :: Maybe DocCheck
  , dAllowed :: [T.Text]
  , dExtra :: Extra
  }

discoverySchema :: FC.Fleece t => FC.Schema t DocDiscovery
discoverySchema =
  FC.object $
    FC.additional
      ( FC.constructor DocDiscovery
          #+ FC.required "kind" dKind FC.text
          #+ FC.required "summary" dSummary FC.text
          #+ FC.required "hypothesis" dHypothesis FC.text
          #+ FC.required "citations" dCitations (FC.list citationSchema)
          #+ FC.optional "reproduction" dReproduction checkSchema
          #+ FC.required "allowed_paths" dAllowed (FC.list FC.text)
      )
      (FC.additionalFields dExtra FC.anyJSON)

{- | A discovery in its answer form, through the schema 'decodeAnswer' reads
it with (so a recorded discovery reads back as the same 'Discovery').
-}
encodeDiscovery :: Discovery -> T.Text
encodeDiscovery d =
  encodeText
    discoverySchema
    DocDiscovery
      { dKind = T.pack "discovery"
      , dSummary = discoverySummary d
      , dHypothesis = discoveryHypothesis d
      , dCitations = fmap toCitation (discoveryCitations d)
      , dReproduction = (\c -> DocCheck (checkArgv c) (checkSignature c) Map.empty) <$> discoveryReproduction d
      , dAllowed = discoveryAllowedPaths d
      , dExtra = Map.empty
      }

fromDiscovery :: DocDiscovery -> Either T.Text Discovery
fromDiscovery d = do
  known (dExtra d)
  citations <- traverse fromCitation (dCitations d)
  reproduction <- traverse fromCheck (dReproduction d)
  pure (Discovery (dSummary d) (dHypothesis d) citations reproduction (dAllowed d))

data DocCriterion
  = DocCriterion
  { crId :: T.Text
  , crText :: T.Text
  , crQuote :: T.Text
  , crCitations :: [DocCitation]
  , crExtra :: Extra
  }

criterionSchema :: FC.Fleece t => FC.Schema t DocCriterion
criterionSchema =
  FC.object $
    FC.additional
      ( FC.constructor DocCriterion
          #+ FC.required "id" crId FC.text
          #+ FC.required "text" crText FC.text
          #+ FC.required "ticket_quote" crQuote FC.text
          #+ FC.required "citations" crCitations (FC.list citationSchema)
      )
      (FC.additionalFields crExtra FC.anyJSON)

data DocTest
  = DocTest
  { tPath :: T.Text
  , tContent :: T.Text
  , tExpect :: T.Text
  , tArgv :: [T.Text]
  , tSignature :: Maybe T.Text
  , tExtra :: Extra
  }

testSchema :: FC.Fleece t => FC.Schema t DocTest
testSchema =
  FC.object $
    FC.additional
      ( FC.constructor DocTest
          #+ FC.required "path" tPath FC.text
          #+ FC.required "content" tContent FC.text
          #+ FC.required "expect" tExpect FC.text
          #+ FC.required "argv" tArgv (FC.list FC.text)
          #+ FC.optional "signature" tSignature FC.text
      )
      (FC.additionalFields tExtra FC.anyJSON)

data DocCandidate
  = DocCandidate
  { cKind :: T.Text
  , cCriteria :: [DocCriterion]
  , cAllowed :: [T.Text]
  , cVerification :: [[T.Text]]
  , cTests :: [DocTest]
  , cExtra :: Extra
  }

candidateSchema :: FC.Fleece t => FC.Schema t DocCandidate
candidateSchema =
  FC.object $
    FC.additional
      ( FC.constructor DocCandidate
          #+ FC.required "kind" cKind FC.text
          #+ FC.required "criteria" cCriteria (FC.list criterionSchema)
          #+ FC.required "allowed_paths" cAllowed (FC.list FC.text)
          #+ FC.required "verification" cVerification (FC.list (FC.list FC.text))
          #+ FC.required "tests" cTests (FC.list testSchema)
      )
      (FC.additionalFields cExtra FC.anyJSON)

-- | A candidate in its answer form, through the schema 'decodeAnswer' reads it with.
encodeCandidate :: Candidate -> T.Text
encodeCandidate c =
  encodeText
    candidateSchema
    DocCandidate
      { cKind = T.pack "candidate"
      , cCriteria = [DocCriterion (criterionId x) (criterionText x) (criterionTicketQuote x) (fmap toCitation (criterionCitations x)) Map.empty | x <- candidateCriteria c]
      , cAllowed = candidateAllowedPaths c
      , cVerification = candidateVerification c
      , cTests = [DocTest (testPath t) (testContent t) (expectationName (testExpectation t)) (testArgv t) (testSignature t) Map.empty | t <- candidateTests c]
      , cExtra = Map.empty
      }

fromCandidate :: DocCandidate -> Either T.Text Candidate
fromCandidate c = do
  known (cExtra c)
  criteria <- traverse fromCriterion (cCriteria c)
  tests <- traverse fromTest (cTests c)
  pure (Candidate criteria (cAllowed c) (cVerification c) tests)
 where
  fromCriterion x = do
    known (crExtra x)
    citations <- traverse fromCitation (crCitations x)
    pure (Criterion (crId x) (crText x) (crQuote x) citations)
  fromTest t = do
    known (tExtra t)
    expectation <-
      case tExpect t of
        e | e == T.pack "red" -> Right ExpectRed
        e | e == T.pack "green" -> Right ExpectGreen
        _ -> Left (T.pack "malformed-output expect")
    pure (CandidateTest (tPath t) (tContent t) expectation (tArgv t) (tSignature t))

data DocFile
  = DocFile T.Text T.Text Extra

fileSchema :: FC.Fleece t => FC.Schema t DocFile
fileSchema =
  FC.object $
    FC.additional
      ( FC.constructor DocFile
          #+ FC.required "path" (\(DocFile p _ _) -> p) FC.text
          #+ FC.required "content" (\(DocFile _ c _) -> c) FC.text
      )
      (FC.additionalFields (\(DocFile _ _ e) -> e) FC.anyJSON)

fromFile :: DocFile -> Either T.Text FileContent
fromFile (DocFile p c extra) =
  known extra >> Right (FileContent p c)

data DocSupplement
  = DocSupplement T.Text T.Text [T.Text] T.Text Extra

supplementSchema :: FC.Fleece t => FC.Schema t DocSupplement
supplementSchema =
  FC.object $
    FC.additional
      ( FC.constructor DocSupplement
          #+ FC.required "path" (\(DocSupplement p _ _ _ _) -> p) FC.text
          #+ FC.required "content" (\(DocSupplement _ c _ _ _) -> c) FC.text
          #+ FC.required "argv" (\(DocSupplement _ _ a _ _) -> a) (FC.list FC.text)
          #+ FC.required "signature" (\(DocSupplement _ _ _ s _) -> s) FC.text
      )
      (FC.additionalFields (\(DocSupplement _ _ _ _ e) -> e) FC.anyJSON)

data DocFinding
  = DocFinding
  { fRequirement :: T.Text
  , fClaim :: T.Text
  , fBasis :: [DocCitation]
  , fMutant :: Maybe [DocFile]
  , fDemonstration :: Maybe DocCheck
  , fTest :: Maybe DocSupplement
  , fHint :: Maybe T.Text
  , fExtra :: Extra
  }

findingSchema :: FC.Fleece t => FC.Schema t DocFinding
findingSchema =
  FC.object $
    FC.additional
      ( FC.constructor DocFinding
          #+ FC.required "requirement" fRequirement FC.text
          #+ FC.required "claim" fClaim FC.text
          #+ FC.required "basis" fBasis (FC.list citationSchema)
          #+ FC.optional "mutant" fMutant (FC.list fileSchema)
          #+ FC.optional "demonstration" fDemonstration checkSchema
          #+ FC.optional "test" fTest supplementSchema
          #+ FC.optional "hint" fHint FC.text
      )
      (FC.additionalFields fExtra FC.anyJSON)

data DocChallenge
  = DocChallenge
  { chKind :: T.Text
  , chFindings :: [DocFinding]
  , chExtra :: Extra
  }

challengeSchema :: FC.Fleece t => FC.Schema t DocChallenge
challengeSchema =
  FC.object $
    FC.additional
      ( FC.constructor DocChallenge
          #+ FC.required "kind" chKind FC.text
          #+ FC.required "findings" chFindings (FC.list findingSchema)
      )
      (FC.additionalFields chExtra FC.anyJSON)

fromChallenge :: DocChallenge -> Either T.Text Challenge
fromChallenge c = do
  known (chExtra c)
  Challenge <$> traverse fromFinding (chFindings c)
 where
  fromFinding f = do
    known (fExtra f)
    basis <- traverse fromCitation (fBasis f)
    mutant <- traverse fromFile (fromMaybe [] (fMutant f))
    demonstration <- traverse fromCheck (fDemonstration f)
    test <-
      traverse
        (\(DocSupplement p content a s extra) -> known extra >> Right (FileContent p content, Check a s))
        (fTest f)
    hint <-
      case fHint f of
        Nothing -> Right HintNone
        Just h | h == T.pack "needs-human" -> Right HintNeedsHuman
        Just h | h == T.pack "inconclusive" -> Right HintInconclusive
        Just _ -> Left (T.pack "malformed-output hint")
    pure (Finding (fRequirement f) (fClaim f) basis mutant demonstration test hint)

data DocImplementation
  = DocImplementation T.Text T.Text Extra

implementationSchema :: FC.Fleece t => FC.Schema t DocImplementation
implementationSchema =
  FC.object $
    FC.additional
      ( FC.constructor DocImplementation
          #+ FC.required "kind" (\(DocImplementation k _ _) -> k) FC.text
          #+ FC.required "summary" (\(DocImplementation _ s _) -> s) FC.text
      )
      (FC.additionalFields (\(DocImplementation _ _ e) -> e) FC.anyJSON)

fromImplementation :: DocImplementation -> Either T.Text Implementation
fromImplementation (DocImplementation _ s extra) =
  known extra >> Right (Implementation s)

data DocReview
  = DocReview T.Text T.Text [T.Text] Extra

reviewSchema :: FC.Fleece t => FC.Schema t DocReview
reviewSchema =
  FC.object $
    FC.additional
      ( FC.constructor DocReview
          #+ FC.required "kind" (\(DocReview k _ _ _) -> k) FC.text
          #+ FC.required "verdict" (\(DocReview _ v _ _) -> v) FC.text
          #+ FC.required "reasons" (\(DocReview _ _ r _) -> r) (FC.list FC.text)
      )
      (FC.additionalFields (\(DocReview _ _ _ e) -> e) FC.anyJSON)

fromReview :: DocReview -> Either T.Text Review
fromReview (DocReview _ v reasons extra) = do
  known extra
  verdict <-
    case v of
      x | x == T.pack "approve" -> Right Approve
      x | x == T.pack "reject" -> Right Reject
      x | x == T.pack "needs-human" -> Right NeedsHuman
      _ -> Left (T.pack "malformed-output verdict")
  pure (Review verdict reasons)
