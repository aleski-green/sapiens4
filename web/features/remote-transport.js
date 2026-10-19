/* Persistent encrypted sessions; UI and pairing are owned by the workspace shell. */
'use strict';
window.RemoteTransport = class {
  constructor(session){
    const keys=session?.keys;
    if(!keys||keys.secretKey?.length!==32||keys.publicKey?.length!==32||!RemoteVendor.nacl.verify(RemoteVendor.nacl.box.keyPair.fromSecretKey(keys.secretKey).publicKey,keys.publicKey)){
      if(session?.corpora)RemoteSession.clear(RemoteSession.key(session)).catch(()=>{});
      throw new Error('Saved device keys are invalid. Connect this corpora again.');
    }
    this.session=session;this.socket=null;this.pending=new Map();this.serial=0;this.generation=0;
  }
  static bytes(text,length){const bytes=Uint8Array.from(atob(text),c=>c.charCodeAt(0));if(length&&bytes.length!==length)throw new Error('Invalid key');return bytes;}
  static b64(bytes){return btoa(Array.from(bytes,b=>String.fromCharCode(b)).join(''));}
  static async invitation(data){
    if(!window.isSecureContext)throw new Error('Open Sapiens4 over HTTPS.');
    if(!data||data.v!=='sapiens-remote-box-v1'||data.relay!==location.origin||!Number.isFinite(data.expires)||data.expires<=Date.now()/1000||data.expires>Date.now()/1000+259260||!['room','token','secret'].every(k=>typeof data[k]==='string'&&/^[A-Za-z0-9_-]{32,64}$/.test(data[k])))throw new Error('Invitation expired or belongs to another server. Use the latest QR from your host.');
    this.bytes(data.desktop,32);
    if(data.public_id){const response=await fetch('/api/corpora/'+encodeURIComponent(data.public_id),{cache:'no-store',redirect:'error'});const found=await response.json();if(!response.ok||found.desktop!==data.desktop||found.expires<=Date.now()/1000)throw new Error('Invitation replaced. Use the latest QR from your host.');}
    return new this({...data,keys:RemoteVendor.nacl.box.keyPair()});
  }
  connect(){
    if(this.blocked)return Promise.reject(this.blocked);
    if(this.ready)return this.ready;
    const generation=this.generation;this.connectionId=crypto.randomUUID();
    this.ready=new Promise((resolve,reject)=>{
      const ws=new WebSocket(this.session.relay.replace(/^http/,'ws')+'/api/socket');this.socket=ws;
      const timer=setTimeout(()=>{reject(new Error('This device is unreachable. Try again later.'));ws.close();},10000);
      let delivery=Promise.resolve(),queued=0;
      ws.onopen=()=>ws.send(JSON.stringify({type:'auth',room:this.session.room,token:this.session.token}));
      ws.onmessage=event=>{
        if(this.generation!==generation)return;
        try{
          if(typeof event.data!=='string'||event.data.length>22008192)throw new Error('Invalid relay response');
          const data=JSON.parse(event.data);
          if(data.type==='ready'){clearTimeout(timer);resolve();}
          else if(data.type==='result'){if(data.error){for(const p of this.pending.values())p.reject(new Error(data.error));this.pending.clear();}}
          else if(data.type==='messages'){
            if(!Array.isArray(data.messages)||data.messages.length>20||++queued>2)throw new Error('Relay overflow');
            delivery=delivery.then(()=>{for(const item of data.messages){this.consume(item);ws.send(JSON.stringify({type:'ack',id:String(++this.serial),message:item.id}));}}).catch(()=>ws.close()).finally(()=>queued--);
          }
        }catch{ws.close();}
      };
      ws.onclose=event=>{
        clearTimeout(timer);if(this.socket!==ws)return;this.socket=null;this.ready=null;
        const error=new Error(event.code===4001?'Access revoked. Connect this corpora again.':event.code===4002?'This connection is open in another window.':'This device is unreachable. Try again later.');error.revoked=event.code===4001;
        if(event.code===4001||event.code===4002)this.blocked=error;
        if(error.revoked&&this.session.corpora)RemoteSession.clear(RemoteSession.key(this.session)).catch(()=>{});
        reject(error);for(const p of this.pending.values())p.reject(error);this.pending.clear();
      };
      ws.onerror=()=>ws.close();
    });return this.ready;
  }
  consume(item){
    const {nacl}=RemoteVendor,s=this.session;
    if(item.frame.sender!==s.desktop)return;
    const plain=nacl.box.open(RemoteTransport.bytes(item.frame.ciphertext),RemoteTransport.bytes(item.frame.nonce,24),RemoteTransport.bytes(s.desktop,32),s.keys.secretKey);
    if(!plain)return;
    const message=JSON.parse(new TextDecoder().decode(plain));
    if(message.v!=='sapiens-remote-box-v1'||message.room!==s.room||message.direction!=='desktop-to-phone'||message.kind!=='response'||!Number.isFinite(message.expires)||message.expires<=Date.now()/1000||message.expires>Date.now()/1000+86400)return;
    const pending=this.pending.get(message.id);if(!pending)return;this.pending.delete(message.id);
    message.result?.error?pending.reject(new Error(message.result.error)):pending.resolve(message.result);
  }
  async request(payload,timeout=15000){
    await this.connect();
    if(this.pending.size>=128)throw new Error('Connection busy. Try again shortly.');
    const s=this.session,{nacl}=RemoteVendor,id=crypto.randomUUID(),nonce=nacl.randomBytes(24);
    const raw=new TextEncoder().encode(JSON.stringify({v:'sapiens-remote-box-v1',room:s.room,direction:'phone-to-desktop',corpora_id:s.corpora?.id,connection_id:this.connectionId,device_info:RemoteCode.deviceInfo(),id,expires:Date.now()/1000+timeout/1000,...payload}));
    if(raw.length>16000000)throw new Error('Request is too large.');
    const frame={sender:RemoteTransport.b64(s.keys.publicKey),nonce:RemoteTransport.b64(nonce),ciphertext:RemoteTransport.b64(nacl.box(raw,nonce,RemoteTransport.bytes(s.desktop,32),s.keys.secretKey))};
    return new Promise((resolve,reject)=>{
      const timer=setTimeout(()=>{this.pending.delete(id);reject(new Error('This device is unreachable. Try again later.'));},timeout);
      this.pending.set(id,{resolve:value=>{clearTimeout(timer);resolve(value);},reject:error=>{clearTimeout(timer);reject(error);}});
      try{this.socket.send(JSON.stringify({type:'send',id:String(++this.serial),frame}));}catch(error){this.pending.get(id).reject(error);this.pending.delete(id);}
    });
  }
  async authenticate(pair=false){
    const result=await this.request(pair?{kind:'pair',secret:this.session.secret}:{kind:'request',op:'resume'},pair?180000:15000);
    const corpora=result.corpora;
    if(!result.paired||!corpora||typeof corpora.name!=='string'||corpora.name.length>200||!/^([0-9a-f]{8}-)([0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(corpora.id)||(this.session.corpora&&corpora.id!==this.session.corpora.id))throw new Error('Corpora identity changed. Connect again.');
    this.session.corpora=corpora;delete this.session.secret;await RemoteSession.save(this.session);return corpora;
  }
  async fetch(path,options={}){
    if(options.signal?.aborted)throw new DOMException('Aborted','AbortError');
    const result=await this.request({kind:'request',op:'api',method:options.method||'GET',path,data:options.body?JSON.parse(options.body):undefined});
    if(options.signal?.aborted)throw new DOMException('Aborted','AbortError');
    if(!Number.isInteger(result.status))throw new Error('Invalid host response');
    return new Response(result.binary?RemoteTransport.bytes(result.body):JSON.stringify(result.body),{status:result.status,headers:{'Content-Type':result.mime}});
  }
  close(){this.generation++;this.socket?.close();this.socket=null;this.ready=null;for(const p of this.pending.values())p.reject(new Error('Connection closed'));this.pending.clear();}
};
