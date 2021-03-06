{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE ScopedTypeVariables #-}
#ifdef CLANG_INLINER
{-# LANGUAGE TemplateHaskell #-}
#endif

module Caide.Commands.Init(
      initialize
) where

import Control.Exception (try, IOException)
import Control.Monad (forM_)
import Control.Monad.State (liftIO)
import Codec.Archive.Zip (extractFilesFromArchive, toArchive, ZipOption(..))
import qualified Data.ByteString as BS
import Data.ByteString.Lazy (fromStrict)
import Data.Char (isSpace)
import Data.List (takeWhile, dropWhile, dropWhileEnd, filter, isInfixOf)
import Data.Maybe (fromMaybe)
import Data.FileEmbed (embedFile)
import qualified Data.Text as T
import qualified Data.Text.IO.Util as T
import System.Environment (lookupEnv)
import System.Process (readProcessWithExitCode)

import Filesystem (createTree)
import Filesystem.Path.CurrentOS (encodeString, (</>))
import qualified Filesystem.Path as FSP
import Filesystem.Util (pathToText, writeTextFile)

import Caide.Configuration (SystemCompilerInfo(..),
    writeCaideConf, writeCaideState, defaultCaideConf, defaultCaideState)
import Caide.Templates (templates)
import Caide.Types


getSystemCompilerInfo :: IO SystemCompilerInfo
getSystemCompilerInfo = do
    [vs12, vs14, vs15] <- mapM lookupEnv ["VS120COMNTOOLS", "VS140COMNTOOLS", "VS150COMNTOOLS"]
    let mscver = case (vs12, vs14, vs15) of
            (_, _, Just _) -> 1900
            (_, Just _, _) -> 1900
            (Just _, _, _) -> 1800
            _              -> 1700
    gcc <- fromMaybe "g++" <$> lookupEnv "CXX"
    -- TODO: More robust subprocess handling (e.g. timeout)
    -- TODO: Set locale
    processResult <- try $ readProcessWithExitCode gcc ["-x", "c++", "-E" ,"-v", "-"] ""
    let gccIncludeDirectories = case processResult of
            Left  (_ex :: IOException)         -> []
            Right (_exitCode, _stdOut, stdErr) -> parseGccOutput stdErr
    return $ SystemCompilerInfo { mscver, gccIncludeDirectories }

parseGccOutput :: String -> [String]
parseGccOutput output = map trim $ filter isDirectory $ takeWhile (not . endOfSearchListLine) $ dropWhile (not . searchStartsHereLine) $ lines output
  where
    trim = dropWhileEnd isSpace . dropWhile isSpace
    isDirectory s = not (null s) && head s == ' '
    endOfSearchListLine s = "End of search list." `isInfixOf` s
    searchStartsHereLine s = "search starts here:" `isInfixOf` s


initialize :: Bool -> CaideIO ()
initialize useSystemCppHeaders = do
    curDir <- caideRoot
    compiler <- liftIO $ getSystemCompilerInfo
    _ <- writeCaideConf $ defaultCaideConf curDir useSystemCppHeaders compiler
    _ <- writeCaideState defaultCaideState
    liftIO $ do
#ifdef CLANG_INLINER
        unpackResources curDir
#endif
        createTree $ curDir </> "templates"
        createTree $ curDir </> ".caide" </> "templates"
        forM_ templates $ \(fileName, cont) -> do
            writeTextFile (curDir </> "templates" </> fileName) cont
            writeTextFile (curDir </> ".caide" </> "templates" </> fileName) cont
        T.putStrLn . T.concat $ ["Initialized caide directory at ", pathToText curDir]


#ifdef CLANG_INLINER
-- This zip file is prepared in advance in Setup.hs
resourcesZipFile :: BS.ByteString
resourcesZipFile = $(embedFile "res/init.zip")

unpackResources :: FSP.FilePath -> IO ()
unpackResources rootDir = do
    let archive = toArchive $ fromStrict resourcesZipFile
        destination = encodeString rootDir
        options = [OptDestination destination]
    extractFilesFromArchive options archive
#endif

