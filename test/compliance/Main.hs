module Main
  ( main
  ) where

import Flipstone.Prelude
import Test.Tasty (defaultMain, testGroup)

import Lockstep.Compliance.PersistenceTest qualified as PersistenceTest

main :: IO ()
main =
  defaultMain $
    testGroup
      "lockstep-compliance (stack-compliance pass)"
      [ PersistenceTest.tests
      ]
