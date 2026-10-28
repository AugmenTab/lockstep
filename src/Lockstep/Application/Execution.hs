{- | Letting Lockstep work in a project, and handing it a bug (contract C-P4.1
X4–X8). PRE-FREEZE STUB: the types and the stored Bug Profile document are
final; the operations refuse until implemented.
-}
module Lockstep.Application.Execution
  ( bugFixDocument
  , Enablement (..)
  , ExecutionStatus (..)
  , Admission (..)
  , executionStatus
  , enableExecution
  , admitBug
  , findAdmission
  ) where

import Data.ByteString.Lazy qualified as LBS
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Text.Show (Show)

import Lockstep.Application.Command (IdempotencyKey)
import Lockstep.Application.Database (DatabaseRuntime, NotReadyReason)
import Lockstep.Application.ProjectChecks (ExpectedChecks)
import Lockstep.Application.Projects (ProjectFolders)

-- | The stored document of the built-in Bug Profile (X1); it decodes to 'Lockstep.Kernel.Execution.bugFixDefinition'.
bugFixDocument :: LBS.ByteString
bugFixDocument =
  LBS.fromStrict (TE.encodeUtf8 bugFixText)

bugFixText :: T.Text
bugFixText =
  T.concat
    [ T.pack "{\"id\":\"lockstep-bug-fix\",\"version\":1,\"gates\":["
    , gate "bug-reproduction" "[\"reproduction\"]" "[\"deterministic-command\"]" True
    , T.pack ","
    , gate "bug-requirements" "[\"impact-assessment\",\"requirements-basis\"]" "[\"digest-check\"]" False
    , T.pack ","
    , gate "bug-regression-test" "[\"frozen-tests\"]" "[\"deterministic-command\",\"digest-check\"]" False
    , T.pack ","
    , gate "bug-verification" "[\"regression-evidence\",\"verification-record\"]" "[\"deterministic-command\"]" False
    , T.pack ","
    , gate "bug-review" "[\"review-record\"]" "[\"independent-review\"]" False
    , T.pack "]}"
    ]
 where
  gate :: String -> String -> String -> Bool -> T.Text
  gate name artifacts verifiers exceptionPath =
    T.pack
      ( "{\"id\":\""
          <> name
          <> "\",\"stage\":\"before-acceptance\",\"artifacts\":"
          <> artifacts
          <> ",\"kinds\":[\"engineering\"],\"classes\":[\"bug\"],\"verifiers\":"
          <> verifiers
          <> ",\"approval\":\"supervisor\",\"exception_path\":"
          <> (if exceptionPath then "true" else "false")
          <> "}"
      )

-- | A project Lockstep may work in (X4): who allowed what, where, under which checks.
data Enablement
  = Enablement
  { enablementProject :: T.Text
  , enablementRepository :: T.Text
  , enablementEngineer :: T.Text
  , enablementFolder :: T.Text
  , enablementChecks :: T.Text
  , enablementChecksVersion :: Int
  , enablementChecksDigest :: T.Text
  , enablementActor :: T.Text
  , enablementAt :: T.Text
  }
  deriving (Eq, Show)

-- | X8: whether Lockstep may work in a project, and why not.
data ExecutionStatus
  = NeedsFolder
  | FolderReadOnly
  | NotEnabled (Maybe T.Text)
  | Enabled Enablement
  deriving (Eq, Show)

-- | A bug handed to Lockstep (X6).
data Admission
  = Admission
  { admissionTask :: T.Text
  , admissionProject :: T.Text
  , admissionWorkOrder :: T.Text
  , admissionEffectiveDigest :: T.Text
  , admissionActor :: T.Text
  , admissionAt :: T.Text
  }
  deriving (Eq, Show)

executionStatus :: DatabaseRuntime -> ProjectFolders -> T.Text -> IO (Either NotReadyReason (Maybe ExecutionStatus))
executionStatus _ _ _ =
  pure (Right Nothing)

enableExecution :: DatabaseRuntime -> ProjectFolders -> IdempotencyKey -> T.Text -> ExpectedChecks -> IO (Either NotReadyReason (Either T.Text Enablement))
enableExecution _ _ _ _ _ =
  pure (Right (Left (T.pack "not-implemented")))

admitBug :: DatabaseRuntime -> ProjectFolders -> IdempotencyKey -> T.Text -> Int -> IO (Either NotReadyReason (Either T.Text Admission))
admitBug _ _ _ _ _ =
  pure (Right (Left (T.pack "not-implemented")))

findAdmission :: DatabaseRuntime -> T.Text -> IO (Either NotReadyReason (Maybe Admission))
findAdmission _ _ =
  pure (Right Nothing)
