{-# LANGUAGE OverloadedStrings #-}

module Lockstep.Web.CommandCenterViewTest
  ( tests
  ) where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTP
import Network.Wai qualified as Wai
import Network.Wai.Test qualified as WaiTest
import Numeric (readHex)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)
import Prelude (Double, (**))

import Lockstep.Foundation.Config (BindHost (Loopback), ServeConfig (..), defaultPort)
import Lockstep.Foundation.EvidenceModel
  ( Disposition (..)
  , EvidenceItem (..)
  , RowInput (..)
  , TestedRevision (..)
  )
import Lockstep.Web.Application (application)
import Lockstep.Web.CommandCenter (MatrixRow (..), renderMatrix)
import Lockstep.Web.Static (StaticAsset (..), lookupAsset)

tests :: TestTree
tests =
  testGroup
    "Command center view"
    [ testGroup
        "matrix rendering"
        [ testCase "a non-PASSED effective row never renders the PASSED label or class" $
            traverse_ assertNotGreen [Failed, Inconclusive "evidence changed", Blocked "decision", NotRun "queued"]
        , testCase "a PASSED row renders the PASSED label and class" $ do
            let
              html = renderMatrix [MatrixRow sampleRow Passed]
            assertContains "PASSED" html
            assertContains "ls-passed" html
        , testCase "a claimed PASSED shown as INCONCLUSIVE is rendered by its effective disposition" $ do
            let
              html = renderMatrix [MatrixRow sampleRow (Inconclusive "evidence changed")]
            assertContains "INCONCLUSIVE (evidence changed)" html
            assertLacks "ls-passed" html
            assertLacks ">PASSED<" html
        , testCase "every row shows criterion, method, expected, actual, label and locator" $ do
            let
              html = renderMatrix [MatrixRow sampleRow Passed]
            traverse_
              (`assertContains` html)
              ["AC-JOB-7@v1", "background dispatcher", "succeeded, 2/2 steps", "observed 2/2", "db:lockstep_jobs/7"]
        , testCase "a missing actual observation renders as an em dash" $ do
            let
              html = renderMatrix [MatrixRow sampleRow {rowActual = Nothing, rowClaimed = NotRun "queued"} (NotRun "queued")]
            assertContains (TE.encodeUtf8 "\8212") html
            assertContains "NOT_RUN (queued)" html
        , testCase "the matrix is a table with column headers" $ do
            let
              html = renderMatrix [MatrixRow sampleRow Passed]
            assertContains "<table" html
            assertContains "<th scope=\"col\">" html
            traverse_ (`assertContains` html) ["Criterion", "Method", "Expected", "Actual", "Disposition", "Evidence"]
        , testCase "rows carry machine-readable criterion and disposition attributes" $ do
            let
              html = renderMatrix [MatrixRow sampleRow (NotRun "in progress")]
            assertContains "data-criterion=\"AC-JOB-7@v1\" data-disposition=\"NOT_RUN (in progress)\"" html
        ]
    , testGroup
        "stylesheet (NFR-12)"
        [ testCase "every disposition class is defined" $ do
            css <- stylesheet
            traverse_ (\c -> assertContains ("." <> c) css) dispositionClasses
        , testCase "NOT_RUN has a dashed outline" $ do
            css <- stylesheet
            case ruleBody ".ls-not-run" css of
              Nothing -> assertFailure ".ls-not-run rule missing"
              Just body -> assertContains "dashed" body
        , testCase "each disposition's colors reach 4.5:1 in light and dark themes" $ do
            css <- stylesheet
            let
              (light, dark) = BS.breakSubstring "@media (prefers-color-scheme: dark)" css
            assertBool "dark theme block missing" (not (BS.null dark))
            traverse_ (checkContrast "light" light) dispositionTokens
            traverse_ (checkContrast "dark" dark) dispositionTokens
        , testCase "the passed (green) tokens are used only by the .ls-passed rule" $ do
            css <- stylesheet
            let
              users = [selector | (selector, body) <- rules css, "var(--ls-passed-" `BS.isInfixOf` body]
            assertBool ("passed tokens used by " <> show users) (not (L.null users) && all (BS.isInfixOf ".ls-passed") users)
        ]
    , testCase "GET /operator/center without a session answers 401" $ do
        res <-
          WaiTest.runSession
            ( WaiTest.request
                (WaiTest.setPath Wai.defaultRequest {Wai.requestHeaders = [("Host", "127.0.0.1:8000")], Wai.requestHeaderHost = Just "127.0.0.1:8000"} "/operator/center")
            )
            (application (ServeConfig Loopback defaultPort) (\_ -> pure ()))
        WaiTest.simpleStatus res @?= HTTP.status401
    ]

sampleRow :: RowInput
sampleRow =
  RowInput
    { rowCriterion = "AC-JOB-7@v1"
    , rowStatement = "Job 7 (receipt 9) completes all 2 steps"
    , rowSourceRefs = ["C-P1.5 E4", "receipt 9"]
    , rowRequired = True
    , rowMethod = "background dispatcher (lockstep serve)"
    , rowExpected = "succeeded, 2/2 steps"
    , rowActual = Just "observed 2/2"
    , rowClaimed = Passed
    , rowEvidence = [EvidenceItem "db:lockstep_jobs/7" "abc123" "db-row" "lockstep serve"]
    , rowTestedRevision = Just (TestedRevision "schema 5" False)
    }

assertNotGreen :: Disposition -> Assertion
assertNotGreen effective = do
  let
    html = renderMatrix [MatrixRow sampleRow effective]
  assertLacks "ls-passed" html
  assertLacks "PASSED" html

dispositionClasses :: [BS.ByteString]
dispositionClasses =
  ["ls-passed", "ls-failed", "ls-inconclusive", "ls-blocked", "ls-not-run"]

dispositionTokens :: [BS.ByteString]
dispositionTokens =
  ["passed", "failed", "inconclusive", "blocked", "not-run"]

stylesheet :: IO BS.ByteString
stylesheet =
  maybe (assertFailure "lockstep.css is not served") (pure . assetBody) (lookupAsset "lockstep.css")

-- | Top-level-ish rules as (selector, body); nested @media blocks are flattened by splitting on braces.
rules :: BS.ByteString -> [(BS.ByteString, BS.ByteString)]
rules css =
  let
    go input =
      let
        (selector, rest) = BS8.break (== '{') input
      in
        if BS.null rest
          then []
          else
            let
              (body, after) = BS8.break (== '}') (BS.drop 1 rest)
              cleanSelector = BS8.dropWhile (\c -> Char.isSpace c || c == '}') (lastLine selector)
            in
              (cleanSelector, body) : go (BS.drop 1 after)
    lastLine s =
      case L.reverse (BS8.split '{' s) of
        x : _ -> BS8.strip x
        [] -> s
  in
    go css

ruleBody :: BS.ByteString -> BS.ByteString -> Maybe BS.ByteString
ruleBody selector css =
  snd <$> L.find (\(s, _) -> s == selector) (rules css)

tokenValue :: BS.ByteString -> BS.ByteString -> Maybe (Double, Double, Double)
tokenValue name block =
  let
    (_, rest) = BS.breakSubstring ("--ls-" <> name <> ":") block
    value = BS8.strip (BS8.takeWhile (/= ';') (BS.drop (BS.length name + 6) rest))
  in
    if BS.null rest then Nothing else parseHex value

parseHex :: BS.ByteString -> Maybe (Double, Double, Double)
parseHex value =
  case BS8.unpack value of
    ['#', r1, r2, g1, g2, b1, b2] -> (,,) <$> channel [r1, r2] <*> channel [g1, g2] <*> channel [b1, b2]
    _ -> Nothing
 where
  channel digits =
    case readHex digits of
      [(n, "")] -> Just (fromInteger n / 255)
      _ -> Nothing

luminance :: (Double, Double, Double) -> Double
luminance (r, g, b) =
  let
    lin c = if c <= 0.03928 then c / 12.92 else ((c + 0.055) / 1.055) ** 2.4
  in
    0.2126 * lin r + 0.7152 * lin g + 0.0722 * lin b

checkContrast :: String -> BS.ByteString -> BS.ByteString -> Assertion
checkContrast theme block token =
  case (tokenValue (token <> "-fg") block, tokenValue (token <> "-bg") block) of
    (Just fg, Just bg) ->
      let
        (hi, lo) = (max (luminance fg) (luminance bg), min (luminance fg) (luminance bg))
        ratio = (hi + 0.05) / (lo + 0.05)
      in
        assertBool (theme <> " " <> BS8.unpack token <> " contrast " <> show ratio) (ratio >= 4.5)
    _ -> assertFailure (theme <> ": --ls-" <> BS8.unpack token <> "-fg/-bg not defined as #rrggbb")

assertContains :: BS.ByteString -> BS.ByteString -> Assertion
assertContains needle haystack =
  assertBool ("expected to contain " <> BS8.unpack needle) (needle `BS.isInfixOf` haystack)

assertLacks :: BS.ByteString -> BS.ByteString -> Assertion
assertLacks needle haystack =
  assertBool ("expected not to contain " <> BS8.unpack needle) (not (needle `BS.isInfixOf` haystack))
