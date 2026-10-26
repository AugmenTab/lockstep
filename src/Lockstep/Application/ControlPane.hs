{- | The control pane's state (contract C-P3.1 L4–L7): its state directory, the
one-time sign-in files the launcher leaves there, the in-memory sessions, and
the request and result files of the channel to the host helper. The pane holds
no database configuration and no Docker access.
-}
module Lockstep.Application.ControlPane
  ( PaneRuntime
  , PaneError (..)
  , renderPaneError
  , openPane
  , paneIdentity
  , exchangeSignIn
  , checkSession
  , endSession
  , SubmitError (..)
  , submitRequest
  , submitLifecycle
  , submitInstall
  , submitOpenApplication
  , submitFolder
  , FolderList (..)
  , readFolders
  , takeHandover
  , ResultView (..)
  , readResult
  ) where

import Control.Concurrent.MVar (MVar, modifyMVar, newMVar)
import Control.Exception (IOException, try)
import Crypto.Random (getRandomBytes)
import Data.Bits ((.&.))
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char qualified as Char
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List qualified as L
import Data.Map.Strict qualified as Map
import Data.Maybe (isNothing, mapMaybe)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Time.Clock.POSIX (getPOSIXTime)
import Flipstone.Prelude
import System.Directory (createDirectory, removeFile, renameFile)
import System.IO (FilePath)
import System.Posix.Files
  ( FileStatus
  , fileMode
  , fileSize
  , getSymbolicLinkStatus
  , isDirectory
  , isRegularFile
  , isSymbolicLink
  , setFileMode
  )
import Text.Show (Show, show)

import Lockstep.Foundation.ControlProtocol
  ( ChannelKey
  , ControlOp
  , ControlRequest (..)
  , ControlResult (..)
  , Expect (ExpectAny)
  , RequestId
  , decodeResult
  , encodeRequest
  , parseChannelKey
  , parseRequestId
  , requestIdText
  , signInDigestHex
  )
import Lockstep.Foundation.FolderProtocol (FolderOp (AddFolder), FolderRequest (..), encodeFolderRequest, foldersDigest)
import Lockstep.Foundation.InstallProtocol (InstallExpect, InstallOp, InstallRequest (..), encodeInstallRequest)
import Lockstep.Foundation.LifecycleProtocol (LifecycleOp, LifecycleRequest (..), encodeLifecycleRequest, expectedFor)
import Lockstep.Foundation.OperatorToken (decodeToken, encodeToken, generateToken, tokenDigest)
import Lockstep.Foundation.SessionProtocol (SessionOp (OpenApplication), SessionRequest (..), encodeSessionRequest)

data PaneRuntime
  = PaneRuntime
  { paneDirectory :: FilePath
  , paneIdentity :: BS.ByteString
  -- ^ the 32-hex-character @pane.id@ the launcher wrote (C-P3.1 L4)
  , paneSessions :: IORef (Map.Map BS.ByteString Integer)
  -- ^ session digest → absolute expiry (unix seconds)
  , paneIssued :: IORef (Set.Set T.Text)
  -- ^ request ids this pane wrote
  , paneLifecycle :: MVar (Maybe (T.Text, Integer))
  -- ^ the last lifecycle request and when it was written (C-P3.2 M6); held while one is written
  }

data PaneError
  = StateDirectoryMissing FilePath
  | StateDirectoryInsecure FilePath
  | PaneIdMissing FilePath
  | SubdirectoryUnusable FilePath
  deriving (Eq, Show)

renderPaneError :: PaneError -> String
renderPaneError err =
  case err of
    StateDirectoryMissing dir -> "the state directory " <> dir <> " does not exist or is not a directory"
    StateDirectoryInsecure dir -> "the state directory " <> dir <> " is a symlink or can be read or written by other users (it must be mode 0700)"
    PaneIdMissing path -> "the state directory has no valid pane identity (" <> path <> ")"
    SubdirectoryUnusable path -> "the state directory entry " <> path <> " is not a plain directory"

sessionSeconds :: Integer
sessionSeconds =
  12 * 60 * 60

maxSessions :: Int
maxSessions =
  16

currentSeconds :: IO Integer
currentSeconds =
  floor <$> getPOSIXTime

lstat :: FilePath -> IO (Maybe FileStatus)
lstat path = do
  r <- try (getSymbolicLinkStatus path) :: IO (Either IOException FileStatus)
  pure (either (const Nothing) Just r)

-- | Checks the state directory and creates its missing subdirectories (C-P3.1 L2).
openPane :: FilePath -> IO (Either PaneError PaneRuntime)
openPane dir = do
  status <- lstat dir
  case status of
    Nothing -> pure (Left (StateDirectoryMissing dir))
    Just s
      | isSymbolicLink s -> pure (Left (StateDirectoryInsecure dir))
      | not (isDirectory s) -> pure (Left (StateDirectoryMissing dir))
      | fileMode s .&. 0o077 /= 0 -> pure (Left (StateDirectoryInsecure dir))
      | otherwise -> do
          ident <- readIdentity (dir <> "/pane.id")
          case ident of
            Nothing -> pure (Left (PaneIdMissing (dir <> "/pane.id")))
            Just i -> do
              made <- traverse (ensureDirectory . ((dir <> "/") <>)) ["signin", "requests", "results"]
              case lefts made of
                p : _ -> pure (Left (SubdirectoryUnusable p))
                [] -> do
                  sessions <- newIORef Map.empty
                  issued <- newIORef Set.empty
                  lifecycle <- newMVar Nothing
                  pure (Right (PaneRuntime dir i sessions issued lifecycle))

readIdentity :: FilePath -> IO (Maybe BS.ByteString)
readIdentity path = do
  r <- try (BS.readFile path) :: IO (Either IOException BS.ByteString)
  pure $ case r of
    Right bytes ->
      let
        ident = BS8.takeWhile (/= '\n') bytes
      in
        if BS.length ident == 32 && BS8.all (\c -> Char.isDigit c || (c >= 'a' && c <= 'f')) ident
          then Just ident
          else Nothing
    Left _ -> Nothing

ensureDirectory :: FilePath -> IO (Either FilePath ())
ensureDirectory path = do
  status <- lstat path
  case status of
    Just s
      | isDirectory s && not (isSymbolicLink s) -> pure (Right ())
      | otherwise -> pure (Left path)
    Nothing -> do
      r <- try (createDirectory path >> setFileMode path 0o700) :: IO (Either IOException ())
      pure (either (const (Left path)) Right r)

isBase64Url :: Char -> Bool
isBase64Url c =
  Char.isAsciiUpper c || Char.isAsciiLower c || Char.isDigit c || c == '-' || c == '_'

{- | Consumes a one-time sign-in token (C-P3.1 L5): the file named by its digest
must be a regular file; it is removed before its expiry is checked, so a token
is never usable twice, and of two simultaneous exchanges only the one whose
removal succeeds gets a session. Returns the new session's text.
-}
exchangeSignIn :: PaneRuntime -> T.Text -> IO (Maybe T.Text)
exchangeSignIn runtime token =
  if T.length token /= 43 || not (T.all isBase64Url token)
    then pure Nothing
    else do
      let
        path = paneDirectory runtime <> "/signin/" <> T.unpack (signInDigestHex token)
      status <- lstat path
      case status of
        Just s | isRegularFile s && fileSize s <= 64 -> do
          content <- try (BS.readFile path) :: IO (Either IOException BS.ByteString)
          removed <- try (removeFile path) :: IO (Either IOException ())
          now <- currentSeconds
          case (content, removed) of
            (Right bytes, Right ()) | maybe False (>= now) (parseExpiry bytes) -> Just <$> newSession runtime now
            _ -> pure Nothing
        _ -> pure Nothing

parseExpiry :: BS.ByteString -> Maybe Integer
parseExpiry bytes =
  case BS.stripPrefix (BS8.pack "expires ") (BS8.takeWhile (/= '\n') bytes) of
    Just digits
      | not (BS.null digits) && BS.length digits <= 18 && BS8.all Char.isDigit digits ->
          Just (BS8.foldl' (\acc c -> acc * 10 + toInteger (Char.ord c - Char.ord '0')) 0 digits)
    _ -> Nothing

newSession :: PaneRuntime -> Integer -> IO T.Text
newSession runtime now = do
  token <- generateToken
  let
    expiry = now + sessionSeconds
    keep sessions =
      let
        live = Map.filter (> now) sessions
        oldestFirst = L.sortOn snd (Map.toList live)
      in
        Map.fromList (L.drop (L.length oldestFirst + 1 - maxSessions) oldestFirst)
  atomicModifyIORef' (paneSessions runtime) (\sessions -> (Map.insert (tokenDigest token) expiry (keep sessions), ()))
  pure (encodeToken token)

-- | A session header that names a live session.
checkSession :: PaneRuntime -> BS.ByteString -> IO Bool
checkSession runtime header =
  case decodeToken (TE.decodeLatin1 header) of
    Nothing -> pure False
    Just token -> do
      now <- currentSeconds
      sessions <- readIORef (paneSessions runtime)
      pure (maybe False (> now) (Map.lookup (tokenDigest token) sessions))

endSession :: PaneRuntime -> BS.ByteString -> IO ()
endSession runtime header =
  case decodeToken (TE.decodeLatin1 header) of
    Nothing -> pure ()
    Just token -> atomicModifyIORef' (paneSessions runtime) (\sessions -> (Map.delete (tokenDigest token) sessions, ()))

readKey :: PaneRuntime -> IO (Maybe ChannelKey)
readKey runtime = do
  let
    path = paneDirectory runtime <> "/channel.key"
  status <- lstat path
  case status of
    Just s | isRegularFile s -> do
      r <- try (BS.readFile path) :: IO (Either IOException BS.ByteString)
      pure (either (const Nothing) parseChannelKey r)
    _ -> pure Nothing

data SubmitError
  = HelperUnavailable
  | RequestNotWritten
  | LifecycleBusy
  deriving (Eq, Show)

{- | Writes one signed request for an allowlisted operation (C-P3.1 L7): a
temporary name, then a rename, so the helper never sees a partial file.
-}
submitRequest :: PaneRuntime -> ControlOp -> IO (Either SubmitError RequestId)
submitRequest runtime op =
  writeSigned runtime ".req" (\key rid now -> encodeRequest key (ControlRequest rid now op ExpectAny))

-- | Asks the helper for a one-time application sign-in (C-P3.4 A3).
submitOpenApplication :: PaneRuntime -> IO (Either SubmitError RequestId)
submitOpenApplication runtime = do
  ensured <- ensureDirectory (paneDirectory runtime <> "/handover")
  case ensured of
    Left _ -> pure (Left RequestNotWritten)
    Right () -> writeSigned runtime ".sreq" (\key rid t -> encodeSessionRequest key (SessionRequest rid t OpenApplication))

{- | The address of the application's sign-in for a hand-over this pane asked
for, exactly once: the file is removed whether or not it is well formed. A
file that is not exactly @port N@ and @token T@ (43 base64url characters) is
not handed over.
-}
takeHandover :: PaneRuntime -> T.Text -> IO (Maybe T.Text)
takeHandover runtime ridText = do
  issued <- readIORef (paneIssued runtime)
  if not (Set.member ridText issued)
    then pure Nothing
    else do
      let
        path = paneDirectory runtime <> "/handover/" <> T.unpack ridText
      status <- lstat path
      case status of
        Just s | isRegularFile s && fileSize s <= 256 -> do
          content <- try (BS.readFile path) :: IO (Either IOException BS.ByteString)
          _ <- try (removeFile path) :: IO (Either IOException ())
          pure $ case fmap BS8.lines content of
            Right [portLine, tokenLine]
              | Just portText <- BS.stripPrefix (BS8.pack "port ") portLine
              , Just token <- BS.stripPrefix (BS8.pack "token ") tokenLine
              , Just port <- parsePort portText
              , BS.length token == 43
              , BS8.all isBase64Url token ->
                  Just (T.pack ("http://127.0.0.1:" <> show port <> "/app/sign-in#") <> TE.decodeLatin1 token)
            _ -> Nothing
        Just _ -> do
          _ <- try (removeFile path) :: IO (Either IOException ())
          pure Nothing
        Nothing -> pure Nothing
 where
  parsePort digits =
    if not (BS.null digits) && BS.length digits <= 5 && BS8.all Char.isDigit digits
      then
        let
          n = BS8.foldl' (\acc c -> acc * 10 + (Char.ord c - Char.ord '0')) 0 digits
        in
          if n >= 1 && n <= 65535 then Just n else Nothing
      else Nothing

-- | How long a lifecycle request without a result blocks the next one.
lifecycleWindow :: Integer
lifecycleWindow =
  600

{- | Writes one signed lifecycle request (C-P3.2 M1, M6) with the operation's
expected state, unless the previous one still has no result.
-}
submitLifecycle :: PaneRuntime -> LifecycleOp -> IO (Either SubmitError RequestId)
submitLifecycle runtime op =
  submitExclusive runtime ".lreq" (\key rid t -> encodeLifecycleRequest key (LifecycleRequest rid t op (expectedFor op)))

{- | Writes one signed install request (C-P3.3 U1), under the same
one-at-a-time rule as lifecycle requests.
-}
submitInstall :: PaneRuntime -> InstallOp -> InstallExpect -> IO (Either SubmitError RequestId)
submitInstall runtime op expect =
  submitExclusive runtime ".ireq" (\key rid t -> encodeInstallRequest key (InstallRequest rid t op expect))

{- | Writes one signed add-folder request (C-P3.5 J6) for the list the person
reviewed, under the same one-at-a-time rule: adding a folder may restart the
service.
-}
submitFolder :: PaneRuntime -> T.Text -> T.Text -> IO (Either SubmitError RequestId)
submitFolder runtime expect path =
  submitExclusive runtime ".freq" (\key rid t -> encodeFolderRequest key (FolderRequest rid t AddFolder expect path))

-- | The folder list the helper published for the pane, and its digest.
data FolderList
  = FolderList
  { folderListDigest :: T.Text
  , folderListEntries :: [(T.Text, T.Text)]
  -- ^ (@rw@ or @ro@, path)
  }

{- | Reads @folders@ in the pane's state directory (written by the helper,
C-P3.5 J5). A missing, oversized or non-regular file is an empty list; lines
that are not @rw PATH@ or @ro PATH@ are not shown.
-}
readFolders :: PaneRuntime -> IO FolderList
readFolders runtime = do
  let
    path = paneDirectory runtime <> "/folders"
  status <- lstat path
  bytes <-
    case status of
      Just s | isRegularFile s && fileSize s <= 16384 -> fromRight BS.empty <$> (try (BS.readFile path) :: IO (Either IOException BS.ByteString))
      _ -> pure BS.empty
  let
    entry line =
      case T.breakOn (T.pack " ") (TE.decodeLatin1 line) of
        (mode, rest)
          | mode `L.elem` [T.pack "rw", T.pack "ro"]
          , Just p <- T.stripPrefix (T.pack " ") rest
          , T.pack "/" `T.isPrefixOf` p ->
              Just (mode, p)
        _ -> Nothing
  pure (FolderList (foldersDigest bytes) (mapMaybe entry (BS8.lines bytes)))

submitExclusive :: PaneRuntime -> String -> (ChannelKey -> RequestId -> Integer -> BS.ByteString) -> IO (Either SubmitError RequestId)
submitExclusive runtime suffix encode =
  modifyMVar (paneLifecycle runtime) $ \previous -> do
    now <- currentSeconds
    busy <- case previous of
      Just (rid, at) | now - at < lifecycleWindow -> do
        status <- lstat (paneDirectory runtime <> "/results/" <> T.unpack rid <> ".res")
        pure (isNothing status)
      _ -> pure False
    if busy
      then pure (previous, Left LifecycleBusy)
      else do
        written <- writeSigned runtime suffix encode
        pure $ case written of
          Right rid -> (Just (requestIdText rid, now), written)
          Left _ -> (previous, written)

writeSigned :: PaneRuntime -> String -> (ChannelKey -> RequestId -> Integer -> BS.ByteString) -> IO (Either SubmitError RequestId)
writeSigned runtime suffix encode = do
  mbKey <- readKey runtime
  case mbKey of
    Nothing -> pure (Left HelperUnavailable)
    Just key -> do
      raw <- getRandomBytes 16 :: IO BS.ByteString
      now <- currentSeconds
      case parseRequestId (TE.decodeLatin1 (convertToBase Base16 raw)) of
        Nothing -> pure (Left RequestNotWritten)
        Just rid -> do
          let
            name = T.unpack (requestIdText rid)
            dir = paneDirectory runtime <> "/requests/"
            tmp = dir <> "." <> name <> ".tmp"
          written <-
            try
              ( do
                  BS.writeFile tmp (encode key rid now)
                  setFileMode tmp 0o600
                  renameFile tmp (dir <> name <> suffix)
              ) ::
              IO (Either IOException ())
          case written of
            Left _ -> pure (Left RequestNotWritten)
            Right () -> do
              atomicModifyIORef' (paneIssued runtime) (\s -> (Set.insert (requestIdText rid) s, ()))
              pure (Right rid)

data ResultView
  = -- | not a request this pane wrote
    ResultUnknown
  | ResultPending
  | -- | present, but not a well-formed result with a valid MAC under the current key
    ResultUntrusted
  | ResultDone ControlResult
  deriving (Eq, Show)

maxResultFileBytes :: Integer
maxResultFileBytes =
  16384

readResult :: PaneRuntime -> T.Text -> IO ResultView
readResult runtime ridText = do
  issued <- readIORef (paneIssued runtime)
  if not (Set.member ridText issued)
    then pure ResultUnknown
    else do
      let
        path = paneDirectory runtime <> "/results/" <> T.unpack ridText <> ".res"
      status <- lstat path
      case status of
        Nothing -> pure ResultPending
        Just s
          | not (isRegularFile s) || toInteger (fileSize s) > maxResultFileBytes -> pure ResultUntrusted
          | otherwise -> do
              mbKey <- readKey runtime
              bytes <- try (BS.readFile path) :: IO (Either IOException BS.ByteString)
              pure $ case (mbKey, bytes) of
                (Just key, Right b) ->
                  case decodeResult key b of
                    Right result | resultId result == ridText -> ResultDone result
                    _ -> ResultUntrusted
                _ -> ResultUntrusted
