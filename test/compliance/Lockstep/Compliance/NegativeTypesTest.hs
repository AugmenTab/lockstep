{-# OPTIONS_GHC -fdefer-type-errors -Wno-deferred-type-errors #-}

{- | Type-discipline Increment B5: identities of different kinds cannot be
interchanged. Each expression below is ill-typed on purpose; the module is
compiled with deferred type errors and @should-not-typecheck@ checks that
evaluating each one meets a type error, so a change that made them typecheck
fails this suite. Each forces the mistyped value (through 'identityText'), so
the deferred error is reached.
-}
module Lockstep.Compliance.NegativeTypesTest
  ( tests
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Orville.PostgreSQL qualified as O
import Test.ShouldNotTypecheck (shouldNotTypecheck)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Lockstep.Kernel.Identity (ProjectId (..), TaskId (..), WorkOrderId (..), identityText, uuidFromWords)
import Lockstep.Persistence.Projects (projectTable)

-- | Accepts only a project's identity.
asProject :: ProjectId -> ProjectId
asProject =
  id

-- | The key a table's entity operations accept.
keyFor :: O.TableDefinition (O.HasKey key) write row -> key -> key
keyFor _ key =
  key

workOrder :: WorkOrderId
workOrder =
  WorkOrderId (uuidFromWords 1 2)

task :: TaskId
task =
  TaskId (uuidFromWords 3 4)

tests :: TestTree
tests =
  testGroup
    "type-discipline B5: identities of different kinds do not typecheck in each other's place"
    [ testCase "a WorkOrderId where a ProjectId is required" $
        shouldNotTypecheck (identityText (asProject workOrder))
    , testCase "a TaskId as the key of the project table (what O.findEntity projectTable would take)" $
        shouldNotTypecheck (identityText (keyFor projectTable task))
    , testCase "control: the project's own identity is accepted" $
        identityText (keyFor projectTable (ProjectId (uuidFromWords 5 6))) @?= T.pack "00000000-0000-0005-0000-000000000006"
    ]
