const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const {TextEncoder,TextDecoder}=require('node:util');
const {webcrypto}=require('node:crypto');
const {JSDOM}=require('jsdom');
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
  const desktop=nacl.box.keyPair(),now=Date.now()/1000;
  const invitation={v:'sapiens-remote-box-v1',relay:'https://relay.example',room:'r'.repeat(43),
    token:'t'.repeat(43),secret:'s'.repeat(43),desktop:b64(desktop.publicKey),expires:now+120};
  const pixels=qrPixels(JSON.stringify(invitation));
  assert.deepEqual(JSON.parse(jsQR(pixels.data,pixels.width,pixels.height).data),invitation);
  const dom=new JSDOM(fs.readFileSync(path.join(root,'web/shell/remote.html'),'utf8'),
    {url:invitation.relay,runScripts:'outside-only'});
  const w=dom.window;
  const intervals=[],posted=[],inbox=[];
  w.Uint8Array=Uint8Array;w.TextEncoder=TextEncoder;w.TextDecoder=TextDecoder;
  Object.defineProperty(w,'crypto',{value:webcrypto});Object.defineProperty(w,'isSecureContext',{value:true});
  w.RemoteVendor={nacl,jsQR,QRCode};
  w.setInterval=fn=>{intervals.push(fn);return intervals.length;};
  w.URL.createObjectURL=()=> 'blob:test';w.URL.revokeObjectURL=()=>{};
  w.Image=class {constructor(){this.naturalWidth=pixels.width;this.naturalHeight=pixels.height;}async decode(){}};
  w.HTMLCanvasElement.prototype.getContext=()=>({drawImage(){},getImageData(){return pixels;}});
  w.fetch=async(url,options={})=>{
    if(options.method==='POST') {
      const frame=JSON.parse(options.body);
      assert.equal(Object.keys(frame).sort().join(','),'ciphertext,nonce,sender');
      const raw=nacl.box.open(bytes(frame.ciphertext),bytes(frame.nonce),bytes(frame.sender),desktop.secretKey);
      assert.ok(raw);posted.push({frame,message:JSON.parse(Buffer.from(raw).toString())});
      return {ok:true,json:async()=>({id:posted.length})};
    }
    if(options.method==='DELETE') {
      const id=Number(url.split('/').at(-1)),index=inbox.findIndex(m=>m.id===id);if(index>=0)inbox.splice(index,1);
      return {ok:true,json:async()=>({deleted:true})};
    }
    return {ok:true,json:async()=>({messages:[...inbox]})};
  };
  w.eval(fs.readFileSync(path.join(root,'web/features/remote.js'),'utf8'));
  const file=w.document.getElementById('qr-file');
  Object.defineProperty(file,'files',{value:[{size:1000}]});
  file.dispatchEvent(new w.Event('change'));
  for(let i=0;i<20&&!posted.length;i++)await sleep();
  assert.ok(posted.length,w.document.getElementById('status').textContent);
  assert.equal(posted[0].message.secret,invitation.secret);
  assert.equal(posted[0].message.kind,'pair');
  assert.equal(w.document.getElementById('verify-panel').hidden,false);
  assert.equal(w.document.getElementById('chat-panel').hidden,true);
  const phone=bytes(posted[0].frame.sender);
  function reply(id,result,wireId=1) {
    const nonce=nacl.randomBytes(24),message={v:invitation.v,room:invitation.room,direction:'desktop-to-phone',
      id,kind:'response',expires:Date.now()/1000+120,result};
    inbox.push({id:wireId,frame:{sender:invitation.desktop,nonce:b64(nonce),ciphertext:b64(nacl.box(
      Buffer.from(JSON.stringify(message)),nonce,phone,desktop.secretKey))}});
  }
  reply(posted[0].message.id,{paired:true});
  await intervals[0]();
  assert.equal(w.document.getElementById('chat-panel').hidden,false);
  const state=posted.find(p=>p.message.op==='state');assert.ok(state);
  reply(state.message.id,{agents:[{id:'chief',name:'Chief'}],agent:'chief',updated:Date.now()/1000,
    turns:[{input:'<img src=x onerror="window.compromised=true">',output:'Reply from desktop',status:'done'}]},2);
  await intervals[0]();
  assert.match(w.document.getElementById('history').textContent,/<img/);
  assert.equal(w.document.querySelector('#history img'),null);
  assert.equal(w.compromised,undefined);
  w.document.getElementById('message').value='A private command';
  w.document.getElementById('chat-form').dispatchEvent(new w.Event('submit',{cancelable:true}));
  await sleep();
  const chat=posted.find(p=>p.message.op==='chat');assert.ok(chat);
  assert.equal(chat.message.text,'A private command');
  assert.ok(!JSON.stringify(chat.frame).includes('A private command'));
  assert.equal(w.document.getElementById('send').disabled,true);
  reply(chat.message.id,{submitted:{id:'turn-1'}},3);await intervals[0]();
  assert.equal(w.document.getElementById('send').disabled,false);
  assert.equal(w.localStorage.length,0);assert.equal(w.sessionStorage.length,0);
  dom.window.close();
  console.log('Remote QR upload, authenticated chat flow, safe rendering, and no persistent browser secrets passed.');
})().catch(error=>{console.error(error);process.exitCode=1;});
