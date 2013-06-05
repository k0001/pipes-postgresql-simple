{-# LANGUAGE OverloadedStrings #-}
module Control.Proxy.PostgreSQL.Simple where

import qualified Control.Concurrent.Async as Async

import Data.Function (fix)
import Data.String (fromString)
import Control.Monad (forever, void, when)
import Control.Monad.Trans (lift)
import Data.ByteString (ByteString)
import Data.Text ()
import Data.Text.Encoding

import qualified Control.Proxy as Pipes
import qualified Database.PostgreSQL.Simple as Pg
import qualified Database.PostgreSQL.Simple.Internal as Pg
import qualified Database.PostgreSQL.LibPQ as LibPQ
import qualified Control.Proxy.Concurrent as Pipes

import qualified Control.Concurrent.STM as STM

--------------------------------------------------------------------------------
query :: (Pg.FromRow r, Pipes.Proxy p, Pg.ToRow params) =>
    Pg.Connection -> Pg.Query -> params -> () -> Pipes.Producer p r IO ()
query c q p () = Pipes.runIdentityP $ do
    (i, o) <- lift (Pipes.spawn Pipes.Single)
    worker <- lift $ Async.async $ do
        Pg.fold c q p () (const $ void . STM.atomically . Pipes.send i)
        Pipes.performGC
    lift $ Async.link worker
    Pipes.recvS o ()
    lift $ do
        Pipes.performGC
        Async.wait worker



--------------------------------------------------------------------------------
-- | Stream a ByteString into the stdin of a COPY statement.
copyTextIn :: Pipes.Proxy p =>
    Pg.Connection -> String -> () -> Pipes.Consumer p (Maybe ByteString) IO ()
copyTextIn c tableName () = Pipes.runIdentityP $ do
    lift $ Pg.withConnection c $ \c' ->
        LibPQ.exec c'
            (encodeUtf8 $ fromString $ "COPY " ++ tableName ++ " FROM STDIN WITH (FORMAT TEXT)")
    fix $ \loop -> do
        r <- Pipes.request ()
        continue <- lift . Pg.withConnection c $ \c' -> case r of
            Just d -> LibPQ.putCopyData c' d >> return True
            Nothing -> LibPQ.putCopyEnd c' Nothing >> return False
        when continue loop
