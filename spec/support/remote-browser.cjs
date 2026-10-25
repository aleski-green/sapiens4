// Current transport and QR capture, with deterministic browser/platform boundaries.
const fs=require('node:fs'),path=require('node:path'),{webcrypto}=require('node:crypto');
const {JSDOM}=require('../../libs4/node_modules/jsdom'),{IDBFactory}=require('../../libs4/node_modules/fake-indexeddb');
const nacl=require('../../libs4/node_modules/tweetnacl'),QRCode=require('../../libs4/node_modules/qrcode');
const sleep=()=>new Promise(r=>setTimeout(r,0)),b64=b=>Buffer.from(b).toString('base64'),bytes=b=>new Uint8Array(Buffer.from(b,'base64'));
const dom=new JSDOM('<button id="scan-qr"></button><input id="qr-file" type="file"><div id="scanner" hidden><video id="qr-camera"></video><button id="stop-scan"></button></div>',{url:'https://relay.example',runScripts:'outside-only'}),w=dom.window,d=w.document;
const desktop=nacl.box.keyPair(),corpora={id:'12345678-1234-4234-8234-123456789abc',name:'Studio'};
const invitation={v:'sapiens-remote-box-v1',relay:w.location.origin,room:'r'.repeat(43),token:'t'.repeat(43),secret:'s'.repeat(43),desktop:b64(desktop.publicKey),expires:Math.floor(Date.now()/1000)+3600};
Object.defineProperty(w,'crypto',{value:webcrypto});Object.defineProperty(w,'isSecureContext',{value:true});
w.indexedDB=new IDBFactory();w.Uint8Array=Uint8Array;w.TextEncoder=TextEncoder;w.TextDecoder=TextDecoder;w.Response=Response;
w.eval(fs.readFileSync(path.join(__dirname,'../../libs4/web/remote-vendor.js'),'utf8'));
for(const name of ['remote-code','remote-session','remote-transport','remote-onboarding'])w.eval(fs.readFileSync(path.join(__dirname,'../../web/features',name+'.js'),'utf8'));
function pixels(text){
 const qr=QRCode.create(text,{errorCorrectionLevel:'M'}),scale=5,margin=4,size=(qr.modules.size+margin*2)*scale,data=new Uint8ClampedArray(size*size*4).fill(255);
 for(let y=0;y<qr.modules.size;y++)for(let x=0;x<qr.modules.size;x++)if(qr.modules.get(y,x))for(let dy=0;dy<scale;dy++)for(let dx=0;dx<scale;dx++){const i=(((y+margin)*scale+dy)*size+(x+margin)*scale+dx)*4;data[i]=data[i+1]=data[i+2]=0;}
 return {data,width:size,height:size};
}
(async()=>{
 const out={};
 if(process.argv[2]==='notes'){
  let requested=[],released=[];
  w.presentMemo=()=>{};w.SapiensConnections={fetch:async uri=>{requested.push(uri);return new Response(new Uint8Array([1,2,3]),{headers:{'Content-Type':'image/png'}});}};
  w.URL.createObjectURL=()=> 'blob:note';w.URL.revokeObjectURL=url=>released.push(url);
  w.eval(fs.readFileSync(path.join(__dirname,'../../web/shell/ui.js'),'utf8'));
  w.eval(fs.readFileSync(path.join(__dirname,'../../web/features/notes.js'),'utf8'));
  const root=w.notesWiki('<section id="about"></section><section id="map"></section><section id="content"><img src="photo.png"></section>','/Notes.html','chief');
  await sleep();const image=root.querySelector('img');out.src=image.src;image.dispatchEvent(new w.Event('load'));out.requested=requested;out.released=released;
 }else if(process.argv[2]==='scanner'){
  let message='',paired=[],stops=0,resolveCamera,revoked=0;
  const flow=w.RemoteOnboarding.mount(value=>paired.push(value),value=>message=value);
  d.querySelector('#scan-qr').click();await sleep();out.unavailable=message;
  Object.defineProperty(w.navigator,'mediaDevices',{value:{getUserMedia:()=>new Promise(resolve=>resolveCamera=resolve)}});
  const stream=()=>({getTracks:()=>[{stop:()=>stops++}]});
  d.querySelector('#scan-qr').click();flow.stop();resolveCamera(stream());await sleep();out.cancelledStops=stops;
  let image=pixels(w.RemoteCode.link(invitation));
  w.HTMLCanvasElement.prototype.getContext=()=>({drawImage(){},getImageData(){return image;}});
  w.URL.createObjectURL=()=> 'blob:qr';w.URL.revokeObjectURL=()=>revoked++;
  w.Image=class{constructor(){this.naturalWidth=image.width;this.naturalHeight=image.height;}async decode(){}};
  const file=d.querySelector('#qr-file');Object.defineProperty(file,'files',{value:[{size:1000}],configurable:true});file.dispatchEvent(new w.Event('change'));await sleep();out.upload=paired[0];out.urlsRevoked=revoked;
  const video=d.querySelector('video');Object.defineProperties(video,{readyState:{value:2},videoWidth:{value:image.width},videoHeight:{value:image.height}});video.play=async()=>{};
  d.querySelector('#scan-qr').click();resolveCamera(stream());await sleep();await sleep();out.camera=paired[1];out.cameraStopped=video.srcObject===null&&d.querySelector('#scanner').hidden;
  Object.defineProperty(file,'files',{value:[{size:11*1024*1024}],configurable:true});file.dispatchEvent(new w.Event('change'));await sleep();out.largeImage=message;
  w.RemoteVendor={...w.RemoteVendor,jsQR:()=>({data:'x'.repeat(4097)})};d.querySelector('#scan-qr').click();resolveCamera(stream());await sleep();out.largePayload=message;out.pairs=paired.length;
  d.querySelector('#scan-qr').click();flow.dispose();resolveCamera(stream());await sleep();out.disposedStops=stops;
  out.expected=invitation;
 }else{
  let socket,posted=[],connections=0,lookup=true;
  w.fetch=async()=>({ok:lookup,json:async()=>({desktop:lookup?invitation.desktop:'replaced',expires:invitation.expires})});
  w.WebSocket=class{
   constructor(){socket=this;connections++;setTimeout(()=>this.onopen(),0);}
   send(raw){const data=JSON.parse(raw);if(data.type==='auth'){this.onmessage({data:JSON.stringify({type:'ready'})});return;}if(data.type==='send'){const frame=data.frame,plain=nacl.box.open(bytes(frame.ciphertext),bytes(frame.nonce),bytes(frame.sender),desktop.secretKey);posted.push({frame,message:JSON.parse(Buffer.from(plain).toString())});}}
   close(){this.onclose?.({code:1000});}
  };
  const errors=[];
  for(const data of [{...invitation,expires:0},{...invitation,expires:Date.now()/1000+4*86400},{...invitation,relay:'https://other.example'},{...invitation,desktop:'bad'}])try{await w.RemoteTransport.invitation(data);}catch(e){errors.push(e.message);}
  lookup=false;try{await w.RemoteTransport.invitation({...invitation,public_id:'sapi4_abc123qwe'});}catch(e){errors.push(e.message);}lookup=true;
  out.invalid={errors:errors.length,connections};
  out.decodeErrors=['s4.invalid','x'.repeat(4097),'https://other.example/#'+w.RemoteCode.encode(invitation)].map(value=>{try{w.RemoteCode.decode(value);return false;}catch{return true;}});
  out.confirmation=await w.RemoteCode.confirmation(b64(Uint8Array.from({length:32},(_,i)=>i)),b64(Uint8Array.from({length:32},(_,i)=>i+32)),'room-test');
  const client=await w.RemoteTransport.invitation(invitation);
  function reply(result,patch={}){
   const last=posted.at(-1),nonce=nacl.randomBytes(24),message={v:invitation.v,room:invitation.room,direction:'desktop-to-phone',kind:'response',expires:Date.now()/1000+120,id:last.message.id,result,...patch};
   socket.onmessage({data:JSON.stringify({type:'messages',messages:[{id:posted.length,frame:{sender:invitation.desktop,nonce:b64(nonce),ciphertext:b64(nacl.box(Buffer.from(JSON.stringify(message)),nonce,bytes(last.frame.sender),desktop.secretKey))}}]})});
  }
  const pairing=client.authenticate(true);while(!posted.length)await sleep();out.unapproved=(await w.RemoteSession.list()).length;
  reply({paired:true,corpora});await pairing;
  const saved=(await w.RemoteSession.list())[0];out.saved={secret:saved.secret??null,corpora:saved.corpora.id,sameKey:b64(saved.keys.publicKey)===posted[0].frame.sender};
  const sending=client.fetch('/api/agents/chief/messages',{method:'POST',body:JSON.stringify({text:'Private command'})});await sleep();out.encrypted=!JSON.stringify(posted.at(-1).frame).includes('Private command');out.message=posted.at(-1).message.data;
  reply({status:202,mime:'application/json',body:{id:'turn'}});out.sent=(await sending).status;
  const image=client.fetch('/api/agents/chief/notes?image=a.png');await sleep();reply({status:200,mime:'image/png',binary:true,body:b64([1,2,3])});out.image=Array.from(new Uint8Array(await (await image).arrayBuffer()));
  out.badResponses=[];
  for(const result of [{status:999},{status:200,binary:true,body:'!'}]){const call=client.fetch('/api/state').catch(e=>e.message);await sleep();reply(result);out.badResponses.push(typeof await call==='string');}
  const resumed=client.authenticate().catch(e=>e.message);await sleep();out.resume={op:posted.at(-1).message.op,key:posted.at(-1).frame.sender===b64(saved.keys.publicKey)};
  reply({paired:true,corpora:{...corpora,id:'87654321-1234-4234-8234-123456789abc'}});out.identityError=await resumed;out.identityKept=(await w.RemoteSession.list())[0].corpora.id;
  const waiting=client.fetch('/api/state').catch(e=>e.message);await sleep();const count=posted.length;socket.close();out.interrupted=await waiting;await sleep();out.replayed=posted.length!==count;
  try{new w.RemoteTransport({...saved,keys:{...saved.keys,secretKey:new Uint8Array(32)}});}catch(e){out.corrupt=e.message;}
  for(let i=0;i<10&&(await w.RemoteSession.list()).length;i++)await sleep();out.corruptRemaining=(await w.RemoteSession.list()).length;
  out.browserStorage=w.localStorage.length+w.sessionStorage.length;client.close();
 }
 console.log(JSON.stringify(out));dom.window.close();
})().catch(error=>{console.error(error);dom.window.close();process.exitCode=1;});
