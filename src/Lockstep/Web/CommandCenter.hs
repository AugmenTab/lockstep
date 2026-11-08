{-# LANGUAGE QuasiQuotes #-}

{- | The command-center view (contract C-P1.6 E4–E10). Every disposition shown
is the effective one from "Lockstep.Foundation.EvidenceModel"; status is
always text, with colour only as a redundant cue.
-}
module Lockstep.Web.CommandCenter
  ( MatrixRow (..)
  , renderMatrix
  , commandCenterPage
  ) where

import Brigid.HTML.Attributes qualified as A
import Brigid.HTML.Elements qualified as E
import Brigid.HTML.Render.ByteString (renderLazyHTML)
import Brigid.HTML.Types qualified as HTML
import Brigid.Types qualified as B
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Maybe (fromMaybe)
import Data.String.Interpolate qualified as Interpolate
import Data.Text qualified as T
import Data.Time qualified as Time
import Flipstone.Prelude
import Text.Show (show)

import Lockstep.Application.CommandCenter
  ( Activity (..)
  , CenterView (..)
  , CommandCenter (..)
  , EvidenceRow (..)
  , SummaryRow (..)
  )
import Lockstep.Foundation.EvidenceModel
  ( Disposition (..)
  , EvidenceItem (..)
  , RowInput (..)
  , dispositionClass
  , dispositionLabel
  )
import Lockstep.Web.Components.Page (page)

data MatrixRow
  = MatrixRow
  { matrixInput :: RowInput
  , matrixEffective :: Disposition
  }

-- | The evidence matrix as an HTML fragment (for tests and the page).
renderMatrix :: [MatrixRow] -> BS.ByteString
renderMatrix rows =
  LBS.toStrict (renderLazyHTML (E.div [] [matrixTable rows] :: E.ChildHTML E.Body E.Html))

txt :: String -> T.Text
txt =
  T.pack

cls :: T.Text -> A.Attribute tag
cls =
  A.class_ . HTML.Class

custom :: String -> T.Text -> A.Attribute tag
custom name =
  A.customAttribute (T.pack name)

matrixTable :: [MatrixRow] -> E.ChildHTML E.Division grandparent
matrixTable rows =
  E.table
    [cls (txt "ls-matrix")]
    [ E.caption [] [E.text (txt "Evidence: criterion, method, expected, actual, disposition, evidence")]
    , E.thead
        []
        [ E.tr
            []
            (fmap (\h -> E.th [custom "scope" (txt "col")] [E.text (txt h)]) ["Criterion", "Method", "Expected", "Actual", "Disposition", "Evidence"])
        ]
    , E.tbody [] (fmap matrixRow rows)
    ]

matrixRow :: MatrixRow -> E.ChildHTML E.TableBody grandparent
matrixRow (MatrixRow input effective) =
  let
    label = dispositionLabel effective
  in
    E.tr
      [custom "data-criterion" (rowCriterion input), custom "data-disposition" label]
      [ E.th
          [custom "scope" (txt "row")]
          [ E.code [] [E.text (rowCriterion input)]
          , E.br []
          , E.span [cls (txt "ls-muted")] [E.text (rowStatement input)]
          ]
      , E.td [] [E.text (rowMethod input)]
      , E.td [] [E.text (rowExpected input)]
      , E.td [] [E.text (fromMaybe (txt "\8212") (rowActual input))]
      , E.td [] [E.span [cls (txt "ls-disposition " <> dispositionClass effective)] [E.text label]]
      , E.td [] (evidenceCell (rowEvidence input))
      ]

evidenceCell :: [EvidenceItem] -> [E.ChildHTML E.TableDataCell grandparent]
evidenceCell items =
  case items of
    [] -> [E.text (txt "none recorded")]
    _ ->
      [ E.code [] [E.text (evidenceLocator item <> txt " sha256:" <> T.take 12 (evidenceSha256 item))]
      | item <- items
      ]

commandCenterPage :: CommandCenter -> E.HTML
commandCenterPage center =
  page
    [Interpolate.i|Lockstep command center|]
    [ E.main
        [cls (txt "ls-wide")]
        ( [ E.h1 [] [E.text (txt "Command center")]
          , E.p
              []
              [ E.text (txt "Read from the database when this page was rendered. ")
              , E.a [A.href (B.mkRawURL (txt "/operator/center"))] [E.text (txt "Refresh")]
              , E.text (txt " · ")
              , E.a [A.href (B.mkRawURL (txt "/operator"))] [E.text (txt "Rename the workspace")]
              , E.text (txt " · ")
              , E.a [A.href (B.mkRawURL (txt "/operator/jobs/new"))] [E.text (txt "Queue a no-op job")]
              ]
          ]
            <> body center
        )
    ]

body :: CommandCenter -> [E.ChildHTML E.Main grandparent]
body center =
  case center of
    CenterUnavailable _ ->
      [ E.p
          [cls (txt "ls-notice")]
          [E.text (txt "Unavailable: the database is not ready, so no status or evidence can be shown. See the status page and lockstep db status.")]
      ]
    CenterReady (CenterView schema summaryRows activity evidence aggregateDisposition) ->
      [ E.h2 [] [E.text (txt "Status")]
      , summaryTable summaryRows
      , E.h2 [] [E.text (txt "Evidence")]
      , E.p
          [custom "data-aggregate" (dispositionLabel aggregateDisposition)]
          [ E.text (txt "Machine summary (worst required row; not acceptance): ")
          , E.span [cls (txt "ls-disposition " <> dispositionClass aggregateDisposition)] [E.text (dispositionLabel aggregateDisposition)]
          , E.text (txt (" · judged at " <> T.unpack schema))
          ]
      , E.div [] [matrixTable (fmap (\r -> MatrixRow (evidenceInput r) (evidenceEffective r)) evidence)]
      , E.h2 [] [E.text (txt "Recent commands")]
      , activityTable activity
      ]

summaryTable :: [SummaryRow] -> E.ChildHTML E.Main grandparent
summaryTable rows =
  E.table
    [cls (txt "ls-summary")]
    [ E.caption [] [E.text (txt "Counts of jobs and command receipts, by status")]
    , E.thead
        []
        [E.tr [] (fmap (\h -> E.th [custom "scope" (txt "col")] [E.text (txt h)]) ["Status", "Count", "Meaning"])]
    , E.tbody
        []
        [ E.tr
            [custom "data-status" (summarySection r <> txt ":" <> summaryStatus r), custom "data-count" (T.pack (show (summaryCount r)))]
            [ E.th [custom "scope" (txt "row")] [E.text (summarySection r <> txt ": "), E.code [] [E.text (summaryStatus r)]]
            , E.td [cls (txt "ls-count")] [E.text (T.pack (show (summaryCount r)))]
            , E.td [] [E.text (summaryDescription r)]
            ]
        | r <- rows
        ]
    ]

activityTable :: [Activity] -> E.ChildHTML E.Main grandparent
activityTable rows =
  E.table
    [cls (txt "ls-activity")]
    [ E.caption [] [E.text (txt "The newest 20 command receipts")]
    , E.thead
        []
        [E.tr [] (fmap (\h -> E.th [custom "scope" (txt "col")] [E.text (txt h)]) ["Receipt", "Command", "Outcome", "Revision", "Actor", "Accepted", "Job"])]
    , E.tbody
        []
        [ E.tr
            []
            [ E.th
                [custom "scope" (txt "row")]
                [E.a [A.href (B.mkRawURL (T.pack ("/operator/receipts/" <> show (activityReceipt r))))] [E.text (T.pack (show (activityReceipt r)))]]
            , E.td [] [E.text (activityKind r)]
            , E.td [] [E.code [] [E.text (activityOutcome r)]]
            , E.td [] [E.text (T.pack (show (activityRevision r)))]
            , E.td [] [E.text (activityActor r)]
            , E.td [] [E.text (T.pack (Time.formatTime Time.defaultTimeLocale "%Y-%m-%d %H:%M:%S UTC" (activityAcceptedAt r)))]
            , E.td [] [E.text (fromMaybe (txt "\8212") (activityJobState r))]
            ]
        | r <- rows
        ]
    ]
