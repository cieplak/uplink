{-|

Time and datetime types.

-}

module Time (
  -- ** Types
  Date,
  Timestamp,

  -- ** Unix Time
  now,
  validateTimestamp,
  validateTimestamp',
  validateTimestamp_,

  posixMicroSecsToDatetime,

) where

import Protolude
import Data.Time.Clock
import Data.Time.Clock.POSIX (getPOSIXTime)
import Data.Hourglass

import Datetime.Types (Datetime, posixToDatetime)

-- | GMT unix timestamp
type Timestamp = Int64

pastThreshold   = 86400 * 1000000 -- 1 day (microsecs)
futureThreshold = 900  * 1000000  -- 15 minutes (microsecs)

-- | Time now (in microseconds)
now :: IO Timestamp
now = round <$> (* 1000000) <$> getPOSIXTime

-- | Validates a timestamp against `now`, +/- hardcoded validation thresholds
validateTimestamp :: Timestamp -> IO Bool
validateTimestamp = validateTimestamp' pastThreshold futureThreshold

-- | Validates a timestamp against `now`, passing explicit past & future
-- thresholds
validateTimestamp' :: Int64 -> Int64 -> Timestamp -> IO Bool
validateTimestamp' pastThreshold' futureThreshold' n = do
  ts <- now
  pure $ and
    [ n < (ts + futureThreshold')
    , n > (ts - pastThreshold')
    ]

-- | Validates a timestamp `t2` against another timestamp `t1`
validateTimestamp_ :: Timestamp -> Timestamp -> Bool
validateTimestamp_ t1 t2 =
     t2 < (t1 + futureThreshold)
  && t2 > (t1 - pastThreshold)

-- | Converts a Posix timestamp to a Datetime value
-- Note: This function expects an Int64 Posix timstamp
-- represented in microseconds, NOT seconds.
posixMicroSecsToDatetime :: Int64 -> Datetime
posixMicroSecsToDatetime = posixToDatetime . (`div` 1000000)
