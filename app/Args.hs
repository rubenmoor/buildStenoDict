module Args
  ( Task (..)
  , OptionsSyllables (..)
  , OptionsHyphenate (..)
  , OptionsStenoWords (..)
  , OptionsStenoWordsRun (..)
  , argOpts
  ) where

import           Data.Bool                      ( Bool )
import           Data.Function                  ( ($) )
import           Data.Functor                   ( (<$) )
import           Data.Int                       ( Int )
import           Data.Maybe                     ( Maybe )
import           Data.Monoid                    ( Monoid(mempty) )
import           Data.Semigroup                 ( (<>) )
import           Data.String                    ( String )
import           Data.Text                      ( Text )
import           Options.Applicative            ( (<$>)
                                                , Alternative((<|>))
                                                , Applicative((<*), (<*>), pure)
                                                , InfoMod
                                                , Parser
                                                , ParserInfo
                                                , auto
                                                , command
                                                , flag'
                                                , help
                                                , helper
                                                , info
                                                , long
                                                , metavar
                                                , option
                                                , optional
                                                , progDesc
                                                , short
                                                , strOption
                                                , subparser
                                                , switch
                                                , value
                                                )
import           System.IO                      ( FilePath )

data Task
  = TaskRawSteno Text
  | TaskSyllables OptionsSyllables
  | TaskHyphenate OptionsHyphenate
  | TaskStenoWords OptionsStenoWords
  | TaskGermanDict Bool
  | TaskFrequency

data OptionsSyllables
  = OSylFile
  | OSylArg Text

data OptionsHyphenate
  = OHypFile
  | OHypArg Text

data OptionsStenoWords
  = OStwRun Int OptionsStenoWordsRun
  | OStwShowChart

data OptionsStenoWordsRun
  = OStwFile Bool (Maybe FilePath)
  | OStwArg Text
  | OStwStdin

argOpts :: ParserInfo Task
argOpts = info (helper <*> task) mempty

task :: Parser Task
task = subparser
    (  command
          "rawSteno"
          (info (TaskRawSteno <$> arg rawStenoHelp <* helper) rawStenoInfo)
    <> command
           "syllables"
           (info (TaskSyllables <$> optsSyllables <* helper) syllablesInfo)
    <> command
           "hyphenate"
           (info (TaskHyphenate <$> optsHyphenate <* helper) hyphenateInfo)
    <> command
           "stenoWords"
           (info (TaskStenoWords <$> optsStenoWords <* helper) stenoWordsInfo)
    <> command
           "stenoDict"
           (info (TaskGermanDict <$> switchReset <* helper) germanDictInfo)
    <> command "frequency"
               (info (TaskFrequency <$ helper) frequencyInfo)
    )
  where
    rawStenoHelp
        = "Parse raw steno like \"A/HIFn/LA/HIFn/GDAOD\" into a steno chord to \
      \validate it."

    rawStenoInfo = progDesc "Validate raw steno."

switchReset :: Parser Bool
switchReset = switch
    (  long "reset"
    <> help
           "delete the no-parse-file, start from scratch and overwrite the \
          \result file."
    )

arg :: String -> Parser Text
arg hlp = strOption (long "arg" <> short 'a' <> help hlp)

optsSyllables :: Parser OptionsSyllables
optsSyllables = pure OSylFile <|> (OSylArg <$> arg hlp)
  where
    hlp
        = "Extract syllable patterns from one single line of the format: \
          \Direktive >>> Di|rek|ti|ve, die; -, -n (Weisung; Verhaltensregel)"

syllablesInfo :: InfoMod a
syllablesInfo =
    progDesc
        "Read the file \"entries.txt\" and extract the syllable patterns. \
           \The result is written to \"syllables.txt\". The remainder is written \
           \to \"syllables-noparse.txt.\" When the file \"syllables-noparse.txt\" \
           \exists already, ignore \"entries.txt\" and work on the remainder, only."

optsHyphenate :: Parser OptionsHyphenate
optsHyphenate = pure OHypFile <|> (OHypArg <$> arg hlp)
  where
    hlp = "Hyphenate the word given in the argument."

hyphenateInfo :: InfoMod a
hyphenateInfo =
  progDesc "Read syllables from \"syllables-set.txt\" and pass through the \
           \list of words in \"german.utf8.dic\" to find the proper hyphenation \
           \and write \"entries-extra-algo.txt."

switchShowChart :: Parser Bool
switchShowChart = switch
    (long "show-chart" <> short 's' <> help
        "Show the histogram of scores after the computation."
    )

mOutputFile :: Parser (Maybe FilePath)
mOutputFile = optional $ strOption
    (  long "output-file"
    <> short 'f'
    <> help "Addiontally write results into the provided file."
    <> metavar "FILE"
    )

greediness :: Parser Int
greediness = option
    auto
    (  long "greediness"
    <> short 'g'
    <> value 4
    <> help
           "Greediness 0: use the minimal set of primitive patterns. greediness \
          \3: use all available patterns."
    )

optsStenoWords :: Parser OptionsStenoWords
optsStenoWords = (OStwRun <$> greediness <*> optsStenoWordsRun) <|> showChart
  where
    showChart = flag'
        OStwShowChart
        (long "show-chart-only" <> short 'c' <> help
            "Don't compute chords. Only show the chart of the latest scores."
        )

optsStenoWordsRun :: Parser OptionsStenoWordsRun
optsStenoWordsRun =
    (OStwFile <$> switchShowChart <*> mOutputFile)
        <|> (OStwArg <$> arg hlp)
        <|> stdin
  where
    hlp
        = "Parse one word into a series of steno chords. The format is: \
          \\"Di|rek|ti|ve\"."
    stdin = flag'
        OStwStdin
        (  long "stdin"
        <> help
               "Read input from stdin. The format for each line is: \
              \\"Sil|ben|tren|nung\"."
        )

stenoWordsInfo :: InfoMod a
stenoWordsInfo =
    progDesc
        "Read the file \"syllables.txt\" and parse every word into a series \
           \of steno chords. The result is written to \"steno-words.txt\". The \
           \remainder is written to \"steno-words-noparse.txt\"."

germanDictInfo :: InfoMod a
germanDictInfo =
    progDesc
        "Read the file \"stenoparts.txt\" and \"german.dic\" \
           \to then find a series of chords for every german word."

frequencyInfo :: InfoMod a
frequencyInfo =
    progDesc
        "Write 'sten/o/chords word' to a file, most frequent first. 'frequency2k' \
        \is meant for use with palantype.com/learn-palantype, e.g. \
        \copy frequency2k.txt ../learn-palantype/backend/. 'frequencyAll' can \
        \be used to identify missing single syllable words and add the to \
        \the stenoWords algorithm."
