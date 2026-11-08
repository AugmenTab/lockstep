{- | The folder request kind (contract C-P3.5 J6): the control pane asks the
helper to add a folder the service may see. The only operation is @add-folder@;
its expectation names the folder list the person reviewed, so a stale review is
refused, and its path is checked again by the helper on the host.
-}
module Lockstep.Foundation.FolderProtocol
  ( FolderOp (..)
  , folderOpName
  , parseFolderOp
  , FolderRequest (..)
  , encodeFolderRequest
  , decodeFolderRequest
  , foldersDigest
  , validFolderExpect
  , validFolderPath
  ) where

import Control.Monad (unless)
import Crypto.Hash (SHA256 (SHA256), hashWith)
import Data.ByteArray.Encoding (Base (Base16), convertToBase)
import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BS8
import Data.Char qualified as Char
import Data.List qualified as L
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Flipstone.Prelude
import Text.Show (Show, show)

import Lockstep.Foundation.ControlProtocol
  ( ChannelKey
  , ProtocolError (..)
  , RequestId
  , decimal
  , decodeSignedKind
  , lineValue
  , parseRequestId
  , requestIdText
  , signBody
  )

data FolderOp
  = AddFolder
  deriving (Eq, Show, Enum, Bounded)

folderOpName :: FolderOp -> T.Text
folderOpName op =
  case op of
    AddFolder -> T.pack "add-folder"

parseFolderOp :: T.Text -> Maybe FolderOp
parseFolderOp text =
  L.find ((== text) . folderOpName) [minBound .. maxBound]

data FolderRequest
  = FolderRequest
  { folderId :: RequestId
  , folderIssued :: Integer
  , folderOp :: FolderOp
  , folderExpect :: T.Text
  , folderPath :: T.Text
  }
  deriving (Eq, Show)

header :: BS.ByteString
header =
  BS8.pack "lockstep-folder-request "

line :: String -> T.Text -> BS.ByteString
line key value =
  BS8.pack key <> BS8.pack " " <> TE.encodeUtf8 value <> BS8.pack "\n"

encodeFolderRequest :: ChannelKey -> FolderRequest -> BS.ByteString
encodeFolderRequest key request =
  signBody key $
    BS.concat
      [ header <> BS8.pack "1\n"
      , line "id" (requestIdText (folderId request))
      , line "issued" (T.pack (show (folderIssued request)))
      , line "op" (folderOpName (folderOp request))
      , line "expect" (folderExpect request)
      , line "path" (folderPath request)
      ]

decodeFolderRequest :: ChannelKey -> BS.ByteString -> Either ProtocolError FolderRequest
decodeFolderRequest key bytes = do
  (version, rest) <- decodeSignedKind header key bytes
  case rest of
    [idLine, issuedLine, opLine, expectLine, pathLine] -> do
      when (version /= BS8.pack "1") (Left BadVersion)
      rid <- lineValue "id" idLine >>= maybe (Left Malformed) Right . parseRequestId
      issued <- lineValue "issued" issuedLine >>= decimal
      op <- lineValue "op" opLine >>= maybe (Left UnknownOp) Right . parseFolderOp
      expect <- lineValue "expect" expectLine
      unless (validFolderExpect expect) (Left BadExpect)
      path <- lineValue "path" pathLine
      unless (validFolderPath path) (Left Malformed)
      Right (FolderRequest rid issued op expect path)
    _ -> Left Malformed

-- | @folders-@ and the first 16 lower-case hex digits of the list's SHA-256.
foldersDigest :: BS.ByteString -> T.Text
foldersDigest list =
  T.pack "folders-" <> T.take 16 (TE.decodeLatin1 (convertToBase Base16 (hashWith SHA256 list)))

validFolderExpect :: T.Text -> Bool
validFolderExpect expect =
  case T.stripPrefix (T.pack "folders-") expect of
    Just digest -> T.length digest == 16 && T.all (\c -> Char.isDigit c || (c >= 'a' && c <= 'f')) digest
    Nothing -> False

{- | An absolute path of at most 512 printable ASCII characters, with no empty,
@.@ or @..@ segment, no trailing @/@, and neither @:@ (the list separator of
@LOCKSTEP_PROJECT_FOLDERS@ and of a mount) nor @,@.
-}
validFolderPath :: T.Text -> Bool
validFolderPath path =
  case T.stripPrefix (T.pack "/") path of
    Nothing -> False
    Just rest ->
      T.length path <= 512
        && T.all (\c -> c >= ' ' && c <= '~' && c /= ':' && c /= ',') path
        && L.all (\s -> not (T.null s) && s /= T.pack "." && s /= T.pack "..") (T.splitOn (T.pack "/") rest)
