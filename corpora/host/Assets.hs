module Assets where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.ByteString.Lazy as BL
import Data.List (find)
import System.FilePath

data Asset = Asset { assetRoute :: Text, assetMime :: Text, assetFile :: FilePath }

publicAssets :: [(Text,Text,FilePath)]
publicAssets =
 [("/terms-of-service.html","text/html","app/shell/terms-of-service.html"),
  ("/privacy-policy.html","text/html","app/shell/privacy-policy.html"),
  ("/remote-vendor.js","text/javascript",".build/web/remote-vendor.js"),
  ("/theme.js","text/javascript",".build/web/theme.js"),
  ("/remote-crypto.js","text/javascript",".build/web/remote-crypto.js"),
  ("/voice-worklet.js","text/javascript",".build/web/voice-worklet.js"),
  ("/corpora.css","text/css","app/theme/corpora.css"),
  ("/remote-install.css","text/css","app/theme/remote-install.css"),
  ("/manifest.webmanifest","application/manifest+json","app/shell/remote.webmanifest"),
  ("/workspace/guest.js","text/javascript",".build/web/guest.js"),
  ("/sw.js","text/javascript",".build/web/sw.js"),
  ("/live.css","text/css","app/theme/live.css"),
  ("/workspace/styles.css","text/css","app/theme/styles.css"),
  ("/assets/sapi-theme.css","text/css","app/theme/sapi-theme.css")]
 ++ [(prefix<>n<>".woff2","font/woff2","app/theme/fonts/"++T.unpack n++".woff2") | prefix <- ["/assets/fonts/","/theme/fonts/"], n <- ["dm-sans","zen-maru-light","zen-maru-medium","ibm-plex-mono"]]
 ++ [("/app-icon-"<>T.pack (show n)<>".png","image/png","app/shell/app-icon-"++show n++".png") | n <- [180,192,512::Int]]
 ++ [("/"<>n<>".svg","image/svg+xml","app/shell/"++T.unpack n++".svg") | n <- ["favicon","favicon-dark","ai-codex","ai-claude","ai-gemini","ai-kimi"]]
asset :: FilePath -> Text -> IO (Maybe (Text,BL.ByteString))
asset root path = traverse readAsset (lookupAsset path)
 where readAsset entry = (assetMime entry,) <$> BL.readFile (root </> assetFile entry)

lookupAsset :: Text -> Maybe Asset
lookupAsset path = find ((==path) . assetRoute) allAssets

allAssets :: [Asset]
allAssets = [Asset p "text/html" "app/shell/index.html" | p <- ["/","/workspace/","/workspace/index.html"]]
 ++ [Asset "/workspace/app.js" "text/javascript" ".build/web/app.js"]
 ++ [Asset route mime file | (route,mime,file) <- publicAssets]
