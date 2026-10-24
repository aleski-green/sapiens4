// IndexedDB bindings; persistence shape, migration and lifecycle live in PureScript.
export const open = name => version => () => indexedDB.open(name, version);
export const close = db => () => { db.close(); };
export const hasStore = name => db => () => db.objectStoreNames.contains(name);
export const createStore = name => db => () => { db.createObjectStore(name); };
export const upgradeTransaction = request => () => request.transaction;
export const begin = name => mode => db => () => db.transaction(name, mode);
export const objectStore = name => transaction => () => transaction.objectStore(name);
export const result = request => () => request.result;
export const failure = source => () => source.error;
export const handle = name => action => source => () => { source[name] = () => action(); };
export const get = key => store => () => store.get(key);
export const getAll = store => () => store.getAll();
export const put = value => key => store => () => store.put(value, key);
export const remove = key => store => () => store.delete(key);
export const timer = milliseconds => action => () => { const id = setTimeout(action, milliseconds); return () => clearTimeout(id); };
export const legacyIdentity = session => session?.corpora?.id ?? null;
