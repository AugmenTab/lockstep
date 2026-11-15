{-# LANGUAGE OverloadedStrings #-}

{- | A project's Master Plan page (contract C-P6.4 M5, M8): every revision,
newest first, with its state, digest, who proposed it, its units and their
needs, and its open questions; and for a proposed revision the owner's
digest-bound decision form. A proposal is shown as a proposal: nothing on this
page runs anything. C-P6.5 S7: for the plan in effect, what Lockstep hands over
next and why each other unit waits.
-}
module Lockstep.Web.PlanPage
  ( planPage
  , planDecisionWords
  ) where

import Brigid.HTML.Attributes qualified as A
import Brigid.HTML.Elements qualified as E
import Brigid.HTML.Types qualified as HTML
import Brigid.Types qualified as B
import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (show)

import Lockstep.Application.Dispatch (DispatchView (..))
import Lockstep.Application.Plans (DraftView (..), PlanView (..), RevisionView (..))
import Lockstep.Kernel.Identity (ProjectId)
import Lockstep.Kernel.Plan (EdgeKind (..), PlanDocument (..), PlanEdge (..), PlanUnit (..), Uncertainty (..), unitKeyText)
import Lockstep.Web.Fields (choiceField, decisionField, digestField, expectedField, expectedSetField, revisionField)
import Lockstep.Web.Fragment (attr, cls, elementId, fragment)
import Lockstep.Web.Routes.App (chooseChecksAction, decidePlanAction, projectLink)

hidden :: B.Name -> T.Text -> E.ChildHTML E.Form E.Division
hidden name value =
  E.input [A.type_ HTML.InputHidden, A.name name, attr "value" value]

planPage :: ProjectId -> T.Text -> PlanView -> Maybe DispatchView -> Maybe T.Text -> Maybe T.Text -> LBS.ByteString
planPage project name view next currentChecks notice =
  fragment $
    [E.h1 [] [E.text ("Plan: " <> name)]]
      <> maybe [] (\n -> [E.p [A.id (elementId 'n' "otice"), attr "role" "status"] [E.text n]]) notice
      <> [ E.p [] [E.text "A plan becomes work only when you approve it. Each approval is of one exact revision; a later change is a new revision for you to approve."]
         , E.h2 [] [E.text "In effect"]
         , E.p [A.id (elementId 'e' "ffective")] [E.text effectiveWords]
         ]
      <> maybe [] runsNext next
      <> engineeringOffer
      <> L.concatMap revision (planViewRevisions view)
      <> drafts
      <> [E.p [] [E.a [A.href (projectLink project)] [E.text ("Back to " <> name)]]]
 where
  {- C-P6.6 G3: a plan in effect with work other than bug fixes needs checks for that work; Lockstep's
  engineering checks hold them (and every bug check). The choice stays the owner's, on the checks' own form. -}
  engineeringOffer =
    case (currentChecks, next >>= dispatchViewRefusal) of
      -- R-P6.6-8: offered only when the next unit was refused because this project's checks do not cover it.
      (Just current, Just (_, code))
        | current /= "lockstep-engineering"
        , code `L.elem` ["kind-checks-missing", "profile-checks-missing"] ->
            [ E.h2 [] [E.text "Checks for this plan's work"]
            , E.p [] [E.text "This plan has work other than bug fixes: new features, a new build, tidying or documentation. Lockstep hands that work over only when this project's checks cover it. Lockstep's engineering checks do, and keep every bug check."]
            , E.form
                [A.id (elementId 'u' "se-engineering"), A.method B.FormPOST, A.action (chooseChecksAction project)]
                [ hidden expectedField current
                , hidden expectedSetField (if current == "none" then "no" else "yes")
                , hidden choiceField "lockstep-engineering"
                , E.button [attr "type" "submit"] [E.text "Use Lockstep's engineering checks"]
                ]
            ]
      _ -> []
  -- C-P6.5 S7: what Lockstep hands over next by itself, and why each other unit waits.
  runsNext d =
    let
      units = maybe [] (planUnits . revisionDocument) (planViewEffective view)
      titleOf k = maybe k unitTitle (L.find ((== k) . unitKeyText . unitKey) units)
    in
      [ E.h2 [] [E.text "What runs next"]
      , E.p [] [E.text "Lockstep hands the approved work over by itself, one piece at a time in this project's folder, as soon as what it needs is ready. It never marks anything Done: that stays yours."]
      , E.p
          [A.id (elementId 'n' "ext")]
          [E.text (maybe "Nothing can be handed over now." (\k -> "Next: " <> titleOf k <> ".") (dispatchViewNext d))]
      , E.ul
          [A.id (elementId 'w' "aiting")]
          [ E.li [attr "data-reason" code] [E.text (titleOf k <> ": " <> fromMaybe code (L.lookup k (dispatchViewWords d)))]
          | (k, code) <- dispatchViewWaiting d
          ]
      ]
  effectiveWords =
    case planViewEffective view of
      Nothing -> "No plan is approved for this project."
      Just r -> "Revision " <> T.pack (show (revisionNumber r)) <> " is approved and in effect."
  revision r =
    let
      document = revisionDocument r
      titleOf k = maybe (unitKeyText k) unitTitle (L.find ((== k) . unitKey) (planUnits document))
      questions = planUncertainties document
    in
      [ E.div
          [A.id (elementId 'r' ("evision-" <> T.pack (show (revisionNumber r)))), attr "data-state" (revisionState r)]
          ( [ E.h2 [] [E.text ("Revision " <> T.pack (show (revisionNumber r)) <> ": " <> planTitle document)]
            , E.p [] [E.text (stateWords r <> " " <> proposerWords r)]
            , E.p [cls "ls-muted"] [E.text "Its digest: ", E.code [] [E.text (revisionDigest r)]]
            , E.h3 [] [E.text "Work"]
            , E.ul
                []
                [ E.li
                    []
                    ( [E.text (unitTitle u <> " (" <> unitPhase u <> ")")]
                        <> [ E.text (" \8212 needs " <> titleOf (edgePrerequisite e) <> " (" <> edgeWords (edgeKind e) <> ")")
                           | e <- planEdges document
                           , edgeDependent e == unitKey u
                           ]
                    )
                | u <- planUnits document
                ]
            , E.h3 [] [E.text "Open questions"]
            ]
              <> case questions of
                [] -> [E.p [] [E.text "The plan names no open question."]]
                _ -> [E.ul [] [E.li [] [E.text (uncertaintyText q)] | q <- questions]]
              <> reconciliation r
              <> decisionForm r (L.length questions)
          )
      ]
  reconciliation r =
    case revisionReconciliation r of
      [] -> []
      outcomes -> [E.h3 [] [E.text "Against the plan before it"], E.ul [] [E.li [] [E.text (key <> ": " <> outcomeWords outcome)] | (key, outcome) <- outcomes]]
  decisionForm r count
    | revisionState r /= "proposed" = []
    | otherwise =
        E.p [] [E.text (questionCount count)]
          : [ E.form
                [A.id (elementId choice' (formId <> T.pack (show (revisionNumber r)))), A.method B.FormPOST, A.action (decidePlanAction project)]
                [ hidden revisionField (T.pack (show (revisionNumber r)))
                , hidden digestField (revisionDigest r)
                , hidden decisionField value
                , E.button [attr "type" "submit"] [E.text label]
                ]
            | (choice', formId, value, label) <- [('a', "pprove-", "approve", "Approve this plan"), ('r', "eject-", "reject", "Reject it")]
            ]
  drafts =
    case planViewDrafts view of
      [] -> []
      ds ->
        [ E.h2 [] [E.text "Drafts asked of Lockstep"]
        , E.ul [] [E.li [] [E.text (draftWords d)] | d <- ds]
        ]

questionCount :: Int -> T.Text
questionCount n =
  case n of
    0 -> "It has no open question."
    1 -> "It has 1 open question; approving does not answer it."
    _ -> "It has " <> T.pack (show n) <> " open questions; approving does not answer them."

stateWords :: RevisionView -> T.Text
stateWords r =
  case T.unpack (revisionState r) of
    "proposed" -> "Proposed, waiting for your decision;"
    "approved" -> "Approved by you and in effect;"
    "rejected" -> "Rejected by you;"
    "superseded" -> "Approved by you, then replaced by a newer approved revision;"
    _ -> revisionState r <> ";"

proposerWords :: RevisionView -> T.Text
proposerWords r =
  case T.unpack (revisionProposedBy r) of
    "Planner" -> "drafted by Lockstep from your documents."
    _ -> "proposed by a person."

edgeWords :: EdgeKind -> T.Text
edgeWords kind =
  case kind of
    Technical -> "needs it working"
    HumanAcceptance -> "needs your Done on it"
    External -> "needs something outside Lockstep"

outcomeWords :: T.Text -> T.Text
outcomeWords outcome =
  case T.unpack outcome of
    "added" -> "new in this revision"
    "kept" -> "unchanged"
    "changed" -> "changed: earlier work on it will need redoing (Lockstep does not enforce this yet)"
    "invalidated" -> "unchanged, but it builds on something that changed: earlier work on it will need redoing (Lockstep does not enforce this yet)"
    "withdrawn" -> "no longer in the plan (its task is kept)"
    _ -> outcome

draftWords :: DraftView -> T.Text
draftWords d =
  case fmap T.unpack (draftOutcome d) of
    Nothing -> "Waiting for Lockstep to draft a plan from your document."
    Just "proposed" -> "Lockstep drafted a plan (" <> fromMaybe "" (draftCode d) <> "); it is listed above for your decision."
    Just "refused" -> "Lockstep's draft broke the plan's rules and was not proposed: " <> fromMaybe "" (draftCode d)
    Just "no-helper" -> "No coding helper is set up, so no plan was drafted."
    Just "uncertain"
      | draftCode d == Just "worker-stopped" -> "Lockstep stopped while drafting; nothing was proposed. Ask again if you still want a draft."
      | otherwise -> "Lockstep could not tell whether the Planner finished, so nothing was proposed. Ask again if you still want a draft."
    Just _ -> "Lockstep could not draft a plan: " <> fromMaybe "" (draftCode d)

-- | A refused plan decision in words.
planDecisionWords :: T.Text -> T.Text
planDecisionWords code =
  case T.unpack code of
    "stale-digest" -> "The plan changed since this page was shown. Look at it again before deciding."
    "already-decided" -> "This revision was already decided; nothing changed."
    "superseded" -> "A newer revision is already approved, so this older one cannot be."
    "unknown-revision" -> "There is no such revision of this plan."
    "no-plan" -> "This project has no plan."
    _ -> "Lockstep could not record your decision. Look at the plan again."
