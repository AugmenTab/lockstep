{- | The read-only Jira intake adapter (contract C-P6.1 B12): a Jira REST v2
search response, read from a file, as a canonical backlog document. Only the
key, summary, update time, description and "Blocks" links are read; nothing
else in the provider's data reaches Lockstep. It never contacts Jira.

* An issue's revision is its update time in milliseconds since the epoch; the
  document's is the newest of them (0 for none).
* Its description, with runs of white space made one space, is its single
  criterion, referenced as @KEY description@; an absent or empty one is none.
* A link of type @Blocks@ with an @inwardIssue@ is a blocker ("is blocked
  by"); outward links and other link types are not read.
* The file must be a complete search result: a response that starts past the
  first issue, or whose @total@ exceeds the issues it holds, is refused.
-}
module Lockstep.Application.BacklogJira
  ( fromJiraSearch
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.List qualified as L
import Data.Maybe (fromMaybe)
import Data.Text qualified as T
import Data.Time (ZonedTime, nominalDiffTimeToSeconds, zonedTimeToUTC)
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Fleece.Aeson qualified as FA
import Fleece.Core ((#+))
import Fleece.Core qualified as FC
import Flipstone.Prelude

import Lockstep.Foundation.Fleece (nullableOf)
import Lockstep.Kernel.Backlog
  ( BacklogDocument (..)
  , BacklogItem (..)
  , Criterion (..)
  , SourceIdentity (..)
  , SourceLocator
  , SourceProvider (ProviderJira)
  , mkSourceKey
  , mkSourceRevision
  )

newtype JiraRef
  = JiraRef {jiraRefKey :: T.Text}

newtype JiraLinkType
  = JiraLinkType {jiraLinkTypeName :: T.Text}

data JiraLink
  = JiraLink
  { jiraLinkType :: JiraLinkType
  , jiraLinkInward :: Maybe JiraRef
  }

data JiraFields
  = JiraFields
  { jiraSummary :: T.Text
  , jiraUpdated :: T.Text
  , jiraDescription :: Maybe (Maybe T.Text)
  , jiraLinks :: Maybe [JiraLink]
  }

data JiraIssue
  = JiraIssue
  { jiraKey :: T.Text
  , jiraFields :: JiraFields
  }

data JiraSearch
  = JiraSearch
  { jiraStartAt :: Maybe Integer
  , jiraTotal :: Maybe Integer
  , jiraIssues :: [JiraIssue]
  }

refSchema :: FC.Fleece t => FC.Schema t JiraRef
refSchema =
  FC.object $ FC.constructor JiraRef #+ FC.required "key" jiraRefKey FC.text

linkTypeSchema :: FC.Fleece t => FC.Schema t JiraLinkType
linkTypeSchema =
  FC.object $ FC.constructor JiraLinkType #+ FC.required "name" jiraLinkTypeName FC.text

linkSchema :: FC.Fleece t => FC.Schema t JiraLink
linkSchema =
  FC.object $
    FC.constructor JiraLink
      #+ FC.required "type" jiraLinkType linkTypeSchema
      #+ FC.optional "inwardIssue" jiraLinkInward refSchema

fieldsSchema :: FC.Fleece t => FC.Schema t JiraFields
fieldsSchema =
  FC.object $
    FC.constructor JiraFields
      #+ FC.required "summary" jiraSummary FC.text
      #+ FC.required "updated" jiraUpdated FC.text
      #+ FC.optional "description" jiraDescription (nullableOf FC.text)
      #+ FC.optional "issuelinks" jiraLinks (FC.list linkSchema)

issueSchema :: FC.Fleece t => FC.Schema t JiraIssue
issueSchema =
  FC.object $
    FC.constructor JiraIssue
      #+ FC.required "key" jiraKey FC.text
      #+ FC.required "fields" jiraFields fieldsSchema

searchSchema :: FC.Fleece t => FC.Schema t JiraSearch
searchSchema =
  FC.object $
    FC.constructor JiraSearch
      #+ FC.optional "startAt" jiraStartAt FC.integer
      #+ FC.optional "total" jiraTotal FC.integer
      #+ FC.required "issues" jiraIssues (FC.list issueSchema)

fromJiraSearch :: SourceLocator -> LBS.ByteString -> Either T.Text BacklogDocument
fromJiraSearch locator bytes =
  case FA.decode searchSchema bytes of
    Left reason -> Left (T.pack ("not a Jira search response: " <> reason))
    Right search -> do
      -- R-P6.1-4: one page of a larger search would look stale and leave blockers dangling.
      when (maybe False (/= 0) (jiraStartAt search) || maybe False (> toInteger (L.length (jiraIssues search))) (jiraTotal search)) $
        Left (T.pack "not a complete search result (a page of a larger one); save the whole result in one file")
      items <- traverse fromIssue (jiraIssues search)
      revision <- revisionOf (L.foldl' max 0 (fmap revisionNumber items))
      pure
        BacklogDocument
          { documentSource = SourceIdentity ProviderJira locator
          , documentRevision = revision
          , documentRepository = Nothing
          , documentItems = fmap snd items
          }
 where
  revisionNumber (n, _) = n
  revisionOf n = maybe (Left (T.pack "a revision out of range")) Right (mkSourceRevision n)

fromIssue :: JiraIssue -> Either T.Text (Integer, BacklogItem)
fromIssue issue = do
  key <- keyOf (jiraKey issue)
  let
    fields = jiraFields issue
  millis <- maybe (Left (T.pack "an unreadable update time on " <> jiraKey issue)) Right (updatedMillis (jiraUpdated fields))
  revision <- maybe (Left (T.pack "an update time out of range on " <> jiraKey issue)) Right (mkSourceRevision millis)
  blockers <-
    traverse
      keyOf
      [ jiraRefKey ref
      | link <- fromMaybe [] (jiraLinks fields)
      , jiraLinkTypeName (jiraLinkType link) == T.pack "Blocks"
      , Just ref <- [jiraLinkInward link]
      ]
  let
    description = T.unwords (T.words (fromMaybe T.empty (join (jiraDescription fields))))
    criteria = [Criterion description (Just (jiraKey issue <> T.pack " description")) | not (T.null description)]
  pure
    ( millis
    , BacklogItem
        { itemKey = key
        , itemRevision = revision
        , itemTitle = jiraSummary fields
        , itemCriteria = criteria
        , itemBlockers = blockers
        }
    )
 where
  keyOf text = maybe (Left (T.pack "not a valid issue key: " <> text)) Right (mkSourceKey text)

-- | Jira's @2026-11-10T09:15:00.000+0000@ as milliseconds since the epoch.
updatedMillis :: T.Text -> Maybe Integer
updatedMillis text = do
  zoned <- parseTimeM False defaultTimeLocale "%Y-%m-%dT%H:%M:%S%Q%z" (T.unpack text) :: Maybe ZonedTime
  pure (floor (nominalDiffTimeToSeconds (utcTimeToPOSIXSeconds (zonedTimeToUTC zoned)) * 1000))
