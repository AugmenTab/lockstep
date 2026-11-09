{-# LANGUAGE OverloadedStrings #-}

{- | Increment E of the type-discipline remediation (2026-11-09): the typed web
layer. Every link the pages use is generated from a route of the tree that
recognises it, at the frozen address; a path parameter that is not a canonical
id is no route; forms are read strictly (UTF-8, one value per field) by
validators that accumulate one error per field, under the field names the pages
use.
-}
module Lockstep.Compliance.WebTest
  ( tests
  ) where

import Brigid.Types qualified as B
import Data.List qualified as L
import Data.Maybe (isJust, isNothing)
import Data.Text qualified as T
import Flipstone.Prelude
import Network.HTTP.Types qualified as HTTP
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

import Lockstep.Kernel.Effect (OperationId (..))
import Lockstep.Kernel.Identity (ProjectId (..), ReceiptId (..), TaskId (..), TransactionId (..), WorkOrderId (..), parseIdentity)
import Lockstep.Web.App (appRouteClass, matchAppRoute)
import Lockstep.Web.Fields (keyField, nameField, titleField)
import Lockstep.Web.Form (readForm)
import Lockstep.Web.Operator (matchOperatorRoute)
import Lockstep.Web.RequestGuard (RouteClass (..))
import Lockstep.Web.Routes.App qualified as App
import Lockstep.Web.Routes.Operator qualified as Operator
import Lockstep.Web.Routes.Params (stoppedWorkKey, unknownOutcomeKey)
import Lockstep.Web.Validation qualified as V

uuidA :: T.Text
uuidA =
  "0b6f1c2e-6a2d-4c55-9d0e-3f1a2b3c4d5e"

parsed :: (T.Text -> Maybe a) -> IO a
parsed parse =
  maybe (assertFailure "the fixture id did not parse") pure (parse uuidA)

pathOf :: B.RelativeURL method -> [T.Text]
pathOf url =
  L.drop 1 (T.splitOn "/" (B.relativeURLToText url))

-- | The link renders at the frozen address and the application recognises it, with the expected guard class.
appLink :: HTTP.StdMethod -> T.Text -> RouteClass -> B.RelativeURL method -> Assertion
appLink method expected routeClass url = do
  B.relativeURLToText url @?= expected
  case matchAppRoute method (pathOf url) of
    Nothing -> assertFailure ("not recognised: " <> T.unpack expected)
    Just route -> appRouteClass route @?= routeClass

tests :: TestTree
tests =
  testGroup
    "Increment E: typed routes, links and validation"
    [ testCase "every application link is generated from a route the tree recognises, at the frozen address" $ do
        pid <- parsed parseIdentity :: IO ProjectId
        tid <- parsed parseIdentity :: IO TaskId
        xid <- parsed parseIdentity :: IO TransactionId
        appLink HTTP.GET ("/app/projects/" <> uuidA) PublicRead (App.projectLink pid)
        appLink HTTP.GET ("/app/projects/" <> uuidA <> "/tasks/new") PublicRead (App.newTaskLink pid)
        appLink HTTP.GET ("/app/projects/" <> uuidA <> "/checks") PublicRead (App.checksLink pid)
        appLink HTTP.GET ("/app/tasks/" <> uuidA) PublicRead (App.taskLink tid)
        appLink HTTP.GET "/app/projects/new" PublicRead App.newProjectLink
        appLink HTTP.GET "/app/decisions" PublicRead (App.sectionLink App.Decisions)
        appLink HTTP.POST "/app/api/projects" OperatorRoute App.createProjectAction
        appLink HTTP.POST ("/app/api/projects/" <> uuidA <> "/connect") OperatorRoute (App.connectProjectAction pid)
        appLink HTTP.POST ("/app/api/projects/" <> uuidA <> "/tasks") OperatorRoute (App.createTaskAction pid)
        appLink HTTP.POST ("/app/api/projects/" <> uuidA <> "/checks") OperatorRoute (App.chooseChecksAction pid)
        appLink HTTP.POST ("/app/api/projects/" <> uuidA <> "/execution") OperatorRoute (App.enableExecutionAction pid)
        appLink HTTP.POST ("/app/api/tasks/" <> uuidA <> "/edit") OperatorRoute (App.editTaskAction tid)
        appLink HTTP.POST ("/app/api/tasks/" <> uuidA <> "/decide") OperatorRoute (App.decideTaskAction tid)
        appLink HTTP.POST ("/app/api/tasks/" <> uuidA <> "/bug") OperatorRoute (App.admitBugAction tid)
        appLink HTTP.POST ("/app/api/transactions/" <> uuidA <> "/decision") OperatorRoute (App.haltDecisionAction xid)
        appLink HTTP.POST ("/app/api/transactions/" <> uuidA <> "/completion") OperatorRoute (App.completionAction xid)
    , testCase "a decision's address is the same for stopped work and an unknown outcome of the same UUID" $ do
        wo <- parsed parseIdentity :: IO WorkOrderId
        op <- parsed parseIdentity :: IO OperationId
        appLink HTTP.GET ("/app/decisions/" <> uuidA) PublicRead (App.decisionLink (stoppedWorkKey wo))
        appLink HTTP.GET ("/app/decisions/" <> uuidA) PublicRead (App.decisionLink (unknownOutcomeKey op))
        appLink HTTP.POST ("/app/api/decisions/" <> uuidA) OperatorRoute (App.decideAction (stoppedWorkKey wo))
    , testCase "a path id that is not canonical is no route; neither is a method the route does not take" $ do
        assertBool "non-uuid" (isNothing (matchAppRoute HTTP.GET ["app", "projects", "not-a-uuid"]))
        assertBool "upper case" (isNothing (matchAppRoute HTTP.GET ["app", "tasks", T.toUpper uuidA]))
        assertBool "fragment" (isNothing (matchAppRoute HTTP.GET ["app", "fragments", "task", "x"]))
        assertBool "wrong method" (isNothing (matchAppRoute HTTP.POST ["app", "projects", uuidA]))
        assertBool "unknown section" (isNothing (matchAppRoute HTTP.GET ["app", "admin"]))
        assertBool "HEAD is the GET" (isJust (matchAppRoute HTTP.HEAD ["app", "home"]))
    , testCase "operator links come from the operator tree; a receipt number out of range is no route" $ do
        B.relativeURLToText (Operator.receiptLink (ReceiptId 42)) @?= "/operator/receipts/42"
        assertBool "receipt link" (isJust (matchOperatorRoute HTTP.GET (pathOf (Operator.receiptLink (ReceiptId 42)))))
        assertBool "centre link" (isJust (matchOperatorRoute HTTP.GET (pathOf Operator.centerLink)))
        assertBool "sign-out is a POST" (isJust (matchOperatorRoute HTTP.POST (pathOf Operator.signOutAction)))
        assertBool "abc" (isNothing (matchOperatorRoute HTTP.GET ["operator", "receipts", "abc"]))
        assertBool "too long" (isNothing (matchOperatorRoute HTTP.GET ["operator", "receipts", "9999999999999999999"]))
        assertBool "signed" (isNothing (matchOperatorRoute HTTP.GET ["operator", "receipts", "+1"]))
    , testCase "a form is read strictly: names and values must be UTF-8" $ do
        assertBool "UTF-8" (isJust (readForm "name=caf%C3%A9"))
        assertBool "not UTF-8" (isNothing (readForm "name=%FF"))
    , testCase "validators accumulate one error per field, under the pages' field names" $ do
        form <- maybe (assertFailure "form") pure (readForm "title=a&title=b")
        case V.runValidator ((,,) <$> keyField `V.required` V.text <*> titleField `V.required` V.text <*> nameField `V.optional` V.text) form of
          Right _ -> assertFailure "accepted"
          Left errs -> do
            assertBool "the missing key" (V.hasError keyField errs)
            assertBool "the repeated title" (V.hasError titleField errs)
            assertBool "an absent optional field is no error" (not (V.hasError nameField errs))
    ]
