{- | Canonical repository identity and exclusive ownership (contract C-P2.1
I4–I6; DG-03 decisions D-3.2a amended, D-3.3d, D-3.4, D-3.5a). Pure: the Git
observation boundary ('Lockstep.Effects.Git') supplies validated observations,
and this module decides.

Identity is the physical Git common directory and the authoritative remote.
Root commits and shared ancestry are deliberately not inputs, so forks,
remote-less clones and template-derived projects stay eligible.
-}
module Lockstep.Kernel.Repository
  ( PhysicalId (..)
  , RemoteLocator (..)
  , parseRemoteUrl
  , RemoteIdentity (..)
  , remoteIdentityText
  , sameRemote
  , RemoteConfig (..)
  , selectAuthoritative
  , settleAuthoritative
  , AuthoritativeRemote (..)
  , RepositoryObservation (..)
  , renderObservation
  , Ownership (..)
  , OwnedRepository (..)
  , RegistrationRequest (..)
  , RegistrationRefusal (..)
  , refusalCode
  , renderRefusal
  , decideRegistration
  ) where

import Data.Char qualified as Char
import Data.List qualified as L
import Data.List.NonEmpty qualified as NE
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show, show)

import Lockstep.Kernel.Identity (EngineerId, RepositoryId (..), uuidText)

-- | A directory's (device, inode): one physical directory whatever its spelling.
data PhysicalId
  = PhysicalId
  { physicalDevice :: Integer
  , physicalInode :: Integer
  }
  deriving (Eq, Ord, Show)

-- | A parsed remote URL: a network host and normalized path, or a local path to resolve.
data RemoteLocator
  = NetworkLocator T.Text T.Text
  | LocalLocator T.Text
  deriving (Eq, Ord, Show)

{- | A resolved remote. A local remote is identified by the physical identity
of its Git common directory; the text is its display path only.
-}
data RemoteIdentity
  = NetworkIdentity T.Text T.Text
  | LocalIdentity PhysicalId T.Text
  deriving (Eq, Show)

-- | The comparison key; a local remote's display path is not part of it.
remoteIdentityText :: RemoteIdentity -> T.Text
remoteIdentityText identity =
  case identity of
    NetworkIdentity host path -> host <> T.pack "/" <> path
    LocalIdentity physical _ -> T.pack "local:" <> physicalText physical

sameRemote :: RemoteIdentity -> RemoteIdentity -> Bool
sameRemote a b =
  remoteIdentityText a == remoteIdentityText b

physicalText :: PhysicalId -> T.Text
physicalText physical =
  T.pack (show (physicalDevice physical) <> ":" <> show (physicalInode physical))

-- | A configured remote, with its URLs after Git's own rewriting.
data RemoteConfig
  = RemoteConfig
  { remoteName :: T.Text
  , remoteFetchUrls :: [T.Text]
  , remotePushUrls :: [T.Text]
  }
  deriving (Eq, Show)

data AuthoritativeRemote
  = AuthoritativeRemote
  { authoritativeName :: T.Text
  , authoritativeIdentity :: RemoteIdentity
  }
  deriving (Eq, Show)

{- | A validated observation of a repository's main worktree (I3). The other
remotes are recorded by name for evidence and never used for identity.
-}
data RepositoryObservation
  = RepositoryObservation
  { observedCommonDir :: T.Text
  , observedPhysical :: PhysicalId
  , observedAuthoritative :: Maybe AuthoritativeRemote
  , observedOtherRemotes :: [T.Text]
  }
  deriving (Eq, Show)

data Ownership
  = Ownership
  { ownershipRepository :: RepositoryId
  , ownershipEngineer :: EngineerId
  }
  deriving (Eq, Show)

data OwnedRepository
  = OwnedRepository
  { ownedOwnership :: Ownership
  , ownedObservation :: RepositoryObservation
  }
  deriving (Eq, Show)

data RegistrationRequest
  = RegistrationRequest
  { requestRepository :: RepositoryId
  , requestEngineer :: EngineerId
  , requestObservation :: RepositoryObservation
  }
  deriving (Eq, Show)

-- | Every reason a registration is refused: observation (I3), remote (I4, I5) and decision (I6).
data RegistrationRefusal
  = PathNotFound
  | NotADirectory
  | NotAGitRepository
  | BareRepository
  | NotTopLevel
  | LinkedWorktree
  | Submodule
  | UnsupportedGitLayout
  | ShallowRepository
  | GitUnavailable
  | GitTimedOut
  | GitFailed T.Text
  | AuthoritativeRemoteAmbiguous [T.Text]
  | AuthoritativeRemoteUnknown T.Text
  | AuthoritativeRemoteInconsistent T.Text
  | RemoteUrlUnsupported T.Text
  | RemoteUnresolvable T.Text
  | RepositoryAlreadyOwned Ownership
  | AuthoritativeRemoteOwned Ownership
  | RemoteIsOwnedRepository Ownership
  | OwnedRepositoryPushesHere Ownership
  | EngineerAlreadyOwnsRepository RepositoryId
  | RepositoryIdInUse
  deriving (Eq, Show)

-- * Remote URLs (I5)

networkSchemes :: [T.Text]
networkSchemes =
  fmap T.pack ["ssh", "git+ssh", "ssh+git", "git", "http", "https"]

-- | Hosts that route repository paths case-insensitively; elsewhere paths compare exactly.
caseInsensitiveHosts :: [T.Text]
caseInsensitiveHosts =
  fmap T.pack ["github.com", "gitlab.com", "bitbucket.org"]

parseRemoteUrl :: T.Text -> Maybe RemoteLocator
parseRemoteUrl url
  | T.null url = Nothing
  | T.pack "::" `T.isInfixOf` url = Nothing
  | otherwise =
      case T.breakOn (T.pack "://") url of
        (scheme, rest)
          | not (T.null rest) ->
              schemeLocator scheme (T.drop 3 rest)
        _ ->
          case T.breakOn (T.pack ":") url of
            (hostPart, rest)
              | not (T.null rest) && not (T.null hostPart) && not (T.pack "/" `T.isInfixOf` hostPart) ->
                  network (afterUserInfo hostPart) (T.drop 1 rest)
            _ ->
              Just (LocalLocator url)

schemeLocator :: T.Text -> T.Text -> Maybe RemoteLocator
schemeLocator scheme rest
  | T.toLower scheme `L.elem` networkSchemes =
      let
        (authority, path) = T.breakOn (T.pack "/") rest
      in
        network (withoutPort (afterUserInfo authority)) path
  | T.toLower scheme == T.pack "file" =
      if T.pack "/" `T.isPrefixOf` rest
        then Just (LocalLocator rest)
        else case T.stripPrefix (T.pack "localhost/") rest of
          Just path -> Just (LocalLocator (T.pack "/" <> path))
          Nothing -> Nothing
  | otherwise = Nothing

afterUserInfo :: T.Text -> T.Text
afterUserInfo authority =
  case T.breakOnEnd (T.pack "@") authority of
    (_, host) -> host

withoutPort :: T.Text -> T.Text
withoutPort host
  | T.pack "[" `T.isPrefixOf` host = fst (T.breakOn (T.pack "]") host) <> T.pack "]"
  | otherwise = T.takeWhile (/= ':') host

network :: T.Text -> T.Text -> Maybe RemoteLocator
network rawHost rawPath = do
  host <- normalHost rawHost
  path <- normalPath rawPath
  pure (NetworkLocator host (if host `L.elem` caseInsensitiveHosts then T.toLower path else path))

normalHost :: T.Text -> Maybe T.Text
normalHost raw =
  let
    host = T.dropWhileEnd (== '.') (T.toLower raw)
  in
    if T.null host || T.any (\c -> Char.isSpace c || c == '/') host
      then Nothing
      else Just host

normalPath :: T.Text -> Maybe T.Text
normalPath raw =
  let
    segments = L.filter (not . T.null) (T.splitOn (T.pack "/") raw)
    joined = T.intercalate (T.pack "/") segments
    path = T.dropWhileEnd (== '/') (fromMaybe joined (T.stripSuffix (T.pack ".git") joined))
  in
    if L.any (`L.elem` [T.pack ".", T.pack ".."]) segments || T.null path || T.pack "//" `T.isInfixOf` path
      then Nothing
      else Just path

-- * Authoritative remote (I4)

{- | Chooses the authoritative remote and parses all of its URLs. With several
remotes and no choice, the operator must name one.
-}
selectAuthoritative :: Maybe T.Text -> [RemoteConfig] -> Either RegistrationRefusal (Maybe (T.Text, NonEmpty RemoteLocator))
selectAuthoritative choice remotes = do
  chosen <-
    case choice of
      Just name ->
        maybe (Left (AuthoritativeRemoteUnknown name)) (Right . Just) (L.find ((== name) . remoteName) remotes)
      Nothing ->
        case remotes of
          [] -> Right Nothing
          [only] -> Right (Just only)
          _ -> Left (AuthoritativeRemoteAmbiguous (L.sort (fmap remoteName remotes)))
  traverse locate chosen
 where
  locate remote =
    let
      name = remoteName remote
      unsupported = Left (RemoteUrlUnsupported name)
    in
      case NE.nonEmpty (remoteFetchUrls remote <> remotePushUrls remote) of
        Nothing -> unsupported
        Just urls -> maybe unsupported (\locators -> Right (name, locators)) (traverse parseRemoteUrl urls)

-- | Every URL of the authoritative remote must resolve to one identity.
settleAuthoritative :: T.Text -> NonEmpty RemoteIdentity -> Either RegistrationRefusal AuthoritativeRemote
settleAuthoritative name (first NE.:| rest) =
  if L.all (sameRemote first) rest
    then Right (AuthoritativeRemote name first)
    else Left (AuthoritativeRemoteInconsistent name)

-- | A canonical rendering of every field, for the stored observation digest.
renderObservation :: RepositoryObservation -> T.Text
renderObservation observation =
  T.unlines
    [ T.pack "common-dir " <> observedCommonDir observation
    , T.pack "physical " <> physicalText (observedPhysical observation)
    , T.pack "authoritative " <> maybe (T.pack "none") renderAuthoritative (observedAuthoritative observation)
    , T.pack "other-remotes " <> T.intercalate (T.pack ",") (observedOtherRemotes observation)
    ]
 where
  renderAuthoritative remote =
    authoritativeName remote
      <> T.pack "="
      <> remoteIdentityText (authoritativeIdentity remote)
      <> case authoritativeIdentity remote of
        LocalIdentity _ display -> T.pack " " <> display
        NetworkIdentity _ _ -> T.empty

-- * Decision (I6)

{- | Compares the candidate with every actively owned repository in
'RepositoryId' order; the first conflict wins. Repository identity conflicts
come before the Engineer's own cardinality.
-}
decideRegistration :: [OwnedRepository] -> RegistrationRequest -> Either RegistrationRefusal OwnedRepository
decideRegistration owned request =
  let
    candidate = requestObservation request
    ordered = L.sortOn (ownershipRepository . ownedOwnership) owned
    ownerships = fmap ownedOwnership ordered
  in
    case mapMaybe (conflictWith candidate) ordered of
      refusal : _ ->
        Left refusal
      []
        | Just mine <- L.find ((== requestEngineer request) . ownershipEngineer) ownerships ->
            Left (EngineerAlreadyOwnsRepository (ownershipRepository mine))
        | L.any ((== requestRepository request) . ownershipRepository) ownerships ->
            Left RepositoryIdInUse
        | otherwise ->
            Right
              OwnedRepository
                { ownedOwnership = Ownership (requestRepository request) (requestEngineer request)
                , ownedObservation = candidate
                }

conflictWith :: RepositoryObservation -> OwnedRepository -> Maybe RegistrationRefusal
conflictWith candidate owned
  | observedPhysical existing == observedPhysical candidate || observedCommonDir existing == observedCommonDir candidate =
      Just (RepositoryAlreadyOwned ownership)
  | Just a <- remoteOf existing
  , Just b <- remoteOf candidate
  , sameRemote a b =
      Just (AuthoritativeRemoteOwned ownership)
  | Just (LocalIdentity target _) <- remoteOf candidate
  , target == observedPhysical existing =
      Just (RemoteIsOwnedRepository ownership)
  | Just (LocalIdentity target _) <- remoteOf existing
  , target == observedPhysical candidate =
      Just (OwnedRepositoryPushesHere ownership)
  | otherwise =
      Nothing
 where
  existing = ownedObservation owned
  ownership = ownedOwnership owned
  remoteOf = fmap authoritativeIdentity . observedAuthoritative

-- * Refusals

refusalCode :: RegistrationRefusal -> T.Text
refusalCode refusal =
  T.pack $
    case refusal of
      PathNotFound -> "path-not-found"
      NotADirectory -> "not-a-directory"
      NotAGitRepository -> "not-a-git-repository"
      BareRepository -> "bare-repository"
      NotTopLevel -> "not-top-level"
      LinkedWorktree -> "linked-worktree"
      Submodule -> "submodule"
      UnsupportedGitLayout -> "unsupported-git-layout"
      ShallowRepository -> "shallow-repository"
      GitUnavailable -> "git-unavailable"
      GitTimedOut -> "git-timed-out"
      GitFailed _ -> "git-failed"
      AuthoritativeRemoteAmbiguous _ -> "authoritative-remote-ambiguous"
      AuthoritativeRemoteUnknown _ -> "authoritative-remote-unknown"
      AuthoritativeRemoteInconsistent _ -> "authoritative-remote-inconsistent"
      RemoteUrlUnsupported _ -> "remote-url-unsupported"
      RemoteUnresolvable _ -> "remote-unresolvable"
      RepositoryAlreadyOwned _ -> "repository-already-owned"
      AuthoritativeRemoteOwned _ -> "authoritative-remote-owned"
      RemoteIsOwnedRepository _ -> "remote-is-owned-repository"
      OwnedRepositoryPushesHere _ -> "owned-repository-pushes-here"
      EngineerAlreadyOwnsRepository _ -> "engineer-already-owns-repository"
      RepositoryIdInUse -> "repository-id-in-use"

renderRefusal :: RegistrationRefusal -> T.Text
renderRefusal refusal =
  case refusal of
    PathNotFound -> T.pack "the path does not exist in this filesystem view"
    NotADirectory -> T.pack "the path is not a directory"
    NotAGitRepository -> T.pack "the path is not in a Git repository"
    BareRepository -> T.pack "bare repositories cannot be registered; register a main worktree"
    NotTopLevel -> T.pack "the path is not the top level of a main worktree"
    LinkedWorktree -> T.pack "the path is a linked worktree; register the repository's main worktree"
    Submodule -> T.pack "submodules cannot be registered"
    UnsupportedGitLayout -> T.pack "the worktree's .git is not the repository's own directory (separate Git directory)"
    ShallowRepository -> T.pack "shallow clones cannot be registered"
    GitUnavailable -> T.pack "git is not available"
    GitTimedOut -> T.pack "git did not answer in time"
    GitFailed detail -> T.pack "git failed: " <> detail
    AuthoritativeRemoteAmbiguous names ->
      T.pack "several remotes ("
        <> T.intercalate (T.pack ", ") names
        <> T.pack "); name the repository's own with --authoritative-remote"
    AuthoritativeRemoteUnknown name -> T.pack "there is no remote named " <> name
    AuthoritativeRemoteInconsistent name -> T.pack "the URLs of remote " <> name <> T.pack " name different repositories"
    RemoteUrlUnsupported name -> T.pack "a URL of remote " <> name <> T.pack " is not supported"
    RemoteUnresolvable name -> T.pack "a local URL of remote " <> name <> T.pack " is not a Git repository here"
    RepositoryAlreadyOwned ownership -> T.pack "this repository is already owned" <> owner ownership
    AuthoritativeRemoteOwned ownership -> T.pack "a repository with the same authoritative remote is already owned" <> owner ownership
    RemoteIsOwnedRepository ownership -> T.pack "the authoritative remote is an owned repository" <> owner ownership
    OwnedRepositoryPushesHere ownership -> T.pack "an owned repository's authoritative remote is this repository" <> owner ownership
    EngineerAlreadyOwnsRepository repository ->
      T.pack "the Engineer already owns repository " <> repositoryText repository
    RepositoryIdInUse -> T.pack "the new repository identity is already in use"
 where
  owner ownership = T.pack " (repository " <> repositoryText (ownershipRepository ownership) <> T.pack ")"
  repositoryText (RepositoryId uuid) = uuidText uuid
