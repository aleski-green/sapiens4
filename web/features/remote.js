/* QR image stays on the phone. NaCl authenticates encrypted application messages. */
'use strict';
(() => {
  const {nacl, jsQR} = RemoteVendor;
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
    if(label) { label.textContent=label.id==='status' ? text : text==='Remote · Disconnect' ? text : 'Remote · Waiting'; label.title=text; }
  };
  let session=null, paired=false, polling=false, socket=null, ready=false, reconnectTimer=null, reconnectDelay=1000, serial=0;
  const calls=new Map();
  const pending=new Map(), received=new Set();
  function frame(payload) {
    const message={v:protocol,room:session.room,direction:'phone-to-desktop',...payload};
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
      if(event.code===4001) {status('Pairing revoked or expired. Disconnect and pair again on desktop.');return;}
      status('Relay disconnected. Reconnecting…');
      reconnectTimer=setTimeout(connect,reconnectDelay+Math.random()*500);
      reconnectDelay=Math.min(30000,reconnectDelay*2);
    };
    ws.onerror=()=>status('Relay connection unavailable. Retrying…');
  }
  function relay(method='POST', body, message) {
    if(!ready || !socket || socket.readyState!==WebSocket.OPEN) return Promise.reject(new Error('Relay reconnecting.'));
    if(calls.size>=128 || socket.bufferedAmount>24000000) return Promise.reject(new Error('Relay is busy. Retrying.'));
    const id=String(++serial);
    return new Promise((resolve,reject)=>{
      const timer=setTimeout(()=>{calls.delete(id);reject(new Error('Relay did not confirm delivery.'));socket?.close();},10000);
      calls.set(id,{resolve,reject,timer});
      try {socket.send(JSON.stringify(method==='DELETE' ? {type:'ack',id,message} : {type:'send',id,frame:body}));}
      catch(error) {clearTimeout(timer);calls.delete(id);reject(error);}
    });
  }
  async function send(payload, callbacks={}) {
    const id=b64(nacl.randomBytes(18)), expires=Date.now()/1000+120;
    const encrypted=frame({id,expires,...payload});
    pending.set(id,{...payload,...callbacks,expires,frame:encrypted,lastSent:0});
    try { await relay('POST',encrypted); if(pending.has(id)) pending.get(id).lastSent=Date.now(); }
    catch(error) { status(error.message+' Message remains pending until its two-minute expiry.'); }
    return id;
  }
  function apiRequest(path, options={}) {
    if(!paired) return Promise.reject(new Error('Pair this device first.'));
    return new Promise((resolve,reject)=>{
      let data;
      try { data=options.body===undefined ? undefined : JSON.parse(options.body); }
      catch(error) { reject(error); return; }
      send({kind:'request',op:'api',method:options.method || 'GET',path,data},{
        resolve(result) {
          if(!Number.isInteger(result.status)) { reject(new Error('Invalid desktop response')); return; }
          const body=result.binary ? bytes(result.body) : JSON.stringify(result.body);
          resolve(new Response(body,{status:result.status,headers:{'Content-Type':result.mime}}));
        },reject
      }).catch(reject);
    });
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
      document.head.append(document.importNode(link,true));
    }
    document.querySelector('link[href="/remote.css"]')?.remove();
    document.body.className=shell.body.className;
    document.body.replaceChildren(...[...shell.body.childNodes].map(node=>document.importNode(node,true)));
    const connect=document.querySelector('a[href="/remote/"]');
    const remote=document.createElement('button');remote.type='button';remote.className='pill';remote.id='remote-status';
    remote.textContent='Remote · Disconnect';remote.setAttribute('aria-label','Disconnect remote device');
    remote.addEventListener('click',disconnect);connect?.replaceWith(remote);
    Object.defineProperty(window,'sapiensRemote',{value:Object.freeze({fetch:apiRequest}),configurable:false});
    for(const src of scripts) {
      const script=document.createElement('script');script.src=src;script.async=false;document.body.append(script);
    }
  }
  function disconnect() {
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
      try { message=decode(item.frame); } catch { await relay('DELETE',null,item.id); continue; }
      if(!received.has(message.id) && pending.has(message.id)) {
        const original=pending.get(message.id);
        received.add(message.id);pending.delete(message.id);
        if(received.size>1000) received.delete(received.values().next().value);
        if(message.result.error) { status(message.result.error);original.reject?.(new Error(message.result.error)); }
        else if(message.result.paired && original.kind==='pair') {
          paired=true;status('Paired. Opening CORPORA…');openCorpora().catch(error=>status(error.message));
        } else if(original.op==='api') {
          original.resolve(message.result);status('Remote · Disconnect');
        }
      }
      await relay('DELETE',null,item.id);
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
          if(item.kind==='pair') status('Pairing timed out. Disconnect this page and create a new QR on desktop.');
        } else if(ready && Date.now()-item.lastSent>15000) {
          item.lastSent=Date.now();
          // Same ciphertext and ID on every retry; desktop durably deduplicates commands.
          await relay('POST',item.frame);
        }
      }
    } catch(error) {status(error.message);}
    finally {polling=false;}
  }
  async function upload(file) {
    if(!window.isSecureContext) throw new Error('Open this app over HTTPS.');
    if(!file || file.size>10*1024*1024) throw new Error('Choose a QR image smaller than 10 MB.');
    const url=URL.createObjectURL(file), image=new Image();
    try {
      image.src=url;await image.decode();
      if(image.naturalWidth*image.naturalHeight>20000000) throw new Error('Image dimensions are too large.');
      const scale=Math.min(1,1600/Math.max(image.naturalWidth,image.naturalHeight));
      const canvas=document.createElement('canvas');canvas.width=Math.round(image.naturalWidth*scale);canvas.height=Math.round(image.naturalHeight*scale);
      const context=canvas.getContext('2d',{willReadFrequently:true});context.drawImage(image,0,0,canvas.width,canvas.height);
      const pixels=context.getImageData(0,0,canvas.width,canvas.height);
      const qr=jsQR(pixels.data,canvas.width,canvas.height);
      if(!qr || qr.data.length>4096) throw new Error('No supported QR found in this image.');
      const data=JSON.parse(qr.data);
      if(data.v!==protocol || data.relay!==location.origin || typeof data.expires!=='number' ||
         data.expires<=Date.now()/1000 || data.expires>Date.now()/1000+180 ||
         !['room','token','secret'].every(k=>typeof data[k]==='string' && /^[A-Za-z0-9_-]{32,64}$/.test(data[k])))
        throw new Error('QR expired or belongs to a different relay. Open the address shown on desktop.');
      bytes(data.desktop,32);
      session={...data,keys:nacl.box.keyPair()};
      const hash=await crypto.subtle.digest('SHA-256',session.keys.publicKey);
      $('fingerprint').textContent=Array.from(new Uint8Array(hash)).map(x=>x.toString(16).padStart(2,'0')).join('').slice(0,32);
      $('pair-panel').hidden=true;$('verify-panel').hidden=false;$('forget').hidden=false;
      connect();
      await send({kind:'pair',secret:data.secret});delete session.secret;
      $('qr-file').value='';status('Compare the fingerprint and approve this phone on desktop.');
      await tick();
    } finally { URL.revokeObjectURL(url); }
  }
  $('qr-file').addEventListener('change',async event=>{try{await upload(event.target.files[0]);}catch(error){status(error.message);}});
  $('forget').addEventListener('click',disconnect);
  document.addEventListener('visibilitychange',()=>{if(!document.hidden){if(!socket){clearTimeout(reconnectTimer);connect();}tick();}});
  setInterval(tick,1000); // Local expiry/retry clock only; no idle network polling.
})();
