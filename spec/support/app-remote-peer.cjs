// Exercise the shipped browser transport against the real relay and host.
const {JSDOM}=require('../../tests/node_modules/jsdom');
const {IDBFactory}=require('../../tests/node_modules/fake-indexeddb');
const WebSocket=require('../../tests/node_modules/ws');
const {webcrypto}=require('node:crypto');
const fs=require('node:fs'),path=require('node:path'),readline=require('node:readline');
let dom,w,client,otherClient,progress;
async function run(data){
 if(data.op==='pair'){
  dom=new JSDOM('',{url:data.invitation.relay,runScripts:'outside-only'});w=dom.window;
  Object.defineProperty(w.navigator,'userAgent',{value:'Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X)'});Object.defineProperty(w.navigator,'standalone',{value:true});
  Object.defineProperty(w,'crypto',{value:webcrypto});Object.defineProperty(w,'isSecureContext',{value:true});
  w.TextEncoder=TextEncoder;w.TextDecoder=TextDecoder;w.Uint8Array=Uint8Array;w.Response=Response;w.indexedDB=new IDBFactory();
  w.eval(fs.readFileSync(path.join(__dirname,'../../libs4/web/remote-vendor.js'),'utf8'));
  w.fetch=(url,options)=>fetch(new URL(url,data.invitation.relay),options);
  w.WebSocket=class extends WebSocket{constructor(url){super(url,{origin:data.invitation.relay});}};
  for(const name of ['remote-code','remote-session','remote-transport'])w.eval(fs.readFileSync(path.join(__dirname,'../../web/features',name+'.js'),'utf8'));
  client=await w.RemoteTransport.invitation(data.invitation);
  progress={state:'waiting',code:await w.RemoteCode.confirmation(data.invitation.desktop,w.RemoteTransport.b64(client.session.keys.publicKey),data.invitation.room)};
  client.authenticate(true).then(corpora=>{progress={state:'approved',corpora};},error=>{progress={state:'failed',error:error.message};});
  return progress;
 }
 if(data.op==='status')return progress;
 if(data.op==='saved'){const saved=await w.RemoteSession.list();return {count:saved.length,secrets:saved.some(s=>'secret' in s),browserStorage:w.localStorage.length+w.sessionStorage.length};}
 if(data.op==='request'||data.op==='other-request'){
  try{const response=await (data.op==='request'?client:otherClient).fetch(data.path,{method:data.method||'GET',...(data.body?{body:JSON.stringify(data.body)}:{})});return {status:response.status,body:await response.json()};}
  catch(error){return {error:error.message,revoked:!!error.revoked};}
 }
 if(data.op==='restore'){
  client.close();const sessions=await w.RemoteSession.list();client=new w.RemoteTransport(sessions[0]);return client.authenticate();
 }
 if(data.op==='open-window'){
  const sessions=await w.RemoteSession.list();otherClient=new w.RemoteTransport(sessions[0]);return otherClient.authenticate();
 }
 if(data.op==='close'){client?.close();return true;}
 throw new Error('Unknown operation');
}
const input=readline.createInterface({input:process.stdin});let chain=Promise.resolve();
input.on('line',line=>{chain=chain.then(async()=>{try{console.log(JSON.stringify({value:await run(JSON.parse(line))}));}catch(error){console.log(JSON.stringify({error:error.message}));}});});
input.on('close',()=>{client?.close();otherClient?.close();dom?.window.close();});
