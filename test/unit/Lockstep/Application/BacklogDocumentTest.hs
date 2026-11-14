{-# LANGUAGE OverloadedStrings #-}

{- | The canonical backlog document and the read-only Jira adapter (contract
C-P6.1 §1 format, B9, B12): one schema decodes and encodes the document; a key
the format does not define refuses it; the Jira adapter reads only the fields
it names, from a file, offline.
-}
module Lockstep.Application.BacklogDocumentTest
  ( tests
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.BacklogDocument
  ( DocumentError (..)
  , criteriaText
  , decodeBacklogDocument
  , decodeCriteria
  , documentErrorCode
  , encodeBacklogDocument
  )
import Lockstep.Application.BacklogJira (fromJiraSearch)
import Lockstep.Kernel.Backlog
  ( BacklogDocument (..)
  , BacklogItem (..)
  , Criterion (..)
  , SourceIdentity (..)
  , SourceKey
  , SourceLocator
  , SourceProvider (..)
  , SourceRevision
  , mkSourceKey
  , mkSourceLocator
  , mkSourceRevision
  )
import Lockstep.Kernel.Identity (RepositoryId (..), parseUuid)

bytes :: T.Text -> LBS.ByteString
bytes =
  LBS.fromStrict . TE.encodeUtf8

k :: T.Text -> SourceKey
k text =
  case mkSourceKey text of
    Just key -> key
    Nothing -> k "invalid-key-in-test"

rev :: Integer -> SourceRevision
rev n =
  case mkSourceRevision n of
    Just r -> r
    Nothing -> rev 0

locator :: T.Text -> SourceLocator
locator text =
  case mkSourceLocator text of
    Just l -> l
    Nothing -> locator "invalid-locator-in-test"

repositoryUuid :: T.Text
repositoryUuid =
  "3f2504e0-4f89-41d3-9a0c-0305e82c3301"

full :: T.Text
full =
  "{\"format\":\"lockstep-backlog\",\"version\":1,"
    <> "\"source\":{\"provider\":\"canonical\",\"locator\":\"caesura-notes\"},"
    <> "\"revision\":7,"
    <> "\"repository\":\""
    <> repositoryUuid
    <> "\","
    <> "\"items\":["
    <> "{\"key\":\"CAE-1\",\"revision\":3,\"title\":\"Play a sleep track\",\"acceptance\":[{\"text\":\"A track plays\",\"ref\":\"CAE-1 AC1\"},{\"text\":\"It stops\"}],\"blockers\":[]},"
    <> "{\"key\":\"CAE-2\",\"revision\":1,\"title\":\"Fade out\",\"blockers\":[\"CAE-1\"]}"
    <> "]}"

expected :: IO BacklogDocument
expected = do
  repository <- either (const (assertFailure "uuid")) (pure . RepositoryId) (parseUuid repositoryUuid)
  pure
    BacklogDocument
      { documentSource = SourceIdentity ProviderCanonical (locator "caesura-notes")
      , documentRevision = rev 7
      , documentRepository = Just repository
      , documentItems =
          [ BacklogItem (k "CAE-1") (rev 3) "Play a sleep track" [Criterion "A track plays" (Just "CAE-1 AC1"), Criterion "It stops" Nothing] []
          , BacklogItem (k "CAE-2") (rev 1) "Fade out" [] [k "CAE-1"]
          ]
      }

-- | The document with one substring replaced.
variant :: T.Text -> T.Text -> LBS.ByteString
variant from to =
  bytes (T.replace from to full)

refusedAs :: LBS.ByteString -> T.Text -> Assertion
refusedAs input code =
  case decodeBacklogDocument input of
    Left e -> documentErrorCode e @?= code
    Right doc -> assertFailure ("decoded: " <> show doc)

jiraFixture :: IO LBS.ByteString
jiraFixture =
  LBS.readFile "test/fixtures/backlog/jira-search.json"

tests :: TestTree
tests =
  testGroup
    "the canonical backlog document and the Jira adapter (C-P6.1)"
    [ testCase "a full document decodes to exactly its items, in order" $ do
        want <- expected
        decodeBacklogDocument (bytes full) @?= Right want
    , testCase "acceptance, blockers and the repository are optional" $ do
        let
          minimal = "{\"format\":\"lockstep-backlog\",\"version\":1,\"source\":{\"provider\":\"jira\",\"locator\":\"acme\"},\"revision\":0,\"items\":[{\"key\":\"A\",\"revision\":0,\"title\":\"T\"}]}"
        decodeBacklogDocument (bytes minimal)
          @?= Right (BacklogDocument (SourceIdentity ProviderJira (locator "acme")) (rev 0) Nothing [BacklogItem (k "A") (rev 0) "T" [] []])
    , testCase "what encodes decodes back to the same document" $ do
        want <- expected
        decodeBacklogDocument (bytes (encodeBacklogDocument want)) @?= Right want
        let
          bare = want {documentRepository = Nothing, documentItems = []}
        decodeBacklogDocument (bytes (encodeBacklogDocument bare)) @?= Right bare
    , testCase "a key the format does not define refuses the document, wherever it is (B9)" $ do
        refusedAs (variant "\"revision\":7," "\"revision\":7,\"status\":\"ready\",") "unknown-keys"
        refusedAs (variant "\"title\":\"Fade out\"" "\"title\":\"Fade out\",\"priority\":\"high\"") "unknown-keys"
        refusedAs (variant "{\"text\":\"It stops\"}" "{\"text\":\"It stops\",\"approved\":true}") "unknown-keys"
        refusedAs (variant "\"locator\":\"caesura-notes\"" "\"locator\":\"caesura-notes\",\"authorized\":true") "unknown-keys"
        decodeBacklogDocument (variant "\"revision\":7," "\"revision\":7,\"authorized\":true,")
          @?= Left (DocumentUnknownKeys ["authorized"])
    , testCase "another format or version is refused" $ do
        refusedAs (variant "\"lockstep-backlog\"" "\"other-backlog\"") "unsupported-format"
        refusedAs (variant "\"version\":1" "\"version\":2") "unsupported-format"
    , testCase "invalid identities and revisions are refused with their code" $ do
        refusedAs (variant "\"canonical\"" "\"github\"") "invalid-provider"
        refusedAs (variant "\"caesura-notes\"" "\"caesura notes\"") "invalid-locator"
        refusedAs (variant "\"key\":\"CAE-2\"" "\"key\":\"CAE 2\"") "invalid-key"
        refusedAs (variant "[\"CAE-1\"]" "[\"CAE 1\"]") "invalid-key"
        refusedAs (variant "\"revision\":7" "\"revision\":-7") "invalid-revision"
        refusedAs (variant repositoryUuid "not-a-uuid") "invalid-repository"
        refusedAs (variant repositoryUuid (T.toUpper repositoryUuid)) "invalid-repository"
        refusedAs (bytes "{\"format\":") "malformed"
        refusedAs (variant "\"title\":\"Fade out\"," "") "malformed"
    , testCase "stored criteria read back exactly" $ do
        let
          criteria = [Criterion "A track plays" (Just "CAE-1 AC1"), Criterion "It stops" Nothing, Criterion "Quotes \" and \\ survive" (Just "§2")]
        decodeCriteria (criteriaText criteria) @?= Right criteria
        decodeCriteria (criteriaText []) @?= Right []
        assertBool "garbage is not criteria" (isLeft (decodeCriteria "not json"))
    , testCase "the Jira adapter reads key, summary, update time, description and inward Blocks links only (B12)" $ do
        input <- jiraFixture
        doc <- either (\e -> assertFailure ("refused: " <> T.unpack e)) pure (fromJiraSearch (locator "https://acme.atlassian.net/projects/CAE") input)
        documentSource doc @?= SourceIdentity ProviderJira (locator "https://acme.atlassian.net/projects/CAE")
        documentRepository doc @?= Nothing
        documentItems doc
          @?= [ BacklogItem (k "CAE-1") (rev 1794302100000) "Play a sleep track" [Criterion "A track plays until the timer ends." (Just "CAE-1 description")] []
              , BacklogItem (k "CAE-2") (rev 1794394800000) "Fade out at the end" [] [k "CAE-1"]
              , BacklogItem (k "CAE-3") (rev 1794211200000) "Timer settings" [Criterion "Choose 15, 30 or 60 minutes." (Just "CAE-3 description")] []
              ]
        documentRevision doc @?= rev 1794394800000
    , testCase "the Jira adapter refuses what it cannot read" $ do
        let
          jira = locator "acme"
        assertBool "not JSON" (isLeft (fromJiraSearch jira "<html>"))
        assertBool "no issues" (isLeft (fromJiraSearch jira "{\"total\":0}"))
        assertBool "a key with a space" (isLeft (fromJiraSearch jira "{\"issues\":[{\"key\":\"CAE 1\",\"fields\":{\"summary\":\"S\",\"updated\":\"2026-11-10T09:15:00.000+0000\"}}]}"))
        assertBool "no update time" (isLeft (fromJiraSearch jira "{\"issues\":[{\"key\":\"CAE-1\",\"fields\":{\"summary\":\"S\"}}]}"))
        assertBool "an unreadable update time" (isLeft (fromJiraSearch jira "{\"issues\":[{\"key\":\"CAE-1\",\"fields\":{\"summary\":\"S\",\"updated\":\"yesterday\"}}]}"))
        fromJiraSearch jira "{\"issues\":[]}" @?= Right (BacklogDocument (SourceIdentity ProviderJira jira) (rev 0) Nothing [])
    ]
