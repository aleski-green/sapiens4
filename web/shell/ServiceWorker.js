// Service Worker platform bindings; cache selection and lifecycle policy are PureScript.
export const listen = name => handler => () => { self.addEventListener(name, event => handler(event)()); };
export const waitUntil = event => promise => () => { event.waitUntil(promise); };
export const respondWith = event => promise => () => { event.respondWith(promise); };
export const openCache = name => () => caches.open(name);
export const addAll = assets => cache => () => cache.addAll(assets);
export const cacheKeys = () => caches.keys();
export const deleteCache = key => () => caches.delete(key);
export const skipWaiting = () => Promise.resolve(self.skipWaiting());
export const request = event => event.request;
export const requestInfo = request => { const url = new URL(request.url); return {method:request.method, origin:url.origin, pathname:url.pathname, mode:request.mode || ''}; };
export const origin = self.location.origin;
export const matchPage = cache => () => cache.match('/');
export const matchAsset = request => cache => () => cache.match(request, {ignoreSearch:true});
export const fetch = request => () => globalThis.fetch(request);
