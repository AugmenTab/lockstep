{- | The strict JSON Profile document (contract C-P2.3 F12, §4). Decoding only
checks the shape and refuses unknown keys at every level; the Kernel
validates names and policy.
-}
module Lockstep.Application.ProfileDocument
  ( decodeProfileDocument
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Fleece.Aeson qualified as FA
import Fleece.Core ((#+))
import Fleece.Core qualified as FC
import Flipstone.Prelude

import Lockstep.Kernel.Profile (RawGate (..), RawProfile (..), RawSpecialization (..))

data DocGate
  = DocGate
  { docGateId :: T.Text
  , docGateStage :: T.Text
  , docGateArtifacts :: [T.Text]
  , docGateKinds :: Maybe [T.Text]
  , docGateClasses :: Maybe [T.Text]
  , docGatePathClasses :: Maybe [T.Text]
  , docGateVerifiers :: [T.Text]
  , docGateApproval :: T.Text
  , docGateExceptionPath :: Maybe Bool
  , docGateExtra :: Map.Map T.Text FC.AnyJSON
  }

data DocSpecialization
  = DocSpecialization
  { docWhenKind :: Maybe T.Text
  , docWhenClass :: Maybe T.Text
  , docSpecializationProfile :: T.Text
  , docSpecializationExtra :: Map.Map T.Text FC.AnyJSON
  }

data DocProfile
  = DocProfile
  { docId :: T.Text
  , docVersion :: Integer
  , docAllowsNonBehavioural :: Maybe Bool
  , docInvariantExceptions :: Maybe [T.Text]
  , docGates :: [DocGate]
  , docSpecializations :: Maybe [DocSpecialization]
  , docExtra :: Map.Map T.Text FC.AnyJSON
  }

gateSchema :: FC.Fleece t => FC.Schema t DocGate
gateSchema =
  FC.object $
    FC.additional
      ( FC.constructor DocGate
          #+ FC.required "id" docGateId FC.text
          #+ FC.required "stage" docGateStage FC.text
          #+ FC.required "artifacts" docGateArtifacts (FC.list FC.text)
          #+ FC.optional "kinds" docGateKinds (FC.list FC.text)
          #+ FC.optional "classes" docGateClasses (FC.list FC.text)
          #+ FC.optional "path_classes" docGatePathClasses (FC.list FC.text)
          #+ FC.required "verifiers" docGateVerifiers (FC.list FC.text)
          #+ FC.required "approval" docGateApproval FC.text
          #+ FC.optional "exception_path" docGateExceptionPath FC.boolean
      )
      (FC.additionalFields docGateExtra FC.anyJSON)

specializationSchema :: FC.Fleece t => FC.Schema t DocSpecialization
specializationSchema =
  FC.object $
    FC.additional
      ( FC.constructor DocSpecialization
          #+ FC.optional "when_kind" docWhenKind FC.text
          #+ FC.optional "when_class" docWhenClass FC.text
          #+ FC.required "profile" docSpecializationProfile FC.text
      )
      (FC.additionalFields docSpecializationExtra FC.anyJSON)

profileSchema :: FC.Fleece t => FC.Schema t DocProfile
profileSchema =
  FC.object $
    FC.additional
      ( FC.constructor DocProfile
          #+ FC.required "id" docId FC.text
          #+ FC.required "version" docVersion FC.integer
          #+ FC.optional "allows_non_behavioural" docAllowsNonBehavioural FC.boolean
          #+ FC.optional "invariant_exceptions" docInvariantExceptions (FC.list FC.text)
          #+ FC.required "gates" docGates (FC.list gateSchema)
          #+ FC.optional "specializations" docSpecializations (FC.list specializationSchema)
      )
      (FC.additionalFields docExtra FC.anyJSON)

decodeProfileDocument :: LBS.ByteString -> Either T.Text RawProfile
decodeProfileDocument bytes =
  case FA.decode profileSchema bytes of
    Left reason -> Left (T.pack reason)
    Right doc -> do
      known "the document" (docExtra doc)
      gates <- traverse fromGate (docGates doc)
      specializations <- traverse fromSpecialization (fromMaybe [] (docSpecializations doc))
      pure
        RawProfile
          { rawProfileId = docId doc
          , rawProfileVersion = docVersion doc
          , rawAllowsNonBehavioural = docAllowsNonBehavioural doc
          , rawInvariantExceptions = fromMaybe [] (docInvariantExceptions doc)
          , rawGates = gates
          , rawSpecializations = specializations
          }

known :: String -> Map.Map T.Text FC.AnyJSON -> Either T.Text ()
known place extra =
  if Map.null extra
    then Right ()
    else Left (T.pack ("unknown keys in " <> place <> ": ") <> T.intercalate (T.pack ", ") (Map.keys extra))

fromGate :: DocGate -> Either T.Text RawGate
fromGate gate = do
  known "a gate" (docGateExtra gate)
  pure
    RawGate
      { rawGateId = docGateId gate
      , rawGateStage = docGateStage gate
      , rawGateArtifacts = docGateArtifacts gate
      , rawGateKinds = docGateKinds gate
      , rawGateClasses = docGateClasses gate
      , rawGatePathClasses = docGatePathClasses gate
      , rawGateVerifiers = docGateVerifiers gate
      , rawGateApproval = docGateApproval gate
      , rawGateExceptionPath = fromMaybe False (docGateExceptionPath gate)
      }

fromSpecialization :: DocSpecialization -> Either T.Text RawSpecialization
fromSpecialization specialization = do
  known "a specialization" (docSpecializationExtra specialization)
  pure
    RawSpecialization
      { rawWhenKind = docWhenKind specialization
      , rawWhenClass = docWhenClass specialization
      , rawSpecializationProfile = docSpecializationProfile specialization
      }
