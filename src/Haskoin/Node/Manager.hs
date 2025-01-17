{-# LANGUAGE ConstraintKinds       #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TupleSections         #-}
module Haskoin.Node.Manager
    ( PeerManagerConfig (..)
    , PeerEvent (..)
    , OnlinePeer (..)
    , PeerManager
    , withPeerManager
    , managerBest
    , managerVersion
    , managerPing
    , managerPong
    , managerAddrs
    , managerVerAck
    , managerTickle
    , getPeers
    , getOnlinePeer
    , buildVersion
    , myVersion
    , toSockAddr
    , toHostService
    ) where

import           Control.Arrow
import           Control.Monad             (forM_, forever, guard, void, when,
                                            (<=<))
import           Control.Monad.Except      (ExceptT (..), runExceptT,
                                            throwError)
import           Control.Monad.Logger      (MonadLogger, MonadLoggerIO,
                                            logDebugS, logErrorS, logInfoS,
                                            logWarnS)
import           Control.Monad.Reader      (MonadReader, ReaderT (ReaderT), ask,
                                            asks, runReaderT)
import           Control.Monad.Trans       (lift)
import           Control.Monad.Trans.Maybe (MaybeT (..), runMaybeT)
import           Data.Bits                 ((.&.))
import           Data.Function             (on)
import           Data.List                 (find, nub, sort, dropWhileEnd, elemIndex)
import           Data.Maybe                (fromMaybe, isJust)
import           Data.Set                  (Set)
import qualified Data.Set                  as Set
import           Data.String.Conversions   (cs)
import           Data.Time.Clock           (NominalDiffTime, UTCTime,
                                            addUTCTime, diffUTCTime,
                                            getCurrentTime)
import           Data.Time.Clock.POSIX     (utcTimeToPOSIXSeconds)
import           Data.Word                 (Word32, Word64)
import           Haskoin                   (BlockHeight, Message (..),
                                            Network (..), NetworkAddress (..),
                                            Ping (..), Pong (..),
                                            VarString (..), Version (..),
                                            hostToSockAddr, nodeNetwork,
                                            sockToHostAddress)
import           Haskoin.Node.Peer
import           NQE                       (Child, Inbox, Mailbox, Publisher,
                                            Strategy (..), Supervisor, addChild,
                                            inboxToMailbox, newInbox,
                                            newMailbox, publish, receive,
                                            receiveMatch, send, sendSTM,
                                            withSupervisor)
import           Network.Socket            (AddrInfo (..), AddrInfoFlag (..),
                                            Family (..), SockAddr (..),
                                            SocketType (..), defaultHints,
                                            getAddrInfo)
import           System.Random             (randomIO, randomRIO)
import           UnliftIO                  (Async, MonadIO, MonadUnliftIO, STM,
                                            SomeException, TVar, atomically,
                                            catch, liftIO, link, modifyTVar,
                                            newTVarIO, readTVar, readTVarIO,
                                            withAsync, withRunInIO, writeTVar)
import           UnliftIO.Concurrent       (threadDelay)
import Control.Applicative ((<|>))

type MonadManager m = (MonadIO m, MonadReader PeerManager m)

data PeerEvent
    = PeerConnected !Peer
    | PeerDisconnected !Peer
    deriving Eq

data PeerManagerConfig =
    PeerManagerConfig
        { peerManagerMaxPeers :: !Int
        , peerManagerPeers    :: ![String]
        , peerManagerDiscover :: !Bool
        , peerManagerNetAddr  :: !NetworkAddress
        , peerManagerNetwork  :: !Network
        , peerManagerEvents   :: !(Publisher PeerEvent)
        , peerManagerTimeout  :: !NominalDiffTime
        , peerManagerMaxLife  :: !NominalDiffTime
        , peerManagerConnect  :: !(SockAddr -> WithConnection)
        , peerManagerPub      :: !(Publisher (Peer, Message))
        }

data PeerManager =
    PeerManager
        { myConfig     :: !PeerManagerConfig
        , mySupervisor :: !Supervisor
        , myMailbox    :: !(Mailbox ManagerMessage)
        , myBestBlock  :: !(TVar BlockHeight)
        , knownPeers   :: !(TVar (Set SockAddr))
        , onlinePeers  :: !(TVar [OnlinePeer])
        }

data ManagerMessage
    = Connect !SockAddr
    | CheckPeer !Peer
    | PeerDied !Child !(Maybe SomeException)
    | ManagerBest !BlockHeight
    | PeerVerAck !Peer
    | PeerVersion !Peer !Version
    | PeerPing !Peer !Word64
    | PeerPong !Peer !Word64
    | PeerAddrs !Peer ![NetworkAddress]
    | PeerTickle !Peer

-- | Data structure representing an online peer.
data OnlinePeer =
    OnlinePeer
        { onlinePeerAddress     :: !SockAddr
        , onlinePeerVerAck      :: !Bool
        , onlinePeerConnected   :: !Bool
        , onlinePeerVersion     :: !(Maybe Version)
        , onlinePeerAsync       :: !(Async ())
        , onlinePeerMailbox     :: !Peer
        , onlinePeerNonce       :: !Word64
        , onlinePeerPing        :: !(Maybe (UTCTime, Word64))
        , onlinePeerPings       :: ![NominalDiffTime]
        , onlinePeerConnectTime :: !UTCTime
        , onlinePeerTickled     :: !UTCTime
        , onlinePeerDisconnect  :: !UTCTime
        }

instance Eq OnlinePeer where
    (==) = (==) `on` f
      where
        f OnlinePeer {onlinePeerMailbox = p} = p

instance Ord OnlinePeer where
    compare = compare `on` f
      where
        f OnlinePeer {onlinePeerPings = pings} = fromMaybe 60 (median pings)

withPeerManager :: (MonadUnliftIO m, MonadLoggerIO m)
                => PeerManagerConfig
                -> (PeerManager -> m a)
                -> m a
withPeerManager cfg action = do
    inbox <- newInbox
    let mgr = inboxToMailbox inbox
    withSupervisor (Notify (death mgr)) $ \sup -> do
        bb <- newTVarIO 0
        kp <- newTVarIO Set.empty
        ob <- newTVarIO []
        let rd = PeerManager { myConfig = cfg
                             , mySupervisor = sup
                             , myMailbox = mgr
                             , myBestBlock = bb
                             , knownPeers = kp
                             , onlinePeers = ob
                             }
        go inbox `runReaderT` rd
  where
    death mgr (a, ex) = PeerDied a ex `sendSTM` mgr
    go inbox =
        withAsync (peerManager inbox) $ \a ->
        withConnectLoop $
        link a >> ReaderT action

peerManager :: ( MonadUnliftIO m
               , MonadManager m
               , MonadLoggerIO m )
            => Inbox ManagerMessage
            -> m ()
peerManager inb = do
    $(logDebugS) "PeerManager" "Awaiting best block"
    putBestBlock <=< receiveMatch inb $ \case
        ManagerBest b -> Just b
        _             -> Nothing
    $(logDebugS) "PeerManager" "Starting peer manager actor"
    forever loop
  where
    loop = do
        m <- receive inb
        managerMessage m

putBestBlock :: MonadManager m => BlockHeight -> m ()
putBestBlock bb = do
    b <- asks myBestBlock
    atomically $ writeTVar b bb

getBestBlock :: MonadManager m => m BlockHeight
getBestBlock =
    asks myBestBlock >>= readTVarIO

getNetwork :: MonadManager m => m Network
getNetwork =
    asks (peerManagerNetwork . myConfig)

loadPeers :: (MonadUnliftIO m, MonadManager m) => m ()
loadPeers = do
    loadStaticPeers
    loadNetSeeds

loadStaticPeers :: (MonadUnliftIO m, MonadManager m) => m ()
loadStaticPeers = do
    net <- asks (peerManagerNetwork . myConfig)
    xs <- asks (peerManagerPeers . myConfig)
    mapM_ newPeer . concat =<< mapM (toSockAddr net) xs

loadNetSeeds :: (MonadUnliftIO m, MonadManager m) => m ()
loadNetSeeds =
    asks (peerManagerDiscover . myConfig) >>= \discover ->
        when discover $ do
            net <- getNetwork
            ss <- concat <$> mapM (toSockAddr net) (getSeeds net)
            mapM_ newPeer ss

logConnectedPeers :: (MonadManager m, MonadLoggerIO m) => m ()
logConnectedPeers = do
    m <- asks (peerManagerMaxPeers . myConfig)
    l <- length <$> getConnectedPeers
    $(logInfoS) "PeerManager" $
        "Peers connected: " <> cs (show l) <> "/" <> cs (show m)

getOnlinePeers :: MonadManager m => m [OnlinePeer]
getOnlinePeers =
    asks onlinePeers >>= readTVarIO

getConnectedPeers :: MonadManager m => m [OnlinePeer]
getConnectedPeers =
    filter onlinePeerConnected <$> getOnlinePeers

managerEvent :: MonadManager m => PeerEvent -> m ()
managerEvent e =
    publish e =<< asks (peerManagerEvents . myConfig)

managerMessage :: ( MonadUnliftIO m
                  , MonadManager m
                  , MonadLoggerIO m )
               => ManagerMessage
               -> m ()

managerMessage (PeerVersion p v) = do
    b <- asks onlinePeers
    e <- runExceptT $ do
        o <- ExceptT . atomically $ setPeerVersion b p v
        when (onlinePeerConnected o) $ announcePeer p
    case e of
        Right () -> do
            $(logDebugS) "PeerManager" $
                "Sending version ack to peer: " <> peerText p
            MVerAck `sendMessage` p
        Left x -> do
            $(logErrorS) "PeerManager" $
                "Version rejected for peer "
                <> peerText p <> ": " <> cs (show x)
            killPeer x p

managerMessage (PeerVerAck p) = do
    b <- asks onlinePeers
    atomically (setPeerVerAck b p) >>= \case
        Just o -> do
            $(logDebugS) "PeerManager" $
                "Received version ack from peer: "
                <> peerText p
            when (onlinePeerConnected o) $
                announcePeer p
        Nothing -> do
            $(logErrorS) "PeerManager" $
                "Received verack from unknown peer: "
                <> peerText p
            killPeer UnknownPeer p

managerMessage (PeerAddrs p nas) = do
    discover <- asks (peerManagerDiscover . myConfig)
    when discover $ do
        let sas = map (hostToSockAddr . naAddress) nas
        forM_ (zip [(1 :: Int) ..] sas) $ \(i, a) -> do
            $(logDebugS) "PeerManager" $
                "Got peer address "
                <> cs (show i) <> "/" <> cs (show (length sas))
                <> ": " <> cs (show a)
                <> " from peer " <> peerText p
            newPeer a

managerMessage (PeerPong p n) = do
    b <- asks onlinePeers
    $(logDebugS) "PeerManager" $
        "Received pong "
        <> cs (show n)
        <> " from: " <> peerText p
    now <- liftIO getCurrentTime
    atomically (gotPong b n now p)

managerMessage (PeerPing p n) = do
    $(logDebugS) "PeerManager" $
        "Responding to ping "
        <> cs (show n)
        <> " from: " <> peerText p
    MPong (Pong n) `sendMessage` p

managerMessage (ManagerBest h) =
    putBestBlock h

managerMessage (Connect sa) =
    connectPeer sa

managerMessage (PeerDied a e) =
    processPeerOffline a e

managerMessage (CheckPeer p) =
    checkPeer p

managerMessage (PeerTickle p) = do
    b <- asks onlinePeers
    now <- liftIO getCurrentTime
    atomically $
        modifyPeer b p $ \o ->
        o { onlinePeerTickled = now }

checkPeer :: (MonadManager m, MonadLoggerIO m) => Peer -> m ()
checkPeer p =
    getBusy p >>= \case
        True -> return ()
        False -> do
            to <- asks (peerManagerTimeout . myConfig)
            b <- asks onlinePeers
            atomically (findPeer b p) >>= \case
                Nothing -> return ()
                Just o -> do
                    now <- liftIO getCurrentTime
                    check_conn now o
                    when (check_tickle now to o) (check_ping o)
  where
    check_tickle now to o =
        now `diffUTCTime` onlinePeerTickled o > to
    check_conn now o =
        when (now `diffUTCTime` onlinePeerDisconnect o > 0) $
        killPeer PeerTooOld p
    check_ping o =
        case onlinePeerPing o of
            Nothing ->
                sendPing p
            Just _ -> do
                $(logWarnS) "PeerManager" $
                    "Peer ping timeout: " <> peerText p
                killPeer PeerTimeout p

sendPing :: (MonadManager m, MonadLoggerIO m) => Peer -> m ()
sendPing p = do
    b <- asks onlinePeers
    atomically (findPeer b p) >>= \case
        Nothing ->
            $(logWarnS) "PeerManager" $
            "Will not ping unknown peer: " <> peerText p
        Just o
            | onlinePeerConnected o -> do
                n <- liftIO randomIO
                now <- liftIO getCurrentTime
                atomically (setPeerPing b n now p)
                $(logDebugS)" PeerManager" $
                    "Sending ping " <> cs (show n)
                    <> " to: " <> peerText p
                MPing (Ping n) `sendMessage` p
            | otherwise -> return ()

processPeerOffline :: (MonadManager m, MonadLoggerIO m)
                   => Child -> Maybe SomeException -> m ()
processPeerOffline a e = do
    b <- asks onlinePeers
    atomically (findPeerAsync b a) >>= \case
        Nothing -> log_unknown e
        Just o -> do
            let p = onlinePeerMailbox o
            if onlinePeerConnected o
                then do
                    log_disconnected p e
                    managerEvent $ PeerDisconnected p
                else log_not_connect p e
            atomically $ removePeer b p
            logConnectedPeers
  where
    log_unknown Nothing =
        $(logErrorS) "PeerManager"
        "Disconnected unknown peer"
    log_unknown (Just x) =
        $(logErrorS) "PeerManager" $
        "Unknown peer died: " <> cs (show x)
    log_disconnected p Nothing =
        $(logWarnS) "PeerManager" $
        "Disconnected peer: " <> peerText p
    log_disconnected p (Just x) =
        $(logErrorS) "PeerManager" $
        "Peer " <> peerText p <> " died: " <> cs (show x)
    log_not_connect p Nothing =
        $(logWarnS) "PeerManager" $
        "Could not connect to peer " <> peerText p
    log_not_connect p (Just x) =
        $(logErrorS) "PeerManager" $
        "Could not connect to peer "
        <> peerText p <> ": " <> cs (show x)

announcePeer :: (MonadManager m, MonadLoggerIO m) => Peer -> m ()
announcePeer p = do
    b <- asks onlinePeers
    atomically (findPeer b p) >>= \case
        Just OnlinePeer {onlinePeerConnected = True} -> do
            $(logInfoS) "PeerManager" $
                "Connected to peer " <> peerText p
            managerEvent $ PeerConnected p
            logConnectedPeers
        Just OnlinePeer {onlinePeerConnected = False} ->
            return ()
        Nothing ->
            $(logErrorS) "PeerManager" $
            "Not announcing disconnected peer: "
            <> peerText p

getNewPeer :: (MonadUnliftIO m, MonadManager m) => m (Maybe SockAddr)
getNewPeer =
    runMaybeT $ lift loadPeers >> go
  where
    go = do
        b <- asks knownPeers
        ks <- readTVarIO b
        guard . not $ Set.null ks
        let xs = Set.toList ks
        a <- liftIO $ randomRIO (0, length xs - 1)
        let p = xs !! a
        o <- asks onlinePeers
        m <- atomically $ do
            modifyTVar b $ Set.delete p
            findPeerAddress o p
        maybe (return p) (const go) m


connectPeer :: ( MonadUnliftIO m
               , MonadManager m
               , MonadLoggerIO m
               )
            => SockAddr
            -> m ()
connectPeer sa = do
    os <- asks onlinePeers
    atomically (findPeerAddress os sa) >>= \case
        Just _ ->
            $(logErrorS) "PeerManager" $
            "Attempted to connect to peer twice: " <> cs (show sa)
        Nothing -> do
            $(logInfoS) "PeerManager" $ "Connecting to " <> cs (show sa)
            PeerManagerConfig { peerManagerNetAddr = ad
                              , peerManagerNetwork = net
                              } <- asks myConfig
            sup <- asks mySupervisor
            conn <- asks (peerManagerConnect . myConfig)
            pub <- asks (peerManagerPub . myConfig)
            nonce <- liftIO randomIO
            bb <- getBestBlock
            now <- liftIO getCurrentTime
            let rmt = NetworkAddress (srv net) (sockToHostAddress sa)
                unix = floor (utcTimeToPOSIXSeconds now)
                ver = buildVersion net nonce bb ad rmt unix
                text = cs (show sa)
            (inbox, mailbox) <- newMailbox
            let pc = PeerConfig { peerConfPub = pub
                                , peerConfNetwork = net
                                , peerConfText = text
                                , peerConfConnect = conn sa
                                }
            busy <- newTVarIO False
            p <- wrapPeer pc busy mailbox
            a <- withRunInIO $ \io ->
                sup `addChild` io (launch pc busy inbox p)
            MVersion ver `sendMessage` p
            b <- asks onlinePeers
            max_life <- asks (peerManagerMaxLife . myConfig)
            rand <- liftIO $ toRational <$> randomRIO (0.75 :: Double, 1.00)
            let life = max_life * fromRational rand
            let dc = life `addUTCTime` now
            _ <- atomically $ newOnlinePeer b sa nonce p a now dc
            return ()
  where
    srv net
        | getSegWit net = 8
        | otherwise = 0
    launch pc busy inbox p =
        ask >>= \mgr ->
        withPeerLoop sa p mgr $ \a ->
        link a >> peer pc busy inbox

withPeerLoop ::
       (MonadUnliftIO m, MonadLogger m)
    => SockAddr
    -> Peer
    -> PeerManager
    -> (Async a -> m a)
    -> m a
withPeerLoop _ p mgr =
    withAsync . forever $ do
        let x = peerManagerTimeout (myConfig mgr)
            y = floor (x * 1000000)
        r <- liftIO $ randomRIO (y * 3 `div` 4, y)
        threadDelay r
        managerCheck p mgr

withConnectLoop :: (MonadUnliftIO m, MonadManager m)
                => m a
                -> m a
withConnectLoop act =
    withAsync go $ \a ->
    link a >> act
  where
    go = forever $ do
        l <- length <$> getOnlinePeers
        x <- asks (peerManagerMaxPeers . myConfig)
        when (l < x) $
            getNewPeer >>= mapM_ (\sa -> ask >>= managerConnect sa)
        delay <- liftIO $
            randomRIO ( 100 * 1000
                      , 10 * 500 * 1000 )
        threadDelay delay

newPeer :: (MonadIO m, MonadManager m) => SockAddr -> m ()
newPeer sa = do
    b <- asks knownPeers
    o <- asks onlinePeers
    atomically $
        findPeerAddress o sa >>= \case
            Just _  -> return ()
            Nothing -> modifyTVar b $ Set.insert sa

gotPong :: TVar [OnlinePeer] -> Word64 -> UTCTime -> Peer -> STM ()
gotPong b nonce now p = void . runMaybeT $ do
    o <- MaybeT $ findPeer b p
    (time, old_nonce) <- MaybeT . return $ onlinePeerPing o
    guard $ nonce == old_nonce
    let diff = now `diffUTCTime` time
    lift $
        insertPeer
            b
            o { onlinePeerPing = Nothing
              , onlinePeerPings = sort $ take 11 $ diff : onlinePeerPings o
              }

setPeerPing :: TVar [OnlinePeer] -> Word64 -> UTCTime -> Peer -> STM ()
setPeerPing b nonce now p =
    modifyPeer b p $ \o -> o {onlinePeerPing = Just (now, nonce)}

setPeerVersion ::
       TVar [OnlinePeer]
    -> Peer
    -> Version
    -> STM (Either PeerException OnlinePeer)
setPeerVersion b p v = runExceptT $ do
    when (services v .&. nodeNetwork == 0) $
        throwError NotNetworkPeer
    ops <- lift $ readTVar b
    when (any ((verNonce v ==) . onlinePeerNonce) ops) $
        throwError PeerIsMyself
    lift (findPeer b p) >>= \case
        Nothing -> throwError UnknownPeer
        Just o -> do
            let n = o { onlinePeerVersion = Just v
                      , onlinePeerConnected = onlinePeerVerAck o }
            lift $ insertPeer b n
            return n

setPeerVerAck :: TVar [OnlinePeer] -> Peer -> STM (Maybe OnlinePeer)
setPeerVerAck b p = runMaybeT $ do
    o <- MaybeT $ findPeer b p
    let n = o { onlinePeerVerAck = True
              , onlinePeerConnected = isJust (onlinePeerVersion o) }
    lift $ insertPeer b n
    return n

newOnlinePeer ::
       TVar [OnlinePeer]
    -> SockAddr
    -> Word64
    -> Peer
    -> Async ()
    -> UTCTime
    -> UTCTime
    -> STM OnlinePeer
newOnlinePeer box addr nonce p peer_async connect_time dc = do
    let op = OnlinePeer
             { onlinePeerAddress = addr
             , onlinePeerVerAck = False
             , onlinePeerConnected = False
             , onlinePeerVersion = Nothing
             , onlinePeerAsync = peer_async
             , onlinePeerMailbox = p
             , onlinePeerNonce = nonce
             , onlinePeerPings = []
             , onlinePeerPing = Nothing
             , onlinePeerConnectTime = connect_time
             , onlinePeerTickled = connect_time
             , onlinePeerDisconnect = dc
             }
    insertPeer box op
    return op

findPeer :: TVar [OnlinePeer] -> Peer -> STM (Maybe OnlinePeer)
findPeer b p =
    find ((== p) . onlinePeerMailbox)
    <$> readTVar b

insertPeer :: TVar [OnlinePeer] -> OnlinePeer -> STM ()
insertPeer b o =
    modifyTVar b $ \x -> sort . nub $ o : x

modifyPeer :: TVar [OnlinePeer]
           -> Peer
           -> (OnlinePeer -> OnlinePeer)
           -> STM ()
modifyPeer b p f =
    findPeer b p >>= \case
        Nothing -> return ()
        Just o  -> insertPeer b $ f o

removePeer :: TVar [OnlinePeer] -> Peer -> STM ()
removePeer b p =
    modifyTVar b $
    filter ((/= p) . onlinePeerMailbox)

findPeerAsync :: TVar [OnlinePeer]
              -> Async ()
              -> STM (Maybe OnlinePeer)
findPeerAsync b a =
    find ((== a) . onlinePeerAsync)
    <$> readTVar b

findPeerAddress :: TVar [OnlinePeer]
                -> SockAddr
                -> STM (Maybe OnlinePeer)
findPeerAddress b a =
    find ((== a) . onlinePeerAddress)
    <$> readTVar b

getPeers :: MonadIO m => PeerManager -> m [OnlinePeer]
getPeers = runReaderT getConnectedPeers

getOnlinePeer :: MonadIO m
              => Peer
              -> PeerManager
              -> m (Maybe OnlinePeer)
getOnlinePeer p =
    runReaderT $ asks onlinePeers >>= atomically . (`findPeer` p)

managerCheck :: MonadIO m => Peer -> PeerManager -> m ()
managerCheck p mgr =
    CheckPeer p `send` myMailbox mgr

managerConnect :: MonadIO m => SockAddr -> PeerManager -> m ()
managerConnect sa mgr =
    Connect sa `send` myMailbox mgr

managerBest :: MonadIO m => BlockHeight -> PeerManager -> m ()
managerBest bh mgr =
    ManagerBest bh `send` myMailbox mgr

managerVerAck :: MonadIO m => Peer -> PeerManager -> m ()
managerVerAck p mgr =
    PeerVerAck p `send` myMailbox mgr

managerVersion :: MonadIO m
               => Peer -> Version -> PeerManager -> m ()
managerVersion p ver mgr =
    PeerVersion p ver `send` myMailbox mgr

managerPing :: MonadIO m
            => Peer -> Word64 -> PeerManager -> m ()
managerPing p nonce mgr =
    PeerPing p nonce `send` myMailbox mgr

managerPong :: MonadIO m
            => Peer -> Word64 -> PeerManager -> m ()
managerPong p nonce mgr =
    PeerPong p nonce `send` myMailbox mgr

managerAddrs :: MonadIO m
             => Peer -> [NetworkAddress] -> PeerManager -> m ()
managerAddrs p addrs mgr =
    PeerAddrs p addrs `send` myMailbox mgr

managerTickle :: MonadIO m
              => Peer -> PeerManager -> m ()
managerTickle p mgr =
    PeerTickle p `send` myMailbox mgr

toHostService :: String -> (Maybe String, Maybe String)
toHostService str =
    let host = case m6 of
            Just (x, _) -> Just x
            Nothing -> case takeWhile (/= ':') str of
                [] -> Nothing
                xs -> Just xs
        srv = case m6 of
            Just (_, y) -> s y
            Nothing -> s str
        s xs =
            case dropWhile (/= ':') xs of
                [] -> Nothing
                _ : ys -> Just ys
        m6 = case str of
            (x : xs)
                | x == '[' -> do
                    i <- elemIndex ']' xs
                    return $ second tail $ splitAt i xs
                | x == ':' -> do
                    return (str, "")
            _ -> Nothing
    in (host, srv)

toSockAddr :: MonadUnliftIO m => Network -> String -> m [SockAddr]
toSockAddr net str = 
    go `catch` e
  where
    go = fmap (map addrAddress) $ liftIO $ getAddrInfo Nothing host srv
    (host, srv) = 
        second (<|> Just (show (getDefaultPort net))) $
        toHostService str
    e :: Monad m => SomeException -> m [SockAddr]
    e _ = return []

median :: (Ord a, Fractional a) => [a] -> Maybe a
median ls
    | null ls =
          Nothing
    | even (length ls) =
          Just . (/ 2) . sum . take 2 $
          drop (length ls `div` 2 - 1) ls'
    | otherwise =
          Just (ls' !! (length ls `div` 2))
  where
    ls' = sort ls

buildVersion
    :: Network
    -> Word64
    -> BlockHeight
    -> NetworkAddress
    -> NetworkAddress
    -> Word64
    -> Version
buildVersion net nonce height loc rmt time =
    Version
        { version = myVersion
        , services = naServices loc
        , timestamp = time
        , addrRecv = rmt
        , addrSend = loc
        , verNonce = nonce
        , userAgent = VarString (getHaskoinUserAgent net)
        , startHeight = height
        , relay = True
        }

myVersion :: Word32
myVersion = 70012
