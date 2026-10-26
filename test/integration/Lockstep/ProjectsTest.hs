{-# LANGUAGE OverloadedStrings #-}

{- | Guided project setup against real PostgreSQL and real Git (contract C-P3.5
J1–J4, J7, J8): every Git fixture lives in a fresh temporary directory, and the
application operations run in this process, which is the filesystem view the
service observes in.
-}
module Lockstep.ProjectsTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.List qualified as L
import Data.Maybe (isJust)
import Data.Text qualified as T
import Data.Traversable (for)
import Flipstone.Prelude
import System.Directory (createDirectory, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, listDirectory, pathIsSymbolicLink)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (FilePath)
import System.IO.Temp (withSystemTempDirectory)
import System.Posix.Files (createSymbolicLink)
import System.Process qualified as Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Command (IdempotencyKey, mkIdempotencyKey)
import Lockstep.Application.Database (DatabaseRuntime, runMigrations)
import Lockstep.Application.Projects
  ( NewProject (..)
  , ProjectFolders (..)
  , ProjectView (..)
  , connectProject
  , createProject
  , listProjects
  , offeredFolders
  , parseProjectFolders
  )
import Lockstep.Kernel.Project (FolderChoice (..), SetupState (..))
import Lockstep.Persistence.Migrations (migrations)
import Lockstep.Support.Postgres (AdminSettings, databaseConfigFor, queryInts, requireAdmin, withFreshDatabase, withRuntime)

data Scenario
  = Scenario
  { scAdmin :: AdminSettings
  , scDb :: T.Text
  , scRuntime :: DatabaseRuntime
  , scDir :: FilePath
  , scRoot :: FilePath
  }

-- | A migrated database, an empty projects folder and a scratch folder beside it.
withScenario :: (Scenario -> IO a) -> IO a
withScenario action = do
  admin <- requireAdmin
  withFreshDatabase admin $ \db ->
    withSystemTempDirectory "lockstep-p35" $ \tmp -> do
      config <- databaseConfigFor admin db
      withRuntime config $ \runtime -> do
        migrated <- runMigrations migrations runtime
        assertBool "migrations failed" (either (const False) (const True) migrated)
        createDirectory (tmp <> "/projects")
        createDirectory (tmp <> "/w")
        action (Scenario admin db runtime (tmp <> "/w") (tmp <> "/projects"))

folders :: Scenario -> [FilePath] -> ProjectFolders
folders sc =
  ProjectFolders (Just (scRoot sc))

-- | A valid creation key (16 to 64 of @A-Za-z0-9_-@) made from a short label.
key :: T.Text -> IO IdempotencyKey
key text =
  either (const (assertFailure ("idempotency key " <> T.unpack text))) pure (mkIdempotencyKey ("test-creation-" <> text))

create :: Scenario -> ProjectFolders -> T.Text -> T.Text -> FolderChoice -> IO (Either T.Text ProjectView)
create sc fs k name choice = do
  ik <- key k
  result <- createProject (scRuntime sc) fs (NewProject ik name "What it should achieve." choice)
  either (\r -> assertFailure ("not ready: " <> show r)) pure result

created :: Scenario -> ProjectFolders -> T.Text -> T.Text -> FolderChoice -> IO ProjectView
created sc fs k name choice =
  create sc fs k name choice >>= either (\c -> assertFailure ("refused: " <> T.unpack c)) pure

connect :: Scenario -> ProjectFolders -> ProjectView -> Int64 -> FolderChoice -> IO (Either T.Text ProjectView)
connect sc fs view revision choice = do
  result <- connectProject (scRuntime sc) fs (projectId view) revision choice
  either (\r -> assertFailure ("not ready: " <> show r)) pure result

count :: Scenario -> String -> IO Int
count sc table = do
  rows <- queryInts (scAdmin sc) (scDb sc) ("SELECT count(*)::integer AS v FROM " <> table)
  case rows of
    [n] -> pure n
    _ -> assertFailure ("count " <> table)

gitIn :: FilePath -> [String] -> IO (ExitCode, String)
gitIn dir args = do
  base <- getEnvironment
  let
    identity = ["-c", "user.name=Lockstep Test", "-c", "user.email=test@example.invalid", "-c", "init.defaultBranch=main", "-c", "protocol.file.allow=always"]
    env = ("GIT_CONFIG_NOSYSTEM", "1") : L.filter ((/= "GIT_CONFIG_NOSYSTEM") . fst) base
  result <-
    timeout 30000000 $
      Process.readCreateProcessWithExitCode ((Process.proc "git" (identity <> args)) {Process.cwd = Just dir, Process.env = Just env}) ""
  case result of
    Nothing -> assertFailure ("git " <> show args <> " did not finish within 30 s")
    Just (code, out, err) -> pure (code, out <> err)

git :: FilePath -> [String] -> Assertion
git dir args = do
  (code, out) <- gitIn dir args
  assertBool ("git " <> show args <> " failed: " <> out) (code == ExitSuccess)

-- | A repository with two commits at @dir/name@.
newRepo :: FilePath -> String -> IO FilePath
newRepo dir name = do
  git dir ["init", "-q", name]
  git (dir <> "/" <> name) ["commit", "-q", "--allow-empty", "-m", "first"]
  git (dir <> "/" <> name) ["commit", "-q", "--allow-empty", "-m", "second"]
  pure (dir <> "/" <> name)

-- | Every file under a folder (symbolic links not followed) with its bytes, sorted.
snapshot :: FilePath -> IO [(FilePath, BS.ByteString)]
snapshot dir = do
  names <- L.sort <$> listDirectory dir
  fmap L.concat . for names $ \name -> do
    let
      path = dir <> "/" <> name
    link <- pathIsSymbolicLink path
    isDir <- doesDirectoryExist path
    if link
      then pure [(path, "<link>")]
      else
        if isDir
          then snapshot path
          else (\b -> [(path, b)]) <$> BS.readFile path

isConnected :: ProjectView -> Assertion
isConnected view = do
  (projectSetup view, projectRefusal view) @?= (Connected, Nothing)
  assertBool "no folder" (isJust (projectFolder view))
  assertBool "no Engineer" (isJust (projectEngineer view))

failedWith :: T.Text -> ProjectView -> Assertion
failedWith code view = do
  (projectSetup view, projectRefusal view) @?= (SetupFailed, Just code)
  projectFolder view @?= Nothing

tests :: TestTree
tests =
  testGroup
    "guided project setup (C-P3.5; real Git + PostgreSQL)"
    [ testCase "the folder list is the projects folder, then the added folders" $ do
        parseProjectFolders "" @?= ProjectFolders Nothing []
        parseProjectFolders "/home/a/lockstep-projects" @?= ProjectFolders (Just "/home/a/lockstep-projects") []
        parseProjectFolders "/home/a/lockstep-projects:/home/a/code/site:/home/a/My Notes" @?= ProjectFolders (Just "/home/a/lockstep-projects") ["/home/a/code/site", "/home/a/My Notes"]
        parseProjectFolders ":/home/a/code/site" @?= ProjectFolders Nothing ["/home/a/code/site"]
        parseProjectFolders "relative:/home/a/b" @?= ProjectFolders Nothing []
        parseProjectFolders "/home/a/p:relative" @?= ProjectFolders Nothing []
    , testCase "a new project gets a folder of its own with no history and no remote, owned by its own Engineer" $
        withScenario $ \sc -> do
          view <- created sc (folders sc []) "k-1" "My Website" NewFolder
          isConnected view
          projectName view @?= "My Website"
          projectOutcome view @?= "What it should achieve."
          projectFolder view @?= Just (T.pack (scRoot sc <> "/my-website"))
          projectEngineer view @?= Just "p-my-website"
          projectRevision view @?= 2
          dotGit <- doesDirectoryExist (scRoot sc <> "/my-website/.git")
          assertBool "no .git folder" dotGit
          (headCode, headRef) <- gitIn (scRoot sc <> "/my-website") ["symbolic-ref", "HEAD"]
          (headCode, headRef) @?= (ExitSuccess, "refs/heads/main\n")
          (_, history) <- gitIn (scRoot sc <> "/my-website") ["rev-list", "--all"]
          history @?= ""
          (_, remotes) <- gitIn (scRoot sc <> "/my-website") ["remote"]
          remotes @?= ""
          count sc "lockstep_projects" >>= (@?= 1)
          count sc "lockstep_repositories" >>= (@?= 1)
          listed <- listProjects (scRuntime sc)
          fmap (fmap projectId) listed @?= Right [projectId view]
    , testCase "taken names are refused; a taken folder name gets the next free one and the folder there is left alone" $
        withScenario $ \sc -> do
          _ <- created sc (folders sc []) "k-1" "My Website" NewFolder
          create sc (folders sc []) "k-2" "My Website" NewFolder >>= (@?= Left "project-name-taken") . fmap projectId
          create sc (folders sc []) "k-3" "  my website " DecideLater >>= (@?= Left "project-name-taken") . fmap projectId
          second <- created sc (folders sc []) "k-4" "My-Website" NewFolder
          projectFolder second @?= Just (T.pack (scRoot sc <> "/my-website-2"))
          projectEngineer second @?= Just "p-my-website-2"
          createDirectory (scRoot sc <> "/recipes")
          BS.writeFile (scRoot sc <> "/recipes/notes.txt") "mine"
          recipes <- created sc (folders sc []) "k-5" "Recipes" NewFolder
          projectFolder recipes @?= Just (T.pack (scRoot sc <> "/recipes-2"))
          untouched <- snapshot (scRoot sc <> "/recipes")
          untouched @?= [(scRoot sc <> "/recipes/notes.txt", "mine")]
          count sc "lockstep_projects" >>= (@?= 3)
    , testCase "names and outcomes are checked first; a refused one creates nothing" $
        withScenario $ \sc -> do
          create sc (folders sc []) "k-1" "   " NewFolder >>= (@?= Left "name-empty") . fmap projectId
          create sc (folders sc []) "k-2" (T.replicate 81 "n") NewFolder >>= (@?= Left "name-too-long") . fmap projectId
          ik <- key "k-3"
          long <- createProject (scRuntime sc) (folders sc []) (NewProject ik "Fine" (T.replicate 2001 "o") NewFolder)
          fmap (fmap projectId) long @?= Right (Left "outcome-too-long")
          count sc "lockstep_projects" >>= (@?= 0)
          count sc "lockstep_engineers" >>= (@?= 0)
          listDirectory (scRoot sc) >>= (@?= [])
    , testCase "a repeated creation key returns the first project and creates nothing" $
        withScenario $ \sc -> do
          first <- created sc (folders sc []) "k-same" "Garden" NewFolder
          again <- created sc (folders sc []) "k-same" "Garden" NewFolder
          projectId again @?= projectId first
          other <- created sc (folders sc []) "k-same" "Something else" DecideLater
          projectId other @?= projectId first
          count sc "lockstep_projects" >>= (@?= 1)
          count sc "lockstep_repositories" >>= (@?= 1)
          listDirectory (scRoot sc) >>= (@?= ["garden"])
    , testCase "an existing folder is connected as it is, and nothing in it changes" $
        withScenario $ \sc -> do
          createDirectory (scDir sc <> "/code")
          site <- newRepo (scDir sc <> "/code") "site"
          git site ["remote", "add", "origin", "git@github.com:Owner/Site.git"]
          let
            fs = folders sc [site]
          offeredFolders (scRuntime sc) fs >>= (@?= [site])
          before <- snapshot site
          view <- created sc fs "k-1" "Site" (ExistingFolder (T.pack site))
          isConnected view
          projectFolder view @?= Just (T.pack site)
          projectEngineer view @?= Just "p-site"
          after <- snapshot site
          assertBool "the folder changed" (after == before)
          offeredFolders (scRuntime sc) fs >>= (@?= [])
    , testCase "only offered folders: projects-folder children and added folders that are project folders, no links" $
        withScenario $ \sc -> do
          a <- newRepo (scRoot sc) "alpha"
          _ <- newRepo (scDir sc) "outside"
          createDirectory (scRoot sc <> "/plain")
          createDirectoryIfMissing True (scRoot sc <> "/nested/deeper")
          _ <- newRepo (scRoot sc <> "/nested/deeper") "deep"
          createSymbolicLink a (scRoot sc <> "/alias")
          git a ["worktree", "add", "-q", scRoot sc <> "/wt", "-b", "feature"]
          added <- newRepo (scDir sc) "added"
          let
            fs = folders sc [added]
          offeredFolders (scRuntime sc) fs >>= (@?= L.sort [a, added])
          traverse_
            ( \(n, p) -> do
                view <- created sc fs (T.pack ("k-" <> show n)) (T.pack ("Project " <> show n)) (ExistingFolder (T.pack p))
                failedWith "folder-not-offered" view
            )
            $ L.zip
              [1 :: Int ..]
              [ scDir sc <> "/outside"
              , scRoot sc <> "/plain"
              , scRoot sc <> "/nested/deeper/deep"
              , scRoot sc <> "/alias"
              , scRoot sc <> "/wt"
              , scRoot sc <> "/missing"
              , scRoot sc <> "/alpha/../alpha"
              ]
          count sc "lockstep_repositories" >>= (@?= 0)
          count sc "lockstep_engineers" >>= (@?= 0)
    , testCase "copies of a connected folder are refused; a fork with its own origin is connected" $
        withScenario $ \sc -> do
          orig <- newRepo (scRoot sc) "orig"
          git orig ["remote", "add", "origin", "git@github.com:Owner/Repo.git"]
          _ <- created sc (folders sc []) "k-orig" "Original" (ExistingFolder (T.pack orig))
          git (scRoot sc) ["clone", "-q", orig, "copy"]
          copy <- created sc (folders sc []) "k-copy" "Copy" (ExistingFolder (T.pack (scRoot sc <> "/copy")))
          failedWith "remote-is-owned-repository" copy
          git (scRoot sc) ["clone", "-q", orig, "same"]
          git (scRoot sc <> "/same") ["remote", "set-url", "origin", "https://github.com/owner/repo"]
          same <- created sc (folders sc []) "k-same" "Same" (ExistingFolder (T.pack (scRoot sc <> "/same")))
          failedWith "authoritative-remote-owned" same
          git (scRoot sc) ["clone", "-q", orig, "fork"]
          git (scRoot sc <> "/fork") ["remote", "set-url", "origin", "git@github.com:someone/repo-fork.git"]
          git (scRoot sc <> "/fork") ["remote", "add", "upstream", "git@github.com:Owner/Repo.git"]
          fork <- created sc (folders sc []) "k-fork" "Fork" (ExistingFolder (T.pack (scRoot sc <> "/fork")))
          isConnected fork
          count sc "lockstep_repositories" >>= (@?= 2)
    , testCase "a refused folder leaves the project organized-but-failed; Try again needs the current revision" $
        withScenario $ \sc -> do
          orig <- newRepo (scDir sc) "orig"
          git (scRoot sc) ["clone", "-q", "--depth", "1", "file://" <> orig, "shallow"]
          view <- created sc (folders sc []) "k-1" "Shallow" (ExistingFolder (T.pack (scRoot sc <> "/shallow")))
          failedWith "shallow-repository" view
          projectRevision view @?= 2
          count sc "lockstep_projects" >>= (@?= 1)
          count sc "lockstep_repositories" >>= (@?= 0)
          connect sc (folders sc []) view 1 NewFolder >>= (@?= Left "stale-revision") . fmap projectId
          count sc "lockstep_repositories" >>= (@?= 0)
          fixed <- connect sc (folders sc []) view 2 NewFolder >>= either (assertFailure . T.unpack) pure
          isConnected fixed
          projectRevision fixed @?= 3
          projectFolder fixed @?= Just (T.pack (scRoot sc <> "/shallow-2"))
          connect sc (folders sc []) fixed 3 DecideLater >>= (@?= Left "already-connected") . fmap projectId
          gone <- connectProject (scRuntime sc) (folders sc []) "00000000-0000-4000-8000-000000000000" 1 NewFolder
          fmap (fmap projectId) gone @?= Right (Left "unknown-project")
    , testCase "decide later: organized, no folder and no Engineer, then connected" $
        withScenario $ \sc -> do
          later <- created sc (folders sc []) "k-1" "Notes" DecideLater
          (projectSetup later, projectFolder later, projectEngineer later, projectRevision later) @?= (Organized, Nothing, Nothing, 1)
          count sc "lockstep_engineers" >>= (@?= 0)
          listDirectory (scRoot sc) >>= (@?= [])
          now <- connect sc (folders sc []) later 1 NewFolder >>= either (assertFailure . T.unpack) pure
          isConnected now
          projectRevision now @?= 2
    , testCase "without a projects folder, a new folder is refused plainly and nothing is made" $
        withScenario $ \sc -> do
          view <- created sc (ProjectFolders Nothing []) "k-1" "Homeless" NewFolder
          failedWith "no-projects-folder" view
          count sc "lockstep_repositories" >>= (@?= 0)
    , testCase "a project's text is stored exactly" $
        withScenario $ \sc -> do
          ik <- key "k-1"
          result <- createProject (scRuntime sc) (folders sc []) (NewProject ik "<b>Bold</b> & \"quoted\"" "Line one\nLine two" DecideLater)
          case result of
            Right (Right view) -> do
              projectName view @?= "<b>Bold</b> & \"quoted\""
              projectOutcome view @?= "Line one\nLine two"
            other -> assertFailure ("unexpected: " <> show (fmap (fmap projectId) other))
          stored <- doesFileExist (scRoot sc <> "/b-bold-b-quoted")
          assertBool "a folder was made for decide-later" (not stored)
    ]
