{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiWayIf #-}

module MakeSteno
    ( makeSteno
    ) where

import           Control.Applicative            ( Applicative(pure) )
import           Control.Arrow                  ( Arrow((***)) )
import           Control.Category               ( (<<<)
                                                , Category((.))
                                                )
import           Control.Concurrent             ( MVar
                                                , getNumCapabilities
                                                )
import           UnliftIO.Async       ( replicateConcurrently_ )
import qualified Control.Concurrent.Lock       as Lock
import           Control.Concurrent.Lock        ( Lock )
import           UnliftIO.MVar        ( modifyMVar
                                                , modifyMVar_
                                                , newMVar
                                                , readMVar
                                                )
import           Control.DeepSeq                ( force )
import           UnliftIO.Exception             ( evaluate )
import           Control.Monad                  ( Monad((>>), (>>=))
                                                , foldM
                                                , when
                                                )
import qualified Data.Aeson.Encode.Pretty      as Aeson
import           Data.Bool                      ( (&&)
                                                , Bool
                                                , not
                                                , otherwise
                                                )
import qualified Data.ByteString.Lazy          as LBS
import           Data.Either                    ( Either(..)
                                                , isRight
                                                )
import           Data.Eq                        ( Eq((==)) )
import           Data.Foldable                  ( Foldable(length)
                                                , for_
                                                , traverse_
                                                )
import           Data.Function                  ( ($)
                                                , flip
                                                )
import           Data.Functor                   ( (<$>)
                                                , Functor(fmap)
                                                )
import           Data.List                      ( minimumBy
                                                , sortOn
                                                , take
                                                , zip
                                                )
import qualified Data.Map.Strict               as Map
import           Data.Map.Strict                ( Map )
import           Data.Maybe                     ( Maybe(..), fromMaybe )
import           Data.Monoid                    ( (<>) )
import           Data.Ord                       ( Down(Down)
                                                , comparing
                                                , (>)
                                                )
import qualified Data.Set                      as Set
import           Data.Set                       ( Set
                                                , (\\)
                                                )
import           Data.Text                      ( Text )
import qualified Data.Text                     as Text
import qualified Data.Text.Encoding            as Text
import qualified Data.Text.IO                  as Text
import           Data.Tuple                     ( fst
                                                , snd
                                                )
import           Formatting                     ( (%)
                                                , fprint
                                                )
import           Formatting.Clock               ( timeSpecs )
import           GHC.Exts                       ( seq )
import           System.Clock                   ( Clock(Monotonic)
                                                , getTime
                                                )
import           System.Console.ANSI            ( setCursorColumn, cursorUp )
import           System.Directory               ( doesFileExist )
import           System.IO                      ( FilePath
                                                , IO
                                                , hFlush
                                                , putStr
                                                , putStrLn
                                                , stdout
                                                )
import           Text.Parsec                    ( runParser )
import           Text.Show                      ( Show(show) )
import           TextShow                       ( TextShow(showt) )
import           WCL                            ( wcl )
import GHC.Num (Num(negate, (+)))

-- my-palantype
import           Palantype.Common               ( ExceptionInterpretation(..)
                                                , Greediness
                                                , SystemLang(..)
                                                , Palantype
                                                    ( PatternGroup
                                                    , mapExceptions
                                                    )
                                                , RawSteno
                                                , StageIndex
                                                , fromChord
                                                , parseWord
                                                , triePrimitives
                                                , unparts, getStageIndexMaybe
                                                )
import Palantype.Common.TH (fromJust, failure)
import qualified Palantype.DE.Keys             as DE
import qualified Palantype.EN.Keys             as EN
import           Palantype.Tools.Collision      ( DictState
                                                    ( DictState
                                                    , dstMapWordStenos, dstMapStenoWord
                                                    ), CollisionInfo (CollisionInfo)
                                                )
import qualified Palantype.Tools.Collision     as Collision
import           Palantype.Tools.StenoOptimizer ( ParseError(..)
                                                , acronym
                                                , isCapitalized
                                                , parseSeries
                                                )
import Palantype.Tools.TraceWords (TraceWords, runTraceWords, traceSample)

-- exec
import           Args                           ( OptionsMakeSteno
                                                    ( OMkStArg
                                                    , OMkStFile
                                                    )
                                                )
import           Common                         ( appendLine
                                                , moveFileDotOld
                                                , writeJSONFile
                                                )
import           Sort                           ( getMapFrequencies )
import Control.Monad.IO.Class (liftIO)
import Data.Int (Int)
import GHC.Real (mod)
import Palantype.Tools.StenoCodeInfo (StenoCodeInfo (sciIndex, sciRawSteno, sciLevel), toStenoCodeInfoMaybe)


fileNoParse :: FilePath
fileNoParse = "makeSteno-noparse.txt"

fileLost :: FilePath
fileLost = "makeSteno-lostwords.txt"

fileCollisions :: FilePath
fileCollisions = "makeSteno-collisions.txt"

fileDuplicates :: FilePath
fileDuplicates = "makeSteno-duplicates.txt"

fileTooManySyllables :: FilePath
fileTooManySyllables = "makeSteno-tooManySyllables.txt"

makeSteno :: OptionsMakeSteno -> IO ()
makeSteno (OMkStArg lang str) = case lang of
    SystemDE -> parseSeries' @DE.Key
    SystemEN -> parseSeries' @EN.Key
  where
    traceWord = Set.singleton $ Text.replace "|" "" str

    parseSeries' :: forall key . Palantype key => IO ()
    parseSeries' = runTraceWords traceWord (parseSeries @key (triePrimitives @key) str) >>= \case
        Left  err -> Text.putStrLn $ showt err
        Right sds -> traverse_ (Text.putStrLn <<< showt) sds
makeSteno (OMkStFile fileInput fileOutputPlover fileOutputPloverAnglicisms fileOutputPloverMin fileOutputDoc lang traceWords)
    = do
        runTraceWords (Set.fromList traceWords) $ case lang of

            SystemDE -> makeSteno' @DE.Key
                                   fileInput
                                   fileOutputPlover
                                   fileOutputPloverAnglicisms
                                   fileOutputPloverMin
                                   fileOutputDoc

            SystemEN -> makeSteno' @EN.Key
                                   fileInput
                                   fileOutputPlover
                                   fileOutputPloverAnglicisms
                                   fileOutputPloverMin
                                   fileOutputDoc

makeSteno'
    :: forall key
     . Palantype key
    => FilePath
    -> FilePath
    -> FilePath
    -> FilePath
    -> FilePath
    -> TraceWords ()
makeSteno' fileInput fileOutputPlover fileOutputPloverAnglicisms fileOutputPloverMin fileOutputDoc = do
    start <- liftIO $ getTime Monotonic

    let lsFiles =
            [ fileNoParse
            , fileOutputPlover
            , fileOutputPloverAnglicisms
            , fileOutputPloverMin
            , fileOutputDoc
            , fileCollisions
            , fileDuplicates
            , fileTooManySyllables
            , fileLost
            ]
    traverse_ (liftIO <<< moveFileDotOld) lsFiles

    -- first: read exception file

    liftIO do
        putStr "Reading exceptions file ..."
        hFlush stdout

    (mapInitWordStenos, mapInitStenoWord, setReplByExc) <-
        foldM accExceptions (Map.empty, Map.empty, Set.empty)
            $ Map.toList mapExceptions

    liftIO do
        putStrLn $ mapInitStenoWord `seq` " done."
        putStrLn
            $  "Added "
            <> show (Map.size mapInitStenoWord)
            <> " entries based on "
            <> show (Map.size mapInitWordStenos)
            <> " words in exceptions file."

    -- moving on to regular input

    liftIO do
        putStr $ "Reading input file " <> fileInput <> " ..."
        hFlush stdout
    ls <- Text.lines <$> liftIO (Text.readFile fileInput)

    let l     = length ls
        setLs = Set.fromList ls

    liftIO do
        putStrLn $ l `seq` " done."

        putStrLn $ "Creating steno chords for " <> show l <> " entries."

    nj <- liftIO getNumCapabilities

    liftIO do
        putStr $ "\nRunning " <> show nj <> " jobs.\n\n"
        putStrLn "Optimizing steno chords ..."
        hFlush stdout

    lock         <- liftIO Lock.new
    varDictState <- liftIO $ newMVar $ DictState mapInitWordStenos mapInitStenoWord
    varLs        <- liftIO $ newMVar (ls, 0 :: Int, start)

    let reportInterval = 1000

    if nj == 1
        then traverse_ (parseWordIO lock varDictState setReplByExc setLs) ls
        else
            let
                loop = do
                    mJob <- modifyMVar varLs $ \case
                        ls'@([], _, _)     -> pure (ls', Nothing)
                        (j : js, i, last) -> do
                            if i `mod` reportInterval == 0
                              then liftIO do
                                current <- liftIO $ getTime Monotonic
                                setCursorColumn 0
                                Text.putStr $ showt i <> "\t"
                                fprint timeSpecs last current
                                Text.putStr $ "/" <> showt reportInterval <> " words"
                                hFlush stdout
                                pure ((js, i + 1, current), Just j)
                              else
                                pure ((js, i + 1, last), Just j)
                    case mJob of
                        Just hyph ->
                            parseWordIO lock
                                        varDictState
                                        setReplByExc
                                        setLs
                                        hyph
                                >> loop
                        Nothing -> pure ()
            in  replicateConcurrently_ nj loop

    liftIO do
      cursorUp 1
      setCursorColumn 28
      putStrLn "done.                 "

    DictState {..} <- liftIO $ readMVar varDictState

    mapFrequencies <- getMapFrequencies "deu_news_2020_freq.txt"

    let
        mapStenoWordDoc
          :: Map Text [StenoCodeInfo key]
          -> TraceWords (Map (PatternGroup key) (Map Greediness [(Text, RawSteno)]))
        mapStenoWordDoc mapWordStenos = foldrWithKeyM
            ( \w stenos m -> do
                let info = minimumBy (comparing sciIndex) stenos
                traceSample w $ "minimum by index: selected for doc: "
                             <> showt (sciRawSteno info)
                             <> " g" <> showt (fst $ sciLevel info)
                             <> "(" <> showt (snd $ sciLevel info) <> ")"
                pure $ Map.insertWith (Map.unionWith (<>))
                                      (fst $ sciLevel info)
                                      (Map.singleton (snd $ sciLevel info) [(w, sciRawSteno info)])
                                      m
            )
            Map.empty
            mapWordStenos

    let
        criterion = Down <<< (\w -> Map.findWithDefault 0 w mapFrequencies)

        -- mapStenoWordTake100
        --     :: Map (PatternGroup key) (Map Greediness (Int, [(Text, RawSteno)]))
    mapStenoWordTake100 <- mapStenoWordDoc dstMapWordStenos <<<&>>> \lsWordSteno ->
        ( length lsWordSteno
        , take 100
            $ sortOn (criterion <<< Text.encodeUtf8 <<< fst) lsWordSteno
        )

    let
        mapStenoWordMin :: Map Text RawSteno
        mapStenoWordMin = Map.foldrWithKey
            (\w stenos m ->
                let info = minimumBy (comparing sciIndex) stenos
                in  Map.insert w (sciRawSteno info) m
            )
            Map.empty
            dstMapWordStenos

    -- checking for lost words
    liftIO do
        putStr $ "Writing lost words to " <> fileLost <> " ..."
        hFlush stdout
    traverse_ (liftIO <<< appendLine fileLost)
        $  Set.map (Text.replace "|" "") setLs \\ Map.keysSet dstMapWordStenos
    liftIO do
        putStrLn " done."
        putStr $ "Writing file " <> fileOutputDoc <> " ..."
        hFlush stdout

    uDoc <- liftIO $ LBS.writeFile fileOutputDoc $ Aeson.encodePretty mapStenoWordTake100
    liftIO $ putStrLn $ uDoc `seq` " done."

    let
        (mapStenoWordsAnglicisms, mapStenoWordsWOAnglicisms) =
          Map.partition (Text.isPrefixOf "PatAngl" . showt . fst . snd) dstMapStenoWord

    writeJSONFile fileOutputPlover $
        sortOn (criterion <<< snd) $
            (Text.encodeUtf8 . showt *** Text.encodeUtf8)
                <$> Map.toList (fst <$> mapStenoWordsWOAnglicisms)

    writeJSONFile fileOutputPloverAnglicisms $
        sortOn (criterion <<< snd) $
            (Text.encodeUtf8 . showt *** Text.encodeUtf8)
                <$> Map.toList (fst <$> mapStenoWordsAnglicisms)

    liftIO do
        LBS.writeFile fileOutputPloverMin $ Aeson.encodePretty mapStenoWordMin
        putStrLn ""
        putStrLn "Number of lines in"

    for_ lsFiles $ \file -> do
        exists <- liftIO $ doesFileExist file
        when exists $ do
            nl <- wcl file
            liftIO $ putStrLn $ show nl <> "\t" <> file

    liftIO $ putStrLn ""

    stop <- liftIO $ getTime Monotonic
    liftIO do
        putStr "StenoWords runtime: "
        fprint (timeSpecs % "\n") start stop

-- exceptions

accExceptions
    :: forall key
     . Palantype key
    => ( Map Text [StenoCodeInfo key]
       , Map RawSteno (Text, (PatternGroup key, Greediness))
       , Set Text
       )
    -> ( Text
       , ( ExceptionInterpretation
         , [(Greediness, RawSteno, PatternGroup key, Bool)]
         )
       )
    -> TraceWords
           ( Map Text [StenoCodeInfo key]
           , Map RawSteno (Text, (PatternGroup key, Greediness))
           , Set Text
           )
accExceptions (mapExcWordStenos, mapExcStenoWord, set) (word, (interp, lsExcEntry))
    = do
        traceSample word $
               "traceWord: in exceptions: "
            <> word <> ": "
            <> showt interp <> ", "
            <> showt lsExcEntry
        let accExcEntry
                :: ( [(RawSteno, StageIndex)]
                   , Map RawSteno (Text, (PatternGroup key, Greediness))
                   )
                -> (Greediness, RawSteno, PatternGroup key, Bool)
                -> IO
                       ( [(RawSteno, StageIndex)]
                       , Map RawSteno (Text, (PatternGroup key, Greediness))
                       )
            accExcEntry (ls, mapEEStenoWord) (g, raw, pg, _) = do

                case parseWord @key raw of
                    Right chords -> do
                        let rawParsed = unparts $ fromChord <$> chords
                            errorMsg = "stage index Nothing for "
                              <> show pg <> " " <> show g
                            -- covered by test
                            si = fromMaybe ($failure errorMsg) $
                              getStageIndexMaybe @key pg g
                        pure
                            ( (rawParsed, si) : ls
                            , Map.insert rawParsed (word, (pg, g)) mapEEStenoWord
                            )
                    Left err -> do
                        Text.putStrLn
                            $  "Error in exception table: "
                            <> word <> ": "
                            <> showt raw <> "; "
                            <> Text.pack (show err)
                        pure (ls, mapEEStenoWord)

        (lsStenoInfo, m) <- foldM ((liftIO <<<) <<< accExcEntry) ([], mapExcStenoWord) lsExcEntry

        set' <- case interp of
            ExcRuleAddition -> pure set
            -- mark the exceptions of type "substitution" for later
            ExcSubstitution -> do
              traceSample word $ "traceWord: in exceptions: " <> word
                              <> " added to substitution set"
              pure $ Set.insert word set

        pure
            ( Map.insert word ($fromJust . toStenoCodeInfoMaybe <$>
                zip (negate <$> [1 ..]) lsStenoInfo) mapExcWordStenos
            , m
            , set'
            )

-- no exceptions

isAcronym :: Text -> Bool
isAcronym = isRight <<< runParser acronym () ""

parseWordIO
    :: forall key
     . Palantype key
    => Lock
    -> MVar (DictState key)
    -> Set Text
    -> Set Text
    -> Text
    -> TraceWords ()
parseWordIO lock varDictState setReplByExc setLs hyph = do
    mapWordStenos <- dstMapWordStenos <$> readMVar varDictState

    let
        numSyllables = length $ Text.splitOn "|" hyph
        hasTooManySyllables = numSyllables > 12

        word = Text.replace "|" "" hyph

        -- exceptions marked as "substitution" replace the regular
        -- steno algorithm and are not computed again
        isReplacedByException = word `Set.member` setReplByExc

        -- duplicate? don't compute any word twice!
        -- but: words from the exception file marked
        --     "rule-addition" do not count as duplicates
        isDupl =
               word `Map.member`    mapWordStenos
            && word `Map.notMember` mapExceptions @key

        -- a capitalized word that also appears in its lower-case
        -- version counts as duplicate
        isCaplDupl =
               isCapitalized hyph
            && not (isAcronym hyph)
            && Text.toLower hyph `Set.member` setLs

    if
      | hasTooManySyllables -> do
          traceSample word $ "traceWord: in parseWordIO: "
                          <> word <> ": has too many syllables"
          appendLine fileTooManySyllables $ showt numSyllables <> "\t" <> word

      | isDupl -> do
          traceSample word $ "traceWord: in parseWordIO: "
                          <> word <> ": is duplicate"
          appendLine fileDuplicates word

      | isCaplDupl -> do
          traceSample word $ "traceWord: in parseWordIO: "
                          <> word <> ": is capitalized duplicate"
          appendLine fileDuplicates $ word <> " capitalized"

      | isReplacedByException -> pure ()

      | otherwise -> do

          traceSample word $ "traceWord: in parseWordIO: " <> word
                          <> ": computing stenos for " <> hyph

          parseSeries @key (triePrimitives @key) hyph >>= \case
              Right stenos -> modifyMVar_ varDictState \dst -> do

                traceSample word $ "traceWord: in parseWordIO: " <> word
                                <> ": stenos: " <> showt stenos

                let (dst', cis) = Collision.resolve word (force stenos) dst
                _ <- evaluate dst'
                for_ cis \(CollisionInfo looser winner raw isLostEntirely) -> do

                    if isLostEntirely
                      then do
                        appendLine fileCollisions $
                          looser <> " " <> Text.intercalate " " (showt <$> stenos)

                        traceSample looser $ "traceWord: in parseWordIO: " <> looser
                                        <> " lost in collision without alternatives to "
                                        <> winner
                      else do
                        traceSample looser $ "traceWord: in parseWordIO: " <> looser
                                        <> " lost steno code " <> showt raw
                                        <> " to " <> winner

                pure dst'
              Left pe -> case pe of
                  PEParsec raw _ -> do
                      traceSample word $ "traceWord: in parseWordIO: " <> word
                                      <> ": failed to parse"

                      liftIO $ Lock.with lock $ appendLine fileNoParse $ Text.unwords
                          [word, hyph, showt raw]
                  PEImpossible str -> do
                      liftIO $ Text.putStrLn $ "Seemingly impossible: " <> str
                      liftIO $ Lock.with lock $ appendLine fileNoParse $ Text.unwords
                          [word, hyph]

-- cf. https://hackage.haskell.org/package/relude-1.1.0.0/docs/Relude-Functor-Fmap.html
(<<<&>>>)
    :: forall m n o a b
     . (Functor m, Functor n, Functor o)
    => m (n ( o a))
    -> (a -> b)
    -> m (n (o b))
(<<<&>>>) = flip (fmap . fmap . fmap)


foldrWithKeyM
  :: forall m k a b
  . ( Monad m
    )
  => (k -> a -> b -> m b)
  -> b
  -> Map k a
  -> m b
foldrWithKeyM acc z m = Map.foldrWithKey acc' pure m z
  where
    acc' :: k -> a -> (b -> m b) -> b -> m b
    acc' k v b2mb b = acc k v b >>= b2mb
