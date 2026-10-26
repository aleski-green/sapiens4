module Main where

import Control.Exception
import Control.Monad
import Data.List
import System.Directory
import System.Environment
import System.Exit
import System.FilePath
import System.Info
import System.Process

main :: IO ()
main = do
 root <- getCurrentDirectory
 peer <- doesFileExist (root </> "spec/support/haskell/Peer.hs")
 let project = root </> "libs4/haskell"
     cache = project </> ".cabal"
     build = project </> ".build"
     suffix = if os=="mingw32" then ".exe" else ""
     targets = ["sapiens4","sapiens-domain"] ++ (if peer then ["sapiens-peer"] else []) ++ if os=="darwin" then ["sapiens-macos"] else if os=="mingw32" then ["sapiens-windows","sapiens-windows-probe","sapiens-provider"] else []
 setEnv "CABAL_DIR" cache
 createDirectoryIfMissing True cache
 index <- doesFileExist (cache </> "packages/hackage.haskell.org/01-index.tar")
 unless index (callProcess "cabal" ["update"])
 sodium <- doesFileExist (project </> "sodium/src/libsodium/.libs/libsodium.a")
 unless sodium $ do
  extracted <- doesDirectoryExist (project </> "sodium")
  unless extracted $ do
   callProcess "tar" ["-xzf",project </> "vendor/libsodium-1.0.20.tar.gz","-C",project]
   renameDirectory (project </> "libsodium-1.0.20") (project </> "sodium")
  withCurrentDirectory (project </> "sodium") $ do
   callProcess "sh" ["configure","--disable-shared","--enable-static"]
   callProcess "make" ["-j4"]
 when (os=="mingw32") $ do
  createDirectoryIfMissing True build
  callProcess "windres" ["-I",root</>"windows",root</>"windows/resources.rc","-O","coff","-o",build</>"windows-resources.o"]
 let cabal args = callProcess "cabal" (["--project-file="<>project</>"cabal.project","--builddir="<>build]++args)
 cabal (["build"]++map ("exe:"++) targets)
 createDirectoryIfMissing True (root </> ".build/bin")
 createDirectoryIfMissing True (root </> ".build/domain")
 forM_ targets $ \name -> do
  source <- trim <$> readProcess "cabal" ["--project-file="<>project</>"cabal.project","--builddir="<>build,"list-bin","exe:"<>name] ""
  let destination = root </> (if name=="sapiens-domain" then ".build/domain" else ".build/bin") </> name<>suffix
  copyFile source (destination<>".installing")
  when (os=="darwin") (packageMac root (destination<>".installing"))
  renameFile (destination<>".installing") destination
 callProcess (root </> ".build/bin/sapiens4"<>suffix) ["build-ui"]
 when (os=="mingw32") $ do
  callProcess "powershell" ["-NoProfile","-ExecutionPolicy","Bypass","-File",root</>"libs4/windows/webview2.ps1","-Destination",root</>".build/bin"]
  callProcess "node" [root</>"libs4/tools/svg-to-ico.cjs",root</>"web/shell/favicon.svg",root</>"windows/AppIcon.ico"]
  callProcess "node" [root</>"libs4/tools/svg-to-ico.cjs",root</>"web/shell/favicon-dark.svg",root</>"windows/AppIconDark.ico"]
trim :: String -> String
trim = dropWhileEnd (`elem` "\r\n \t") . dropWhile (`elem` "\r\n \t")
packageMac :: FilePath -> FilePath -> IO ()
packageMac root binary = do
 let directory = root </> "libs4/haskell/.runtime"
 createDirectoryIfMissing True directory
 output <- readProcess "otool" ["-L",binary] ""
 forM_ (drop 1 (lines output)) $ \line -> case words line of
  dependency:_ | "/" `isPrefixOf` dependency && not ("/usr/lib/" `isPrefixOf` dependency || "/System/Library/" `isPrefixOf` dependency) -> do
   let target = directory </> takeFileName dependency
   copyFile dependency (target<>".installing")
   renameFile (target<>".installing") target
   callProcess "install_name_tool" ["-change",dependency,"@loader_path/../../libs4/haskell/.runtime/"<>takeFileName dependency,binary]
  _ -> pure ()
 callProcess "codesign" ["--force","--sign","-",binary]
