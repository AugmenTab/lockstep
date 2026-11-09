module Main
  ( main
  ) where

import Flipstone.Prelude
import Test.Tasty (defaultMain, testGroup)

import Lockstep.Compliance.DefectsTest qualified as DefectsTest
import Lockstep.Compliance.FailureTest qualified as FailureTest
import Lockstep.Compliance.IdentityTest qualified as IdentityTest
import Lockstep.Compliance.JsonTest qualified as JsonTest
import Lockstep.Compliance.NegativeTypesTest qualified as NegativeTypesTest
import Lockstep.Compliance.PersistenceTest qualified as PersistenceTest
import Lockstep.Compliance.StateTest qualified as StateTest

main :: IO ()
main =
  defaultMain $
    testGroup
      "lockstep-compliance (stack-compliance and type-discipline passes)"
      [ JsonTest.tests
      , PersistenceTest.tests
      , DefectsTest.tests
      , IdentityTest.tests
      , NegativeTypesTest.tests
      , StateTest.tests
      , FailureTest.tests
      ]
