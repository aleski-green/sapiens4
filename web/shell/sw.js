/* Cache only the public app shell. Credentials and API responses never enter CacheStorage. */
const CACHE='sapiens-shell-v1';
const ASSETS=['/','/workspace/app.js','/workspace/styles.css','/live.css','/corpora.css','/assets/sapi-theme.css','/assets/sapi-theme.js','/corpora.js','/remote-code.js','/remote-session.js','/remote-transport.js','/remote-onboarding.js','/remote-install.js','/remote-install.css','/remote-vendor.js','/manifest.webmanifest','/app-icon-180.png','/app-icon-192.png','/app-icon-512.png'];
self.addEventListener('install',event=>event.waitUntil(caches.open(CACHE).then(cache=>cache.addAll(ASSETS))));
self.addEventListener('activate',event=>event.waitUntil(caches.keys().then(keys=>Promise.all(keys.filter(key=>key.startsWith('sapiens-shell-')&&key!==CACHE).map(key=>caches.delete(key))))));
self.addEventListener('fetch',event=>{
 const url=new URL(event.request.url);
 if(event.request.method!=='GET'||url.origin!==self.location.origin||url.pathname.startsWith('/api/'))return;
 if(event.request.mode==='navigate'){event.respondWith(fetch(event.request).catch(()=>caches.match('/')));return;}
 if(ASSETS.includes(url.pathname))event.respondWith(caches.match(event.request,{ignoreSearch:true}).then(cached=>cached||fetch(event.request)));
});
