{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Network.Haskoin.Wallet.ConsolePrinter where

import           Control.Monad         (when)
import           Data.Monoid
import           Foundation
import           Foundation.Collection
import           Foundation.IO
import           System.Console.ANSI
import           System.Exit
import           System.IO.Unsafe

data ConsolePrinter
    = ConsoleConcat !ConsolePrinter !ConsolePrinter
    | ConsoleNewline !ConsolePrinter
    | ConsoleNest !(CountOf (Element String)) !ConsolePrinter
    | ConsoleText !ConsoleFormat
    | ConsoleEmpty

instance Monoid ConsolePrinter where
    mempty = ConsoleEmpty
    mappend a ConsoleEmpty = a
    mappend ConsoleEmpty b = b
    mappend a b            = ConsoleConcat a b

isEmptyPrinter :: ConsolePrinter -> Bool
isEmptyPrinter ConsoleEmpty       = True
isEmptyPrinter (ConsoleNest _ n)  = isEmptyPrinter n
isEmptyPrinter (ConsoleNewline n) = isEmptyPrinter n
isEmptyPrinter _                  = False

text :: ConsoleFormat -> ConsolePrinter
text = ConsoleText

(<+>) :: ConsolePrinter -> ConsolePrinter -> ConsolePrinter
p1 <+> p2 = p1 <> text (FormatStatic " ") <> p2

vcat :: [ConsolePrinter] -> ConsolePrinter
vcat = go . filter (not . isEmptyPrinter)
  where
    go []     = ConsoleEmpty
    go [x]    = x
    go (x:xs) = x <> ConsoleNewline (go xs)

nest :: CountOf (Element String) -> ConsolePrinter -> ConsolePrinter
nest = ConsoleNest

block :: CountOf (Element String) -> String -> String
block n str =
    case n - length str of
        Just missing -> str <> replicate missing ' '
        _            -> str

renderIO :: ConsolePrinter -> IO ()
renderIO cp = go 0 0 cp >> putStrLn ""
  where
    go :: CountOf (Element String)
       -> CountOf (Element String)
       -> ConsolePrinter
       -> IO (CountOf (Element String))
    go l n p
        | isEmptyPrinter p = return l
        | otherwise = case p of
            ConsoleConcat p1 p2 -> do
                l2 <- go l n p1
                go l2 n p2
            ConsoleNewline p1 -> do
                putStrLn ""
                putStr $ replicate n ' '
                go n n p1
            ConsoleNest i p1 -> do
                putStr $ replicate i ' '
                go (l + i) (n + i) p1
            ConsoleText f -> do
                printFormat f
                return $ l + length (getFormat f)
            ConsoleEmpty -> return l

data ConsoleFormat
    = FormatTitle { getFormat :: !String }
    | FormatStatic { getFormat :: !String }
    | FormatAccount { getFormat :: !String }
    | FormatPubKey { getFormat :: !String }
    | FormatFilePath { getFormat :: !String }
    | FormatKey { getFormat :: !String }
    | FormatDeriv { getFormat :: !String }
    | FormatMnemonic { getFormat :: !String }
    | FormatAddress { getFormat :: !String }
    | FormatInternalAddress { getFormat :: !String }
    | FormatTxHash { getFormat :: !String }
    | FormatBlockHash { getFormat :: !String }
    | FormatPosAmount { getFormat :: !String }
    | FormatNegAmount { getFormat :: !String }
    | FormatFee { getFormat :: !String }
    | FormatTrue { getFormat :: !String }
    | FormatFalse { getFormat :: !String }
    | FormatCash { getFormat :: !String }
    | FormatBitcoin { getFormat :: !String }
    | FormatTestnet { getFormat :: !String }
    | FormatError { getFormat :: !String }

formatTitle :: String -> ConsolePrinter
formatTitle = text . FormatTitle

formatStatic :: String -> ConsolePrinter
formatStatic = text . FormatStatic

formatAccount :: String -> ConsolePrinter
formatAccount = text . FormatAccount

formatPubKey :: String -> ConsolePrinter
formatPubKey = text . FormatPubKey

formatFilePath :: String -> ConsolePrinter
formatFilePath = text . FormatFilePath

formatKey :: String -> ConsolePrinter
formatKey = text . FormatKey

formatDeriv :: String -> ConsolePrinter
formatDeriv = text . FormatDeriv

formatMnemonic :: String -> ConsolePrinter
formatMnemonic = text . FormatMnemonic

formatAddress :: String -> ConsolePrinter
formatAddress = text . FormatAddress

formatInternalAddress :: String -> ConsolePrinter
formatInternalAddress = text . FormatInternalAddress

formatTxHash :: String -> ConsolePrinter
formatTxHash = text . FormatTxHash

formatBlockHash :: String -> ConsolePrinter
formatBlockHash = text . FormatBlockHash

formatPosAmount :: String -> ConsolePrinter
formatPosAmount = text . FormatPosAmount

formatNegAmount :: String -> ConsolePrinter
formatNegAmount = text . FormatNegAmount

formatFee :: String -> ConsolePrinter
formatFee = text . FormatFee

formatTrue :: String -> ConsolePrinter
formatTrue = text . FormatTrue

formatFalse :: String -> ConsolePrinter
formatFalse = text . FormatFalse

formatCash :: String -> ConsolePrinter
formatCash = text . FormatCash

formatBitcoin :: String -> ConsolePrinter
formatBitcoin = text . FormatBitcoin

formatTestnet :: String -> ConsolePrinter
formatTestnet = text . FormatTestnet

formatError :: String -> ConsolePrinter
formatError = text . FormatError

formatSGR :: ConsoleFormat -> [SGR]
formatSGR frm = case frm of
    FormatTitle _           -> [ SetConsoleIntensity BoldIntensity ]
    FormatStatic _          -> []
    FormatAccount _         -> [ SetConsoleIntensity BoldIntensity
                               , SetColor Foreground Dull White
                               ]
    FormatPubKey _          -> [ SetColor Foreground Dull Magenta ]
    FormatFilePath _        -> [ SetItalicized True
                               , SetColor Foreground Dull White
                               ]
    FormatKey _             -> []
    FormatDeriv _           -> []
    FormatMnemonic _        -> [ SetConsoleIntensity BoldIntensity
                               , SetColor Foreground Dull Cyan
                               ]
    FormatAddress _         -> [ SetConsoleIntensity BoldIntensity
                               , SetColor Foreground Dull Blue
                               ]
    FormatInternalAddress _ -> [ SetConsoleIntensity BoldIntensity
                               , SetColor Foreground Vivid Black
                               ]
    FormatTxHash _          -> [ SetColor Foreground Vivid Magenta ]
    FormatBlockHash _       -> [ SetColor Foreground Vivid Magenta ]
    FormatPosAmount  _      -> [ SetConsoleIntensity BoldIntensity
                               , SetColor Foreground Dull Green
                               ]
    FormatNegAmount _       -> [ SetConsoleIntensity BoldIntensity
                               , SetColor Foreground Dull Red
                               ]
    FormatFee _             -> []
    FormatTrue _            -> [ SetConsoleIntensity BoldIntensity
                               , SetColor Foreground Dull Green
                               ]
    FormatFalse _           -> [ SetConsoleIntensity BoldIntensity
                               , SetColor Foreground Dull Red
                               ]
    FormatCash _            -> [ SetColor Foreground Dull Green
                               ]
    FormatBitcoin _         -> [ SetColor Foreground Dull Cyan
                               ]
    FormatTestnet _         -> [ SetColor Foreground Vivid Yellow ]
    FormatError _           -> [ SetColor Foreground Dull Red ]

printFormat :: ConsoleFormat -> IO ()
printFormat f = do
    support <- hSupportsANSI stdout
    when support $ setSGR $ formatSGR f
    putStr $ getFormat f
    when support $ setSGR []

consoleError :: ConsolePrinter -> a
consoleError prt = unsafePerformIO $ renderIO prt >> exitFailure
