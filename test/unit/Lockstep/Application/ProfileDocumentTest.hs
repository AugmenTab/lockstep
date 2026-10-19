{-# LANGUAGE OverloadedStrings #-}

-- | C-P2.3 F12 and §4: the strict Profile document format.
module Lockstep.Application.ProfileDocumentTest
  ( tests
  ) where

import Data.ByteString.Lazy qualified as LBS
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.ProfileDocument (decodeProfileDocument)
import Lockstep.Kernel.Profile (RawGate (..), RawProfile (..), RawSpecialization (..))

tests :: TestTree
tests =
  testGroup
    "Profile documents (C-P2.3 F12, §4)"
    [ testCase "the §4 example decodes" $
        decodeProfileDocument example
          @?= Right
            RawProfile
              { rawProfileId = "team-default"
              , rawProfileVersion = 1
              , rawAllowsNonBehavioural = Just True
              , rawInvariantExceptions = []
              , rawGates =
                  [ RawGate
                      { rawGateId = "impact"
                      , rawGateStage = "before-execution"
                      , rawGateArtifacts = ["impact-assessment"]
                      , rawGateKinds = Just ["engineering"]
                      , rawGateClasses = Just ["bug-fix"]
                      , rawGatePathClasses = Just ["source"]
                      , rawGateVerifiers = ["human-inspection"]
                      , rawGateApproval = "human"
                      , rawGateExceptionPath = False
                      }
                  ]
              , rawSpecializations =
                  [ RawSpecialization (Just "engineering") Nothing "eng"
                  , RawSpecialization Nothing (Just "security") "sec"
                  ]
              }
    , testCase "absent optional keys take their defaults" $
        decodeProfileDocument
          "{\"id\":\"p\",\"version\":2,\"gates\":[{\"id\":\"g\",\"stage\":\"before-acceptance\",\"artifacts\":[\"review-record\"],\"verifiers\":[\"independent-review\"],\"approval\":\"human\"}]}"
          @?= Right
            RawProfile
              { rawProfileId = "p"
              , rawProfileVersion = 2
              , rawAllowsNonBehavioural = Nothing
              , rawInvariantExceptions = []
              , rawGates =
                  [ RawGate
                      { rawGateId = "g"
                      , rawGateStage = "before-acceptance"
                      , rawGateArtifacts = ["review-record"]
                      , rawGateKinds = Nothing
                      , rawGateClasses = Nothing
                      , rawGatePathClasses = Nothing
                      , rawGateVerifiers = ["independent-review"]
                      , rawGateApproval = "human"
                      , rawGateExceptionPath = False
                      }
                  ]
              , rawSpecializations = []
              }
    , testCase "invariant exceptions are carried to the Kernel, which refuses them" $
        fmap rawInvariantExceptions (decodeProfileDocument "{\"id\":\"p\",\"version\":1,\"gates\":[],\"invariant_exceptions\":[\"independent-review\"]}")
          @?= Right ["independent-review"]
    , testCase "an unknown top-level key is refused" $
        refused "{\"id\":\"p\",\"version\":1,\"gates\":[],\"priority\":3}"
    , testCase "an unknown gate key is refused" $
        refused "{\"id\":\"p\",\"version\":1,\"gates\":[{\"id\":\"g\",\"stage\":\"before-acceptance\",\"artifacts\":[\"review-record\"],\"verifiers\":[\"independent-review\"],\"approval\":\"human\",\"script\":\"rm -rf /\"}]}"
    , testCase "an unknown specialization key is refused" $
        refused "{\"id\":\"p\",\"version\":1,\"gates\":[],\"specializations\":[{\"when_kind\":\"engineering\",\"profile\":\"e\",\"weight\":1}]}"
    , testCase "missing required keys are refused" $ do
        refused "{\"version\":1,\"gates\":[]}"
        refused "{\"id\":\"p\",\"gates\":[]}"
        refused "{\"id\":\"p\",\"version\":1}"
        refused "{\"id\":\"p\",\"version\":1,\"gates\":[{\"id\":\"g\",\"artifacts\":[],\"verifiers\":[],\"approval\":\"human\"}]}"
    , testCase "wrong types are refused" $ do
        refused "{\"id\":\"p\",\"version\":\"1\",\"gates\":[]}"
        refused "{\"id\":\"p\",\"version\":1,\"gates\":{}}"
        refused "{\"id\":\"p\",\"version\":1,\"gates\":[],\"allows_non_behavioural\":\"yes\"}"
        refused "[]"
    , testCase "invalid JSON is refused" $ do
        refused "{\"id\":\"p\","
        refused ""
    ]

example :: LBS.ByteString
example =
  "{\n\
  \  \"id\": \"team-default\",\n\
  \  \"version\": 1,\n\
  \  \"allows_non_behavioural\": true,\n\
  \  \"invariant_exceptions\": [],\n\
  \  \"gates\": [\n\
  \    { \"id\": \"impact\", \"stage\": \"before-execution\", \"artifacts\": [\"impact-assessment\"],\n\
  \      \"kinds\": [\"engineering\"], \"classes\": [\"bug-fix\"], \"path_classes\": [\"source\"],\n\
  \      \"verifiers\": [\"human-inspection\"], \"approval\": \"human\", \"exception_path\": false }\n\
  \  ],\n\
  \  \"specializations\": [ { \"when_kind\": \"engineering\", \"profile\": \"eng\" }, { \"when_class\": \"security\", \"profile\": \"sec\" } ]\n\
  \}\n"

refused :: LBS.ByteString -> Assertion
refused document =
  case decodeProfileDocument document of
    Left _ -> pure ()
    Right decoded -> assertFailure ("decoded: " <> show decoded)
