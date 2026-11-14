{- | The canonical backlog document, @lockstep-backlog@ version 1 (contract
C-P6.1 §1): one Fleece schema decodes and encodes it. A document with a key
the format does not define is refused, so no field a source adds can carry
state, priority or approval into Lockstep (B9).
-}
module Lockstep.Application.BacklogDocument
  ( DocumentError (..)
  , documentErrorCode
  , decodeBacklogDocument
  , encodeBacklogDocument
  , criteriaText
  , decodeCriteria
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Fleece.Aeson qualified as FA
import Fleece.Core ((#+))
import Fleece.Core qualified as FC
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Foundation.Fleece (decodeText, encodeText)
import Lockstep.Kernel.Backlog
  ( BacklogDocument (..)
  , BacklogItem (..)
  , Criterion (..)
  , SourceIdentity (..)
  , mkSourceKey
  , mkSourceLocator
  , mkSourceRevision
  , parseSourceProvider
  , sourceKeyText
  , sourceLocatorText
  , sourceProviderCode
  , sourceRevisionValue
  )
import Lockstep.Kernel.Identity (RepositoryId (..), parseUuid, uuidText)

data DocumentError
  = DocumentMalformed T.Text
  | DocumentUnknownKeys [T.Text]
  | DocumentUnsupportedFormat
  | DocumentInvalidProvider
  | DocumentInvalidLocator
  | DocumentInvalidKey T.Text
  | DocumentInvalidRevision
  | DocumentInvalidRepository
  deriving (Eq, Show)

documentErrorCode :: DocumentError -> T.Text
documentErrorCode e =
  T.pack $
    case e of
      DocumentMalformed _ -> "malformed"
      DocumentUnknownKeys _ -> "unknown-keys"
      DocumentUnsupportedFormat -> "unsupported-format"
      DocumentInvalidProvider -> "invalid-provider"
      DocumentInvalidLocator -> "invalid-locator"
      DocumentInvalidKey _ -> "invalid-key"
      DocumentInvalidRevision -> "invalid-revision"
      DocumentInvalidRepository -> "invalid-repository"

-- The wire shape -----------------------------------------------------------------

data DocCriterion
  = DocCriterion
  { docCriterionText :: T.Text
  , docCriterionRef :: Maybe T.Text
  , docCriterionExtra :: Map.Map T.Text FC.AnyJSON
  }

data DocItem
  = DocItem
  { docItemKey :: T.Text
  , docItemRevision :: Integer
  , docItemTitle :: T.Text
  , docItemAcceptance :: Maybe [DocCriterion]
  , docItemBlockers :: Maybe [T.Text]
  , docItemExtra :: Map.Map T.Text FC.AnyJSON
  }

data DocSource
  = DocSource
  { docSourceProvider :: T.Text
  , docSourceLocator :: T.Text
  , docSourceExtra :: Map.Map T.Text FC.AnyJSON
  }

data Doc
  = Doc
  { docFormat :: T.Text
  , docVersion :: Integer
  , docSource :: DocSource
  , docRevision :: Integer
  , docRepository :: Maybe T.Text
  , docItems :: [DocItem]
  , docExtra :: Map.Map T.Text FC.AnyJSON
  }

criterionSchema :: FC.Fleece t => FC.Schema t DocCriterion
criterionSchema =
  FC.object $
    FC.additional
      ( FC.constructor DocCriterion
          #+ FC.required "text" docCriterionText FC.text
          #+ FC.optional "ref" docCriterionRef FC.text
      )
      (FC.additionalFields docCriterionExtra FC.anyJSON)

itemSchema :: FC.Fleece t => FC.Schema t DocItem
itemSchema =
  FC.object $
    FC.additional
      ( FC.constructor DocItem
          #+ FC.required "key" docItemKey FC.text
          #+ FC.required "revision" docItemRevision FC.integer
          #+ FC.required "title" docItemTitle FC.text
          #+ FC.optional "acceptance" docItemAcceptance (FC.list criterionSchema)
          #+ FC.optional "blockers" docItemBlockers (FC.list FC.text)
      )
      (FC.additionalFields docItemExtra FC.anyJSON)

sourceSchema :: FC.Fleece t => FC.Schema t DocSource
sourceSchema =
  FC.object $
    FC.additional
      ( FC.constructor DocSource
          #+ FC.required "provider" docSourceProvider FC.text
          #+ FC.required "locator" docSourceLocator FC.text
      )
      (FC.additionalFields docSourceExtra FC.anyJSON)

documentSchema :: FC.Fleece t => FC.Schema t Doc
documentSchema =
  FC.object $
    FC.additional
      ( FC.constructor Doc
          #+ FC.required "format" docFormat FC.text
          #+ FC.required "version" docVersion FC.integer
          #+ FC.required "source" docSource sourceSchema
          #+ FC.required "revision" docRevision FC.integer
          #+ FC.optional "repository" docRepository FC.text
          #+ FC.required "items" docItems (FC.list itemSchema)
      )
      (FC.additionalFields docExtra FC.anyJSON)

criteriaSchema :: FC.Fleece t => FC.Schema t [DocCriterion]
criteriaSchema =
  FC.list criterionSchema

-- Decoding -------------------------------------------------------------------------

formatName :: T.Text
formatName =
  T.pack "lockstep-backlog"

decodeBacklogDocument :: LBS.ByteString -> Either DocumentError BacklogDocument
decodeBacklogDocument bytes =
  case FA.decode documentSchema bytes of
    Left reason -> Left (DocumentMalformed (T.pack reason))
    Right doc -> do
      when (docFormat doc /= formatName || docVersion doc /= 1) (Left DocumentUnsupportedFormat)
      let
        unknown =
          Map.keys (docExtra doc)
            <> Map.keys (docSourceExtra (docSource doc))
            <> concatMap (\i -> Map.keys (docItemExtra i) <> maybe [] (concatMap (Map.keys . docCriterionExtra)) (docItemAcceptance i)) (docItems doc)
      when (not (null unknown)) (Left (DocumentUnknownKeys unknown))
      provider <- maybe (Left DocumentInvalidProvider) Right (parseSourceProvider (docSourceProvider (docSource doc)))
      locator <- maybe (Left DocumentInvalidLocator) Right (mkSourceLocator (docSourceLocator (docSource doc)))
      revision <- revisionOf (docRevision doc)
      repository <- traverse (either (const (Left DocumentInvalidRepository)) (Right . RepositoryId) . parseUuid) (docRepository doc)
      items <- traverse fromItem (docItems doc)
      pure
        BacklogDocument
          { documentSource = SourceIdentity provider locator
          , documentRevision = revision
          , documentRepository = repository
          , documentItems = items
          }
 where
  revisionOf n = maybe (Left DocumentInvalidRevision) Right (mkSourceRevision n)
  keyOf text = maybe (Left (DocumentInvalidKey text)) Right (mkSourceKey text)
  fromItem i = do
    key <- keyOf (docItemKey i)
    revision <- revisionOf (docItemRevision i)
    blockers <- traverse keyOf (fromMaybe [] (docItemBlockers i))
    pure
      BacklogItem
        { itemKey = key
        , itemRevision = revision
        , itemTitle = docItemTitle i
        , itemCriteria = fmap fromCriterion (fromMaybe [] (docItemAcceptance i))
        , itemBlockers = blockers
        }

fromCriterion :: DocCriterion -> Criterion
fromCriterion c =
  Criterion (docCriterionText c) (docCriterionRef c)

toCriterion :: Criterion -> DocCriterion
toCriterion c =
  DocCriterion (criterionText c) (criterionRef c) Map.empty

-- Encoding -------------------------------------------------------------------------

encodeBacklogDocument :: BacklogDocument -> T.Text
encodeBacklogDocument d =
  encodeText
    documentSchema
    Doc
      { docFormat = formatName
      , docVersion = 1
      , docSource =
          DocSource
            { docSourceProvider = sourceProviderCode (sourceProvider (documentSource d))
            , docSourceLocator = sourceLocatorText (sourceLocator (documentSource d))
            , docSourceExtra = Map.empty
            }
      , docRevision = toInteger (sourceRevisionValue (documentRevision d))
      , docRepository = fmap (\(RepositoryId u) -> uuidText u) (documentRepository d)
      , docItems =
          [ DocItem
              { docItemKey = sourceKeyText (itemKey i)
              , docItemRevision = toInteger (sourceRevisionValue (itemRevision i))
              , docItemTitle = itemTitle i
              , docItemAcceptance = Just (fmap toCriterion (itemCriteria i))
              , docItemBlockers = Just (fmap sourceKeyText (itemBlockers i))
              , docItemExtra = Map.empty
              }
          | i <- documentItems d
          ]
      , docExtra = Map.empty
      }

-- | The stored form of an item's criteria (B8): the document's own criterion objects.
criteriaText :: [Criterion] -> T.Text
criteriaText =
  encodeText criteriaSchema . fmap toCriterion

decodeCriteria :: T.Text -> Either T.Text [Criterion]
decodeCriteria text =
  case decodeText criteriaSchema text of
    Left reason -> Left (T.pack reason)
    Right cs
      | all (Map.null . docCriterionExtra) cs -> Right (fmap fromCriterion cs)
      | otherwise -> Left (T.pack "unknown keys in stored criteria")
