{-# LANGUAGE OverloadedStrings #-}

-- | The @lockstep-plan@ version 1 wire format (contract C-P6.4 M1).
module Lockstep.Application.PlanDocumentTest
  ( tests
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Lockstep.Application.PlanDocument
  ( PlanDocumentError (..)
  , decodePlanDocument
  , decodePlanDocumentText
  , encodePlanDocument
  , planDocumentErrorCode
  )
import Lockstep.Kernel.Plan (EdgeKind (..), Envelope (..), PlanCriterion (..), PlanDocument (..), PlanEdge (..), PlanMode (..), PlanSource (..), PlanUnit (..), Uncertainty (..))
import Lockstep.Kernel.PlanTest (key, realisticPlan)

bytes :: T.Text -> LBS.ByteString
bytes =
  LBS.fromStrict . TE.encodeUtf8

-- | A one-unit plan in the exact wire spelling.
minimal :: T.Text
minimal =
  T.concat
    [ "{\"format\":\"lockstep-plan\",\"version\":1,\"title\":\"Tiny\",\"mode\":\"brownfield\","
    , "\"sources\":[{\"name\":\"prd\",\"sha256\":\"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855\"}],"
    , "\"envelope\":{\"external_effects\":false,\"max_units\":3},"
    , "\"units\":[{\"key\":\"fix-menu\",\"title\":\"Fix the menu\",\"phase\":\"P1\",\"subphase\":\"P1.1\",\"work_kind\":\"bug-fix\","
    , "\"profile\":\"lockstep-bug-fix\",\"priority\":\"high\",\"effect\":\"local-only\",\"risk\":\"low\",\"provisional\":false,"
    , "\"outputs\":[\"src/menu.js\"],\"acceptance\":[{\"text\":\"The menu opens.\",\"cites\":[\"prd\"]}],"
    , "\"negative\":[\"A closed menu stays closed.\"],\"checks\":[\"npm test\"],\"prerequisites\":[],\"resources\":[]}],"
    , "\"edges\":[],"
    , "\"uncertainties\":[{\"text\":\"Which menu?\",\"cites\":[]}]}"
    ]

replace :: T.Text -> T.Text -> T.Text
replace old new =
  T.replace old new minimal

code :: Either PlanDocumentError PlanDocument -> T.Text
code =
  either planDocumentErrorCode (const "decoded")

tests :: TestTree
tests =
  testGroup
    "C-P6.4 the lockstep-plan document"
    [ testCase "the exact wire spelling decodes" $ do
        let
          decoded = decodePlanDocument (bytes minimal)
        fmap planTitle decoded @?= Right "Tiny"
        fmap planMode decoded @?= Right Brownfield
        fmap planEnvelope decoded @?= Right (Envelope False 3 Nothing)
        fmap (fmap unitKey . planUnits) decoded @?= Right [key "fix-menu"]
        fmap (fmap unitAcceptance . planUnits) decoded @?= Right [[PlanCriterion "The menu opens." ["prd"]]]
        fmap planUncertainties decoded @?= Right [Uncertainty "Which menu?" []]
        fmap planSources decoded @?= Right [PlanSource "prd" "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"]
    , testCase "a realistic plan survives encoding and decoding unchanged" $
        decodePlanDocumentText (encodePlanDocument realisticPlan) @?= Right realisticPlan
    , testCase "edges are spelled dependent, prerequisite, kind" $
        fmap planEdges (decodePlanDocument (bytes (replace "\"edges\":[]" "\"edges\":[{\"dependent\":\"fix-menu\",\"prerequisite\":\"fix-menu\",\"kind\":\"human-acceptance\"}]")))
          @?= Right [PlanEdge (key "fix-menu") (key "fix-menu") HumanAcceptance]
    , testCase "an unknown key at any level is refused, naming it" $ do
        decodePlanDocument (bytes (replace "\"title\":\"Tiny\"" "\"title\":\"Tiny\",\"approved\":true")) @?= Left (PlanUnknownKeys ["approved"])
        decodePlanDocument (bytes (replace "\"risk\":\"low\"" "\"risk\":\"low\",\"skip_review\":true")) @?= Left (PlanUnknownKeys ["skip_review"])
        decodePlanDocument (bytes (replace "\"max_units\":3" "\"max_units\":3,\"sudo\":true")) @?= Left (PlanUnknownKeys ["sudo"])
        decodePlanDocument (bytes (replace "\"cites\":[\"prd\"]" "\"cites\":[\"prd\"],\"weight\":2")) @?= Left (PlanUnknownKeys ["weight"])
    , testCase "the format and version are checked" $ do
        code (decodePlanDocument (bytes (replace "lockstep-plan" "lockstep-backlog"))) @?= "unsupported-format"
        code (decodePlanDocument (bytes (replace "\"version\":1" "\"version\":2"))) @?= "unsupported-format"
    , testCase "values outside the vocabularies are refused" $ do
        code (decodePlanDocument (bytes (replace "\"key\":\"fix-menu\"" "\"key\":\"Fix Menu\""))) @?= "invalid-unit-key"
        code (decodePlanDocument (bytes (replace "brownfield" "bluefield"))) @?= "invalid-value"
        code (decodePlanDocument (bytes (replace "local-only" "anywhere"))) @?= "invalid-value"
        code (decodePlanDocument (bytes (replace "\"risk\":\"low\"" "\"risk\":\"none\""))) @?= "invalid-value"
        code (decodePlanDocument (bytes (replace "\"priority\":\"high\"" "\"priority\":\"urgent\""))) @?= "invalid-value"
        code (decodePlanDocument (bytes (replace "\"edges\":[]" "\"edges\":[{\"dependent\":\"fix-menu\",\"prerequisite\":\"fix-menu\",\"kind\":\"soft\"}]"))) @?= "invalid-value"
    , testCase "malformed JSON is malformed" $
        code (decodePlanDocument "{\"format\":") @?= "malformed"
    , testCase "a work kind is carried as written, for validation to judge" $
        fmap (fmap unitWorkKind . planUnits) (decodePlanDocument (bytes (replace "bug-fix" "magic"))) @?= Right ["magic"]
    ]
