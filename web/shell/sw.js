/* Cache only the public app shell. Credentials and API responses never enter CacheStorage. */
const CACHE='sapiens-shell-v1';
const ASSETS=['/','/workspace/app.js','/workspace/styles.css','/live.css','/corpora.css','/assets/sapi-theme.css','/assets/sapi-theme.js','/corpora.js','/remote-code.js','/remote-session.js','/remote-transport.js','/remote-onboarding.js','/remote-install.js','/remote-install.css','/remote-vendor.js','/manifest.webmanifest','/app-icon-180.png','/app-icon-192.png','/app-icon-512.png'];
// iOS can keep an installed app's old worker alive after it leaves the screen.
// Activate a complete new shell immediately; existing pages are never reloaded.
self.addEventListener('install',event=>event.waitUntil(caches.open(CACHE).then(cache=>cache.addAll(ASSETS)).then(()=>self.skipWaiting())));
self.addEventListener('activate',event=>event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(key=>key.startsWith('sapiens-shell-')&&key!==CACHE).map(key=>caches.delete(key))))));
self.addEventListener('fetch',event=>{
 const url=new URL(event.request.url);
 if(event.request.method!=='GET'||url.origin!==self.location.origin||url.pathname.startsWith('/api/'))return;
 // Keep HTML and scripts from the same complete shell during an update.
 if(event.request.mode==='navigate'){event.respondWith(caches.open(CACHE).then(cache=>cache.match('/')).then(cached=>cached||fetch(event.request)));return;}
 if(ASSETS.includes(url.pathname))event.respondWith(caches.open(CACHE).then(cache=>cache.match(event.request,{ignoreSearch:true})).then(cached=>cached||fetch(event.request)));
});
