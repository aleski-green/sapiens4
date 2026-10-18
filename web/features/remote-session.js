/* Trust is scoped to both relay origin and permanent corpora identity. */
'use strict';
window.RemoteSession = (() => {
  const key = session => session.relay + '|' + session.corpora.id;
  function transaction(mode, operation) {
    return new Promise((resolve, reject) => {
      let db, value, finished = false;
      const finish = error => { if(finished)return;finished=true;clearTimeout(timer);db?.close();error?reject(error):resolve(value); };
      const timer=setTimeout(()=>finish(new Error('Device storage is unavailable.')),3000);
      try {
        const opening=indexedDB.open('sapiens-remote',2);
        opening.onupgradeneeded=()=>{
          const database=opening.result;
          if(!database.objectStoreNames.contains('device'))database.createObjectStore('device');
          if(!database.objectStoreNames.contains('connections'))database.createObjectStore('connections');
          const tx=opening.transaction;
          const old=tx.objectStore('device').get('trusted');
          old.onsuccess=()=>{if(old.result?.corpora?.id){tx.objectStore('connections').put(old.result,key(old.result));}};
        };
        opening.onerror=()=>finish(opening.error);
        opening.onblocked=()=>finish(new Error('Close other Sapiens4 tabs and try again.'));
        opening.onsuccess=()=>{
          db=opening.result;if(finished){db.close();return;}
          try {
            const tx=db.transaction(['device','connections'],mode);
            const request=operation(tx.objectStore('connections'),tx.objectStore('device'));
            request.onsuccess=()=>{value=request.result;};
            tx.oncomplete=()=>finish();tx.onabort=()=>finish(tx.error||new Error('Device storage failed.'));
          }catch(error){finish(error);}
        };
      }catch(error){finish(error);}
    });
  }
  return {
    key,
    list:()=>transaction('readonly',store=>store.getAll()),
    read:id=>transaction('readonly',(store,legacy)=>id?store.get(id):legacy.get('trusted')),
    save:session=>transaction('readwrite',(store,legacy)=>{
      const saved={version:1,relay:session.relay,room:session.room,token:session.token,desktop:session.desktop,keys:session.keys,corpora:session.corpora};
      legacy.put(saved,'trusted');return store.put(saved,key(saved));
    }),
    clear:id=>transaction('readwrite',(store,legacy)=>{
      if(id){const old=legacy.get('trusted');old.onsuccess=()=>{if(old.result&&key(old.result)===id)legacy.delete('trusted');};return store.delete(id);}
      const old=legacy.get('trusted');old.onsuccess=()=>{if(old.result?.corpora)store.delete(key(old.result));};return legacy.delete('trusted');
    }),
  };
})();
