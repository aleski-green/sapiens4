/* QR image stays on the phone. NaCl authenticates encrypted application messages. */
'use strict';
(() => {
  const {nacl} = RemoteVendor;
  const $ = id => document.getElementById(id);
  const protocol = 'sapiens-remote-box-v1';
  const encoder = new TextEncoder(), decoder = new TextDecoder();
  const b64 = bytes => { let s=''; for(const b of bytes) s+=String.fromCharCode(b); return btoa(s); };
  const bytes = (text, length) => {
    if(typeof text !== 'string' || text.length > 22000000) throw new Error('Invalid encoded data');
    const raw = Uint8Array.from(atob(text), c => c.charCodeAt(0));
    if(length && raw.length !== length) throw new Error('Invalid key or nonce');
    return raw;
  };
  const status = text => {
    const label=$('status') || $('remote-status');
    if(label) {
      label.textContent=text;
      label.title=storageWarning && text==='Remote · Connected' ?
        'This browser could not remember the device. Keep this page open or pair again after closing it.' : text;
    }
    if(label?.id==='remote-status') {
      label.dataset.connected=String(text==='Remote · Connected');
      window.dispatchEvent(new Event('sapiens-connection-change'));
    }
    const feedback=$('remote-feedback');
    if(feedback) {feedback.textContent=text;feedback.hidden=text==='Remote · Connected';}
  };
  let session=null, paired=false, polling=false, socket=null, ready=false, reconnectTimer=null, reconnectDelay=1000, serial=0;
  let starting=true, storageWarning=false, pairing=false;
  const calls=new Map();
  const pending=new Map();
  function frame(payload) {
    const message={v:protocol,room:session.room,direction:'phone-to-desktop',corpora_id:session.corpora?.id,...payload};
    const raw=encoder.encode(JSON.stringify(message));
    if(raw.length>16000000) throw new Error('Remote request exceeds the 16 MB limit.');
    const nonce=nacl.randomBytes(24);
    return {sender:b64(session.keys.publicKey),nonce:b64(nonce),ciphertext:b64(nacl.box(
      raw,nonce,bytes(session.desktop,32),session.keys.secretKey))};
  }
  function decode(frame) {
    if(frame.sender !== session.desktop) throw new Error('Wrong desktop identity');
    const plain=nacl.box.open(bytes(frame.ciphertext),bytes(frame.nonce,24),bytes(session.desktop,32),session.keys.secretKey);
    if(!plain) throw new Error('Message authentication failed');
    const message=JSON.parse(decoder.decode(plain));
    if(message.v!==protocol || message.room!==session.room || message.direction!=='desktop-to-phone' ||
       message.kind!=='response' || typeof message.expires!=='number' || message.expires<=Date.now()/1000 ||
       message.expires>Date.now()/1000+86400 || typeof message.id!=='string' || !message.result) throw new Error('Invalid message');
    return message;
  }
  function connect() {
    if(!session || socket) return;
    const ws=new WebSocket(location.origin.replace(/^http/, 'ws')+'/api/socket');
    socket=ws;ready=false;
    let delivery=Promise.resolve(), queued=0;
    const authTimer=setTimeout(()=>ws.close(),10000);
    ws.onopen=()=>ws.send(JSON.stringify({type:'auth',room:session.room,token:session.token}));
    ws.onmessage=event=>{
      if(socket!==ws) return;
      try {
        if(typeof event.data!=='string' || event.data.length>22008192) throw new Error('Relay message too large');
        const data=JSON.parse(event.data);
        if(data.type==='ready') {
          clearTimeout(authTimer);ready=true;reconnectDelay=1000;
          for(const item of pending.values()) item.lastSent=0;
          tick();
        } else if(data.type==='result') {
          const call=calls.get(data.id);
          if(call) { calls.delete(data.id);clearTimeout(call.timer);data.error ? call.reject(new Error(data.error)) : call.resolve(data.result); }
        } else if(data.type==='messages') {
          if(++queued>2) throw new Error('Relay delivery overflow');
          delivery=delivery.then(()=>consume(data)).catch(error=>{status(error.message);ws.close();}).finally(()=>queued--);
        } else throw new Error('Invalid relay response');
      } catch(error) { status(error.message);ws.close(); }
    };
    ws.onclose=event=>{
      clearTimeout(authTimer);
      if(socket!==ws) return;
      socket=null;ready=false;
      for(const call of calls.values()) {clearTimeout(call.timer);call.reject(new Error('Relay disconnected.'));}
      calls.clear();
      if(!session) return;
      if(event.code===4002) {status('Connected in another tab. Return to this tab to reconnect.');return;}
      if(event.code===4001) {
        RemoteSession.clear().catch(()=>{});
        for(const item of pending.values()) item.reject?.(new Error('Device access was revoked.'));
        pending.clear();paired=false;session.keys.secretKey.fill(0);session=null;
        status('Device access was revoked or the invitation expired. Forget this device and scan a new QR on desktop.');return;
      }
      status('Relay disconnected. Reconnecting…');
      reconnectTimer=setTimeout(connect,reconnectDelay+Math.random()*500);
      reconnectDelay=Math.min(30000,reconnectDelay*2);
    };
    ws.onerror=()=>status('Relay connection unavailable. Retrying…');
  }
  function relay(type, body) {
    if(!ready || !socket || socket.readyState!==WebSocket.OPEN) return Promise.reject(new Error('Relay reconnecting.'));
    if(calls.size>=128 || socket.bufferedAmount>24000000) return Promise.reject(new Error('Relay is busy. Retrying.'));
    const id=String(++serial);
    return new Promise((resolve,reject)=>{
      const timer=setTimeout(()=>{calls.delete(id);reject(new Error('Relay did not confirm delivery.'));socket?.close();},10000);
      calls.set(id,{resolve,reject,timer});
      try {socket.send(JSON.stringify({type,id,...body}));}
      catch(error) {clearTimeout(timer);calls.delete(id);reject(error);}
    });
  }
  async function send(payload, callbacks={}) {
    const id=b64(nacl.randomBytes(18)), expires=payload.kind==='pair' ? session.expires : Date.now()/1000+120;
    const encrypted=frame({id,expires,...payload});
    pending.set(id,{kind:payload.kind,op:payload.op,...callbacks,expires,frame:encrypted,lastSent:0});
    try { await relay('send',{frame:encrypted}); if(pending.has(id)) pending.get(id).lastSent=Date.now(); }
    catch(error) { status(error.message+(payload.kind==='pair' ? ' Pairing remains pending until the code expires.' : ' Message remains pending until its two-minute expiry.')); }
  }
  async function apiRequest(path, options={}) {
    if(!paired) throw new Error('Pair this device first.');
    const data=options.body===undefined ? undefined : JSON.parse(options.body);
    const result=await new Promise((resolve,reject)=>{
      send({kind:'request',op:'api',method:options.method || 'GET',path,data},{resolve,reject}).catch(reject);
    });
    if(!Number.isInteger(result.status)) throw new Error('Invalid desktop response');
    const body=result.binary ? bytes(result.body) : JSON.stringify(result.body);
    return new Response(body,{status:result.status,headers:{'Content-Type':result.mime}});
  }
  async function openCorpora() {
    // Fetch only the static shell here. All application requests use the paired transport.
    const response=await fetch('/workspace/',{cache:'no-store',redirect:'error'});
    if(!response.ok) throw new Error('Could not load CORPORA. Reconnect this page.');
    const shell=new DOMParser().parseFromString(await response.text(),'text/html');
    const scripts=[...shell.querySelectorAll('script[src]')].map(node=>new URL(node.getAttribute('src'),location.origin+'/workspace/').pathname);
    shell.querySelectorAll('script').forEach(node=>node.remove());
    for(const link of shell.querySelectorAll('link[rel="stylesheet"]')) {
      link.href=new URL(link.getAttribute('href'),location.origin+'/workspace/').pathname;
      if(![...document.querySelectorAll('link[rel="stylesheet"]')].some(existing=>existing.href===link.href))
        document.head.append(document.importNode(link,true));
    }
    document.querySelector('link[href="/remote.css"]')?.remove();
    document.body.className=shell.body.className;
    onboarding.stop();
    document.body.replaceChildren(...[...shell.body.childNodes].map(node=>document.importNode(node,true)));
    const identity=$('corpora-identity');
    if(identity && session.corpora) {
      identity.hidden=false;identity.textContent=session.corpora.name;identity.title=session.corpora.id;
    }
    const remote=document.createElement('button');remote.type='button';remote.hidden=true;remote.id='remote-status';
    remote.textContent='Remote · Connected';remote.setAttribute('aria-label','Forget this trusted device');
    remote.addEventListener('click',disconnect);document.body.append(remote);
    const feedback=document.createElement('p');feedback.id='remote-feedback';feedback.setAttribute('role','status');
    feedback.hidden=true;document.body.append(feedback);
    Object.defineProperty(window,'sapiensRemote',{value:Object.freeze({fetch:apiRequest}),configurable:false});
    RemoteInstall.mount(true);
    for(const src of scripts) {
      if(src==='/assets/sapi-theme.js') { window.SapiTheme?.refresh(); continue; }
      const script=document.createElement('script');script.src=src;script.async=false;document.body.append(script);
    }
    status('Remote · Connected');
  }
  async function disconnect() {
    try { await RemoteSession.clear(); }
    catch { status('Could not forget this device. Close other remote tabs and try again.'); return; }
    clearTimeout(reconnectTimer);
    if(session) session.keys.secretKey.fill(0);
    for(const item of pending.values()) item.reject?.(new Error('Disconnected'));
    pending.clear();paired=false;session=null;socket?.close();location.reload();
  }
  async function consume(data) {
    if(!session) return;
    if(!Array.isArray(data.messages) || data.messages.length>20) throw new Error('Invalid relay response');
    for(const item of data.messages) {
      if(!Number.isSafeInteger(item.id) || item.id<=0) throw new Error('Invalid relay message');
      let message;
      try { message=decode(item.frame); } catch { await relay('ack',{message:item.id}); continue; }
      if(pending.has(message.id)) {
        const original=pending.get(message.id);
        pending.delete(message.id);
        if(message.result.error) { status(message.result.error);original.reject?.(new Error(message.result.error)); }
        else if(message.result.paired && (original.kind==='pair' || original.op==='resume')) {
          const corpora=message.result.corpora;
          if(!corpora || typeof corpora.id!=='string' || !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(corpora.id) ||
             typeof corpora.name!=='string' || corpora.name.length>200 ||
             (session.corpora && session.corpora.id!==corpora.id)) {
            session.identityRejected=true;
            status('CORPORA identity changed or is unavailable. Forget this device and pair with the intended workspace.');
            await relay('ack',{message:item.id});continue;
          }
          session.corpora={id:corpora.id,name:corpora.name};
          paired=true;
          const approved=session;
          try { await RemoteSession.save(approved); } catch { storageWarning=true; }
          if(session!==approved || !paired) return;
          status('Connected. Opening CORPORA…');openCorpora().catch(error=>status(error.message));
        } else if(original.op==='api') {
          original.resolve(message.result);status('Remote · Connected');
        }
      }
      await relay('ack',{message:item.id});
    }
  }
  async function tick() {
    if(!session || polling) return;
    polling=true;
    try {
      for(const [id,item] of pending) {
        if(item.expires<=Date.now()/1000) {
          pending.delete(id);
          item.reject?.(new Error('Desktop did not confirm this request. Check desktop state before repeating an action.'));
          if(item.kind==='pair') status('QR expired. Cancel and show a new QR on desktop.');
          if(item.op==='resume') status('Your desktop is offline. Reconnecting when it becomes available…');
        } else if(ready && Date.now()-item.lastSent>15000) {
          item.lastSent=Date.now();
          // Same ciphertext and ID on every retry; desktop durably deduplicates commands.
          await relay('send',{frame:item.frame});
        }
      }
      if(session && !paired && session.restored && !session.identityRejected && ![...pending.values()].some(item=>item.op==='resume'))
        await send({kind:'request',op:'resume'});
    } catch(error) {status(error.message);}
    finally {polling=false;}
  }
  async function pair(data) {
    if(pairing) throw new Error('Connection already in progress.');
    pairing=true;
    try { await beginPair(data); } finally { pairing=false; }
  }
  async function beginPair(data) {
    if(starting) throw new Error('Checking saved device…');
    if (!window.isSecureContext) throw new Error('Open this app over HTTPS.');
    if (session) throw new Error('A pairing is already in progress.');
    if (!data || typeof data !== 'object') throw new Error('Invalid pairing invitation.');
    if(data.v!==protocol || data.relay!==location.origin || typeof data.expires!=='number' ||
       data.expires<=Date.now()/1000 || data.expires>Date.now()/1000+259260 ||
       !['room','token','secret'].every(k=>typeof data[k]==='string' && /^[A-Za-z0-9_-]{32,64}$/.test(data[k])))
      throw new Error('QR expired or belongs to another server. Use the latest QR from your desktop.');
    bytes(data.desktop,32);
    await onboarding.validate(data);
    onboarding.stop();
    session={...data,keys:nacl.box.keyPair()};
    $('confirmation-code').textContent=await RemoteCode.confirmation(data.desktop,b64(session.keys.publicKey),data.room);
    $('pair-panel').hidden=true;$('verify-panel').hidden=false;$('forget').hidden=false;
    connect();
    await send({kind:'pair',secret:data.secret});delete session.secret;
    $('qr-file').value='';status('Waiting for desktop approval…');
    await tick();
  }
  const onboarding = RemoteOnboarding.mount(pair, status);
  $('forget').addEventListener('click',disconnect);
  const wake=()=>{if(!document.hidden){if(!socket){clearTimeout(reconnectTimer);connect();}tick();}};
  document.addEventListener('visibilitychange',wake);
  window.addEventListener('online',wake);
  window.addEventListener('hashchange',async()=>{
    const invitation=location.hash.slice(1);
    if(!invitation) return;
    history.replaceState(null,'',location.pathname);
    if(session) {status('Forget the current device connection before pairing with another CORPORA.');return;}
    try {await pair(RemoteCode.decode(invitation));}
    catch(error) {status(error.message);}
  });
  setInterval(tick,1000); // Local expiry/retry clock only; no idle network polling.
  async function start() {
    // Fragments never reach HTTP or referrer headers. Erase the one-use invitation
    // from this history entry before any asynchronous work or network connection.
    const fragment=location.hash.slice(1);
    if(fragment) history.replaceState(null,'',location.pathname);
    $('find-corpora').disabled=true;
    let saved;
    try { saved=await RemoteSession.read(); } catch { storageWarning=true; }
    starting=false;$('find-corpora').disabled=false;
    if(saved) {
      try {
        if(saved.version!==1 || saved.relay!==location.origin ||
          !['room','token'].every(k=>typeof saved[k]==='string' && /^[A-Za-z0-9_-]{32,64}$/.test(saved[k])))
          throw new Error('Invalid saved device');
        bytes(saved.desktop,32);
        if(!(saved.keys?.secretKey instanceof Uint8Array) || saved.keys.secretKey.length!==32 ||
          !(saved.keys.publicKey instanceof Uint8Array) || saved.keys.publicKey.length!==32 ||
          b64(nacl.box.keyPair.fromSecretKey(saved.keys.secretKey).publicKey)!==b64(saved.keys.publicKey))
          throw new Error('Invalid saved device key');
        session={...saved,restored:true};
        $('pair-panel').hidden=true;$('forget').hidden=false;
        status('Reconnecting to your desktop…');connect();
        await send({kind:'request',op:'resume'});return;
      } catch {
        session=null;await RemoteSession.clear().catch(()=>{});
        status('Saved device could not be restored. Scan a new QR on desktop.');
      }
    }
    if(fragment) {
      try { await pair(RemoteCode.decode(fragment)); }
      catch(error) { status(error.message); }
    }
  }
  start();
})();
