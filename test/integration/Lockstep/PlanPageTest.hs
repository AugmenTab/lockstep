{-# LANGUAGE OverloadedStrings #-}

{- | The plan page over the real service (contract C-P6.4 M5, M8): a
project's plan revisions with their units, edges and uncertainties, and the
owner's digest-bound decision, taken only with the session and this origin.
-}
module Lockstep.PlanPageTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTPTypes
import System.Directory (createDirectory)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (Show, show)

import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Database (DatabaseRuntime)
import Lockstep.Application.PlanDocument (encodePlanDocument)
import Lockstep.Application.Plans (PlanView (..), RevisionView (..), planView, proposePlan)
import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Application.Projects (NewProject (..), ProjectFolders (..), ProjectView (..), createProject)
import Lockstep.Kernel.Plan (EdgeKind (..), EffectClass (..), Envelope (..), PlanCriterion (..), PlanDocument (..), PlanEdge (..), PlanMode (..), PlanSource (..), PlanUnit (..), RiskClass (..), Uncertainty (..), UnitKey, mkUnitKey)
import Lockstep.Kernel.Profile (Hasher (..), contentDigestText)
import Lockstep.Kernel.Project (FolderChoice (..))
import Lockstep.Kernel.Task (Priority (..))
import Lockstep.Support.Http (HttpResponse (..), httpRequest, responseHeader)
import Lockstep.Support.Postgres (AdminSettings (..), databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime, writeConfigFile)
import Lockstep.Support.Process (freePort, runLockstep, withService)

data Env
  = Env
  { envAdmin :: AdminSettings
  , envDb :: T.Text
  , envRuntime :: DatabaseRuntime
  , envCli :: [(String, String)]
  , envPort :: Int
  , envDir :: FilePath
  }

withEnv :: (Env -> IO a) -> IO a
withEnv action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-p64-page" $ \dir -> do
      path <- writeConfigFile dir admin db (adminPassword admin)
      let
        cli = [("LOCKSTEP_CONFIG", path)]
      (code, _, err) <- runLockstep cli ["db", "migrate"]
      assertBool ("db migrate failed: " <> err) (code == ExitSuccess)
      createDirectory (dir <> "/projects")
      config <- databaseConfigFor admin db
      withRuntime config $ \runtime -> do
        port <- freePort
        (result, _) <- withService cli port (dir <> "/serve.log") (action (Env admin db runtime cli port dir))
        pure result

accepted :: Show e => IO (Either e a) -> IO a
accepted act =
  act >>= either (\e -> assertFailure ("refused: " <> show e)) pure

ready :: Show e => IO (Either e a) -> IO a
ready act =
  act >>= either (\e -> assertFailure ("not ready: " <> show e)) pure

idem :: T.Text -> IO IdempotencyKey
idem text =
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-plan-page-" <> text))

k :: T.Text -> UnitKey
k text =
  case mkUnitKey text of
    Just u -> u
    Nothing -> k "invalid-key-in-test"

sha :: T.Text -> T.Text
sha text =
  case sha256Hasher of
    Hasher f -> contentDigestText (f text)

unit :: T.Text -> T.Text -> PlanUnit
unit name title =
  PlanUnit (k name) title "P1" "P1.1" "feature" "lockstep-bug-fix" Normal LocalOnly RiskNormal True [] [PlanCriterion ("The " <> name <> " works.") ["prd"]] [] [] [] []

plan :: PlanDocument
plan =
  PlanDocument
    { planTitle = "Caesura"
    , planMode = Brownfield
    , planSources = [PlanSource "prd" (sha "the PRD")]
    , planEnvelope = Envelope False 5 Nothing
    , planUnits = [unit "core" "Parse poems into syllables", unit "cli" "Read a poem from a file"]
    , planEdges = [PlanEdge (k "cli") (k "core") Technical]
    , planUncertainties = [Uncertainty "The PRD does not say which meters count." ["prd"]]
    }

-- | A project with a proposed plan (revision 1, proposed by a person through the application).
proposed :: Env -> IO (ProjectView, RevisionView)
proposed env = do
  pk <- idem "project"
  view <- accepted (ready (createProject (envRuntime env) (ProjectFolders (Just (envDir env <> "/projects")) []) (NewProject pk "Caesura" "" NewFolder)))
  ik <- idem "plan"
  r <- accepted (ready (proposePlan (envRuntime env) ik (projectId view) "owner-session" (LBS.fromStrict (TE.encodeUtf8 (encodePlanDocument plan)))))
  pure (view, r)

origin :: Env -> BS.ByteString
origin env =
  "http://127.0.0.1:" <> BS8.pack (show (envPort env))

session :: Env -> IO BS.ByteString
session env = do
  (code, out, err) <- runLockstep (envCli env) ["operator", "sign-in", "--port", show (envPort env)]
  code @?= ExitSuccess
  token <-
    case L.stripPrefix "=" (L.dropWhile (/= '=') (L.filter (/= '\n') out)) of
      Just t | L.length t == 43 -> pure t
      _ -> assertFailure ("unexpected sign-in output: " <> out <> err)
  resp <- httpRequest (envPort env) "POST" "/app/api/session" [("Origin", origin env)] (BS8.pack token)
  responseStatus resp @?= 200
  pure (BS.take 43 (BS.drop 11 (snd (BS.breakSubstring "\"session\":\"" (responseBody resp)))))

fragment :: Env -> BS.ByteString -> String -> IO HttpResponse
fragment env s path =
  httpRequest (envPort env) "GET" ("/app/fragments/" <> path) [("X-Lockstep-Session", s)] ""

contains :: BS.ByteString -> BS.ByteString -> Bool
contains needle haystack =
  not (BS.null (snd (BS.breakSubstring needle haystack)))

has :: BS.ByteString -> T.Text -> Assertion
has page needle =
  assertBool ("the page lacks " <> show needle) (contains (TE.encodeUtf8 needle) page)

decisionPath :: ProjectView -> String
decisionPath view =
  "/app/api/projects/" <> T.unpack (projectId view) <> "/plan/decisions"

postDecision :: Env -> [HTTPTypes.Header] -> ProjectView -> Int -> T.Text -> T.Text -> IO HttpResponse
postDecision env headers view number digest decision =
  httpRequest
    (envPort env)
    "POST"
    (decisionPath view)
    (("Content-Type", "application/x-www-form-urlencoded") : headers)
    (HTTPTypes.renderSimpleQuery False [("revision", BS8.pack (show number)), ("digest", TE.encodeUtf8 digest), ("decision", TE.encodeUtf8 decision)])

countOf :: Env -> String -> IO Int
countOf env query = do
  rows <- queryInts (envAdmin env) (envDb env) ("SELECT count(*)::integer AS v FROM " <> query)
  case rows of
    [n] -> pure n
    _ -> assertFailure "count"

tests :: TestTree
tests =
  testGroup
    "C-P6.4 the plan page over the real service (HTTP, PostgreSQL)"
    [ testCase "the plan page shows each revision with its state, digest, units, typed edges and uncertainties, and a digest-bound approval form; the project page links to it (M5, M8)" $
        withEnv $ \env -> do
          (view, r) <- proposed env
          s <- session env
          resp <- fragment env s ("project-plan/" <> T.unpack (projectId view))
          responseStatus resp @?= 200
          let
            page = responseBody resp
          traverse_
            (has page)
            [ "Caesura"
            , "Revision 1"
            , "proposed by a person"
            , revisionDigest r
            , "Parse poems into syllables"
            , "Read a poem from a file"
            , "needs it working"
            , "The PRD does not say which meters count."
            , "1 open question"
            , T.pack (decisionPath view)
            , "name=\"digest\" value=\"" <> revisionDigest r <> "\""
            , "Approve this plan"
            ]
          projectPage <- fragment env s ("project/" <> T.unpack (projectId view))
          has (responseBody projectPage) ("/app/projects/" <> projectId view <> "/plan")
    , testCase "deciding needs the session and this origin; a wrong digest is explained and changes nothing; the right one approves (M5)" $
        withEnv $ \env -> do
          (view, r) <- proposed env
          s <- session env
          noSession <- postDecision env [("Origin", origin env)] view 1 (revisionDigest r) "approve"
          responseStatus noSession @?= 401
          foreign' <- postDecision env [("Origin", "http://127.0.0.1:1"), ("X-Lockstep-Session", s)] view 1 (revisionDigest r) "approve"
          responseStatus foreign' @?= 403
          stale <- postDecision env [("Origin", origin env), ("X-Lockstep-Session", s)] view 1 (sha "another plan") "approve"
          responseStatus stale @?= 200
          assertBool ("a stale decision was not explained: " <> show (responseBody stale)) (contains "changed since this page was shown" (responseBody stale))
          countOf env "lockstep_plan_decisions" >>= (@?= 0)
          approved <- postDecision env [("Origin", origin env), ("X-Lockstep-Session", s)] view 1 (revisionDigest r) "approve"
          responseStatus approved @?= 200
          responseHeader "X-Lockstep-Path" approved @?= Just (TE.encodeUtf8 ("/app/projects/" <> projectId view <> "/plan"))
          assertBool "the page does not say the plan is approved" (contains "approved" (responseBody approved))
          pv <- accepted (ready (planView (envRuntime env) (projectId view)))
          fmap revisionNumber (planViewEffective pv) @?= Just 1
          countOf env "lockstep_project_tasks" >>= (@?= 2)
          -- A decided revision offers no more form, and a replayed decision changes nothing.
          again <- postDecision env [("Origin", origin env), ("X-Lockstep-Session", s)] view 1 (revisionDigest r) "reject"
          responseStatus again @?= 200
          assertBool "a replayed decision was not explained" (contains "already decided" (responseBody again))
          countOf env "lockstep_plan_decisions" >>= (@?= 1)
    ]
