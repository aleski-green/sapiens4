module Host.Assets where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.ByteString.Lazy as BL
import System.FilePath

publicAssets :: [(Text,Text,FilePath)]
publicAssets =
 [("/remote-vendor.js","text/javascript","libs4/web/remote-vendor.js"),
  ("/corpora.css","text/css","web/theme/corpora.css"),
  ("/remote-install.css","text/css","web/theme/remote-install.css"),
  ("/manifest.webmanifest","application/manifest+json","web/shell/remote.webmanifest"),
  ("/workspace/guest.js","text/javascript",".build/web/guest.js"),
  ("/sw.js","text/javascript",".build/web/sw.js"),
  ("/live.css","text/css","web/theme/live.css"),
  ("/workspace/styles.css","text/css","web/theme/styles.css"),
  ("/assets/sapi-theme.css","text/css","web/theme/sapi-theme.css")]
 ++ [("/app-icon-"<>T.pack (show n)<>".png","image/png","web/shell/app-icon-"++show n++".png") | n <- [180,192,512::Int]]
 ++ [("/"<>n<>".svg","image/svg+xml","web/shell/"++T.unpack n++".svg") | n <- ["favicon","favicon-dark"]]
asset :: FilePath -> Text -> IO (Maybe (Text,BL.ByteString))
asset root path = case [(mime,file) | (p,mime,file) <- allAssets, p == path] of
 [] -> pure Nothing
 (mime,file):_ -> Just . (mime,) <$> BL.readFile (root </> file)
 where allAssets = [(p,"text/html","web/shell/index.html") | p <- ["/","/workspace/","/workspace/index.html"]] ++ [("/workspace/app.js","text/javascript",".build/web/app.js")] ++ publicAssets
