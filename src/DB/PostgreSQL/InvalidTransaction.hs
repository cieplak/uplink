{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}

module DB.PostgreSQL.InvalidTransaction (

  -- ** Types
  InvalidTxRow(..),

  -- ** Conversions
  invalidTxToRowType,
  rowTypeToInvalidTx,

  -- ** Queries
  queryInvalidTxByHash,
  queryInvalidTxs,

  -- ** Inserts
  insertInvalidTx,
  insertInvalidTxs,

  -- ** Deletions
  deleteInvalidTxs,

) where

import Protolude

import qualified Data.Text as Text
import qualified Data.Serialize as S

import Address
import Transaction ( Transaction(..)
                   , InvalidTransaction(..)
                   , TransactionHeader
                   , TxValidationError
                   , base16HashInvalidTx
                   )

import DB.PostgreSQL.Error

import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.ToRow
import Database.PostgreSQL.Simple.ToField

--------------------------------------------------------------------------------
-- Types and Conversions
--------------------------------------------------------------------------------

data InvalidTxRow = InvalidTxRow
  { itxHash       :: ByteString
  , itxHeader     :: TransactionHeader
  , itxSignature  :: ByteString
  , itxOrigin     :: Address
  , itxTimestamp  :: Int64
  , itxReason     :: TxValidationError
  } deriving (Generic)

instance ToRow InvalidTxRow
instance FromRow InvalidTxRow

invalidTxToRowType :: InvalidTransaction -> InvalidTxRow
invalidTxToRowType itx@(InvalidTransaction Transaction{..} reason) =
  InvalidTxRow
    { itxHash       = base16HashInvalidTx itx
    , itxHeader     = header
    , itxSignature  = signature
    , itxOrigin     = origin
    , itxTimestamp  = timestamp
    , itxReason     = reason
    }

rowTypeToInvalidTx :: InvalidTxRow -> InvalidTransaction
rowTypeToInvalidTx InvalidTxRow{..} = do
    InvalidTransaction
      { transaction = transaction'
      , reason      = itxReason
      }
  where
    transaction' = Transaction
      { header    = itxHeader
      , signature = itxSignature
      , origin    = itxOrigin
      , timestamp = itxTimestamp
      }

--------------------------------------------------------------------------------
-- Queries (SELECTs)
--------------------------------------------------------------------------------

queryInvalidTxByHash
  :: Connection
  -> ByteString -- ^ must be base16 encoded sha3_256 hash
  -> IO (Either PostgreSQLError InvalidTransaction)
queryInvalidTxByHash conn b16itxHash = do
  eRows <- querySafe conn "SELECT (hash,header,signature,origin,timestamp,reason FROM invalidtxs WHERE hash=?" (Only b16itxHash)
  case fmap headMay eRows of
    Left err         -> pure $ Left err
    Right Nothing    -> pure $ Left $ InvalidTxDoesNotExist b16itxHash
    Right (Just itx) -> pure $ Right $ rowTypeToInvalidTx itx

queryInvalidTxs :: Connection -> IO (Either PostgreSQLError [InvalidTransaction])
queryInvalidTxs conn =
  second (map rowTypeToInvalidTx) <$> queryInvalidTxRows conn

queryInvalidTxRows :: Connection -> IO (Either PostgreSQLError [InvalidTxRow])
queryInvalidTxRows conn =
  querySafe_ conn "SELECT hash,header,signature,origin,timestamp,reason FROM invalidtxs"

--------------------------------------------------------------------------------
-- Inserts
--------------------------------------------------------------------------------

insertInvalidTx :: Connection -> InvalidTransaction -> IO (Either PostgreSQLError Int64)
insertInvalidTx conn itx = insertInvalidTxs conn [itx]

insertInvalidTxs :: Connection -> [InvalidTransaction] -> IO (Either PostgreSQLError Int64)
insertInvalidTxs conn itxs =
  insertInvalidTxRows conn $
    map invalidTxToRowType itxs

insertInvalidTxRow :: Connection -> InvalidTxRow -> IO (Either PostgreSQLError Int64)
insertInvalidTxRow conn itxRow = insertInvalidTxRows conn [itxRow]

insertInvalidTxRows :: Connection -> [InvalidTxRow] -> IO (Either PostgreSQLError Int64)
insertInvalidTxRows conn itxRows =
  executeManySafe conn "INSERT INTO invalidtxs (hash,header,signature,origin,timestamp,reason) VALUES (?,?,?,?,?,?)" itxRows

--------------------------------------------------------------------------------
-- Deletions
--------------------------------------------------------------------------------

deleteInvalidTxs :: Connection -> IO (Either PostgreSQLError Int64)
deleteInvalidTxs conn =
  executeSafe_ conn "DELETE FROM invalidtxs"
