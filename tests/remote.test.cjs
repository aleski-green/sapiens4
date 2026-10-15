const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {TextEncoder,TextDecoder}=require('node:util');
const {webcrypto}=require('node:crypto');
const {JSDOM}=require('jsdom');
const {IDBFactory}=require('fake-indexeddb');
const nacl=require('tweetnacl'), jsQR=require('jsqr'), QRCode=require('qrcode');
const root=path.join(__dirname,'..');
const b64=b=>Buffer.from(b).toString('base64');
const bytes=b=>new Uint8Array(Buffer.from(b,'base64'));
const sleep=()=>new Promise(resolve=>setTimeout(resolve,0));

// Decode a real QR at the actual pairing payload size without BarcodeDetector/camera APIs.
function qrPixels(text) {
  const qr=QRCode.create(text,{errorCorrectionLevel:'M'}),scale=5,margin=4;
  const size=(qr.modules.size+margin*2)*scale,data=new Uint8ClampedArray(size*size*4).fill(255);
  for(let y=0;y<qr.modules.size;y++)for(let x=0;x<qr.modules.size;x++)if(qr.modules.get(y,x)){
    for(let dy=0;dy<scale;dy++)for(let dx=0;dx<scale;dx++){
      const i=(((y+margin)*scale+dy)*size+(x+margin)*scale+dx)*4;
      data[i]=data[i+1]=data[i+2]=0;
    }
  }
  return {data,width:size,height:size};
}
(async()=>{
  const corpora={id:'12345678-1234-4234-8234-123456789abc',name:'CORPORA · Chief'};
  const desktop=nacl.box.keyPair(),now=Date.now()/1000;
  const invitation={v:'sapiens-remote-box-v1',relay:'https://relay.example',room:'r'.repeat(43),
    token:'t'.repeat(43),secret:'s'.repeat(43),desktop:b64(desktop.publicKey),expires:now+259200,public_id:'sapi4_abc123qwe'};
  const pixels=qrPixels(JSON.stringify(invitation));
  assert.deepEqual(JSON.parse(jsQR(pixels.data,pixels.width,pixels.height).data),invitation);
  const deviceStorage=new IDBFactory();
  let dom,w;
  const intervals=[],posted=[];let offline=false;
  let activeSocket, connections=0;
  function initialize(url=invitation.relay) {
  intervals.length=0;
  dom=new JSDOM(fs.readFileSync(path.join(root,'web/shell/remote.html'),'utf8'),
    {url,runScripts:'outside-only'});
  w=dom.window;
  w.indexedDB=deviceStorage;
  w.Uint8Array=Uint8Array;w.TextEncoder=TextEncoder;w.TextDecoder=TextDecoder;
  Object.defineProperty(w,'crypto',{value:webcrypto});Object.defineProperty(w,'isSecureContext',{value:true});
  w.RemoteVendor={nacl,jsQR,QRCode};w.Response=Response;
  w.setInterval=fn=>{intervals.push(fn);return intervals.length;};
  w.URL.createObjectURL=()=> 'blob:test';w.URL.revokeObjectURL=()=>{};
  w.Image=class {constructor(){this.naturalWidth=pixels.width;this.naturalHeight=pixels.height;}async decode(){}};
  w.HTMLCanvasElement.prototype.getContext=()=>({drawImage(){},getImageData(){return pixels;}});
  class FakeSocket {
    static OPEN=1;
    constructor(url) {
      assert.equal(url,'wss://relay.example/api/socket');
      activeSocket=this;connections++;this.readyState=1;this.bufferedAmount=0;
      setTimeout(()=>this.onopen(),0);
    }
    deliver(value) { this.onmessage({data:JSON.stringify(value)}); }
    send(raw) {
      if(offline) throw new Error('Offline');
      const data=JSON.parse(raw);
      if(data.type==='auth') {
        assert.equal(data.token,invitation.token);assert.equal(data.room,invitation.room);
        setTimeout(()=>this.deliver({type:'ready'}),0);return;
      }
      if(data.type==='send') {
        const frame=data.frame;
        assert.equal(Object.keys(frame).sort().join(','),'ciphertext,nonce,sender');
        const plain=nacl.box.open(bytes(frame.ciphertext),bytes(frame.nonce),bytes(frame.sender),desktop.secretKey);
        assert.ok(plain);posted.push({frame,message:JSON.parse(Buffer.from(plain).toString())});
      } else assert.equal(data.type,'ack');
      this.deliver({type:'result',id:data.id,result:{stored:true}});
    }
    close() {this.readyState=3;this.onclose?.({code:1000});}
  }
  w.WebSocket=FakeSocket;
  w.fetch=async(url)=>{
    if(url==='/api/corpora/'+invitation.public_id) return {ok:true,json:async()=>({public_id:invitation.public_id,desktop:invitation.desktop,expires:invitation.expires})};
    assert.equal(url,'/workspace/', 'Only static assets may use fetch');
    return {ok:true,text:async()=>fs.readFileSync(path.join(root,'web/shell/index.html'),'utf8')};
  };
  w.eval(fs.readFileSync(path.join(root,'web/features/remote-code.js'),'utf8'));
  w.eval(fs.readFileSync(path.join(root,'web/features/remote-session.js'),'utf8'));
  w.eval(fs.readFileSync(path.join(root,'web/features/remote-install.js'),'utf8'));
  w.eval(fs.readFileSync(path.join(root,'web/features/remote-onboarding.js'),'utf8'));
  w.eval(fs.readFileSync(path.join(root,'web/features/remote.js'),'utf8'));
  }
  initialize();
  for(let i=0;i<20&&w.document.getElementById('find-corpora').disabled;i++)await sleep();
  for(const invalid of ['s4.invalid','x'.repeat(4097)]) assert.throws(()=>w.RemoteCode.decode(invalid));
  w.document.getElementById('corpora-address').value=invitation.public_id;
  w.document.getElementById('corpora-form').dispatchEvent(new w.Event('submit',{cancelable:true}));
  await sleep();assert.equal(w.document.getElementById('qr-step').hidden,false);
  for(const invalid of [w.RemoteCode.encode({...invitation,expires:now-1}),
      w.RemoteCode.encode({...invitation,expires:now+4*86400}),
      w.RemoteCode.encode({...invitation,relay:'https://other.example'})]) {
    w.location.hash=invalid;
    for(let i=0;i<5;i++)await sleep();
    assert.equal(connections,0,'Expired, overlong and cross-origin invitations must not connect');
  }
  const file=w.document.getElementById('qr-file');
  Object.defineProperty(file,'files',{value:[{size:1000}]});
  if(process.argv.includes('--hash')) {
    w.location.hash=w.RemoteCode.encode(invitation);
    for(let i=0;i<20&&w.location.hash;i++)await sleep();
    assert.equal(w.location.hash,'','Same-page invitations must be consumed and removed');
  } else if(process.argv.includes('--link')) {
    const link=w.RemoteCode.link(invitation);
    const linkPixels=qrPixels(link);
    assert.equal(jsQR(linkPixels.data,linkPixels.width,linkPixels.height).data,link);
    dom.window.close();initialize(link);
    assert.equal(w.location.hash,'','Invitation must be removed before networking');
  } else file.dispatchEvent(new w.Event('change'));
  for(let i=0;i<20&&!posted.length;i++)await sleep();
  assert.ok(posted.length,w.document.getElementById('status').textContent);
  assert.equal(posted[0].message.secret,invitation.secret);
  assert.equal(posted[0].message.kind,'pair');
  assert.ok(posted[0].message.expires > now+259190, 'Pairing request must remain valid for three days');
  assert.equal(w.document.getElementById('verify-panel').hidden,false);
  assert.equal(w.document.getElementById('chat-panel'),null);
  const phone=bytes(posted[0].frame.sender);
  assert.equal(await w.RemoteCode.confirmation(b64(Uint8Array.from({length:32},(_,i)=>i)),
    b64(Uint8Array.from({length:32},(_,i)=>i+32)), 'room-test'), 'CwnX · eCGC');
  const verification=w.document.getElementById('confirmation-code').textContent;
  assert.equal(verification,await w.RemoteCode.confirmation(invitation.desktop,b64(phone),invitation.room));
  assert.match(verification,/^[A-HJKMNP-Za-hjkmnp-z]{4} · [A-HJKMNP-Za-hjkmnp-z]{4}$/);
  assert.notEqual(verification,await w.RemoteCode.confirmation(invitation.desktop,b64(phone),'other-room'));

  assert.equal(await w.RemoteSession.read(),undefined,'An unapproved phone must not be remembered');
  function reply(id,result,wireId=1) {
    const nonce=nacl.randomBytes(24),message={v:invitation.v,room:invitation.room,direction:'desktop-to-phone',
      id,kind:'response',expires:Date.now()/1000+120,result};
    activeSocket.deliver({type:'messages',messages:[{id:wireId,frame:{sender:invitation.desktop,nonce:b64(nonce),ciphertext:b64(nacl.box(
      Buffer.from(JSON.stringify(message)),nonce,phone,desktop.secretKey))}}]});
  }
  reply(posted[0].message.id,{paired:true,corpora});
  await intervals[0]();await sleep();
  for(let i=0;i<20&&!w.sapiensRemote;i++)await sleep();
  assert.ok(w.document.querySelector('.sapi-workspace .app'));
  assert.ok(w.document.querySelector('#agent-list'));
  assert.ok(w.document.querySelector('#workspace-panel'));
  assert.ok(w.document.querySelector('button[data-panel="work"]'));
  assert.ok(w.document.querySelector('button[data-scope="groups"]'));
  assert.equal(w.document.querySelector('a[href="/remote/"]'),null);
  assert.ok(w.document.querySelector('script[src="/workspace/app.js"]'));
  const styles=[...w.document.querySelectorAll('link[rel="stylesheet"]')].map(link=>link.href);
  assert.equal(styles.length,new Set(styles).size,'Mounting must reuse the shared stylesheets');
  reply(posted[0].message.id,{paired:true,corpora});await sleep();await sleep();
  assert.equal(w.document.querySelectorAll('script[src="/workspace/app.js"]').length,1,
    'Replayed approval must not mount the workspace twice');
  const reading=w.sapiensRemote.fetch('/api/state');
  await sleep();
  const state=posted.find(p=>p.message.path==='/api/state');assert.ok(state);
  reply(state.message.id,{status:200,mime:'application/json',body:{agents:[{id:'chief',name:'Chief'}],
    turns:[{input:'Private full desktop snapshot',output:'Reply from desktop',status:'done'}]}},2);
  await intervals[0]();await sleep();
  assert.equal((await (await reading).json()).turns[0].input,'Private full desktop snapshot');
  const sending=w.sapiensRemote.fetch('/api/agents/chief/messages',{method:'POST',body:JSON.stringify({text:'A private command'})});
  await sleep();
  const chat=posted.find(p=>p.message.path==='/api/agents/chief/messages');assert.ok(chat);
  assert.equal(chat.message.data.text,'A private command');
  assert.ok(!JSON.stringify(chat.frame).includes('A private command'));
  reply(chat.message.id,{status:202,mime:'application/json',body:{id:'turn-1'}},3);await intervals[0]();await sleep();
  assert.equal((await sending).status,202);
  const image=w.sapiensRemote.fetch('/api/agents/chief/notes?image=test.png');await sleep();
  const imageRequest=posted.at(-1);
  reply(imageRequest.message.id,{status:200,mime:'image/png',body:b64(Buffer.from([1,2,3])),binary:true},4);
  await intervals[0]();await sleep();assert.deepEqual(new Uint8Array(await (await image).arrayBuffer()),new Uint8Array([1,2,3]));
  for(const result of [{status:200,mime:'image/png',body:'!',binary:true},{status:999,body:{}}]) {
    const invalid=w.sapiensRemote.fetch('/api/state');
    const rejected=assert.rejects(invalid);
    await sleep();reply(posted.at(-1).message.id,result,5);await rejected;await sleep();
  }
  assert.equal(connections,1);
  const count=posted.length;await intervals[0]();await sleep();assert.equal(posted.length,count,'Idle timer must not poll');
  const unanswered=w.sapiensRemote.fetch('/api/state').catch(error=>error.message);await sleep();
  const beforeReconnect=posted.at(-1);
  activeSocket.close();
  await new Promise(resolve=>setTimeout(resolve,1600));
  assert.equal(connections,2);
  assert.deepEqual(posted.at(-1).frame,beforeReconnect.frame,'Reconnect must reuse ciphertext and request ID');
  offline=true;const future=Date.now()+121000;w.Date.now=()=>future;
  await intervals[0]();await sleep();assert.match(await unanswered,/did not confirm/);
  assert.equal(w.localStorage.length,0);assert.equal(w.sessionStorage.length,0);
  const stored=await w.RemoteSession.read();
  assert.equal(stored.room,invitation.room);
  assert.equal(stored.corpora.id,corpora.id);
  assert.equal(stored.secret,undefined,'One-use invitation secret must not be remembered');
  assert.equal(b64(stored.keys.publicKey),b64(phone));
  const previousCount=posted.length;
  dom.window.close();offline=false;initialize();
  for(let i=0;i<30&&posted.length===previousCount;i++)await sleep();
  const resumed=posted.at(-1);
  assert.equal(resumed.message.corpora_id,corpora.id);
  assert.equal(resumed.message.op,'resume','Reload must resume instead of re-pairing');
  assert.equal(resumed.frame.sender,b64(phone),'Reload must reuse the approved phone key');
  assert.equal(w.sapiensRemote,undefined,'Do not open the workspace before the desktop authenticates resume');
  reply(resumed.message.id,{paired:true,corpora},5);
  for(let i=0;i<30&&!w.sapiensRemote;i++)await sleep();
  assert.ok(w.sapiensRemote,'Approved device reconnects without a new QR or approval');
  const beforeHandoff=connections;
  activeSocket.onclose({code:4002});
  await new Promise(resolve=>setTimeout(resolve,1600));
  assert.equal(connections,beforeHandoff,'Replaced tabs must not fight for the socket');
  assert.ok(await w.RemoteSession.read(),'Tab handoff must preserve trusted credentials');
  Object.defineProperty(w.document,'hidden',{value:false,configurable:true});
  w.dispatchEvent(new w.Event('online'));
  for(let i=0;i<20&&connections===beforeHandoff;i++)await sleep();
  assert.equal(connections,beforeHandoff+1,'The foreground tab can reconnect');
  await sleep();await sleep();
  activeSocket.onclose({code:4001});
  for(let i=0;i<20&&(await w.RemoteSession.read());i++)await sleep();
  assert.equal(await w.RemoteSession.read(),undefined,'Revocation forgets persistent device credentials');
  dom.window.close();
  const beforeForgotten=connections;initialize();
  for(let i=0;i<20&&w.document.getElementById('find-corpora').disabled;i++)await sleep();
  assert.equal(connections,beforeForgotten,'A revoked device must not reconnect on reload');
  await w.RemoteSession.save({...stored,keys:{publicKey:stored.keys.publicKey,secretKey:new Uint8Array(32)}});
  dom.window.close();initialize();
  for(let i=0;i<30&&(await w.RemoteSession.read());i++)await sleep();
  assert.equal(connections,beforeForgotten,'Corrupted saved keys must not authenticate');
  assert.equal(await w.RemoteSession.read(),undefined,'Corrupt device state must allow fresh pairing');
  await w.RemoteSession.save(stored);
  dom.window.close();
  const beforeMismatch=posted.length;initialize();
  for(let i=0;i<30&&posted.length===beforeMismatch;i++)await sleep();
  reply(posted.at(-1).message.id,{paired:true,corpora:{...corpora,id:'87654321-1234-4234-8234-123456789abc'}},6);
  for(let i=0;i<20;i++)await sleep();
  assert.equal(w.sapiensRemote,undefined,'A different CORPORA must never open under existing device trust');
  assert.match(w.document.getElementById('status').textContent,/CORPORA identity changed/);
  assert.equal((await w.RemoteSession.read()).corpora.id,corpora.id,'Mismatch must not replace the saved identity');
  dom.window.close();
  console.log('Remote QR upload, shared CORPORA shell, encrypted API and image transport, trusted-device reload, and revocation passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});
