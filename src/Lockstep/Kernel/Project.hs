{- | Pure project rules (contract C-P3.5 J1, J3, J4, J10): what a project's
name and intended outcome may be, the folder name and Engineer name derived from
it, the person's folder choice, the setup states, and the plain words shown for
every refusal. No Git word is needed on the ordinary path (PRD FR-UX-05).
-}
module Lockstep.Kernel.Project
  ( ProjectName
  , mkProjectName
  , projectNameText
  , ProjectOutcome
  , mkProjectOutcome
  , projectOutcomeText
  , ProjectRuleError (..)
  , ruleErrorCode
  , projectSlug
  , slugCandidate
  , engineerNameFor
  , FolderChoice (..)
  , parseFolderChoice
  , SetupState (..)
  , setupStateCode
  , parseSetupState
  , projectRefusalCodes
  , refusalWords
  ) where

import Data.Bifunctor (bimap)
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Flipstone.Prelude
import Text.Show (Show, show)

newtype ProjectName
  = ProjectName T.Text
  deriving (Eq, Show)

newtype ProjectOutcome
  = ProjectOutcome T.Text
  deriving (Eq, Show)

data ProjectRuleError
  = NameEmpty
  | NameTooLong
  | NameHasControl
  | OutcomeTooLong
  | OutcomeHasControl
  deriving (Eq, Show)

-- | 1 to 80 characters after trimming surrounding spaces, with no control character.
mkProjectName :: T.Text -> Either ProjectRuleError ProjectName
mkProjectName raw =
  let
    name = T.strip raw
  in
    if T.null name
      then Left NameEmpty
      else
        if T.any Char.isControl name
          then Left NameHasControl
          else
            if T.length name > 80
              then Left NameTooLong
              else Right (ProjectName name)

projectNameText :: ProjectName -> T.Text
projectNameText (ProjectName t) =
  t

{- | At most 2000 characters after trimming, with @\\r\\n@ written as @\\n@; new
lines and tabs are kept, other control characters are refused.
-}
mkProjectOutcome :: T.Text -> Either ProjectRuleError ProjectOutcome
mkProjectOutcome raw =
  let
    outcome = T.strip (T.replace (T.pack "\r\n") (T.pack "\n") raw)
  in
    if T.any (\c -> Char.isControl c && c /= '\n' && c /= '\t') outcome
      then Left OutcomeHasControl
      else
        if T.length outcome > 2000
          then Left OutcomeTooLong
          else Right (ProjectOutcome outcome)

projectOutcomeText :: ProjectOutcome -> T.Text
projectOutcomeText (ProjectOutcome t) =
  t

ruleErrorCode :: ProjectRuleError -> T.Text
ruleErrorCode e =
  T.pack $
    case e of
      NameEmpty -> "name-empty"
      NameTooLong -> "name-too-long"
      NameHasControl -> "name-control"
      OutcomeTooLong -> "outcome-too-long"
      OutcomeHasControl -> "outcome-control"

slugLimit :: Int
slugLimit =
  36

trimDashes :: T.Text -> T.Text
trimDashes =
  T.dropAround (== '-')

{- | Lower-case ASCII letters and digits; every other run of characters becomes
one @-@; at most 36 characters; @project@ when nothing is left.
-}
projectSlug :: ProjectName -> T.Text
projectSlug (ProjectName name) =
  let
    mapped = T.map (\c -> if Char.isAsciiUpper c then Char.toLower c else if Char.isAsciiLower c || Char.isDigit c then c else '-') name
    collapsed = T.intercalate (T.pack "-") (L.filter (not . T.null) (T.splitOn (T.pack "-") mapped))
    slug = trimDashes (T.take slugLimit collapsed)
  in
    if T.null slug then T.pack "project" else slug

-- | The n-th candidate: the slug itself, then @slug-2@, @slug-3@ … within 36 characters.
slugCandidate :: T.Text -> Int -> T.Text
slugCandidate slug n =
  if n <= 1
    then slug
    else
      let
        suffix = T.pack ("-" <> show n)
      in
        trimDashes (T.take (slugLimit - T.length suffix) slug) <> suffix

-- | The project's own Engineer: @p-@ and the folder name (the C-P2.1 name rule holds).
engineerNameFor :: T.Text -> T.Text
engineerNameFor slug =
  T.pack "p-" <> slug

data FolderChoice
  = NewFolder
  | ExistingFolder T.Text
  | DecideLater
  deriving (Eq, Show)

-- | The form's @folder@ field and, for @existing@, its non-empty @path@.
parseFolderChoice :: T.Text -> Maybe T.Text -> Maybe FolderChoice
parseFolderChoice choice path =
  case T.unpack choice of
    "new" -> Just NewFolder
    "later" -> Just DecideLater
    "existing" ->
      case path of
        Just p | not (T.null p) -> Just (ExistingFolder p)
        _ -> Nothing
    _ -> Nothing

data SetupState
  = Organized
  | Connected
  | SetupFailed
  deriving (Eq, Show, Enum, Bounded)

setupStateCode :: SetupState -> T.Text
setupStateCode s =
  T.pack $
    case s of
      Organized -> "organized"
      Connected -> "connected"
      SetupFailed -> "setup-failed"

parseSetupState :: T.Text -> Maybe SetupState
parseSetupState code =
  L.find ((== code) . setupStateCode) [minBound .. maxBound]

-- | The refusal codes of P3.5 itself (the C-P2.1 registration codes come from 'Lockstep.Kernel.Repository').
projectRefusalCodes :: [T.Text]
projectRefusalCodes =
  fmap fst projectWords

projectWords :: [(T.Text, T.Text)]
projectWords =
  fmap
    (bimap T.pack T.pack)
    [ ("folder-not-offered", "This is not one of the folders Lockstep can see. Choose one from the list, or add it in the control pane under Project folders (run lockstep to open it).")
    , ("no-projects-folder", "Lockstep has no folder for new projects on this computer yet. Open the control pane by running lockstep, or choose a folder that is already on this computer.")
    , ("folder-exists", "A folder with this name already exists, so Lockstep left it alone.")
    , ("folder-create-failed", "Lockstep could not make the new folder. Try again; the exact reason is under Advanced.")
    , ("project-name-taken", "Lockstep already has a project with this name. Choose another name.")
    , ("stale-revision", "This project changed since this page was shown. Nothing was changed; the page now shows it as it is.")
    , ("already-connected", "This project already has its folder.")
    , ("project-busy", "This project is being set up right now. Nothing was changed. Try again in a moment.")
    , ("unknown-project", "Lockstep has no such project.")
    , ("name-empty", "Give the project a name.")
    , ("name-too-long", "A project name can be at most 80 characters long.")
    , ("name-control", "A project name is one line of text.")
    , ("outcome-too-long", "What it should achieve can be at most 2000 characters long.")
    , ("outcome-control", "What it should achieve contains characters that cannot be shown.")
    ]

registrationWords :: [(T.Text, T.Text)]
registrationWords =
  fmap
    (bimap T.pack T.pack)
    [ ("path-not-found", "Lockstep cannot find this folder. It may have been moved, renamed or deleted.")
    , ("not-a-directory", "This is a file, not a folder.")
    , ("not-a-git-repository", "This folder does not keep a history of its changes yet, so Lockstep cannot use it as a project folder.")
    , ("bare-repository", "This folder holds only a stored history, without the files themselves, so it cannot be a project folder.")
    , ("not-top-level", "This folder is inside a larger project folder. Choose the outermost folder instead.")
    , ("linked-worktree", "This folder is an extra working copy of another project folder. Choose the original folder instead.")
    , ("submodule", "This folder is a part embedded in another project folder, so it cannot be a project of its own.")
    , ("unsupported-git-layout", "This folder keeps its history in an unusual way that Lockstep cannot use yet.")
    , ("shallow-repository", "This folder holds only part of its history, so Lockstep cannot be sure what it is. A complete copy can be used.")
    , ("git-unavailable", "Lockstep could not look inside this folder: a tool it needs is missing on this computer.")
    , ("git-timed-out", "Looking inside this folder took too long. Try again.")
    , ("git-failed", "Lockstep could not read this folder. Try again; the exact reason is under Advanced.")
    , ("authoritative-remote-ambiguous", "This folder is linked to several online copies, and Lockstep cannot yet tell which one is the main one.")
    , ("authoritative-remote-unknown", "The online copy chosen for this folder is not one it is linked to.")
    , ("authoritative-remote-inconsistent", "This folder's main online copy has different addresses for sending and receiving, so Lockstep cannot tell which project it belongs to.")
    , ("remote-url-unsupported", "This folder is linked to an online copy whose address Lockstep cannot read.")
    , ("remote-unresolvable", "This folder is linked to a copy on this computer that cannot be found.")
    , ("repository-already-owned", "This folder is already used by another project.")
    , ("authoritative-remote-owned", "Another project already uses a copy of the same work: both are linked to the same online copy.")
    , ("remote-is-owned-repository", "This folder is a copy of a folder another project already uses.")
    , ("owned-repository-pushes-here", "Another project's folder sends its changes to this folder, so it cannot be a separate project.")
    , ("engineer-already-owns-repository", "This project already has a folder.")
    , ("repository-id-in-use", "Lockstep could not record this folder. Try again.")
    ]

-- | The plain words for a refusal code; a general sentence for a code without its own words.
refusalWords :: T.Text -> T.Text
refusalWords code =
  fromMaybe
    (T.pack "Something went wrong. The exact reason is under Advanced.")
    (L.lookup code (projectWords <> registrationWords))
