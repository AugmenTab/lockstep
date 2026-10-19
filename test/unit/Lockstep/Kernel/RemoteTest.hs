{-# LANGUAGE OverloadedStrings #-}

module Lockstep.Kernel.RemoteTest
  ( tests
  ) where

import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Text qualified as T
import Flipstone.Prelude
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

import Lockstep.Kernel.Repository
  ( AuthoritativeRemote (..)
  , PhysicalId (..)
  , RegistrationRefusal (..)
  , RemoteConfig (..)
  , RemoteIdentity (..)
  , RemoteLocator (..)
  , parseRemoteUrl
  , refusalCode
  , remoteIdentityText
  , sameRemote
  , selectAuthoritative
  , settleAuthoritative
  )

tests :: TestTree
tests =
  testGroup
    "Kernel remotes (C-P2.1 I4, I5)"
    [ testGroup
        "parsing and normalization"
        [ testCase "scp, ssh, git+ssh, git and https forms of one GitHub repository are one identity" $
            traverse_
              (\url -> network url @?= Just ("github.com", "owner/repo"))
              [ "git@github.com:Owner/Repo.git"
              , "github.com:owner/repo"
              , "ssh://git@github.com/owner/repo.git"
              , "ssh://git@github.com:22/Owner/Repo"
              , "git+ssh://git@github.com/owner/repo"
              , "ssh+git://github.com/owner/repo/"
              , "git://github.com/owner/repo.git"
              , "https://github.com/Owner/Repo"
              , "https://user:token@GitHub.com:443/owner/repo.git/"
              , "https://github.com./owner//repo"
              ]
        , testCase "GitLab and Bitbucket paths are lowercased" $ do
            network "git@gitlab.com:Group/Sub/Proj.git" @?= Just ("gitlab.com", "group/sub/proj")
            network "https://bitbucket.org/Team/Repo" @?= Just ("bitbucket.org", "team/repo")
        , testCase "another host's path case is kept (no blind case-folding)" $ do
            network "https://git.example.com/Team/Repo.git" @?= Just ("git.example.com", "Team/Repo")
            (network "https://git.example.com/Team/Repo" == network "https://git.example.com/team/repo") @?= False
        , testCase "a different owner or name is a different identity" $ do
            (network "git@github.com:owner/repo" == network "git@github.com:other/repo") @?= False
            (network "git@github.com:owner/repo" == network "git@github.com:owner/repo2") @?= False
            (network "git@github.com:owner/repo" == network "git@gitlab.com:owner/repo") @?= False
        , testCase "file URLs and plain paths are local" $ do
            parseRemoteUrl "file:///srv/git/repo.git" @?= Just (LocalLocator "/srv/git/repo.git")
            parseRemoteUrl "file://localhost/srv/git/repo.git" @?= Just (LocalLocator "/srv/git/repo.git")
            parseRemoteUrl "/srv/git/repo.git" @?= Just (LocalLocator "/srv/git/repo.git")
            parseRemoteUrl "../orig" @?= Just (LocalLocator "../orig")
            parseRemoteUrl "./orig" @?= Just (LocalLocator "./orig")
        , testCase "helpers, unknown schemes, foreign file hosts and empty paths are unsupported" $
            traverse_
              (\url -> parseRemoteUrl url @?= Nothing)
              [ "ext::sh -c x"
              , "foo::bar"
              , "file://otherhost/srv/repo"
              , "svn://host/path"
              , ""
              , "host:"
              , "https://github.com/"
              , "https://github.com/owner/../repo"
              , "git@github.com:owner/./repo"
              , "https:///owner/repo"
              ]
        ]
    , testGroup
        "authoritative remote selection"
        [ testCase "no remotes: no authoritative remote" $
            selected Nothing [] @?= Right Nothing
        , testCase "one remote: it is authoritative" $
            selected Nothing [remote "origin" ["git@github.com:o/r.git"] ["git@github.com:o/r.git"]]
              @?= Right (Just ("origin", [NetworkLocator "github.com" "o/r"]))
        , testCase "two remotes without a choice: ambiguous, names sorted" $
            codeAndArgs
              ( selected
                  Nothing
                  [ remote "upstream" ["git@github.com:t/r"] []
                  , remote "origin" ["git@github.com:o/r"] []
                  ]
              )
              @?= Left (AuthoritativeRemoteAmbiguous ["origin", "upstream"])
        , testCase "a chosen existing remote is authoritative; the others are not identity" $
            selected
              (Just "origin")
              [ remote "upstream" ["git@github.com:t/r"] []
              , remote "origin" ["git@github.com:o/r"] []
              ]
              @?= Right (Just ("origin", [NetworkLocator "github.com" "o/r"]))
        , testCase "a chosen missing remote: unknown" $
            codeAndArgs (selected (Just "nope") [remote "origin" ["git@github.com:o/r"] []])
              @?= Left (AuthoritativeRemoteUnknown "nope")
        , testCase "an unparseable URL of the authoritative remote: unsupported" $
            codeAndArgs (selected Nothing [remote "origin" ["ext::sh -c x"] []])
              @?= Left (RemoteUrlUnsupported "origin")
        , testCase "a remote with no URL at all: unsupported" $
            codeAndArgs (selected Nothing [remote "origin" [] []])
              @?= Left (RemoteUrlUnsupported "origin")
        , testCase "fetch and push URLs in different forms of one identity settle" $
            fmap
              authoritativeName
              (settleAuthoritative "origin" (NetworkIdentity "github.com" "o/r" :| [NetworkIdentity "github.com" "o/r"]))
              @?= Right "origin"
        , testCase "fetch and push to different repositories: inconsistent" $
            fmap
              authoritativeName
              (settleAuthoritative "origin" (NetworkIdentity "github.com" "o/r" :| [NetworkIdentity "github.com" "x/r"]))
              @?= Left (AuthoritativeRemoteInconsistent "origin")
        , testCase "two local spellings with one physical identity settle" $
            fmap
              (remoteIdentityText . authoritativeIdentity)
              (settleAuthoritative "origin" (LocalIdentity (PhysicalId 1 7) "/a/orig/.git" :| [LocalIdentity (PhysicalId 1 7) "/A/orig/.git"]))
              @?= Right (remoteIdentityText (LocalIdentity (PhysicalId 1 7) "/a/orig/.git"))
        , testCase "local identities compare by physical identity only" $ do
            sameRemote (LocalIdentity (PhysicalId 1 7) "/a") (LocalIdentity (PhysicalId 1 7) "/b") @?= True
            sameRemote (LocalIdentity (PhysicalId 1 7) "/a") (LocalIdentity (PhysicalId 1 8) "/a") @?= False
            sameRemote (NetworkIdentity "h" "p") (NetworkIdentity "h" "p") @?= True
            sameRemote (NetworkIdentity "h" "p") (LocalIdentity (PhysicalId 1 7) "h/p") @?= False
        , testCase "selection refusals have their codes" $ do
            refusalCode (AuthoritativeRemoteAmbiguous []) @?= "authoritative-remote-ambiguous"
            refusalCode (AuthoritativeRemoteUnknown "x") @?= "authoritative-remote-unknown"
            refusalCode (AuthoritativeRemoteInconsistent "x") @?= "authoritative-remote-inconsistent"
            refusalCode (RemoteUrlUnsupported "x") @?= "remote-url-unsupported"
            refusalCode (RemoteUnresolvable "x") @?= "remote-unresolvable"
        ]
    ]

network :: T.Text -> Maybe (T.Text, T.Text)
network url =
  case parseRemoteUrl url of
    Just (NetworkLocator host path) -> Just (host, path)
    _ -> Nothing

remote :: T.Text -> [T.Text] -> [T.Text] -> RemoteConfig
remote name fetch push =
  RemoteConfig {remoteName = name, remoteFetchUrls = fetch, remotePushUrls = push}

-- The selection with the locators as a deduplicated list, for comparison.
selected :: Maybe T.Text -> [RemoteConfig] -> Either RegistrationRefusal (Maybe (T.Text, [RemoteLocator]))
selected choice remotes =
  fmap (fmap (\(name, locators :| rest) -> (name, dedupe (locators : rest)))) (selectAuthoritative choice remotes)

dedupe :: [RemoteLocator] -> [RemoteLocator]
dedupe =
  foldr (\x acc -> if x `elem` acc then acc else x : acc) []

codeAndArgs :: Either RegistrationRefusal a -> Either RegistrationRefusal ()
codeAndArgs =
  fmap (const ())
