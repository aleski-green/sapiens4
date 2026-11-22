{-# LANGUAGE ForeignFunctionInterface #-}
module LMDB (Environment, open, close, rows, prefix, commit) where

import Control.Exception
import Control.Concurrent (runInBoundThread)
import Control.Monad
import qualified Data.ByteString as B
import Foreign
import Foreign.C
import System.Directory

data Env
data Txn
data Cursor
newtype Environment = Environment (Ptr Env)
foreign import ccall safe "sapiens_kv_open" c_open :: CString -> Ptr (Ptr Env) -> IO CInt
foreign import ccall unsafe "mdb_env_close" c_close :: Ptr Env -> IO ()
foreign import ccall safe "sapiens_kv_begin" c_begin :: Ptr Env -> CInt -> Ptr (Ptr Txn) -> IO CInt
foreign import ccall safe "mdb_txn_commit" c_commit :: Ptr Txn -> IO CInt
foreign import ccall unsafe "mdb_txn_abort" c_abort :: Ptr Txn -> IO ()
foreign import ccall unsafe "sapiens_kv_put" c_put :: Ptr Txn -> CString -> CSize -> CString -> CSize -> CInt -> IO CInt
foreign import ccall unsafe "sapiens_kv_cursor" c_cursor :: Ptr Txn -> Ptr (Ptr Cursor) -> IO CInt
foreign import ccall unsafe "mdb_cursor_close" c_closeCursor :: Ptr Cursor -> IO ()
foreign import ccall unsafe "sapiens_kv_next" c_next :: Ptr Cursor -> CInt -> Ptr CString -> Ptr CSize -> Ptr CString -> Ptr CSize -> IO CInt
foreign import ccall unsafe "sapiens_kv_seek" c_seek :: Ptr Cursor -> CString -> CSize -> Ptr CString -> Ptr CSize -> Ptr CString -> Ptr CSize -> IO CInt
foreign import ccall unsafe "mdb_strerror" c_error :: CInt -> IO CString
foreign import ccall safe "sapiens_kv_grow" c_grow :: Ptr Env -> IO CInt

newtype LMDBError = LMDBError CInt deriving Show
instance Exception LMDBError
check :: CInt -> IO ()
check rc = unless (rc == 0) (throwIO (LMDBError rc))
allocate :: (Ptr (Ptr a) -> IO CInt) -> IO (Ptr a)
allocate f = alloca $ \out -> f out >>= check >> peek out
open :: FilePath -> IO Environment
open path = do
 createDirectoryIfMissing True path
 Environment <$> withCString path (allocate . c_open)
close :: Environment -> IO ()
close (Environment env) = c_close env

-- Callers serialize access, including map growth, with the store's mutex.
commit :: Environment -> [(B.ByteString,B.ByteString,Bool)] -> IO ()
commit (Environment env) entries = runInBoundThread $ mask_ $ attempt `catch` \(LMDBError rc) ->
 if rc == -30792 then c_grow env >>= check >> attempt else do
  message <- c_error rc >>= peekCString
  fail ("LMDB commit failed: " ++ message)
 where
 attempt = do
  txn <- allocate (c_begin env 1)
  (forM_ entries $ \(key,value,immutable) ->
    B.useAsCStringLen key $ \(k,kn) -> B.useAsCStringLen value $ \(v,vn) ->
     c_put txn k (fromIntegral kn) v (fromIntegral vn) (if immutable then 1 else 0) >>= check)
    `onException` c_abort txn
  -- LMDB frees the transaction even when commit fails.
  c_commit txn >>= check
rows :: Environment -> IO [(B.ByteString,B.ByteString)]
rows env = prefix env B.empty
prefix :: Environment -> B.ByteString -> IO [(B.ByteString,B.ByteString)]
prefix (Environment env) bound = bracket (allocate (c_begin env 0)) c_abort $ \txn ->
 bracket (allocate (c_cursor txn)) c_closeCursor $ \cursor ->
 alloca $ \key -> alloca $ \kn -> alloca $ \value -> alloca $ \vn ->
  let loop first acc = do
       rc <- if first then B.useAsCStringLen bound $ \(p,n) -> c_seek cursor p (fromIntegral n) key kn value vn
             else c_next cursor 0 key kn value vn
       if rc == -30798 then pure (reverse acc) else do
        check rc
        k <- (,) <$> peek key <*> (fromIntegral <$> peek kn) >>= B.packCStringLen
        if not (bound `B.isPrefixOf` k) then pure (reverse acc) else do
         v <- (,) <$> peek value <*> (fromIntegral <$> peek vn) >>= B.packCStringLen
         loop False ((k,v):acc)
  in if B.null bound then
      let allRows first acc = do
           rc <- c_next cursor first key kn value vn
           if rc == -30798 then pure (reverse acc) else do
            check rc
            k <- (,) <$> peek key <*> (fromIntegral <$> peek kn) >>= B.packCStringLen
            v <- (,) <$> peek value <*> (fromIntegral <$> peek vn) >>= B.packCStringLen
            allRows 0 ((k,v):acc)
      in allRows 1 []
     else loop True []
