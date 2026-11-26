module Config (boxKeyBytes, identityFileVersion, yokeHistoryLimit, yokeStart) where

yokeHistoryLimit :: Int
yokeHistoryLimit = 100

yokeStart :: Integer
yokeStart = 0

identityFileVersion :: Int
identityFileVersion = 1

boxKeyBytes :: Int
boxKeyBytes = 32
