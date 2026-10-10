/* Rebuild the checked-in, same-origin vendor bundle. No runtime CDN dependencies. */
const path = require('node:path');
require('esbuild').buildSync({
  stdin: {contents: "export {default as nacl} from 'tweetnacl'; export {default as jsQR} from 'jsqr'; export {default as QRCode} from 'qrcode';",
    resolveDir: __dirname},
  bundle:true,platform:'browser',format:'iife',globalName:'RemoteVendor',minify:true,
  legalComments:'eof',outfile:path.join(__dirname,'../web/features/remote-vendor.js'),
});
