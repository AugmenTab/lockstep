{- | The plan document, @lockstep-plan@ version 1 (contract C-P6.4 M1): one
Fleece schema decodes and encodes it. A key the format does not define is
refused at every level, so no field a Planner adds can carry authority.
-}
module Lockstep.Application.PlanDocument
  ( PlanDocumentError (..)
  , planDocumentErrorCode
  , decodePlanDocument
  , decodePlanDocumentText
  , encodePlanDocument
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Fleece.Aeson qualified as FA
import Fleece.Core ((#+))
import Fleece.Core qualified as FC
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Foundation.Fleece (encodeText)
import Lockstep.Kernel.Plan
  ( Envelope (..)
  , PlanCriterion (..)
  , PlanDocument (..)
  , PlanEdge (..)
  , PlanSource (..)
  , PlanUnit (..)
  , Uncertainty (..)
  , edgeKindCode
  , effectClassCode
  , mkUnitKey
  , parseEdgeKind
  , parseEffectClass
  , parsePlanMode
  , parseRiskClass
  , planModeCode
  , riskClassCode
  , unitKeyText
  )
import Lockstep.Kernel.Task (parsePriority, priorityCode)

data PlanDocumentError
  = PlanMalformed T.Text
  | PlanUnknownKeys [T.Text]
  | PlanUnsupportedFormat
  | PlanInvalidUnitKey T.Text
  | PlanInvalidValue T.Text
  deriving (Eq, Show)

planDocumentErrorCode :: PlanDocumentError -> T.Text
planDocumentErrorCode e =
  T.pack $
    case e of
      PlanMalformed _ -> "malformed"
      PlanUnknownKeys _ -> "unknown-keys"
      PlanUnsupportedFormat -> "unsupported-format"
      PlanInvalidUnitKey _ -> "invalid-unit-key"
      PlanInvalidValue _ -> "invalid-value"

-- The wire shape -----------------------------------------------------------------

type Extra =
  Map.Map T.Text FC.AnyJSON

data DocCited
  = DocCited T.Text [T.Text] Extra

data DocSource
  = DocSource T.Text T.Text Extra

data DocEnvelope
  = DocEnvelope Bool Integer (Maybe Integer) Extra

data DocUnit
  = DocUnit
  { duKey :: T.Text
  , duTitle :: T.Text
  , duPhase :: T.Text
  , duSubphase :: T.Text
  , duWorkKind :: T.Text
  , duProfile :: T.Text
  , duPriority :: T.Text
  , duEffect :: T.Text
  , duRisk :: T.Text
  , duProvisional :: Bool
  , duOutputs :: [T.Text]
  , duAcceptance :: [DocCited]
  , duNegative :: [T.Text]
  , duChecks :: [T.Text]
  , duPrerequisites :: [T.Text]
  , duResources :: [T.Text]
  , duExtra :: Extra
  }

data DocEdge
  = DocEdge T.Text T.Text T.Text Extra

data Doc
  = Doc
  { docFormat :: T.Text
  , docVersion :: Integer
  , docTitle :: T.Text
  , docMode :: T.Text
  , docSources :: [DocSource]
  , docEnvelope :: DocEnvelope
  , docUnits :: [DocUnit]
  , docEdges :: [DocEdge]
  , docUncertainties :: [DocCited]
  , docExtra :: Extra
  }

citedSchema :: FC.Fleece t => FC.Schema t DocCited
citedSchema =
  FC.object $
    FC.additional
      ( FC.constructor DocCited
          #+ FC.required "text" (\(DocCited t _ _) -> t) FC.text
          #+ FC.required "cites" (\(DocCited _ c _) -> c) (FC.list FC.text)
      )
      (FC.additionalFields (\(DocCited _ _ e) -> e) FC.anyJSON)

sourceSchema :: FC.Fleece t => FC.Schema t DocSource
sourceSchema =
  FC.object $
    FC.additional
      ( FC.constructor DocSource
          #+ FC.required "name" (\(DocSource n _ _) -> n) FC.text
          #+ FC.required "sha256" (\(DocSource _ d _) -> d) FC.text
      )
      (FC.additionalFields (\(DocSource _ _ e) -> e) FC.anyJSON)

envelopeSchema :: FC.Fleece t => FC.Schema t DocEnvelope
envelopeSchema =
  FC.object $
    FC.additional
      ( FC.constructor DocEnvelope
          #+ FC.required "external_effects" (\(DocEnvelope x _ _ _) -> x) FC.boolean
          #+ FC.required "max_units" (\(DocEnvelope _ m _ _) -> m) FC.integer
          #+ FC.optional "token_budget" (\(DocEnvelope _ _ b _) -> b) FC.integer
      )
      (FC.additionalFields (\(DocEnvelope _ _ _ e) -> e) FC.anyJSON)

unitSchema :: FC.Fleece t => FC.Schema t DocUnit
unitSchema =
  FC.object $
    FC.additional
      ( FC.constructor DocUnit
          #+ FC.required "key" duKey FC.text
          #+ FC.required "title" duTitle FC.text
          #+ FC.required "phase" duPhase FC.text
          #+ FC.required "subphase" duSubphase FC.text
          #+ FC.required "work_kind" duWorkKind FC.text
          #+ FC.required "profile" duProfile FC.text
          #+ FC.required "priority" duPriority FC.text
          #+ FC.required "effect" duEffect FC.text
          #+ FC.required "risk" duRisk FC.text
          #+ FC.required "provisional" duProvisional FC.boolean
          #+ FC.required "outputs" duOutputs (FC.list FC.text)
          #+ FC.required "acceptance" duAcceptance (FC.list citedSchema)
          #+ FC.required "negative" duNegative (FC.list FC.text)
          #+ FC.required "checks" duChecks (FC.list FC.text)
          #+ FC.required "prerequisites" duPrerequisites (FC.list FC.text)
          #+ FC.required "resources" duResources (FC.list FC.text)
      )
      (FC.additionalFields duExtra FC.anyJSON)

edgeSchema :: FC.Fleece t => FC.Schema t DocEdge
edgeSchema =
  FC.object $
    FC.additional
      ( FC.constructor DocEdge
          #+ FC.required "dependent" (\(DocEdge d _ _ _) -> d) FC.text
          #+ FC.required "prerequisite" (\(DocEdge _ p _ _) -> p) FC.text
          #+ FC.required "kind" (\(DocEdge _ _ k _) -> k) FC.text
      )
      (FC.additionalFields (\(DocEdge _ _ _ e) -> e) FC.anyJSON)

documentSchema :: FC.Fleece t => FC.Schema t Doc
documentSchema =
  FC.object $
    FC.additional
      ( FC.constructor Doc
          #+ FC.required "format" docFormat FC.text
          #+ FC.required "version" docVersion FC.integer
          #+ FC.required "title" docTitle FC.text
          #+ FC.required "mode" docMode FC.text
          #+ FC.required "sources" docSources (FC.list sourceSchema)
          #+ FC.required "envelope" docEnvelope envelopeSchema
          #+ FC.required "units" docUnits (FC.list unitSchema)
          #+ FC.required "edges" docEdges (FC.list edgeSchema)
          #+ FC.required "uncertainties" docUncertainties (FC.list citedSchema)
      )
      (FC.additionalFields docExtra FC.anyJSON)

-- Decoding -------------------------------------------------------------------------

formatName :: T.Text
formatName =
  T.pack "lockstep-plan"

decodePlanDocumentText :: T.Text -> Either PlanDocumentError PlanDocument
decodePlanDocumentText =
  decodePlanDocument . LBS.fromStrict . TE.encodeUtf8

decodePlanDocument :: LBS.ByteString -> Either PlanDocumentError PlanDocument
decodePlanDocument bytes =
  case FA.decode documentSchema bytes of
    Left reason -> Left (PlanMalformed (T.pack reason))
    Right doc -> do
      when (docFormat doc /= formatName || docVersion doc /= 1) (Left PlanUnsupportedFormat)
      let
        citedKeys (DocCited _ _ e) = Map.keys e
        DocEnvelope _ _ _ envelopeExtra = docEnvelope doc
        unknown =
          Map.keys (docExtra doc)
            <> concatMap (\(DocSource _ _ e) -> Map.keys e) (docSources doc)
            <> Map.keys envelopeExtra
            <> concatMap (\u -> Map.keys (duExtra u) <> concatMap citedKeys (duAcceptance u)) (docUnits doc)
            <> concatMap (\(DocEdge _ _ _ e) -> Map.keys e) (docEdges doc)
            <> concatMap citedKeys (docUncertainties doc)
      when (not (null unknown)) (Left (PlanUnknownKeys unknown))
      mode <- value "mode" parsePlanMode (docMode doc)
      units <- traverse fromUnit (docUnits doc)
      edges <- traverse fromEdge (docEdges doc)
      let
        DocEnvelope external maxUnits budget _ = docEnvelope doc
      pure
        PlanDocument
          { planTitle = docTitle doc
          , planMode = mode
          , planSources = [PlanSource n d | DocSource n d _ <- docSources doc]
          , planEnvelope = Envelope external (fromInteger (clamp maxUnits)) budget
          , planUnits = units
          , planEdges = edges
          , planUncertainties = [Uncertainty t c | DocCited t c _ <- docUncertainties doc]
          }
 where
  -- An out-of-range count is kept out of range (validation refuses it) without overflowing.
  clamp n = max (-1) (min 1000000 n)
  value name parse text = maybe (Left (PlanInvalidValue (T.pack name <> T.pack " " <> text))) Right (parse text)
  keyOf text = maybe (Left (PlanInvalidUnitKey text)) Right (mkUnitKey text)
  fromUnit u = do
    k <- keyOf (duKey u)
    priority <- value "priority" parsePriority (duPriority u)
    effect <- value "effect" parseEffectClass (duEffect u)
    risk <- value "risk" parseRiskClass (duRisk u)
    pure
      PlanUnit
        { unitKey = k
        , unitTitle = duTitle u
        , unitPhase = duPhase u
        , unitSubphase = duSubphase u
        , unitWorkKind = duWorkKind u
        , unitProfile = duProfile u
        , unitPriority = priority
        , unitEffect = effect
        , unitRisk = risk
        , unitProvisional = duProvisional u
        , unitOutputs = duOutputs u
        , unitAcceptance = [PlanCriterion t c | DocCited t c _ <- duAcceptance u]
        , unitNegative = duNegative u
        , unitChecks = duChecks u
        , unitPrerequisites = duPrerequisites u
        , unitResources = duResources u
        }
  fromEdge (DocEdge d p k _) =
    PlanEdge <$> keyOf d <*> keyOf p <*> value "kind" parseEdgeKind k

-- Encoding -------------------------------------------------------------------------

encodePlanDocument :: PlanDocument -> T.Text
encodePlanDocument d =
  encodeText
    documentSchema
    Doc
      { docFormat = formatName
      , docVersion = 1
      , docTitle = planTitle d
      , docMode = planModeCode (planMode d)
      , docSources = [DocSource (sourceName s) (sourceDigest s) Map.empty | s <- planSources d]
      , docEnvelope =
          let
            e = planEnvelope d
          in
            DocEnvelope (envelopeExternalEffects e) (toInteger (envelopeMaxUnits e)) (envelopeTokenBudget e) Map.empty
      , docUnits = fmap toUnit (planUnits d)
      , docEdges = [DocEdge (unitKeyText (edgeDependent e)) (unitKeyText (edgePrerequisite e)) (edgeKindCode (edgeKind e)) Map.empty | e <- planEdges d]
      , docUncertainties = [DocCited (uncertaintyText u) (uncertaintyCites u) Map.empty | u <- planUncertainties d]
      , docExtra = Map.empty
      }
 where
  toUnit u =
    DocUnit
      { duKey = unitKeyText (unitKey u)
      , duTitle = unitTitle u
      , duPhase = unitPhase u
      , duSubphase = unitSubphase u
      , duWorkKind = unitWorkKind u
      , duProfile = unitProfile u
      , duPriority = priorityCode (unitPriority u)
      , duEffect = effectClassCode (unitEffect u)
      , duRisk = riskClassCode (unitRisk u)
      , duProvisional = unitProvisional u
      , duOutputs = unitOutputs u
      , duAcceptance = [DocCited (planCriterionText c) (planCriterionCites c) Map.empty | c <- unitAcceptance u]
      , duNegative = unitNegative u
      , duChecks = unitChecks u
      , duPrerequisites = unitPrerequisites u
      , duResources = unitResources u
      , duExtra = Map.empty
      }
