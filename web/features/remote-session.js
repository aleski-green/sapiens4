/* Trusted-device credentials stay in this relay origin's browser profile. */
'use strict';
window.RemoteSession = (() => {
  function transaction(mode, operation) {
    return new Promise((resolve, reject) => {
      let db, value, finished = false;
      const finish = error => {
        if (finished) return;
        finished = true; clearTimeout(timer); db?.close();
        error ? reject(error) : resolve(value);
      };
      const timer = setTimeout(() => finish(new Error('Device storage is unavailable.')), 3000);
      try {
        const opening = indexedDB.open('sapiens-remote', 1);
        opening.onupgradeneeded = () => opening.result.createObjectStore('device');
        opening.onerror = () => finish(opening.error);
        opening.onblocked = () => finish(new Error('Close other remote tabs and try again.'));
        opening.onsuccess = () => {
          db = opening.result;
          if (finished) { db.close(); return; }
          try {
            const tx = db.transaction('device', mode);
            const request = operation(tx.objectStore('device'));
            request.onsuccess = () => { value = request.result; };
            tx.oncomplete = () => finish();
            tx.onabort = () => finish(tx.error || new Error('Device storage failed.'));
          } catch (error) { finish(error); }
        };
      } catch (error) { finish(error); }
    });
  }
  return {
    read: () => transaction('readonly', store => store.get('trusted')),
    save: session => transaction('readwrite', store => store.put({
      version: 1, relay: session.relay, room: session.room, token: session.token,
      desktop: session.desktop, keys: session.keys, corpora: session.corpora,
    }, 'trusted')),
    clear: () => transaction('readwrite', store => store.delete('trusted')),
  };
})();
