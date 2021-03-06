-- |
-- Module      :  HPath.IO.Errors
-- Copyright   :  © 2016 Julian Ospald
-- License     :  GPL-2
--
-- Maintainer  :  Julian Ospald <hasufell@posteo.de>
-- Stability   :  experimental
-- Portability :  portable
--
-- Provides error handling.

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE ScopedTypeVariables #-}

module HPath.IO.Errors
  (
  -- * Types
    HPathIOException(..)

  -- * Exception identifiers
  , isFileDoesNotExist
  , isDirDoesNotExist
  , isSameFile
  , isDestinationInSource
  , isFileDoesExist
  , isDirDoesExist
  , isInvalidOperation
  , isCan'tOpenDirectory
  , isCopyFailed

  -- * Path based functions
  , throwFileDoesExist
  , throwDirDoesExist
  , throwFileDoesNotExist
  , throwDirDoesNotExist
  , throwSameFile
  , sameFile
  , throwDestinationInSource
  , doesFileExist
  , doesDirectoryExist
  , isWritable
  , canOpenDirectory
  , throwCantOpenDirectory

  -- * Error handling functions
  , catchErrno
  , rethrowErrnoAs
  , handleIOError
  , bracketeer
  , reactOnError
  )
  where


import Control.Applicative
  (
    (<$>)
  )
import Control.Exception
import Control.Monad
  (
    forM
  , when
  )
import Data.ByteString
  (
    ByteString
  )
import Data.ByteString.UTF8
  (
    toString
  )
import Data.Data
  (
    Data(..)
  )
import Data.Typeable
import Foreign.C.Error
  (
    getErrno
  , Errno
  )
import GHC.IO.Exception
  (
    IOErrorType
  )
import HPath
import {-# SOURCE #-} HPath.IO
  (
    canonicalizePath
  )
import HPath.IO.Utils
import System.IO.Error
  (
    catchIOError
  , ioeGetErrorType
  )

import qualified System.Posix.Directory.ByteString as PFD
import System.Posix.Files.ByteString
  (
    fileAccess
  , getFileStatus
  )
import qualified System.Posix.Files.ByteString as PF


data HPathIOException = FileDoesNotExist ByteString
                      | DirDoesNotExist ByteString
                      | SameFile ByteString ByteString
                      | DestinationInSource ByteString ByteString
                      | FileDoesExist ByteString
                      | DirDoesExist ByteString
                      | InvalidOperation String
                      | Can'tOpenDirectory ByteString
                      | CopyFailed String
  deriving (Typeable, Eq, Data)


instance Show HPathIOException where
  show (FileDoesNotExist fp) = "File does not exist:" ++ toString fp
  show (DirDoesNotExist fp) = "Directory does not exist: "
                              ++ toString fp
  show (SameFile fp1 fp2) = toString fp1
                            ++ " and " ++ toString fp2
                            ++ " are the same file!"
  show (DestinationInSource fp1 fp2) = toString fp1
                                       ++ " is contained in "
                                       ++ toString fp2
  show (FileDoesExist fp) = "File does exist: " ++ toString fp
  show (DirDoesExist fp) = "Directory does exist: " ++ toString fp
  show (InvalidOperation str) = "Invalid operation: " ++ str
  show (Can'tOpenDirectory fp) = "Can't open directory: "
                                 ++ toString fp
  show (CopyFailed str) = "Copying failed: " ++ str



instance Exception HPathIOException





    -----------------------------
    --[ Exception identifiers ]--
    -----------------------------

isFileDoesNotExist, isDirDoesNotExist, isSameFile, isDestinationInSource, isFileDoesExist, isDirDoesExist, isInvalidOperation, isCan'tOpenDirectory, isCopyFailed :: HPathIOException -> Bool
isFileDoesNotExist ex = toConstr (ex :: HPathIOException) == toConstr FileDoesNotExist{}
isDirDoesNotExist ex = toConstr (ex :: HPathIOException) == toConstr DirDoesNotExist{}
isSameFile ex = toConstr (ex :: HPathIOException) == toConstr SameFile{}
isDestinationInSource ex = toConstr (ex :: HPathIOException) == toConstr DestinationInSource{}
isFileDoesExist ex = toConstr (ex :: HPathIOException) == toConstr FileDoesExist{}
isDirDoesExist ex = toConstr (ex :: HPathIOException) == toConstr DirDoesExist{}
isInvalidOperation ex = toConstr (ex :: HPathIOException) == toConstr InvalidOperation{}
isCan'tOpenDirectory ex = toConstr (ex :: HPathIOException) == toConstr Can'tOpenDirectory{}
isCopyFailed ex = toConstr (ex :: HPathIOException) == toConstr CopyFailed{}




    ----------------------------
    --[ Path based functions ]--
    ----------------------------


throwFileDoesExist :: Path Abs -> IO ()
throwFileDoesExist fp =
  whenM (doesFileExist fp) (throwIO . FileDoesExist
                                    . fromAbs $ fp)


throwDirDoesExist :: Path Abs -> IO ()
throwDirDoesExist fp =
  whenM (doesDirectoryExist fp) (throwIO . DirDoesExist
                                         . fromAbs $ fp)


throwFileDoesNotExist :: Path Abs -> IO ()
throwFileDoesNotExist fp =
  unlessM (doesFileExist fp) (throwIO . FileDoesNotExist
                                      . fromAbs $ fp)


throwDirDoesNotExist :: Path Abs -> IO ()
throwDirDoesNotExist fp =
  unlessM (doesDirectoryExist fp) (throwIO . DirDoesNotExist
                                           . fromAbs $ fp)


-- |Uses `isSameFile` and throws `SameFile` if it returns True.
throwSameFile :: Path Abs
              -> Path Abs
              -> IO ()
throwSameFile fp1 fp2 =
  whenM (sameFile fp1 fp2)
        (throwIO $ SameFile (fromAbs fp1) (fromAbs fp2))


-- |Check if the files are the same by examining device and file id.
-- This follows symbolic links.
sameFile :: Path Abs -> Path Abs -> IO Bool
sameFile fp1 fp2 =
  withAbsPath fp1 $ \fp1' -> withAbsPath fp2 $ \fp2' ->
    handleIOError (\_ -> return False) $ do
      fs1 <- getFileStatus fp1'
      fs2 <- getFileStatus fp2'

      if ((PF.deviceID fs1, PF.fileID fs1) ==
          (PF.deviceID fs2, PF.fileID fs2))
        then return True
        else return False


-- |Checks whether the destination directory is contained
-- within the source directory by comparing the device+file ID of the
-- source directory with all device+file IDs of the parent directories
-- of the destination.
throwDestinationInSource :: Path Abs -- ^ source dir
                         -> Path Abs -- ^ full destination, `dirname dest`
                                     --   must exist
                         -> IO ()
throwDestinationInSource source dest = do
  dest'   <- (\x -> maybe x (\y -> x </> y) $ basename dest)
             <$> (canonicalizePath $ dirname dest)
  dids <- forM (getAllParents dest') $ \p -> do
          fs <- PF.getSymbolicLinkStatus (fromAbs p)
          return (PF.deviceID fs, PF.fileID fs)
  sid <- fmap (\x -> (PF.deviceID x, PF.fileID x))
              $ PF.getFileStatus (fromAbs source)
  when (elem sid dids)
       (throwIO $ DestinationInSource (fromAbs dest)
                                      (fromAbs source))


-- |Checks if the given file exists and is not a directory.
-- Does not follow symlinks.
doesFileExist :: Path Abs -> IO Bool
doesFileExist fp =
  handleIOError (\_ -> return False) $ do
    fs  <- PF.getSymbolicLinkStatus (fromAbs fp)
    return $ not . PF.isDirectory $ fs


-- |Checks if the given file exists and is a directory.
-- Does not follow symlinks.
doesDirectoryExist :: Path Abs -> IO Bool
doesDirectoryExist fp =
  handleIOError (\_ -> return False) $ do
    fs  <- PF.getSymbolicLinkStatus (fromAbs fp)
    return $ PF.isDirectory fs


-- |Checks whether a file or folder is writable.
isWritable :: Path Abs -> IO Bool
isWritable fp =
  handleIOError (\_ -> return False) $
    fileAccess (fromAbs fp) False True False


-- |Checks whether the directory at the given path exists and can be
-- opened. This invokes `openDirStream` which follows symlinks.
canOpenDirectory :: Path Abs -> IO Bool
canOpenDirectory fp =
  handleIOError (\_ -> return False) $ do
    bracket (PFD.openDirStream . fromAbs $ fp)
            PFD.closeDirStream
            (\_ -> return ())
    return True


-- |Throws a `Can'tOpenDirectory` HPathIOException if the directory at the given
-- path cannot be opened.
throwCantOpenDirectory :: Path Abs -> IO ()
throwCantOpenDirectory fp =
  unlessM (canOpenDirectory fp)
          (throwIO . Can'tOpenDirectory . fromAbs $ fp)



    --------------------------------
    --[ Error handling functions ]--
    --------------------------------


-- |Carries out an action, then checks if there is an IOException and
-- a specific errno. If so, then it carries out another action, otherwise
-- it rethrows the error.
catchErrno :: [Errno] -- ^ errno to catch
           -> IO a    -- ^ action to try, which can raise an IOException
           -> IO a    -- ^ action to carry out in case of an IOException and
                      --   if errno matches
           -> IO a
catchErrno en a1 a2 =
  catchIOError a1 $ \e -> do
    errno <- getErrno
    if errno `elem` en
      then a2
      else ioError e


-- |Execute the given action and retrow IO exceptions as a new Exception
-- that have the given errno. If errno does not match the exception is rethrown
-- as is.
rethrowErrnoAs :: Exception e
               => [Errno]       -- ^ errno to catch
               -> e             -- ^ rethrow as if errno matches
               -> IO a          -- ^ action to try
               -> IO a
rethrowErrnoAs en fmex action = catchErrno en action (throwIO fmex)



-- |Like `catchIOError`, with arguments swapped.
handleIOError :: (IOError -> IO a) -> IO a -> IO a
handleIOError = flip catchIOError


-- |Like `bracket`, but allows to have different clean-up
-- actions depending on whether the in-between computation
-- has raised an exception or not. 
bracketeer :: IO a        -- ^ computation to run first
           -> (a -> IO b) -- ^ computation to run last, when
                          --   no exception was raised
           -> (a -> IO b) -- ^ computation to run last,
                          --   when an exception was raised
           -> (a -> IO c) -- ^ computation to run in-between
           -> IO c
bracketeer before after afterEx thing =
  mask $ \restore -> do
    a <- before
    r <- restore (thing a) `onException` afterEx a
    _ <- after a
    return r


reactOnError :: IO a
             -> [(IOErrorType, IO a)]      -- ^ reaction on IO errors
             -> [(HPathIOException, IO a)] -- ^ reaction on HPathIOException
             -> IO a
reactOnError a ios fmios =
  a `catches` [iohandler, fmiohandler]
  where
    iohandler = Handler $
      \(ex :: IOException) ->
         foldr (\(t, a') y -> if ioeGetErrorType ex == t
                                then a'
                                else y)
               (throwIO ex)
               ios
    fmiohandler = Handler $
      \(ex :: HPathIOException) ->
         foldr (\(t, a') y -> if toConstr ex == toConstr t
                                then a'
                                else y)
               (throwIO ex)
               fmios
