{-# LANGUAGE OverloadedStrings #-}

module Lockstep.Kernel.RepositoryTest
  ( tests
  ) where

import Data.List qualified as L
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase, (@?=))
import Text.Show (show)

import Lockstep.Kernel.Identity (EngineerId (..), RepositoryId (..), uuidFromWords)
import Lockstep.Kernel.Repository
  ( AuthoritativeRemote (..)
  , OwnedRepository (..)
  , Ownership (..)
  , PhysicalId (..)
  , RegistrationRefusal (..)
  , RegistrationRequest (..)
  , RemoteIdentity (..)
  , RepositoryObservation (..)
  , decideRegistration
  , refusalCode
  , renderObservation
  )

tests :: TestTree
tests =
  testGroup
    "Kernel repository registration (C-P2.1 I6, DG-03 D-3.3d/D-3.5a)"
    [ testCase "an unrelated repository is accepted for an Engineer without one" $
        accepted [owned1] (request 9 2 unrelated)
    , testCase "duplicate physical identity, same Engineer: repository-already-owned" $
        refusedWith [owned1] (request 9 1 orig) (RepositoryAlreadyOwned own1)
    , testCase "duplicate physical identity, other Engineer: repository-already-owned" $
        refusedWith [owned1] (request 9 2 orig) (RepositoryAlreadyOwned own1)
    , testCase "symlink or case alias (other display path, same physical identity): repository-already-owned" $
        refusedWith [owned1] (request 9 2 orig {observedCommonDir = "/w/ORIG/.git"}) (RepositoryAlreadyOwned own1)
    , testCase "same canonical path with a new physical identity (device renumbered): repository-already-owned" $
        refusedWith [owned1] (request 9 2 orig {observedPhysical = PhysicalId 99 99}) (RepositoryAlreadyOwned own1)
    , testCase "case-sensitive filesystem: Proj and proj are different repositories" $ do
        let
          upper = noRemote "/r/Proj/.git" (PhysicalId 5 1)
          lower = noRemote "/r/proj/.git" (PhysicalId 5 2)
        accepted [owned 1 1 upper] (request 9 2 lower)
    , testCase "duplicate clone (other directory, same authoritative network remote): authoritative-remote-owned" $
        refusedWith
          [owned1]
          (request 9 2 (withRemote "/w/clone/.git" (PhysicalId 1 20) "origin" githubOwnerRepo))
          (AuthoritativeRemoteOwned own1)
    , testCase "a clone pushing into the owned repository's common directory: remote-is-owned-repository" $
        refusedWith
          [owned1]
          (request 9 2 (withRemote "/w/clone/.git" (PhysicalId 1 20) "origin" (LocalIdentity (PhysicalId 1 10) "/w/orig/.git")))
          (RemoteIsOwnedRepository own1)
    , testCase "an owned repository pushing into the candidate: owned-repository-pushes-here" $ do
        let
          bareUpstream = noRemote "/srv/up.git" (PhysicalId 1 30)
          ownedClone = owned 1 1 (withRemote "/w/clone/.git" (PhysicalId 1 20) "origin" (LocalIdentity (PhysicalId 1 30) "/srv/up.git"))
        refusedWith [ownedClone] (request 9 2 bareUpstream) (OwnedRepositoryPushesHere (ownership 1 1))
    , testCase "two clones of one local bare repository: authoritative-remote-owned" $ do
        let
          bare = LocalIdentity (PhysicalId 1 30) "/srv/up.git"
          first = owned 1 1 (withRemote "/w/a/.git" (PhysicalId 1 21) "origin" bare)
        refusedWith [first] (request 9 2 (withRemote "/w/b/.git" (PhysicalId 1 22) "origin" bare)) (AuthoritativeRemoteOwned (ownership 1 1))
    , testCase "a fork (own authoritative remote; owned upstream only as another remote) is eligible" $
        accepted
          [owned1]
          ( request
              9
              2
              (withRemote "/w/fork/.git" (PhysicalId 1 40) "origin" (NetworkIdentity "github.com" "bob/repo-fork"))
                { observedOtherRemotes = ["upstream"]
                }
          )
    , testCase "shared ancestry alone (remote-less clone in another directory) is eligible" $
        accepted [owned1] (request 9 2 (noRemote "/w/copy/.git" (PhysicalId 1 50)))
    , testCase "a template-derived project is eligible" $
        accepted
          [owned1]
          ( request
              9
              2
              (withRemote "/w/app/.git" (PhysicalId 1 60) "origin" (NetworkIdentity "github.com" "dave/app"))
                { observedOtherRemotes = ["template"]
                }
          )
    , testCase "an Engineer who already owns a repository: engineer-already-owns-repository" $
        refusedWith [owned1] (request 9 1 unrelated) (EngineerAlreadyOwnsRepository (repoId 1))
    , testCase "a repository conflict is reported before the Engineer conflict" $
        refusedWith [owned1] (request 9 1 orig) (RepositoryAlreadyOwned own1)
    , testCase "a reused RepositoryId: repository-id-in-use" $
        refusedWith [owned1] (request 1 2 unrelated) RepositoryIdInUse
    , testCase "the result does not depend on the order of the owned list" $ do
        let
          others =
            [ owned 2 2 (noRemote "/w/two/.git" (PhysicalId 2 2))
            , owned 3 3 (withRemote "/w/three/.git" (PhysicalId 2 3) "origin" githubOwnerRepo)
            , owned 4 4 (withRemote "/w/four/.git" (PhysicalId 2 4) "origin" (LocalIdentity (PhysicalId 2 2) "/w/two/.git"))
            ]
          candidates =
            [ request 9 5 (withRemote "/w/x/.git" (PhysicalId 3 1) "origin" githubOwnerRepo)
            , request 9 5 (noRemote "/w/two/.git" (PhysicalId 2 2))
            , request 9 5 (noRemote "/w/new/.git" (PhysicalId 3 2))
            , request 9 2 (noRemote "/w/new/.git" (PhysicalId 3 2))
            ]
        traverse_
          ( \candidate -> do
              let
                results = fmap (\perm -> codeOf (decideRegistration perm candidate)) (L.permutations others)
              L.length (L.nub results) @?= 1
          )
          candidates
    , testCase "the identity carried by an accepted registration is the requested RepositoryId" $
        case decideRegistration [owned1] (request 9 2 unrelated) of
          Right result -> ownedOwnership result @?= ownership 9 2
          Left refusal -> assertFailure ("refused: " <> show refusal)
    , testCase "the observation rendering is deterministic and covers every field" $ do
        renderObservation orig @?= renderObservation orig
        (renderObservation orig == renderObservation orig {observedOtherRemotes = ["upstream"]}) @?= False
        (renderObservation orig == renderObservation orig {observedPhysical = PhysicalId 1 11}) @?= False
    , testCase "decision refusal codes" $ do
        refusalCode (RepositoryAlreadyOwned own1) @?= "repository-already-owned"
        refusalCode (AuthoritativeRemoteOwned own1) @?= "authoritative-remote-owned"
        refusalCode (RemoteIsOwnedRepository own1) @?= "remote-is-owned-repository"
        refusalCode (OwnedRepositoryPushesHere own1) @?= "owned-repository-pushes-here"
        refusalCode (EngineerAlreadyOwnsRepository (repoId 1)) @?= "engineer-already-owns-repository"
        refusalCode RepositoryIdInUse @?= "repository-id-in-use"
    , testCase "observation refusal codes" $
        fmap
          refusalCode
          [ PathNotFound
          , NotADirectory
          , NotAGitRepository
          , BareRepository
          , NotTopLevel
          , LinkedWorktree
          , Submodule
          , UnsupportedGitLayout
          , ShallowRepository
          , GitUnavailable
          , GitTimedOut
          , GitFailed "x"
          ]
          @?= [ "path-not-found"
              , "not-a-directory"
              , "not-a-git-repository"
              , "bare-repository"
              , "not-top-level"
              , "linked-worktree"
              , "submodule"
              , "unsupported-git-layout"
              , "shallow-repository"
              , "git-unavailable"
              , "git-timed-out"
              , "git-failed"
              ]
    ]

githubOwnerRepo :: RemoteIdentity
githubOwnerRepo =
  NetworkIdentity "github.com" "owner/repo"

orig :: RepositoryObservation
orig =
  withRemote "/w/orig/.git" (PhysicalId 1 10) "origin" githubOwnerRepo

unrelated :: RepositoryObservation
unrelated =
  withRemote "/w/other/.git" (PhysicalId 1 11) "origin" (NetworkIdentity "github.com" "someone/else")

own1 :: Ownership
own1 =
  ownership 1 1

owned1 :: OwnedRepository
owned1 =
  owned 1 1 orig

noRemote :: T.Text -> PhysicalId -> RepositoryObservation
noRemote dir physical =
  RepositoryObservation
    { observedCommonDir = dir
    , observedPhysical = physical
    , observedAuthoritative = Nothing
    , observedOtherRemotes = []
    }

withRemote :: T.Text -> PhysicalId -> T.Text -> RemoteIdentity -> RepositoryObservation
withRemote dir physical name identity =
  (noRemote dir physical) {observedAuthoritative = Just (AuthoritativeRemote name identity)}

-- Distinct fixed identities: the n-th repository or Engineer UUID.
repoId :: Word8 -> RepositoryId
repoId n =
  RepositoryId (uuidFromWords 1 (fromIntegral n))

engineerId :: Word8 -> EngineerId
engineerId n =
  EngineerId (uuidFromWords 2 (fromIntegral n))

ownership :: Word8 -> Word8 -> Ownership
ownership r e =
  Ownership {ownershipRepository = repoId r, ownershipEngineer = engineerId e}

owned :: Word8 -> Word8 -> RepositoryObservation -> OwnedRepository
owned r e observation =
  OwnedRepository {ownedOwnership = ownership r e, ownedObservation = observation}

request :: Word8 -> Word8 -> RepositoryObservation -> RegistrationRequest
request r e observation =
  RegistrationRequest {requestRepository = repoId r, requestEngineer = engineerId e, requestObservation = observation}

codeOf :: Either RegistrationRefusal a -> T.Text
codeOf =
  either refusalCode (const "accepted")

accepted :: [OwnedRepository] -> RegistrationRequest -> Assertion
accepted owners candidate =
  case decideRegistration owners candidate of
    Right result -> ownedObservation result @?= requestObservation candidate
    Left refusal -> assertFailure ("expected acceptance, got " <> show refusal)

refusedWith :: [OwnedRepository] -> RegistrationRequest -> RegistrationRefusal -> Assertion
refusedWith owners candidate expected =
  case decideRegistration owners candidate of
    Right _ -> assertFailure ("expected " <> show expected <> ", got acceptance")
    Left refusal -> refusal @?= expected
