module Common where

import Control.Monad (when)
import Data.Foldable (Foldable (toList, foldMap), for_)
import Data.Function (($))
import Data.Semigroup (Semigroup ((<>)))
import Data.Text (Text)
import qualified Data.Text.IO as Text
import Data.Time (
    UTCTime,
    defaultTimeLocale,
    formatTime,
 )
import GHC.Exts (seq)
import GHC.IO (FilePath)
import System.Directory (
    doesFileExist,
    removeFile,
 )
import System.IO (
    IO,
    hFlush,
    putStr,
    putStrLn,
    stdout, Handle, IOMode (WriteMode), withBinaryFile
 )
import Data.ByteString (ByteString)
import qualified Data.ByteString.Builder.Internal as BSB
import Control.Category ((<<<))

removeFiles :: [FilePath] -> IO ()
removeFiles files = for_ files $ \file -> do
    exists <- doesFileExist file
    when exists $ do
        putStrLn $ "Deleting " <> file
        removeFile file

appendLine :: FilePath -> Text -> IO ()
appendLine file str = Text.appendFile file $ str <> "\n"

fileScores :: UTCTime -> FilePath
fileScores time =
    "stenowordsstats/stenowords-stats_"
        <> formatTime defaultTimeLocale "%y%m%d-%T" time
        <> ".txt"

writeJSONFile :: forall l. Foldable l => FilePath -> l (ByteString, ByteString) -> IO ()
writeJSONFile file ls = do
    putStr $ "Writing file " <> file <> " ..."
    hFlush stdout
    u <-
        writeFile file $
            BSB.byteString "{\n"
                <> foldMap ((<> ",\n") <<< BSB.byteString <<< formatJSONLine) (toList ls)
                <> BSB.byteString "\n}\n"
    putStrLn $ u `seq` " done."
  where
    formatJSONLine :: (ByteString, ByteString) -> ByteString
    formatJSONLine (raw, word) =
        "\"" <> raw <> "\": \"" <> word <> "\""

-- using bytestring 0.10 and 0.11.1
-- `writeFile` is in bytestring 0.11.2
hPutBuilder :: Handle -> BSB.Builder -> IO ()
hPutBuilder h = BSB.hPut h <<< BSB.putBuilder

modifyFile :: IOMode -> FilePath -> BSB.Builder -> IO ()
modifyFile mode f bld = withBinaryFile f mode (`hPutBuilder` bld)

writeFile :: FilePath -> BSB.Builder -> IO ()
writeFile = modifyFile WriteMode
