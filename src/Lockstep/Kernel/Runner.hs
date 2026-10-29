{- | The finite runner's rules (contract C-P4.2 R1; DG-17 D-17.7, D-17.9). A
run is a direct argument vector, never a shell string, in an absolute
directory, with exactly the environment it is given and finite limits on
wall-clock time and captured output. These checks are pure; the runners
('Lockstep.Effects.Process', the host helper's container runner) apply them
before anything starts.
-}
module Lockstep.Kernel.Runner
  ( RunSpec (..)
  , Limits (..)
  , checkSpec
  , RoleKind (..)
  , roleKindName
  , roleLimits
  , runnerEnvironment
  , Stream (..)
  , streamName
  , RunOutcome (..)
  , outcomeName
  , outcomeSucceeded
  ) where

import Data.Char qualified as Char
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show)

data Limits
  = Limits
  { limitWallMillis :: Int
  , limitStdoutBytes :: Int
  , limitStderrBytes :: Int
  }
  deriving (Eq, Show)

data RunSpec
  = RunSpec
  { runArgv :: [T.Text]
  , runDirectory :: T.Text
  , runEnvironment :: [(T.Text, T.Text)]
  , runLimits :: Limits
  }
  deriving (Eq, Show)

{- | R1, in this order: @argv-empty@; @argv-invalid@ (an empty program, more
than 1024 entries, an entry over 32768 characters or a NUL character, more
than 262144 characters in all); @executable-not-absolute@ (the program
contains @/@ but does not start with it; a bare name is looked up in the
run's own PATH); @directory-invalid@ (not absolute, a NUL character or a
@..@ segment); @environment-invalid@ (more than 64 entries, a name not
matching @[A-Za-z_][A-Za-z0-9_]{0,127}@, a repeated name, a value over 32768
characters or with a NUL character); @limits-invalid@ (wall clock outside
1–3600000 ms, a stream limit outside 0–67108864 bytes).
-}
checkSpec :: RunSpec -> Either T.Text RunSpec
checkSpec spec
  | L.null argv = Left (T.pack "argv-empty")
  | not argvValid = Left (T.pack "argv-invalid")
  | relativeWithSlash = Left (T.pack "executable-not-absolute")
  | not directoryValid = Left (T.pack "directory-invalid")
  | not environmentValid = Left (T.pack "environment-invalid")
  | not limitsValid = Left (T.pack "limits-invalid")
  | otherwise = Right spec
 where
  argv = runArgv spec
  program = case argv of
    p : _ -> p
    [] -> T.empty
  argvValid =
    not (T.null program)
      && L.length argv <= 1024
      && L.all (\a -> T.length a <= 32768 && not (hasNul a)) argv
      && L.sum (fmap T.length argv) <= 262144
  relativeWithSlash =
    T.any (== '/') program && not (T.isPrefixOf (T.pack "/") program)
  directory = runDirectory spec
  directoryValid =
    T.isPrefixOf (T.pack "/") directory
      && not (hasNul directory)
      && L.notElem (T.pack "..") (T.splitOn (T.pack "/") directory)
  environment = runEnvironment spec
  names = fmap fst environment
  environmentValid =
    L.length environment <= 64
      && L.all validName names
      && L.nub names == names
      && L.all (\(_, v) -> T.length v <= 32768 && not (hasNul v)) environment
  limits = runLimits spec
  limitsValid =
    within 1 3600000 (limitWallMillis limits)
      && within 0 67108864 (limitStdoutBytes limits)
      && within 0 67108864 (limitStderrBytes limits)

hasNul :: T.Text -> Bool
hasNul =
  T.any (== '\NUL')

within :: Int -> Int -> Int -> Bool
within low high n =
  n >= low && n <= high

validName :: T.Text -> Bool
validName name =
  case T.uncons name of
    Just (c, rest) ->
      (Char.isAsciiUpper c || Char.isAsciiLower c || c == '_')
        && T.length rest <= 127
        && T.all (\x -> Char.isAsciiUpper x || Char.isAsciiLower x || Char.isDigit x || x == '_') rest
    Nothing -> False

-- | Who a run is for (DG-17 D-17.7).
data RoleKind
  = RolePlanner
  | RoleChallenger
  | RoleImplementer
  | RoleReviewer
  | RoleCommand
  deriving (Eq, Show)

roleKindName :: RoleKind -> T.Text
roleKindName role =
  T.pack $
    case role of
      RolePlanner -> "planner"
      RoleChallenger -> "challenger"
      RoleImplementer -> "implementer"
      RoleReviewer -> "reviewer"
      RoleCommand -> "command"

{- | D-17.7: the Implementer 20 minutes, every other role and every command 10
minutes; 8 MiB of standard output and 2 MiB of standard error.
-}
roleLimits :: RoleKind -> Limits
roleLimits role =
  Limits
    { limitWallMillis = if role == RoleImplementer then 1200000 else 600000
    , limitStdoutBytes = 8388608
    , limitStderrBytes = 2097152
    }

{- | The whole environment of a run (R1): a fixed search path, the given home
directory, a UTF-8 locale and UTC. Nothing else from Lockstep's own
environment reaches a run.
-}
runnerEnvironment :: T.Text -> [(T.Text, T.Text)]
runnerEnvironment home =
  [ (T.pack "PATH", T.pack "/usr/local/bin:/usr/bin:/bin")
  , (T.pack "HOME", home)
  , (T.pack "LANG", T.pack "C.UTF-8")
  , (T.pack "LC_ALL", T.pack "C.UTF-8")
  , (T.pack "TZ", T.pack "UTC")
  ]

data Stream
  = Stdout
  | Stderr
  deriving (Eq, Show)

streamName :: Stream -> T.Text
streamName stream =
  T.pack $
    case stream of
      Stdout -> "stdout"
      Stderr -> "stderr"

{- | How a run ended. Only @Exited 0@ succeeded; a timeout, too much output,
a cancellation or a failed launch is never a success, whatever was printed.
-}
data RunOutcome
  = Exited Int
  | TimedOut
  | OutputLimit Stream
  | OutputHeld Stream
  | Cancelled
  | LaunchFailed T.Text
  | ProviderStopped T.Text
  -- ^ C-P4.L L3: a live run the helper's egress boundary stopped or could not
  -- account for (the budget, a limit, a refused request, unknown usage, the proxy
  -- gone); what it printed is not trusted
  deriving (Eq, Show)

{- | @output-held@: the program ended but something outside its process group
kept a stream open past the grace period; what it printed is not trusted.
-}
outcomeName :: RunOutcome -> T.Text
outcomeName outcome =
  T.pack $
    case outcome of
      Exited _ -> "exited"
      TimedOut -> "timed-out"
      OutputLimit _ -> "output-limit"
      OutputHeld _ -> "output-held"
      Cancelled -> "cancelled"
      LaunchFailed _ -> "launch-failed"
      ProviderStopped _ -> "provider-stopped"

outcomeSucceeded :: RunOutcome -> Bool
outcomeSucceeded outcome =
  outcome == Exited 0
