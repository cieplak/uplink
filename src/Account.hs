{-|

Account data structures and serialization.

--}

{-# LANGUAGE StrictData #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE DeriveAnyClass #-}

module Account (
  -- ** Types
  Account(..),
  Metadata(..),
  newAccount,
  createAccount,
  createAccountDir,
  validateAccount,

  -- ** Serialization
  encodeAccount,
  decodeAccount,
  accountKeyVal,

  -- ** Persistence
  AccountPrompt(..),
  createAccPrompt,
  createAccPrompt',

  readKeys,
  readKeys',
  writeKeys,
  writePrivKey,
  writePrivKey',
  writePrivKey_,
  writePubKey,
  writePubKey',
  writePubKey_,

  readAccount,
  writeAccount,
  writeAccount',
  writeAccount_,
  writeAccountData,
  readAccountData,
  readAccountsFromDir,

  accountFile,
  privKeyFile,
  pubKeyFile,

) where

import Protolude
import qualified Key
import qualified Hash
import qualified Utils
import qualified Address
import qualified Logging as Log
import Data.Aeson ((.=), (.:))
import Data.Aeson.Types (typeMismatch)
import qualified Data.Map as Map
import qualified Data.Aeson as A
import qualified Data.Serialize as S
import qualified Data.Text as T
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import qualified Data.Aeson.Encode.Pretty as A
import qualified Data.Binary as Binary
import qualified Text.PrettyPrint.Leijen.Text as PP

import Control.Monad (fail)

import Database.PostgreSQL.Simple.ToRow     (ToRow(..))
import Database.PostgreSQL.Simple.FromRow   (FromRow(..), field)
import Database.PostgreSQL.Simple.ToField   (ToField(..), Action(..))
import Database.PostgreSQL.Simple.FromField (FromField(..), ResultError(..), returnError)

import System.FilePath
import System.Directory
import System.Posix.Files

-------------------------------------------------------------------------------
-- Types
-------------------------------------------------------------------------------

-- XXX: needs to not have unbounded bytestring objects for metadata
-- Need a Safe ByteString

-- | An account in a distributed legder consists of:
--
-- 1. An elliptic public key
-- 2. An address
-- 3. A node key of the screen hosting the account.
-- 4. A ISO timezone code
-- 5. An arbitray key-value metadata store of personal information (name,
-- company, geography, etc)
newtype Metadata = Metadata
  { unMetadata :: Map ByteString ByteString }
  deriving (Show, Eq, Generic, NFData, Hash.Hashable)

instance Monoid Metadata where
  mempty = Metadata mempty
  (Metadata m1) `mappend` (Metadata m2) =
    Metadata $ m1 <> m2

data Account = Account
  { publicKey   :: Key.PubKey
  , address     :: Address.Address
  , timezone    :: ByteString
  , metadata    :: Metadata
  } deriving (Show, Eq, Generic, NFData, S.Serialize, Hash.Hashable)

-- | Validate the integrity of acccount information
validateAccount :: Account -> Bool
validateAccount Account {..} = and [
    Key.validateKey publicKey
  , Address.validateAddress address
  , Address.verifyAddress publicKey address
  ]

-- | Create a new Acccount
createAccount
  :: Key.PubKey
  -> ByteString
  -> Metadata
  -> Account
createAccount pub timezone metadata =
    Account {
      publicKey  = pub
    , address    = Address.deriveAddress pub
    , timezone   = timezone
    , metadata   = metadata
    }

-- | Generate a new Acccount (random seed)
-- returns private key so the new account can be written to disk
newAccount :: ByteString -> Metadata -> IO (Account, Key.ECDSAKeyPair)
newAccount timezone metadata = do
  keys@(pub,_) <- Key.new
  return $ (,keys) $
    createAccount pub timezone metadata

-- | Single user key file settings
pubKeyFile, privKeyFile, accountFile :: FilePath -> FilePath
pubKeyFile root  = root </> "key.pub"
privKeyFile root = root </> "key"
accountFile root = root </> "account"

accountFilesExist :: FilePath -> IO Bool
accountFilesExist root = do
  pubKeyExists  <- doesFileExist $ pubKeyFile root
  privKeyExists <- doesFileExist $ privKeyFile root
  accountExists <- doesFileExist $ accountFile root
  return $ pubKeyExists && privKeyExists && accountExists

-- | Like `loadAccount` but will throw an exception if account doesn't exist
readAccountData :: FilePath -> IO (Either Text (Account, Key.ECDSAKeyPair))
readAccountData root = do
  res <- liftA3 (,,)
    <$> Utils.safeRead (pubKeyFile root)
    <*> Utils.safeRead (privKeyFile root)
    <*> Utils.safeRead (accountFile root)

  case res of
    Left err -> return $ Left err
    (Right (pubKeyPem, privKeyPem, account)) ->
      pure $ do
        pk   <- Key.importPub pubKeyPem
        pair <- Key.importPriv privKeyPem
        acc  <- first toS $ A.eitherDecode' (toS account)
        if (Key.validatePair pair) && (pk == publicKey acc)
          then pure (acc, pair)
          else (Left "key.pub and account don't match keys")

data AccountPrompt = Prompt | NoPrompt
  deriving (Eq, Ord, Show)

-- | Prompts user for account creation, returning the created account data
createAccPrompt
  :: FilePath
  -> Maybe FilePath
  -> AccountPrompt
  -> IO (Either Text (Account, Key.ECDSAKeyPair))
createAccPrompt root privKey accPrompt = do
    ePrivKey <- case privKey of
      Nothing -> promptSupplyKey $ promptArg accPrompt
      Just _  -> promptKeyFile privKey
    case ePrivKey of
      Left err -> return $ Left err
      Right privKey -> do
        -- XXX Prompt for timezone & metadata? How?
        let pubKey = Key.toPublic privKey
            acc = createAccount pubKey "UTC" mempty
            keys = (pubKey,privKey)
        return $ Right (acc, keys)
  where
    promptArg Prompt = Nothing
    promptArg NoPrompt = Just "n"

    -- Prompt the user to supply a private key or not
    promptSupplyKey :: Maybe Text -> IO (Either Text Key.PrivateKey)
    promptSupplyKey (Just "y") = promptKeyFile Nothing
    promptSupplyKey (Just "n") = Right . snd <$> Key.new
    promptSupplyKey (Just _)   = do
      yOrNo <- Utils.prompt "Please enter 'y' or 'n': "
      promptSupplyKey $ Just yOrNo
    promptSupplyKey Nothing    = do
      yOrNo <- Utils.prompt "Do you want to supply your own private key (y/n): "
      promptSupplyKey $ Just yOrNo

    -- Prompt the user for a path to file containing their hex or pem priv key
    promptKeyFile :: Maybe FilePath -> IO (Either Text Key.PrivateKey)
    promptKeyFile (Just privKeyFile) = do
      privKeyFp <- makeAbsolute privKeyFile
      fileExists <- doesFileExist privKeyFp
      if fileExists then do
        privKeyBS <- BS.readFile =<< makeAbsolute privKeyFile
        return $ Key.tryDecodePriv privKeyBS
      else do
        putText $ "Could not find file at filepath " <> show privKeyFp <> "."
        promptKeyFile Nothing
    promptKeyFile Nothing = do
      privKeyFile <- Utils.prompt "Please provide the filepath to your EC private key: "
      promptKeyFile $ Just $ toS privKeyFile

-- | Like `setupAccount`, but will throw an exception if an error occurs.
createAccPrompt' :: FilePath -> Maybe FilePath -> AccountPrompt -> IO (Account, Key.ECDSAKeyPair)
createAccPrompt' root privKey accPrompt = do
  eAccAndKeys <- createAccPrompt root privKey accPrompt
  case eAccAndKeys of
    Left err         -> Utils.dieRed err
    Right accAndKeys -> return accAndKeys

createAccountDir :: FilePath -> IO (Either Text ())
createAccountDir root = do
  rootExists <- doesDirectoryExist root
  if rootExists then
    pure (Left "Not overwriting existing keys.")
  else do
    createDirectoryIfMissing True root
    pure (Right ())

-- | Reads an ECC private key in PEM format from a
-- file found in the given directory: <root>/key
readKeys :: FilePath -> IO (Either Text Key.ECDSAKeyPair)
readKeys root = do
  rootExists <- doesDirectoryExist root
  if rootExists then do
    let privFile = privKeyFile root
    readKeys' privFile
  else
    pure $ Left "Node root directory has not been initialized."

-- | Reads a private key found at the given path
readKeys' :: FilePath -> IO (Either Text Key.ECDSAKeyPair)
readKeys' privKeyPath =
  join . fmap Key.importPriv <$> Utils.safeRead privKeyPath

-- | Write account key data to disk
-- Note: does not overwrite existing keys
writeKeys :: FilePath -> Key.ECDSAKeyPair -> IO (Either Text ())
writeKeys root (publicKey, privateKey) = do
  rootExists <- doesDirectoryExist root
  if rootExists then do
    e1 <- writePrivKey root privateKey
    e2 <- writePubKey root publicKey
    pure (e1 >> e2)
  else
    pure (Left "Root directory does not exist.")

--------------------------------------------------------------------------------

-- | Writes a private key to the given directory in PEM format tothe file <root>/key
writePrivKey :: FilePath -> Key.PrivateKey -> IO (Either Text ())
writePrivKey root = writePrivKey' (privKeyFile root)

-- | Writes a private key to a given file in PEM format
-- Note: Does not overwrite existing files
writePrivKey' :: FilePath -> Key.PrivateKey -> IO (Either Text ())
writePrivKey' file privKey = do
  privExists <- doesFileExist file
  if privExists
    then pure $ Left $
      "Not overwriting existing Private Key at: " <> toS file
    else writePrivKey_ file privKey

-- | Writes a private key to a given file in PEM format
-- Note: Overwrites existing file
writePrivKey_ :: FilePath -> Key.PrivateKey -> IO (Either Text ())
writePrivKey_ file privKey = do
  eRes <- Utils.safeWrite file $ Key.exportPriv privKey
  case eRes of
    Left err -> pure $ Left err -- V Set chmod 0400
    Right _  -> Right <$> setFileMode file ownerReadMode

--------------------------------------------------------------------------------

-- | Write a PEM serialized Public Key to disk
writePubKey :: FilePath -> Key.PubKey -> IO (Either Text ())
writePubKey root = writePubKey' (pubKeyFile root)

-- | Write a PEM serialized Public Key to disk
-- Note: Does not overwrite existing file at the given filepath
writePubKey' :: FilePath -> Key.PubKey -> IO (Either Text ())
writePubKey' file pubKey = do
  pubExists <- doesFileExist file
  if pubExists
    then pure $ Left $
      "Not overwriting existing Public Key at: " <> toS file
    else do
      BS.writeFile file (Key.exportPub pubKey)
      setFileMode file ownerReadMode -- Set chmod 0400
      pure $ Right ()

-- | Write a PEM serialized Public Key to disk
-- Warning: Overwrites existing file at the given filepath
writePubKey_ :: FilePath -> Key.PubKey -> IO (Either Text ())
writePubKey_ file pubKey = do
  eRes <- Utils.safeWrite file $ Key.exportPub pubKey
  case eRes of
    Left err -> pure $ Left err -- V Set chmod 0400
    Right _  -> Right <$> setFileMode file ownerReadMode

--------------------------------------------------------------------------------

-- | Write JSON encoded account metadata to disk as file <root>/account
-- Note: Will not overwrite existing file at the given filepath
writeAccount :: FilePath -> Account -> IO (Either Text ())
writeAccount root acct = do
  rootExists <- doesDirectoryExist root
  if rootExists then do
    let acctFile = accountFile root
    writeAccount' acctFile acct
  else
    pure (Left "Root directory does not exist.")

-- | Write JSON encoded account metadata to disk at filepath
-- Note: Will not overwrite existing file at the given filepath
writeAccount' :: FilePath -> Account -> IO (Either Text ())
writeAccount' file acct = do
  acctExists <- doesFileExist file
  if acctExists then
    pure (Left "Not overwriting existing account file.")
  else writeAccount_ file acct

-- | Write JSON encoded account metadata to disk at filepath
-- Warning: Will overwrite an existing file at the given filepath
writeAccount_ :: FilePath -> Account -> IO (Either Text ())
writeAccount_ file acct = do
  eRes <- Utils.safeWrite file (toS (A.encodePretty acct))
  case eRes of
    Left err -> pure $ Left err
    Right _  -> Right <$> setFileMode file ownerReadMode

writeAccountData
  :: FilePath
  -> Account
  -> (Key.PubKey, Key.PrivateKey)
  -> IO (Either Text ())
writeAccountData root acc keys = do
  eRes <- writeAccount root acc
  case eRes of
    Left err -> pure $ Left err
    Right _  -> writeKeys root keys

-------------------------------------------------------------------------------

readAccountsFromDir :: FilePath -> IO (Either Text [Account.Account])
readAccountsFromDir dir = do
  dirExists <- doesDirectoryExist dir
  if not dirExists
    then pure $ Left $
      "No directory found at path '" <> toS dir <> "'."
    else do
      accDirs <- listDirectory dir
      if (null accDirs)
        then pure $ Left $
          "No account directories found in directory '" <> show dir <> "'."
        else fmap (Right . rights) $
          forM accDirs $ \accDir -> do
            eAcc <- readAccountData $ dir </> accDir
            case eAcc of
              Left err -> Log.warning $ show err
              Right _  -> pure ()
            pure $ fst <$> eAcc

-------------------------------------------------------------------------------
-- Serialization
-------------------------------------------------------------------------------

instance A.ToJSON Account where
  toJSON acc = A.object
    [ "publicKey" .= publicKey acc
    , "address"   .= address acc
    , "timezone"  .= decodeUtf8 (timezone acc)
    , "metadata"  .= metadata acc
    ]

instance A.FromJSON Account where
  parseJSON o@(A.Object v) = do
    pubKey   <- v .: "publicKey"
    addr     <- v .: "address"
    timezone <- v .: "timezone"
    metadata <- v .: "metadata"

    pure $ Account
      pubKey
      addr
      (encodeUtf8 timezone)
      (parseMetadata metadata)

  parseJSON invalid = typeMismatch "Account" invalid

instance Binary.Binary Account where
  put tx = Binary.put $ S.encode tx
  get = do
    bs <- Binary.get
    case S.decode bs of
      (Right tx) -> return tx
      (Left err) -> fail err

instance S.Serialize Metadata where
  put (Metadata m) = do
    let len = Map.size m
    S.putWord16be $ Utils.toWord16 len
    go $ sortBy (\a b -> compare (fst a) (fst b)) $ Map.toList m

    where
      go [] = return ()
      go ((k,v):xs) = do
        S.putWord16be $ Utils.toWord16 $ BS.length k
        S.putByteString k
        S.putWord16be $ Utils.toWord16 $ BS.length v
        S.putByteString v
        go xs
  get = do
      len <- S.getWord16be
      go [] 0 len
    where
      go acc i len
        | i == len = return $ Metadata $ Map.fromList acc
        | otherwise = do
          keyLen <- S.getWord16be
          key    <- S.getBytes $ Utils.toInt keyLen
          valLen <- S.getWord16be
          val    <- S.getBytes $ Utils.toInt valLen
          go ((key, val) : acc) (i+1) len

instance A.ToJSON Metadata where
  toJSON (Metadata metadata) = A.toJSON $
    map decodeUtf8 $ Map.mapKeys decodeUtf8 metadata

instance A.FromJSON Metadata where
  parseJSON = fmap parseMetadata . A.parseJSON

parseMetadata :: Map Text Text -> Metadata
parseMetadata keys = Metadata $ map encodeUtf8 (Map.mapKeys encodeUtf8 $ keys)

-- | Binary serialize account
encodeAccount :: Account -> ByteString
encodeAccount = S.encode

-- | Binary deserialize account
decodeAccount :: ByteString -> Either [Char] Account
decodeAccount = S.decode

accountKeyVal :: Account -> (Address.Address, Account)
accountKeyVal acct = (address acct, acct)

readAccount :: FilePath -> IO (Either Text Account)
readAccount fp =
    pure . either Left decodeAccountJSON =<< Utils.safeRead fp
  where
    decodeAccountJSON = first toS . A.eitherDecodeStrict

-------------------------------------------------------------------------------
-- Postgres DB
-------------------------------------------------------------------------------

instance ToField Metadata where
  toField = EscapeByteA . S.encode . Map.toList . unMetadata

instance FromField Metadata where
  fromField f mdata = do
    bs <- fromField f mdata
    case fmap Map.fromList . S.decode <$> bs of
      Nothing               -> returnError UnexpectedNull f ""
      Just (Left err)       -> returnError ConversionFailed f err
      Just (Right metadata) -> return $ Metadata metadata

instance FromRow Account
instance ToRow Account
