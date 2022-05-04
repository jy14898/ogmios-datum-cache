module Block.Fetch (
    OgmiosWorkerMVar (MkOgmiosWorkerMVar),
    OgmiosInfo (..),
    StartBlockFetcherError (..),
    StopBlockFetcherError (..),
    startBlockFetcher,
    stopBlockFetcher,
    isBlockFetcherRunning,
    createStoppedFetcher,
) where

import Control.Concurrent.MVar (MVar, isEmptyMVar, newEmptyMVar, tryPutMVar, tryTakeMVar)
import Control.Exception (Exception, onException)
import Control.Monad (forever, unless, void)
import Control.Monad.IO.Class (MonadIO)
import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.Logger (MonadLogger, logErrorNS, logInfoNS, logWarnNS, runStdoutLoggingT)
import Control.Monad.Reader qualified as Reader
import Control.Monad.Reader.Has (Has, MonadReader, ask, runReaderT)
import Control.Monad.Trans (liftIO)
import Data.Aeson qualified as Json
import Data.ByteString.Base64 qualified as BSBase64
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text
import Hasql.Connection qualified as Hasql
import Network.WebSockets qualified as WS
import UnliftIO.Async (Async)
import UnliftIO.Async qualified as Async
import UnliftIO.Concurrent (threadDelay)

import Block.Filter (DatumFilter, runDatumFilter)
import Block.Types (
    AlonzoBlock (..),
    AlonzoBlockHeader (..),
    AlonzoTransaction (..),
    Block (..),
    BlockInfo (BlockInfo),
    FindIntersectResult (..),
    OgmiosFindIntersectResponse,
    OgmiosRequestNextResponse,
    OgmiosResponse (..),
    RequestNextResult (..),
    mkFindIntersectRequest,
    mkRequestNextRequest,
 )
import Database (saveDatums, updateLastBlock)

data OgmiosInfo = OgmiosInfo
    { ogmiosPort :: Int
    , ogmiosAddress :: String
    }

newtype OgmiosWorkerMVar = MkOgmiosWorkerMVar (MVar (Async ()))

data StartBlockFetcherError
    = StartBlockFetcherErrorAlreadyRunning
    deriving stock (Show)

startBlockFetcher ::
    ( MonadIO m
    , MonadUnliftIO m
    , MonadReader r m
    , Has OgmiosWorkerMVar r
    , Has OgmiosInfo r
    , Has Hasql.Connection r
    ) =>
    BlockInfo ->
    DatumFilter ->
    m (Either StartBlockFetcherError ())
startBlockFetcher blockInfo datumFilter = do
    OgmiosInfo ogmiosPort ogmiosAddress <- ask
    MkOgmiosWorkerMVar envOgmiosWorker <- ask
    env <- Reader.ask

    let runStack = runStdoutLoggingT . flip runReaderT env

    let errorHandler = runStack $ do
            logErrorNS "ogmiosWorker" "Error starting ogmios client"
            stopBlockFetcher

    let runOgmiosClient =
            WS.runClient ogmiosAddress ogmiosPort "" $ \wsConn ->
                runStack $ Right <$> wsApp wsConn blockInfo datumFilter

    ogmiosWorker <- liftIO $
        Async.async $ do
            runStdoutLoggingT $ logInfoNS "ogmiosWorker" "Starting ogmios client"
            runOgmiosClient `onException` errorHandler

    putSuccessful <- liftIO $ tryPutMVar envOgmiosWorker $ void ogmiosWorker
    pure $ unless putSuccessful $ Left StartBlockFetcherErrorAlreadyRunning

isBlockFetcherRunning :: (MonadIO m) => OgmiosWorkerMVar -> m Bool
isBlockFetcherRunning (MkOgmiosWorkerMVar mvar) = liftIO $ isEmptyMVar mvar

data StopBlockFetcherError
    = StopBlockFetcherErrorNotRunning
    deriving stock (Show, Eq)

stopBlockFetcher ::
    (MonadIO m, MonadReader r m, Has OgmiosWorkerMVar r) =>
    m (Either StopBlockFetcherError ())
stopBlockFetcher = do
    MkOgmiosWorkerMVar envOgmiosWorker <- ask
    ogmiosWorker' <- liftIO $ tryTakeMVar envOgmiosWorker
    case ogmiosWorker' of
        Just ogmiosWorker -> do
            liftIO $ Async.cancel ogmiosWorker
            pure . pure $ ()
        Nothing -> pure $ Left StopBlockFetcherErrorNotRunning

createStoppedFetcher :: MonadIO m => m OgmiosWorkerMVar
createStoppedFetcher = MkOgmiosWorkerMVar <$> liftIO newEmptyMVar

receiveLoop ::
    ( MonadIO m
    , MonadUnliftIO m
    , MonadLogger m
    , MonadReader r m
    , Has Hasql.Connection r
    ) =>
    WS.Connection ->
    DatumFilter ->
    m ()
receiveLoop conn datumFilter = do
    jsonMsg <- liftIO $ WS.receiveData conn
    let msg = Json.decode @OgmiosFindIntersectResponse jsonMsg
    case _result <$> msg of
        Nothing -> do
            logErrorNS "receiveLoop" "Error decoding FindIntersect response"
        Just (IntersectionNotFound _) -> do
            logErrorNS "receiveLoop" "Find intersection error: Intersection not found. Consider restarting block fetcher with different block info"
        Just (IntersectionFound _ _) -> do
            logInfoNS "receiveLoop" "Find intersection: intersection found, starting RequestNext loop"
            Async.withAsync (receiveBlocksLoop conn datumFilter) $ \receiveBlocksWorker -> do
                Async.link receiveBlocksWorker
                requestRemainingBlocks conn
                Async.wait receiveBlocksWorker

-- b3faa2bc1465aa0d8500655981108904e5a7a9339be5fc1e6a9754088a4456c1
-- dd5733ec572c904a98376ecce6759c943b8fa05d2765aaef3cb50cd016d620e9

-- Why it's neccesary?
debounce ::
    MonadIO m =>
    m ()
debounce = liftIO $ threadDelay 10

requestRemainingBlocks ::
    MonadIO m =>
    WS.Connection ->
    m ()
requestRemainingBlocks conn = forever $ do
    liftIO $ WS.sendTextData conn (Json.encode $ mkRequestNextRequest 0)
    debounce

receiveBlocksLoop ::
    (MonadIO m, MonadLogger m, MonadReader r m, Has Hasql.Connection r) =>
    WS.Connection ->
    DatumFilter ->
    m ()
receiveBlocksLoop conn datumFilter = forever $ do
    jsonMsg <- liftIO $ WS.receiveData conn
    let msg = Json.eitherDecode @OgmiosRequestNextResponse jsonMsg
    case _result <$> msg of
        Left e ->
            logErrorNS "receiveBlocksLoop" $ Text.pack $ "Error decoding RequestNext response: " <> e
        Right (RollBackward _point _tip) ->
            logWarnNS "receiveBlocksLoop" "Received RollBackward response"
        Right (RollForward OtherBlock _tip) ->
            logWarnNS "receiveBlocksLoop" "Received non-Alonzo block in the RollForward response"
        Right (RollForward (MkAlonzoBlock block) _tip) -> do
            logInfoNS "receiveBlocksLoop" $
                Text.pack $ "Processing block: " <> show (slot $ header block, headerHash block)
            saveDatumsFromAlonzoBlock block datumFilter
            case headerHash block of
                Just headerHash' ->
                    updateLastBlock $ BlockInfo (slot $ header block) headerHash'
                Nothing ->
                    logWarnNS "receiveBlocksLoop" $ Text.pack $ "Block without header hash: " <> show block

saveDatumsFromAlonzoBlock ::
    (MonadIO m, MonadLogger m, MonadReader r m, Has Hasql.Connection r) =>
    AlonzoBlock ->
    DatumFilter ->
    m ()
saveDatumsFromAlonzoBlock block datumFilter = do
    let txs = body block
    let requestedDatums =
            Map.fromList
                . concatMap (\tx -> (filter (runDatumFilter datumFilter tx) . Map.toList . datums) tx)
                $ txs
    let decodeDatumValue = BSBase64.decodeBase64 . Text.encodeUtf8
    let (failedDecodings, requestedDatumsWithDecodedValues) = Map.mapEither decodeDatumValue requestedDatums
    unless (null failedDecodings) $ do
        logErrorNS "saveDatumsFromAlonzoBlock" $
            "Error decoding values for datums: " <> Text.intercalate ", " (Map.keys failedDecodings)
        pure ()
    let datums = Map.toList requestedDatumsWithDecodedValues
    unless (null datums) $ saveDatums datums

wsApp ::
    ( MonadIO m
    , MonadUnliftIO m
    , MonadLogger m
    , MonadReader r m
    , Has Hasql.Connection r
    ) =>
    WS.Connection ->
    BlockInfo ->
    DatumFilter ->
    m ()
wsApp conn blockInfo datumFilter = do
    logInfoNS "wsApp" "Connected to ogmios websocket"
    Async.withAsync (receiveLoop conn datumFilter) $ \receiveWorker -> do
        Async.link receiveWorker
        logInfoNS "wsApp" $ Text.pack $ "Starting fetcher from block: " <> show blockInfo
        let findIntersectRequest = mkFindIntersectRequest blockInfo
        liftIO $ WS.sendTextData conn (Json.encode findIntersectRequest)
        debounce
        Async.wait receiveWorker
        liftIO $ WS.sendClose conn ("Fin" :: Text)

newtype FindIntersectException = FindIntersectException Text
    deriving stock (Eq, Show)
    deriving anyclass (Exception)
