{-# LANGUAGE OverloadedStrings #-}

{- | The page for how a project's work is checked, and the work waiting to
start (contract C-P3.7 L7): the always-on rules, the chosen checks as a
checklist, the choice form, the read-only queue, and the exact Profile
identities, versions and digests under Technical details. No Profile, gate,
invariant, Work Order, Ticket, Engineer, scheduler or digest word on the
ordinary path.
-}
module Lockstep.Web.ChecksPages
  ( checksPage
  , projectChecksSection
  , choiceName
  , choiceLosses
  ) where

import Brigid.HTML.Attributes qualified as A
import Brigid.HTML.Elements qualified as E
import Brigid.HTML.Types qualified as HTML
import Brigid.Types qualified as B
import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (show)

import Lockstep.Application.ProjectChecks
  ( ChecksChoice (..)
  , EffectiveRules (..)
  , KindRules (..)
  , ProjectChecks (..)
  , QueueEntry (..)
  , Standing (..)
  , basicChecksId
  )
import Lockstep.Application.Projects (ProjectView (..))
import Lockstep.Kernel.Policy (CheckRow (..), Loss, checkRow, checksLost, ineligibilityWords, invariantWords, kindWords)
import Lockstep.Kernel.Profile (definitionGates, gateId, gateIdText)
import Lockstep.Kernel.Scheduler (ineligibilityCode)
import Lockstep.Kernel.Task (priorityOf, priorityWords)
import Lockstep.Kernel.WorkOrder (workOrderKindName)
import Lockstep.Web.Fragment (attr, cls, fragment, href)

-- | The name a person sees for a set of checks.
choiceName :: ChecksChoice -> T.Text
choiceName c =
  if choiceId c == basicChecksId then "Always-on rules only" else choiceId c

-- | What choosing the named set instead of the current one would stop requiring (L2).
choiceLosses :: ProjectChecks -> T.Text -> [Loss]
choiceLosses pc chosen =
  case L.find ((== chosen) . choiceId) (checksChoices pc) >>= choiceDefinition of
    Nothing -> []
    Just d -> checksLost (checksCurrent pc >>= choiceDefinition) d

summaryOf :: ChecksChoice -> T.Text
summaryOf c =
  case choiceDefinition c of
    Nothing -> "cannot be used: it is damaged"
    Just d ->
      case L.length (definitionGates d) of
        0 -> "no extra checks"
        1 -> "1 extra check"
        n -> T.pack (show n) <> " extra checks"

alwaysOn :: [E.ChildHTML E.Division E.Body]
alwaysOn =
  [ E.h2 [] [E.text "Rules that always apply"]
  , E.p [] [E.text "These rules always apply to work Lockstep does. No choice on this page can turn them off."]
  , E.ul [cls "ls-rules"] [E.li [] [E.text (invariantWords i)] | i <- [minBound .. maxBound]]
  ]

checklist :: ChecksChoice -> [E.ChildHTML E.Division E.Body]
checklist c =
  case choiceDefinition c of
    Nothing -> [E.p [cls "ls-notice"] [E.text "This set of checks is damaged, so Lockstep will not use it. Choose another one below."]]
    Just d ->
      case fmap checkRow (definitionGates d) of
        [] -> [E.p [] [E.text "No extra checks: only the rules that always apply."]]
        rows ->
          [ E.div
              [cls "ls-check"]
              [ E.h3 [] [E.text (rowCheck row)]
              , E.p [] [E.text ("When: " <> rowWhen row)]
              , E.p [] [E.text ("What is needed: " <> T.intercalate "; " (rowNeeds row))]
              , E.p [] [E.text ("Checked by: " <> T.intercalate "; " (rowCheckedBy row))]
              , E.p [] [E.text (rowApproval row <> ". " <> rowWaivable row <> ".")]
              , E.p [] [E.text ("Applies to: " <> rowAppliesTo row)]
              ]
          | row <- rows
          ]

standingWords :: Standing -> T.Text
standingWords standing =
  case standing of
    FirstInLine -> "First in line: it can start."
    InLine n -> "Number " <> T.pack (show n) <> " in line: it can start."
    CannotStartYet reasons -> "Cannot start yet: " <> T.unwords (fmap ineligibilityWords reasons)

queueSection :: Either T.Text [QueueEntry] -> [E.ChildHTML E.Division E.Body]
queueSection queue =
  [ E.h2 [] [E.text "Work waiting to start"]
  , case queue of
      Left _ -> E.p [cls "ls-notice"] [E.text "The work waiting to start cannot be shown right now. The exact reason is under Technical details."]
      Right [] -> E.p [] [E.text "No work in this project is waiting to start."]
      Right entries ->
        E.ul
          [cls "ls-projects"]
          [ E.li
              [cls (if canStart (entryStanding e) then "ls-good-text" else "ls-notice")]
              [E.text (entryTitle e <> " \8212 Matters: " <> priorityWords (priorityOf (entryPriority e)) <> " \8212 " <> standingWords (entryStanding e))]
          | e <- entries
          ]
  , E.p [cls "ls-muted"] [E.text "Lockstep does not start work by itself yet; this is the order it would use. How much a piece of work matters decides its place in line only once it can start."]
  ]
 where
  canStart standing =
    case standing of
      CannotStartYet _ -> False
      _ -> True

-- | The project page's section: the current choice in one line, the link, and the queue when there is any.
projectChecksSection :: ProjectChecks -> [E.ChildHTML E.Division E.Body]
projectChecksSection pc =
  [ E.h2 [] [E.text "How work is checked"]
  , E.p
      []
      [ E.text $
          case (checksSettable pc, checksCurrent pc) of
            (False, _) -> "Checks are chosen once the project has a folder."
            (True, Nothing) -> "No checks are chosen yet, so work in this project cannot start."
            (True, Just c) -> "Chosen: " <> choiceName c <> "."
      ]
  , E.p [] [E.a [href ("/app/projects/" <> projectId (checksProject pc) <> "/checks"), attr "id" "project-checks"] [E.text "See or change how work is checked"]]
  ]
    <> case checksQueue pc of
      Right [] -> []
      queue -> L.take 2 (queueSection queue)

choiceForm :: ProjectChecks -> E.ChildHTML E.Division E.Body
choiceForm pc =
  let
    expected = maybe "none" choiceId (checksCurrent pc)
    selected = maybe basicChecksId choiceId (checksCurrent pc)
    option c =
      E.div
        [cls "ls-choice"]
        [ E.input
            ( [ A.type_ HTML.InputRadio
              , attr "id" ("choice-" <> choiceId c)
              , attr "name" "choice"
              , attr "value" (choiceId c)
              ]
                <> [attr "checked" "checked" | choiceId c == selected]
            )
        , E.label
            [attr "for" ("choice-" <> choiceId c)]
            [E.text (choiceName c <> (if choiceBuiltIn c then " (recommended to start)" else "") <> " \8212 " <> summaryOf c)]
        ]
  in
    E.form
      [attr "id" "checks-form", A.method B.FormPOST, A.action (B.mkRawURL ("/app/api/projects/" <> projectId (checksProject pc) <> "/checks"))]
      [ E.input [A.type_ HTML.InputHidden, attr "name" "expected", attr "value" expected]
      , E.fieldset [] (E.legend [] [E.text "Which checks should apply?"] : fmap option (checksChoices pc))
      , E.div
          [cls "ls-choice"]
          [ E.input [A.type_ HTML.InputCheckbox, attr "id" "confirm-fewer", attr "name" "confirm_fewer", attr "value" "yes"]
          , E.label [attr "for" "confirm-fewer"] [E.text "I understand that this choice may stop requiring some checks."]
          ]
      , E.button [attr "id" "save-checks", attr "type" "submit", cls "ls-primary"] [E.text "Save"]
      ]

technical :: ProjectChecks -> E.ChildHTML E.Division E.Body
technical pc =
  E.details
    []
    [ E.summary [] [E.text "Technical details"]
    , E.dl
        [cls "ls-facts"]
        ( [ E.dt [] [E.text "Repository default Profile"]
          , E.dd [] [E.code [] [E.text (maybe "none" (\c -> choiceId c <> " version " <> T.pack (show (choiceVersion c)) <> " sha256 " <> choiceDigest c) (checksCurrent pc))]]
          ]
            <> L.concatMap kindFacts (checksRules pc)
            <> queueFacts
        )
    ]
 where
  kindFacts rules =
    [ E.dt [] [E.text ("Effective Profile for " <> workOrderKindName (rulesKind rules) <> " (" <> kindWords (rulesKind rules) <> ")")]
    , E.dd
        []
        [ E.code
            []
            [ E.text $
                case rulesOutcome rules of
                  Left code -> "refused: " <> code
                  Right e ->
                    T.unlines $
                      ["effective sha256 " <> rulesDigest e]
                        <> ["source " <> level <> " " <> p <> " version " <> T.pack (show v) <> " sha256 " <> d | (level, p, v, d) <- rulesSources e]
                        <> ["gates " <> (if L.null (rulesChecks e) then "none" else T.intercalate "," (fmap (gateIdText . gateId) (rulesChecks e)))]
            ]
        ]
    ]
  queueFacts =
    case checksQueue pc of
      Left code -> [E.dt [] [E.text "Scheduler preview"], E.dd [] [E.code [] [E.text ("unavailable: " <> code)]]]
      Right entries ->
        [ E.dt [] [E.text "Scheduler preview (Work Orders)"]
        , E.dd
            []
            [ E.code
                []
                [ E.text $
                    if L.null entries
                      then "none queued"
                      else T.unlines [entryOrder e <> " priority=" <> T.pack (show (entryPriority e)) <> " " <> codes (entryStanding e) | e <- entries]
                ]
            ]
        ]
  codes standing =
    case standing of
      FirstInLine -> "eligible 1"
      InLine n -> "eligible " <> T.pack (show n)
      CannotStartYet reasons -> "ineligible " <> T.intercalate "," (fmap ineligibilityCode reasons)

checksPage :: ProjectChecks -> Maybe T.Text -> LBS.ByteString
checksPage pc notice =
  let
    project = checksProject pc
  in
    fragment $
      [ E.h1 [] [E.text "How work is checked"]
      , E.p [cls "ls-muted"] [E.text ("In the project " <> projectName project)]
      ]
        <> [E.p [cls "ls-notice", attr "role" "alert"] [E.text n] | Just n <- [notice]]
        <> alwaysOn
        <> ( if checksSettable pc
               then
                 [ E.h2 [] [E.text "Extra checks"]
                 ]
                   <> ( case checksCurrent pc of
                          Nothing ->
                            [ E.p [cls "ls-notice"] [E.text "No checks are chosen for this project yet."]
                            , E.p [] [E.text "Until a choice is saved, work in this project cannot start. Always-on rules only is a safe first choice: it adds nothing to the rules above, and you can choose more checks later."]
                            ]
                          Just c -> E.p [] [E.text ("Chosen: " <> choiceName c)] : checklist c
                      )
                   <> [ E.h2 [] [E.text "Choose"]
                      , choiceForm pc
                      ]
               else [E.p [cls "ls-notice"] [E.text "This project has no folder yet, so there is nothing to check. Connect a folder on the project's page first."]]
           )
        <> queueSection (checksQueue pc)
        <> [ technical pc
           , E.p [] [E.a [href ("/app/projects/" <> projectId project), attr "id" "back-to-project"] [E.text ("Back to " <> projectName project)]]
           ]
