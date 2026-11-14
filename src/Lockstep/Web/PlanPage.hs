{-# LANGUAGE OverloadedStrings #-}

{- | A project's Master Plan page (contract C-P6.4 M5, M8): every revision,
newest first, with its state, digest, who proposed it, its units and their
needs, and its open questions; and for a proposed revision the owner's
digest-bound decision form. A proposal is shown as a proposal: nothing on this
page runs anything.
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

import Lockstep.Application.Plans (DraftView (..), PlanView (..), RevisionView (..))
import Lockstep.Kernel.Identity (ProjectId)
import Lockstep.Kernel.Plan (EdgeKind (..), PlanDocument (..), PlanEdge (..), PlanUnit (..), Uncertainty (..), unitKeyText)
import Lockstep.Web.Fields (decisionField, digestField, revisionField)
import Lockstep.Web.Fragment (attr, cls, elementId, fragment)
import Lockstep.Web.Routes.App (decidePlanAction, projectLink)

hidden :: B.Name -> T.Text -> E.ChildHTML E.Form E.Division
hidden name value =
  E.input [A.type_ HTML.InputHidden, A.name name, attr "value" value]

planPage :: ProjectId -> T.Text -> PlanView -> Maybe T.Text -> LBS.ByteString
planPage project name view notice =
  fragment $
    [E.h1 [] [E.text ("Plan: " <> name)]]
      <> maybe [] (\n -> [E.p [A.id (elementId 'n' "otice"), attr "role" "status"] [E.text n]]) notice
      <> [ E.p [] [E.text "A plan becomes work only when you approve it. Each approval is of one exact revision; a later change is a new revision for you to approve."]
         , E.h2 [] [E.text "In effect"]
         , E.p [A.id (elementId 'e' "ffective")] [E.text effectiveWords]
         ]
      <> L.concatMap revision (planViewRevisions view)
      <> drafts
      <> [E.p [] [E.a [A.href (projectLink project)] [E.text ("Back to " <> name)]]]
 where
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
    "changed" -> "changed: earlier work on it no longer counts"
    "invalidated" -> "unchanged, but it builds on something that changed, so earlier work on it no longer counts"
    "withdrawn" -> "no longer in the plan (its task is kept)"
    _ -> outcome

draftWords :: DraftView -> T.Text
draftWords d =
  case fmap T.unpack (draftOutcome d) of
    Nothing -> "Waiting for Lockstep to draft a plan from your document."
    Just "proposed" -> "Lockstep drafted a plan (" <> fromMaybe "" (draftCode d) <> "); it is listed above for your decision."
    Just "refused" -> "Lockstep's draft broke the plan's rules and was not proposed: " <> fromMaybe "" (draftCode d)
    Just "no-helper" -> "No coding helper is set up, so no plan was drafted."
    Just "uncertain" -> "Lockstep stopped while drafting; nothing was proposed. Ask again if you still want a draft."
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
