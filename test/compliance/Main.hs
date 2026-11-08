module Main
  ( main
  ) where

import Flipstone.Prelude
import Test.Tasty (defaultMain, testGroup)

import Lockstep.Compliance.DefectsTest qualified as DefectsTest
import Lockstep.Compliance.JsonTest qualified as JsonTest
import Lockstep.Compliance.PersistenceTest qualified as PersistenceTest

main :: IO ()
main =
  defaultMain $
    testGroup
      "lockstep-compliance (stack-compliance and type-discipline passes)"
      [ JsonTest.tests
      , PersistenceTest.tests
      , DefectsTest.tests
      ]
