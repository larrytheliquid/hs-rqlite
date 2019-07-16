{-# LANGUAGE DeriveAnyClass      #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings   #-}

module Rqlite.Status
    ( RQStatus (..)
    , getLeader
    , retryUntilAlive
    , queryStatus
    ) where

import           Control.Concurrent (threadDelay)
import           Control.Arrow
import           Control.Exception
import           Data.Aeson hiding (Result)
import qualified Data.ByteString.Char8 as C8
import qualified Data.HashMap.Strict as M
import           Data.Scientific
import qualified Data.Text hiding (break, tail)
import           GHC.Generics
import           GHC.IO.Exception
import           Network.HTTP
import           Network.Stream

import           Rqlite

-- This module provides support for requesting the status of a node
-- The actual status has many more info than what @RQStatus@ contains.

queryStatus :: String -> IO RQStatus
queryStatus host = do
    resp <- reify $ simpleHTTP $ getRequest $ concat
            [ "http://"
            , host
            , "/status?pretty"
            ]
    case eitherDecodeStrict $ C8.pack $ resp of
            Left e -> throwIO $ UnexpectedResponse $ concat
                ["Got ", e, " while trying to decode ", resp, " as PostResult"]
            Right st -> return st

data RQState = Leader | Follower | UnknownState
    deriving (Show, Eq, Generic)

readState :: String -> RQState
readState "Leader"   = Leader
readState "Follower" = Follower
readState _          = UnknownState

-- | A subset of the status that a node reports.
data RQStatus = RQStatus {
      path           :: String
    , leader         :: Maybe String
    , peers          :: [String]
    , state          :: RQState
    , fk_constraints :: Bool
    } deriving (Show, Eq, Generic)

instance FromJSON RQStatus where
    parseJSON j = do
        Object o <- parseJSON j
        Object store <- o .: "store"
        pth <- store .: "dir"
        leader <- store .: "leader"
        let mLeader = if leader == "" then Nothing else Just leader
        peers :: [String] <- store .: "peers"
        sqliteInfo <- store .: "sqlite3"
        raft <- store .: "raft"
        st <- raft .: "state"
        let state = readState st
        fk' :: String <- sqliteInfo .: "fk_constraints"
        let fk = fk' /= "disabled"
        return $ RQStatus pth mLeader peers state fk

getLeader :: String -> IO (Maybe String)
getLeader host = do
    mstatus <- queryStatus host
    return $ leader mstatus

-- | This can be used to make sure that a node is alive, before starting to query it.
retryUntilAlive :: String -> IO Bool
retryUntilAlive host = go 15
    where
        go 0 = do
            putStrLn $ "Warning: Failed to get Status from " ++ host
            return False
        go n = do
            mStatus <- try $ queryStatus host
            case mStatus of
                Right _ -> return True
                Left (e :: IOError) | ioe_type e == NoSuchThing -> do
                    putStrLn $ "Warning: Got " ++ show e ++ " while trying to get Status from " ++ host ++ ". Trying again.."
                    threadDelay 1000000
                    go $ n-1
