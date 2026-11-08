{-# LANGUAGE OverloadedStrings #-}

module Lockstep.Kernel.WorkUnitTest
  ( tests
  ) where

import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Kernel.Identity
  ( EngineerId (..)
  , RepositoryId (..)
  , TicketId (..)
  , WorkOrderId (..)
  , WorkUnitId (..)
  , uuidFromWords
  )
import Lockstep.Kernel.Repository (Ownership (..))
import Lockstep.Kernel.WorkUnit
  ( AdmittedWorkUnit (..)
  , PlanRef
  , WorkUnitRefusal (..)
  , WorkUnitRequest (..)
  , admitWorkUnit
  , mkPlanRef
  )

tests :: TestTree
tests =
  testGroup
    "Kernel Work Unit identity (C-P2.1 I7, FR-WRK-01)"
    [ testCase "a Ticket-originated Work Unit with no plan reference is admitted with the owning Engineer" $
        case admitWorkUnit [ownedRepo] (request Nothing) of
          Right admitted -> do
            admittedEngineer admitted @?= engineer
            wuPlanRef (admittedRequest admitted) @?= Nothing
            wuTicket (admittedRequest admitted) @?= ticket
          Left refusal -> assertFailure ("refused: " <> show refusal)
    , testCase "a plan reference is optional ancestry and is kept when given" $
        case mkPlanRef "phase-02 P2.1" of
          Nothing -> assertFailure "a valid plan reference was refused"
          Just ref ->
            fmap (wuPlanRef . admittedRequest) (admitWorkUnit [ownedRepo] (request (Just ref))) @?= Right (Just ref)
    , testCase "a Work Unit for a repository without an active owner is refused" $
        fmap admittedEngineer (admitWorkUnit [] (request Nothing))
          @?= Left (WorkUnitRepositoryNotOwned repository)
    , testCase "another repository's ownership does not admit it" $
        fmap
          admittedEngineer
          (admitWorkUnit [Ownership (RepositoryId (uuidFromWords 1 2)) engineer] (request Nothing))
          @?= Left (WorkUnitRepositoryNotOwned repository)
    , testCase "plan references: empty, control characters and 201 characters are refused; 200 accepted" $ do
        fmap (const ()) (mkPlanRef "") @?= Nothing
        fmap (const ()) (mkPlanRef "a\nb") @?= Nothing
        fmap (const ()) (mkPlanRef (T.replicate 201 "a")) @?= Nothing
        fmap (const ()) (mkPlanRef (T.replicate 200 "a")) @?= Just ()
    ]

repository :: RepositoryId
repository =
  RepositoryId (uuidFromWords 1 1)

engineer :: EngineerId
engineer =
  EngineerId (uuidFromWords 2 1)

ticket :: TicketId
ticket =
  TicketId (uuidFromWords 3 1)

ownedRepo :: Ownership
ownedRepo =
  Ownership repository engineer

request :: Maybe PlanRef -> WorkUnitRequest
request planRef =
  WorkUnitRequest
    { wuId = WorkUnitId (uuidFromWords 4 1)
    , wuRepository = repository
    , wuTicket = ticket
    , wuWorkOrder = WorkOrderId (uuidFromWords 5 1)
    , wuPlanRef = planRef
    }
