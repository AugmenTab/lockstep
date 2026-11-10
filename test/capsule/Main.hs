{- | Phase 5 checks of the Capsule Runtime's typed vocabulary (contract C-P5.1
V1-V4), apart from the frozen suites. Each enumeration round-trips through its
one text; and every word is the runtime script's own word, read from
@scripts/capsule-runtime@ (run from the checkout's root).
-}
module Main
  ( main
  ) where

import Data.Foldable (for_)
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TIO
import Flipstone.Prelude
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))
import Text.Show (show)

import Lockstep.Effects.Provider.Claude (ProviderConfig (..), capsuleRoleInstructions, claudeCapsuleArgv, parseCapsuleLine)
import Lockstep.Effects.Roles (View (..), Workspace (..))
import Lockstep.Kernel.Capsule
  ( CapsuleOperation (..)
  , CapsuleProfile
  , CapsuleRefusal
  , HostOutcome
  , LifecycleOperation (..)
  , ReplyResult (..)
  , Resources (..)
  , RuntimeReply (..)
  , VmStatus
  , capsuleNameText
  , capsuleOperationText
  , capsuleProfileText
  , capsuleRefusalText
  , hostOutcomeText
  , lifecycleOperationText
  , operationMutates
  , parseCapsuleName
  , parseCapsuleOperation
  , parseCapsuleProfile
  , parseCapsuleRefusal
  , parseHostOutcome
  , parseRuntimeReply
  , parseVmStatus
  , profileResources
  , roleOperations
  , vmName
  , vmStatusText
  )
import Lockstep.Kernel.Roles (Role (..), roleName)

main :: IO ()
main = do
  script <- TIO.readFile "scripts/capsule-runtime"
  defaultMain (tests script)

every :: (Bounded a, Enum a) => [a]
every =
  [minBound .. maxBound]

tests :: T.Text -> TestTree
tests script =
  testGroup
    "lockstep-capsule"
    [ testGroup
        "V1 one text each, parsed back"
        [ testCase "operations" $ fmap (parseCapsuleOperation . capsuleOperationText) every @?= fmap Just (every :: [CapsuleOperation])
        , testCase "profiles" $ fmap (parseCapsuleProfile . capsuleProfileText) every @?= fmap Just (every :: [CapsuleProfile])
        , testCase "VM status" $ fmap (parseVmStatus . vmStatusText) every @?= fmap Just (every :: [VmStatus])
        , testCase "host outcomes" $ fmap (parseHostOutcome . hostOutcomeText) every @?= fmap Just (every :: [HostOutcome])
        , testCase "refusals" $ fmap (parseCapsuleRefusal . capsuleRefusalText) every @?= fmap Just (every :: [CapsuleRefusal])
        , testCase "an unknown word parses to nothing" $ parseHostOutcome (T.pack "succeeded") @?= Nothing
        ]
    , testGroup
        "V2 names"
        [ testCase "a valid name" $ fmap capsuleNameText (parseCapsuleName (T.pack "brigid-dev")) @?= Just (T.pack "brigid-dev")
        , testCase "the VM name is derived" $ fmap vmName (parseCapsuleName (T.pack "brigid-dev")) @?= Just (T.pack "lockstep-brigid-dev")
        , testCase "path-like, shell-like, upper-case, short, long and dash-ended names are refused" $
            fmap (parseCapsuleName . T.pack) ["../etc", "a;rm", "Brigid", "abc", L.replicate 33 'a', "brigid-", "1abc", "", "a b c d"]
              @?= L.replicate 9 Nothing
        ]
    , testGroup
        "V3 role authority"
        [ testCase "only the Implementer may mutate" $
            fmap (L.any operationMutates . roleOperations) [Planner, Challenger, Implementer, Reviewer]
              @?= [False, False, True, False]
        , testCase "the read-only roles run no command (review finding 1)" $
            fmap (L.elem OpExec . roleOperations) [Planner, Challenger, Implementer, Reviewer]
              @?= [False, False, True, False]
        , testCase "the runtime's binding grants each role exactly these operations" $
            for_ [Planner, Challenger, Implementer, Reviewer] $ \role ->
              assertBool (T.unpack (roleName role)) (bindingLine role `L.elem` T.lines script)
        ]
    , testGroup
        "V4 the runtime's own words"
        [ testCase "every refusal is one the runtime gives" $
            for_ (every :: [CapsuleRefusal]) $ \r ->
              assertBool (T.unpack (capsuleRefusalText r)) (said (capsuleRefusalText r))
        , testCase "every host outcome is one the runtime writes" $
            for_ (every :: [HostOutcome]) $ \o ->
              assertBool (T.unpack (hostOutcomeText o)) (said (hostOutcomeText o))
        , testCase "every lifecycle operation is in the runtime's dispatch" $
            for_ (every :: [LifecycleOperation]) $ \o ->
              assertBool (T.unpack (lifecycleOperationText o)) (L.any (dispatches (lifecycleOperationText o)) (T.lines script))
        , testCase "the profiles have the runtime's numbers" $
            for_ (every :: [CapsuleProfile]) $ \p ->
              assertBool (T.unpack (capsuleProfileText p)) (profileLine p `L.elem` fmap T.strip (T.lines script))
        , testCase "a reply is read" $
            parseRuntimeReply (T.pack "capsule-runtime 1 bind refused reason=writer-already-active")
              @?= Just (RuntimeReply Bind ReplyRefused [(T.pack "reason", T.pack "writer-already-active")])
        , testCase "a reply of another version, or with a malformed field, is not" $
            fmap (parseRuntimeReply . T.pack) ["capsule-runtime 2 bind ok", "capsule-runtime 1 bind ok =x", "capsule-runtime 1 frobnicate ok"]
              @?= [Nothing, Nothing, Nothing]
        ]
    , testGroup
        "C-P5.5 the service in capsule mode"
        [ testCase "the helper's capsule line is read" $
            fmap capsuleNameText (parseCapsuleLine (TE.encodeUtf8 (T.pack "lockstep-capsule 1 brigid-dev\n"))) @?= Right (T.pack "brigid-dev")
        , testCase "a malformed capsule line is refused" $
            fmap
              (either Just (const Nothing) . parseCapsuleLine . TE.encodeUtf8 . T.pack)
              ["lockstep-capsule 2 brigid-dev\n", "lockstep-capsule 1 ../x\n", "lockstep-capsule 1 brigid-dev", "lockstep-capsule 1 a b\n"]
              @?= L.replicate 4 (Just (T.pack "capsule-file-invalid"))
        , testCase "the capsule argv turns every built-in tool off" $
            L.isInfixOf [T.pack "--tools", T.empty] capsuleArgv @?= True
        , testCase "and names no built-in tool and no MCP configuration of its own (the helper adds the bridge)" $
            L.filter (`L.elem` fmap T.pack ["Read Edit Bash", "--mcp-config", "--settings", "--add-dir"]) capsuleArgv @?= []
        , testCase "only the Implementer is told it may run commands" $
            fmap (T.isInfixOf (T.pack "mcp__capsule__exec runs") . (`capsuleRoleInstructions` capsuleView)) [Planner, Challenger, Implementer, Reviewer]
              @?= [False, False, True, False]
        , testCase "every role still gets its answer documents" $
            for_ [Planner, Challenger, Implementer, Reviewer] $ \role ->
              assertBool (T.unpack (roleName role)) (T.isInfixOf (T.pack "\"kind\"") (capsuleRoleInstructions role capsuleView))
        ]
    ]
 where
  capsuleView =
    View (T.pack "/work/tree") (T.pack "/input") (T.pack "/output")
  capsuleArgv =
    claudeCapsuleArgv
      (ProviderConfig (T.pack "claude-sonnet-5-5") (T.pack "medium"))
      (Workspace "/w/tree" "/w/input" "/w/output" capsuleView (T.pack "0123456789abcdef0123456789abcdef"))
  -- A word the runtime says in code (a refusal, outcome or detail), not merely in a comment.
  said word =
    L.any
      ( \l ->
          not (T.isPrefixOf (T.pack "#") (T.strip l))
            && L.any (\boundary -> T.isInfixOf (T.pack boundary <> word) l) [" ", "=", "\""]
      )
      (T.lines script)
  dispatches word line =
    let
      stripped = T.strip line
    in
      T.isPrefixOf (word <> T.pack ")") stripped
        || T.isInfixOf (T.pack "| " <> word <> T.pack " ") stripped
        || T.isInfixOf (T.pack "| " <> word <> T.pack ")") stripped
        || T.isInfixOf (T.pack " " <> word <> T.pack " |") stripped
        || T.isPrefixOf (word <> T.pack " |") stripped
  bindingLine role =
    T.pack "    "
      <> bindingRoles role
      <> T.pack ") ops=\""
      <> T.unwords (fmap capsuleOperationText (roleOperations role))
      <> T.pack "\" ;;"
  bindingRoles role =
    case role of
      Implementer -> T.pack "implementer"
      _ -> T.pack "planner | challenger | reviewer"
  profileLine p =
    let
      r = profileResources p
    in
      capsuleProfileText p
        <> T.pack ") echo \""
        <> T.unwords (fmap (T.pack . show) [resourceCpus r, resourceMemoryGib r, resourceDiskGib r, resourceCommandSeconds r])
        <> T.pack "\" ;;"
