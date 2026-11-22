module BuildVersion (currentBuild, legacyBuild, dataBuildFile) where

currentBuild, legacyBuild :: String
currentBuild = "v00.02.00"
legacyBuild = "v00.01.00"
dataBuildFile :: FilePath
dataBuildFile = "data-build.json"
