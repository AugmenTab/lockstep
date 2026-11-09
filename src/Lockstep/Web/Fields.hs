{-# LANGUAGE OverloadedStrings #-}

{- | The form field names, declared once (as Artificer's @Routes.App.Packs.Shared@):
each 'B.Name' is used both for the input's @name@ and by the validator that reads
the submission. The spellings are the frozen pages' (C-P1.4, C-P3.5–C-P4.16).
-}
module Lockstep.Web.Fields
  ( -- * Application forms
    keyField
  , nameField
  , outcomeField
  , folderField
  , pathField
  , revisionField
  , titleField
  , acceptanceField
  , priorityField
  , dependsOnField
  , ticketRevisionField
  , actionField
  , reasonField
  , expectedField
  , expectedSetField
  , confirmFewerField
  , choiceField
  , requestField
  , textField
  , acknowledgeField

    -- * Operator forms
  , tokenField
  , csrfField
  , idempotencyKeyField
  , expectedRevisionField
  , stepsField
  , stepMsField
  , failAtStepField
  ) where

import Brigid.Types qualified as B
import Data.NonEmptyText qualified as NET

keyField :: B.Name
keyField = B.Name (NET.new 'k' "ey")

nameField :: B.Name
nameField = B.Name (NET.new 'n' "ame")

outcomeField :: B.Name
outcomeField = B.Name (NET.new 'o' "utcome")

folderField :: B.Name
folderField = B.Name (NET.new 'f' "older")

pathField :: B.Name
pathField = B.Name (NET.new 'p' "ath")

revisionField :: B.Name
revisionField = B.Name (NET.new 'r' "evision")

titleField :: B.Name
titleField = B.Name (NET.new 't' "itle")

acceptanceField :: B.Name
acceptanceField = B.Name (NET.new 'a' "cceptance")

priorityField :: B.Name
priorityField = B.Name (NET.new 'p' "riority")

dependsOnField :: B.Name
dependsOnField = B.Name (NET.new 'd' "epends_on")

ticketRevisionField :: B.Name
ticketRevisionField = B.Name (NET.new 't' "icket_revision")

actionField :: B.Name
actionField = B.Name (NET.new 'a' "ction")

reasonField :: B.Name
reasonField = B.Name (NET.new 'r' "eason")

expectedField :: B.Name
expectedField = B.Name (NET.new 'e' "xpected")

expectedSetField :: B.Name
expectedSetField = B.Name (NET.new 'e' "xpected_set")

confirmFewerField :: B.Name
confirmFewerField = B.Name (NET.new 'c' "onfirm_fewer")

choiceField :: B.Name
choiceField = B.Name (NET.new 'c' "hoice")

requestField :: B.Name
requestField = B.Name (NET.new 'r' "equest")

textField :: B.Name
textField = B.Name (NET.new 't' "ext")

acknowledgeField :: B.Name
acknowledgeField = B.Name (NET.new 'a' "cknowledge")

tokenField :: B.Name
tokenField = B.Name (NET.new 't' "oken")

csrfField :: B.Name
csrfField = B.Name (NET.new 'c' "srf")

idempotencyKeyField :: B.Name
idempotencyKeyField = B.Name (NET.new 'i' "dempotency_key")

expectedRevisionField :: B.Name
expectedRevisionField = B.Name (NET.new 'e' "xpected_revision")

stepsField :: B.Name
stepsField = B.Name (NET.new 's' "teps")

stepMsField :: B.Name
stepMsField = B.Name (NET.new 's' "tep_ms")

failAtStepField :: B.Name
failAtStepField = B.Name (NET.new 'f' "ail_at_step")
