{-# LANGUAGE OverloadedStrings #-}

-- | The finite runner's pure rules (contract C-P4.2 R1).
module Lockstep.Kernel.RunnerTest
  ( tests
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))
import Text.Show (show)

import Lockstep.Kernel.Runner
  ( Limits (..)
  , RoleKind (..)
  , RunOutcome (..)
  , RunSpec (..)
  , Stream (..)
  , checkSpec
  , outcomeName
  , outcomeSucceeded
  , roleKindName
  , roleLimits
  , runnerEnvironment
  )

tests :: TestTree
tests =
  testGroup
    "C-P4.2 runner rules"
    [ testCase "a well-formed run is accepted as it is" accepted
    , testCase "each malformed part is refused with its code, in R1's order" refusals
    , testCase "the boundaries of the limits are inclusive" limitBounds
    , testCase "DG-17 D-17.7: 20 minutes for the Implementer, 10 for every other run, 8 MiB and 2 MiB" limitsTable
    , testCase "the environment is exactly the fixed five variables" environment
    , testCase "only exit 0 succeeds; every other ending has its name" outcomes
    ]

good :: RunSpec
good =
  RunSpec
    { runArgv = ["/bin/sh", "-c", "true"]
    , runDirectory = "/work/tree"
    , runEnvironment = [("PATH", "/usr/bin"), ("_X1", "")]
    , runLimits = Limits 1000 0 67108864
    }

code :: RunSpec -> T.Text
code spec =
  fromLeft "accepted" (checkSpec spec)

accepted :: IO ()
accepted = do
  checkSpec good @?= Right good
  code good {runArgv = ["python3", "-m", "unittest"]} @?= "accepted"
  code good {runArgv = ["/bin/echo", T.replicate 32768 "a"]} @?= "accepted"
  code good {runArgv = "/bin/echo" : L.replicate 1023 "x"} @?= "accepted"
  code good {runArgv = ["/bin/echo", "line\nbreak\ttab"]} @?= "accepted"
  code good {runEnvironment = []} @?= "accepted"

refusals :: IO ()
refusals = do
  code good {runArgv = []} @?= "argv-empty"
  code good {runArgv = [""]} @?= "argv-invalid"
  code good {runArgv = "/bin/echo" : L.replicate 1024 "x"} @?= "argv-invalid"
  code good {runArgv = ["/bin/echo", T.replicate 32769 "a"]} @?= "argv-invalid"
  code good {runArgv = ["/bin/echo", "a\NULb"]} @?= "argv-invalid"
  code good {runArgv = "/bin/echo" : L.replicate 9 (T.replicate 30000 "a")} @?= "argv-invalid"
  code good {runArgv = ["bin/sh"]} @?= "executable-not-absolute"
  code good {runArgv = ["./run"]} @?= "executable-not-absolute"
  code good {runDirectory = "work"} @?= "directory-invalid"
  code good {runDirectory = ""} @?= "directory-invalid"
  code good {runDirectory = "/work/../etc"} @?= "directory-invalid"
  code good {runDirectory = "/work/\NUL"} @?= "directory-invalid"
  code good {runEnvironment = [("1A", "x")]} @?= "environment-invalid"
  code good {runEnvironment = [("A-B", "x")]} @?= "environment-invalid"
  code good {runEnvironment = [("", "x")]} @?= "environment-invalid"
  code good {runEnvironment = [(T.replicate 129 "A", "x")]} @?= "environment-invalid"
  code good {runEnvironment = [("A", "1"), ("A", "2")]} @?= "environment-invalid"
  code good {runEnvironment = [("A", "x\NULy")]} @?= "environment-invalid"
  code good {runEnvironment = [("A", T.replicate 32769 "x")]} @?= "environment-invalid"
  code good {runEnvironment = [(T.pack ("V" <> show n), "x") | n <- [1 .. 65 :: Int]]} @?= "environment-invalid"
  code good {runLimits = Limits 0 0 0} @?= "limits-invalid"
  code good {runLimits = Limits 3600001 0 0} @?= "limits-invalid"
  code good {runLimits = Limits 1 (-1) 0} @?= "limits-invalid"
  code good {runLimits = Limits 1 0 67108865} @?= "limits-invalid"
  -- the order: the first failing rule names the refusal
  code good {runArgv = ["bin/sh"], runDirectory = "rel", runLimits = Limits 0 0 0} @?= "executable-not-absolute"
  code good {runDirectory = "rel", runEnvironment = [("1", "")]} @?= "directory-invalid"
  code good {runEnvironment = [("1", "")], runLimits = Limits 0 0 0} @?= "environment-invalid"

limitBounds :: IO ()
limitBounds = do
  code good {runLimits = Limits 1 0 0} @?= "accepted"
  code good {runLimits = Limits 3600000 67108864 67108864} @?= "accepted"
  code good {runEnvironment = [(T.pack ("V" <> show n), "x") | n <- [1 .. 64 :: Int]]} @?= "accepted"
  code good {runEnvironment = [(T.replicate 128 "A", "x")]} @?= "accepted"

limitsTable :: IO ()
limitsTable = do
  roleLimits RoleImplementer @?= Limits 1200000 8388608 2097152
  fmap roleLimits [RolePlanner, RoleChallenger, RoleReviewer, RoleCommand]
    @?= L.replicate 4 (Limits 600000 8388608 2097152)
  fmap roleKindName [RolePlanner, RoleChallenger, RoleImplementer, RoleReviewer, RoleCommand]
    @?= ["planner", "challenger", "implementer", "reviewer", "command"]

environment :: IO ()
environment =
  runnerEnvironment "/tmp/home"
    @?= [ ("PATH", "/usr/local/bin:/usr/bin:/bin")
        , ("HOME", "/tmp/home")
        , ("LANG", "C.UTF-8")
        , ("LC_ALL", "C.UTF-8")
        , ("TZ", "UTC")
        ]

outcomes :: IO ()
outcomes = do
  let
    all' = [Exited 0, Exited 1, Exited (-9), TimedOut, OutputLimit Stdout, OutputLimit Stderr, OutputHeld Stdout, Cancelled, LaunchFailed "x"]
  fmap outcomeSucceeded all' @?= [True, False, False, False, False, False, False, False, False]
  fmap outcomeName all'
    @?= ["exited", "exited", "exited", "timed-out", "output-limit", "output-limit", "output-held", "cancelled", "launch-failed"]
