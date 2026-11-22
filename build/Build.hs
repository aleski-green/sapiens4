module Main where

import Control.Monad
import Data.List
import System.Directory
import System.Environment
import System.FilePath
import System.Info
import System.Process

main :: IO ()
main = do
 args <- getArgs
 root <- getCurrentDirectory >>= buildPath
 when (os=="darwin") $ setEnv "MACOSX_DEPLOYMENT_TARGET" "13.0"
 let cache = root </> ".build/cabal"
     platformBuild = root </> ".build" </> (if os=="darwin" then "haskell-macos-13.0" else "haskell")
     build = platformBuild </> "browser-crypto"
     suffix = if os=="mingw32" then ".exe" else ""
     desktop = os=="linux" && "--desktop" `elem` args
     buildFlags = ["--flags=" ++ (if desktop then "linux-desktop" else "-linux-desktop")]
     targets = ["sapiens4","sapiens-domain","sapiens-migrate","sapiens-storage-check"] ++ case os of
      "darwin" -> ["sapiens-macos","sapiens-macos-starter"]
      "mingw32" -> ["sapiens-windows","sapiens-starter"]
      _ -> ["sapiens-linux" | desktop]
 setEnv "CABAL_DIR" cache
 createDirectoryIfMissing True cache
 index <- doesFileExist (cache </> "packages/hackage.haskell.org/01-index.tar")
 unless index (callProcess "cabal" ["update"])
 when (os=="mingw32") $ do
  createDirectoryIfMissing True platformBuild
  callProcess "windres" ["-I",root</>"environments/windows",root</>"environments/windows/resources.rc","-O","coff","-o",platformBuild</>"windows-resources.o"]
 let cabal options = callProcess "cabal" (["--project-file="<>root</>"build/cabal.project","--builddir="<>build]++options)
 cabal (["build"]++buildFlags++map ("exe:"++) (filter (/="sapiens-windows") targets)++
  ["--ghc-options=-optc-mmacosx-version-min=13.0 -optl-mmacosx-version-min=13.0" | os=="darwin"])
 -- The desktop resource already contains the application's DPI/UAC manifest.
 when (os=="mingw32") $ cabal (["build","exe:sapiens-windows","--ghc-options=-fno-gen-manifest"]++buildFlags)
 createDirectoryIfMissing True (root </> ".build/bin")
 createDirectoryIfMissing True (root </> ".build/domain")
 forM_ targets $ \name -> do
  source <- trim <$> readProcess "cabal" (["--project-dir="<>root</>"build","--project-file=cabal.project","--builddir="<>build,"list-bin","exe:"<>name]++buildFlags) ""
  let destination = root </> (if name=="sapiens-domain" then ".build/domain" else ".build/bin") </> name<>suffix
  copyFile source (destination<>".installing")
  renameFile (destination<>".installing") destination
 when (os=="mingw32") $ do
  runtime <- case arch of
   "x86_64" -> pure "win-x64"
   "aarch64" -> pure "win-arm64"
   _ -> fail ("Unsupported Windows architecture: "<>arch)
  -- Windows PowerShell must not inherit PowerShell 7's incompatible modules.
  unsetEnv "PSModulePath"
  callProcess "powershell" ["-NoProfile","-ExecutionPolicy","Bypass","-File",root</>"environments/windows/webview2.ps1","-Runtime",runtime,"-Destination",root</>".build/bin"]
 callProcess (root </> ".build/bin/sapiens4"<>suffix) ["build-ui"]
trim :: String -> String
trim = dropWhileEnd (`elem` "\r\n \t") . dropWhile (`elem` "\r\n \t")
buildPath :: FilePath -> IO FilePath
buildPath path = if os=="mingw32" then trim <$> readCreateProcess (shell ("for %I in (\""<>normalise path<>"\") do @echo %~sI")) "" else pure path
