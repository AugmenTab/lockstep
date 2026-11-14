{-# LANGUAGE OverloadedStrings #-}

{- | The pure backlog import decision (contract C-P6.1 B2, B4, B6, B7, B8 and
the decision rendering): what an import does, given what was imported before.
-}
module Lockstep.Kernel.BacklogTest
  ( tests
  ) where

import Data.List qualified as L
import Data.Maybe (isJust, isNothing)
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Application.Profiles (sha256Hasher)
import Lockstep.Kernel.Backlog
  ( BacklogDocument (..)
  , BacklogItem (..)
  , Criterion (..)
  , DocumentRefusal (..)
  , ImportDecision (..)
  , ItemOutcome (..)
  , ItemRefusal (..)
  , LocalCondition (..)
  , PriorImport (..)
  , SourceIdentity (..)
  , SourceKey
  , SourceProvider (..)
  , SourceRevision
  , StoredItem (..)
  , acceptanceText
  , decideImport
  , documentRefusalCode
  , itemContentText
  , itemRefusalCode
  , mkSourceKey
  , mkSourceLocator
  , mkSourceRevision
  , parseSourceProvider
  , renderImportDecision
  , sourceProviderCode
  )
import Lockstep.Kernel.Profile (Hasher (..))
import Lockstep.Kernel.Task (TaskRuleError (..))

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

source :: SourceIdentity
source =
  case mkSourceLocator "caesura-notes" of
    Just locator -> SourceIdentity ProviderCanonical locator
    Nothing -> source

item :: T.Text -> Integer -> [T.Text] -> BacklogItem
item key r blockers =
  BacklogItem
    { itemKey = k key
    , itemRevision = rev r
    , itemTitle = "Item " <> key
    , itemCriteria = [Criterion ("It works for " <> key) (Just (key <> " AC"))]
    , itemBlockers = fmap k blockers
    }

document :: Integer -> [BacklogItem] -> BacklogDocument
document r items =
  BacklogDocument
    { documentSource = source
    , documentRevision = rev r
    , documentRepository = Nothing
    , documentItems = items
    }

digestOf :: BacklogItem -> StoredItem
digestOf i =
  case sha256Hasher of
    Hasher f -> StoredItem (itemKey i) (itemRevision i) (f (itemContentText i)) (itemBlockers i) LocalUntouched

-- | What a previous import of these items left, all untouched.
priorOf :: Integer -> [BacklogItem] -> PriorImport
priorOf r items =
  PriorImport (rev r) (fmap digestOf items)

decided :: Maybe PriorImport -> BacklogDocument -> IO ImportDecision
decided prior doc =
  case decideImport sha256Hasher prior doc of
    Right d -> pure d
    Left refusal -> assertFailure ("document refused: " <> show refusal)

outcomes :: Maybe PriorImport -> BacklogDocument -> IO [ItemOutcome]
outcomes prior doc =
  fmap snd . decisionItems <$> decided prior doc

outcomeOf :: Maybe PriorImport -> BacklogDocument -> T.Text -> IO ItemOutcome
outcomeOf prior doc key = do
  d <- decided prior doc
  maybe (assertFailure ("no outcome for " <> T.unpack key)) pure (L.lookup (k key) (decisionItems d))

refusedWith :: Maybe PriorImport -> BacklogDocument -> T.Text -> ItemRefusal -> Assertion
refusedWith prior doc key expected =
  outcomeOf prior doc key >>= (@?= ItemRefused expected)

tests :: TestTree
tests =
  testGroup
    "backlog import decision (C-P6.1)"
    [ testGroup
        "source identities (B2)"
        [ testCase "providers have stable codes and parse back" $ do
            fmap sourceProviderCode [minBound .. maxBound] @?= ["canonical", "jira", "shortcut"]
            fmap (parseSourceProvider . sourceProviderCode) [minBound .. maxBound] @?= fmap Just [minBound .. maxBound]
            parseSourceProvider "Jira" @?= Nothing
        , testCase "a locator is 1-200 characters with no space or control character" $ do
            assertBool "a URL locator" (isJust (mkSourceLocator "https://acme.atlassian.net/projects/CAE"))
            assertBool "empty" (isNothing (mkSourceLocator ""))
            assertBool "a space" (isNothing (mkSourceLocator "acme jira"))
            assertBool "a newline" (isNothing (mkSourceLocator "acme\njira"))
            assertBool "200 characters" (isJust (mkSourceLocator (T.replicate 200 "a")))
            assertBool "201 characters" (isNothing (mkSourceLocator (T.replicate 201 "a")))
        , testCase "a key is 1-100 characters of A-Z a-z 0-9 . _ : / # -" $ do
            assertBool "CAE-12" (isJust (mkSourceKey "CAE-12"))
            assertBool "punctuation" (isJust (mkSourceKey "a.b_c:d/e#f-9"))
            assertBool "empty" (isNothing (mkSourceKey ""))
            assertBool "a space" (isNothing (mkSourceKey "CAE 12"))
            assertBool "a quote" (isNothing (mkSourceKey "CAE\"12"))
            assertBool "non-ASCII" (isNothing (mkSourceKey "CAÉ-12"))
            assertBool "100 characters" (isJust (mkSourceKey (T.replicate 100 "a")))
            assertBool "101 characters" (isNothing (mkSourceKey (T.replicate 101 "a")))
        , testCase "a revision is a non-negative number" $ do
            assertBool "zero" (isJust (mkSourceRevision 0))
            assertBool "negative" (isNothing (mkSourceRevision (-1)))
            assertBool "beyond 64 bits" (isNothing (mkSourceRevision 9223372036854775808))
        ]
    , testGroup
        "canonical content (B4, B8)"
        [ testCase "acceptance is one criterion a line, with its reference" $
            acceptanceText [Criterion "Plays the track" (Just "CAE-1 §2"), Criterion "Stops at the end" Nothing]
              @?= "- Plays the track (CAE-1 §2)\n- Stops at the end"
        , testCase "no criteria is empty acceptance" $
            acceptanceText [] @?= ""
        , testCase "the content does not depend on the order of blockers, and changes with what the item says" $ do
            let
              base = item "A" 1 ["B", "C"]
            itemContentText base @?= itemContentText base {itemBlockers = fmap k ["C", "B"]}
            itemContentText base @?= itemContentText base {itemRevision = rev 9}
            assertBool "title" (itemContentText base /= itemContentText base {itemTitle = "Other"})
            assertBool "criteria" (itemContentText base /= itemContentText base {itemCriteria = []})
            assertBool "criterion reference" (itemContentText base /= itemContentText base {itemCriteria = [Criterion "It works for A" Nothing]})
            assertBool "blockers" (itemContentText base /= itemContentText base {itemBlockers = [k "B"]})
            assertBool "not empty" (not (T.null (itemContentText base)))
        ]
    , testGroup
        "a first import (B1, B7)"
        [ testCase "every valid item is created, in document order, and the decision renders exactly" $ do
            let
              doc = document 7 [item "CAE-2" 1 ["CAE-1"], item "CAE-1" 1 []]
            d <- decided Nothing doc
            decisionItems d @?= [(k "CAE-2", ItemCreated), (k "CAE-1", ItemCreated)]
            decisionAbsent d @?= []
            renderImportDecision d
              @?= T.unlines
                [ "lockstep-backlog-import 1"
                , "source canonical caesura-notes revision 7"
                , "item CAE-2 created"
                , "item CAE-1 created"
                ]
        , testCase "a blocker that is in neither the document nor an earlier import is dangling, and the item is not imported" $ do
            refusedWith Nothing (document 1 [item "A" 1 ["Z"]]) "A" (DanglingBlocker (k "Z"))
            itemRefusalCode (DanglingBlocker (k "Z")) @?= "dangling-blocker"
        , testCase "an item blocked by a refused item is refused too, transitively" $ do
            let
              doc = document 1 [item "C" 1 ["B"], item "B" 1 ["A"], item "A" 1 ["Z"], item "D" 1 []]
            outcomeOf Nothing doc "A" >>= (@?= ItemRefused (DanglingBlocker (k "Z")))
            outcomeOf Nothing doc "B" >>= (@?= ItemRefused (BlockerRefused (k "A")))
            outcomeOf Nothing doc "C" >>= (@?= ItemRefused (BlockerRefused (k "B")))
            outcomeOf Nothing doc "D" >>= (@?= ItemCreated)
            itemRefusalCode (BlockerRefused (k "A")) @?= "blocker-refused"
        , testCase "items on a blocker cycle are refused; an item blocked by one of them is refused; others are created" $ do
            let
              doc = document 1 [item "A" 1 ["B"], item "B" 1 ["A"], item "C" 1 ["A"], item "D" 1 []]
            outcomeOf Nothing doc "A" >>= (@?= ItemRefused BlockerCycle)
            outcomeOf Nothing doc "B" >>= (@?= ItemRefused BlockerCycle)
            outcomeOf Nothing doc "C" >>= (@?= ItemRefused (BlockerRefused (k "A")))
            outcomeOf Nothing doc "D" >>= (@?= ItemCreated)
            itemRefusalCode BlockerCycle @?= "blocker-cycle"
        , testCase "an item blocking itself, or with more than 20 blockers, is refused" $ do
            refusedWith Nothing (document 1 [item "A" 1 ["A"]]) "A" BlockerSelf
            let
              many = fmap (\n -> "B" <> T.pack (show n)) [1 .. 21 :: Int]
              doc = document 1 (item "A" 1 many : fmap (\b -> item b 1 []) many)
            refusedWith Nothing doc "A" TooManyBlockers
            fmap itemRefusalCode [BlockerSelf, TooManyBlockers] @?= ["blocker-self", "too-many-blockers"]
        , testCase "an invalid title, criterion or acceptance refuses only that item" $ do
            let
              blank = (item "A" 1 []) {itemTitle = "   "}
              newline = (item "B" 1 []) {itemCriteria = [Criterion "two\nlines" Nothing]}
              controlRef = (item "E" 1 []) {itemCriteria = [Criterion "fine" (Just "bad\tref")]}
              long = (item "C" 1 []) {itemCriteria = fmap (\n -> Criterion (T.replicate 99 "x" <> T.pack (show n)) Nothing) [1 .. 40 :: Int]}
              doc = document 1 [blank, newline, long, controlRef, item "D" 1 []]
            refusedWith Nothing doc "A" (TitleInvalid TitleEmpty)
            refusedWith Nothing doc "B" CriterionInvalid
            refusedWith Nothing doc "C" (AcceptanceInvalid AcceptanceTooLong)
            refusedWith Nothing doc "E" CriterionInvalid
            outcomeOf Nothing doc "D" >>= (@?= ItemCreated)
            fmap itemRefusalCode [TitleInvalid TitleEmpty, CriterionInvalid, AcceptanceInvalid AcceptanceTooLong] @?= ["title-empty", "criterion-invalid", "acceptance-too-long"]
        ]
    , testGroup
        "the document as a whole"
        [ testCase "a repeated key refuses the document" $ do
            decideImport sha256Hasher Nothing (document 1 [item "A" 1 [], item "B" 1 [], item "A" 2 []]) @?= Left (DuplicateKey (k "A"))
            documentRefusalCode (DuplicateKey (k "A")) @?= "duplicate-key"
        , testCase "more than 500 items refuses the document" $ do
            let
              items = fmap (\n -> item ("K" <> T.pack (show n)) 1 []) [1 .. 501 :: Int]
            decideImport sha256Hasher Nothing (document 1 items) @?= Left (TooManyItems 501)
            assertBool "500 is allowed" (isRight (decideImport sha256Hasher Nothing (document 1 (L.take 500 items))))
            documentRefusalCode (TooManyItems 501) @?= "too-many-items"
        , testCase "a document older than the last import is refused whole; the same revision is not" $ do
            let
              items = [item "A" 1 []]
            decideImport sha256Hasher (Just (priorOf 5 items)) (document 4 items) @?= Left (StaleDocument (rev 5) (rev 4))
            assertBool "same revision" (isRight (decideImport sha256Hasher (Just (priorOf 5 items)) (document 5 items)))
            documentRefusalCode (StaleDocument (rev 5) (rev 4)) @?= "stale-document"
        ]
    , testGroup
        "an import after an earlier one (B4, B5, B6)"
        [ testCase "the same document again changes nothing" $ do
            let
              items = [item "A" 1 [], item "B" 2 ["A"]]
            outcomes (Just (priorOf 3 items)) (document 3 items) >>= (@?= [ItemUnchanged, ItemUnchanged])
        , testCase "reordering the items changes nothing, and the decision follows the new order" $ do
            let
              items = [item "A" 1 [], item "B" 2 ["A"], item "C" 1 ["A", "B"]]
            d <- decided (Just (priorOf 3 items)) (document 3 (L.reverse items))
            decisionItems d @?= [(k "C", ItemUnchanged), (k "B", ItemUnchanged), (k "A", ItemUnchanged)]
        , testCase "an older item revision is stale and changes nothing" $ do
            let
              newer = item "A" 3 []
              older = (item "A" 2 []) {itemTitle = "An older title"}
            refusedWith (Just (priorOf 1 [newer])) (document 1 [older]) "A" (StaleRevision (rev 3) (rev 2))
            itemRefusalCode (StaleRevision (rev 3) (rev 2)) @?= "stale-revision"
        , testCase "the same revision with different content is a conflict" $ do
            let
              stored = item "A" 3 []
            refusedWith (Just (priorOf 1 [stored])) (document 1 [stored {itemTitle = "Changed"}]) "A" (RevisionReused (rev 3))
            itemRefusalCode (RevisionReused (rev 3)) @?= "revision-reused"
        , testCase "a newer revision with the same content is unchanged; with new content it updates an untouched task" $ do
            let
              stored = item "A" 3 []
              prior = Just (priorOf 1 [stored])
            outcomeOf prior (document 2 [stored {itemRevision = rev 4}]) "A" >>= (@?= ItemUnchanged)
            outcomeOf prior (document 2 [stored {itemRevision = rev 4, itemTitle = "Changed"}]) "A" >>= (@?= ItemUpdated)
        , testCase "new content never overwrites a task a person edited or moved on" $ do
            let
              stored = item "A" 3 []
              changed = document 2 [stored {itemRevision = rev 4, itemTitle = "Changed"}]
              withCondition c = Just (PriorImport (rev 1) [(digestOf stored) {storedCondition = c}])
            refusedWith (withCondition LocalEdited) changed "A" LocallyEdited
            refusedWith (withCondition LocalProgressed) changed "A" LocallyProgressed
            fmap itemRefusalCode [LocallyEdited, LocallyProgressed] @?= ["locally-edited", "locally-progressed"]
        , testCase "a blocker imported before but missing from this document still resolves" $
            outcomeOf (Just (priorOf 1 [item "A" 1 []])) (document 2 [item "B" 1 ["A"]]) "B" >>= (@?= ItemCreated)
        , testCase "a blocker refused here but imported before still resolves (its task exists)" $ do
            let
              stored = item "A" 3 []
              doc = document 2 [stored {itemRevision = rev 2, itemTitle = "Older"}, item "B" 1 ["A"]]
            outcomeOf (Just (priorOf 1 [stored])) doc "A" >>= (@?= ItemRefused (StaleRevision (rev 3) (rev 2)))
            outcomeOf (Just (priorOf 1 [stored])) doc "B" >>= (@?= ItemCreated)
        , testCase "a new cycle through an earlier import is refused" $ do
            let
              a = item "A" 1 []
              b = item "B" 1 ["A"]
              prior = Just (priorOf 1 [a, b])
            refusedWith prior (document 2 [a {itemRevision = rev 2, itemBlockers = [k "B"]}]) "A" BlockerCycle
        , testCase "items imported before and missing now are reported absent, in key order; nothing is deleted" $ do
            d <- decided (Just (priorOf 1 [item "C" 1 [], item "A" 1 [], item "B" 1 []])) (document 2 [item "B" 1 []])
            decisionItems d @?= [(k "B", ItemUnchanged)]
            decisionAbsent d @?= [k "A", k "C"]
            renderImportDecision d
              @?= T.unlines
                [ "lockstep-backlog-import 1"
                , "source canonical caesura-notes revision 2"
                , "item B unchanged"
                , "absent A"
                , "absent C"
                ]
        , testCase "refusals render with their code and detail" $ do
            let
              stored = item "A" 3 []
              doc = document 2 [stored {itemRevision = rev 2, itemTitle = "Older"}, item "B" 1 ["Q"], item "C" 1 [], stored {itemKey = k "D", itemRevision = rev 3, itemTitle = "Changed"}]
              prior = Just (PriorImport (rev 1) [digestOf stored, (digestOf stored) {storedKey = k "D"}])
            d <- decided prior doc
            renderImportDecision d
              @?= T.unlines
                [ "lockstep-backlog-import 1"
                , "source canonical caesura-notes revision 2"
                , "item A refused stale-revision stored=3 given=2"
                , "item B refused dangling-blocker Q"
                , "item C created"
                , "item D refused revision-reused revision=3"
                ]
        ]
    ]
