// Browser probe: RSpec owns the assertions; this reports rendered behavior.
const fs=require('node:fs'),path=require('node:path');
const {JSDOM}=require('../../libs4/node_modules/jsdom');
const {IDBFactory}=require('../../libs4/node_modules/fake-indexeddb');
const {webcrypto}=require('node:crypto');
const root=path.resolve(__dirname,'../..'),scenario=process.argv[2];
const sleep=()=>new Promise(resolve=>setTimeout(resolve,0));
const template=fs.readFileSync(path.join(root,'prompts/corpora-settings-request.md'),'utf8');
const a={id:'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',name:'Home',device:'This Mac',scope:'Home tasks',status:'active',revision:1,chief_id:'chief-a',location:'Local',settings_template:template};
const b={id:'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',name:'Studio',device:'Mac mini',scope:'Studio tasks',status:'paused',revision:1,chief_id:'chief-b',location:'Remote',settings_template:template};
const c={...a,id:'cccccccc-cccc-4ccc-8ccc-cccccccccccc',name:'Second local',paired:true};
const snapshot=record=>({corpora:{...record},preferences:{},agents:[],groups:[],turns:[]});
(async()=>{
 const dom=new JSDOM(fs.readFileSync(path.join(root,'web/shell/index.html'),'utf8'),{url:'https://relay.example/workspace/',runScripts:'outside-only',pretendToBeVisual:true});
 const w=dom.window,d=w.document,calls=[],operations=new Map(),workers=[];let fail=false,credentialReads=0;let paired=true;
 Object.defineProperty(w,'crypto',{value:webcrypto});w.AbortSignal=AbortSignal;w.Response=Response;
 w.HTMLDialogElement.prototype.showModal=function(){this.open=true;};w.HTMLDialogElement.prototype.close=function(){this.open=false;};
 w.confirm=()=>true;
 w.matchMedia=()=>({matches:false,addEventListener(){},removeEventListener(){}});
 const evaluate=name=>w.eval(fs.readFileSync(path.join(root,'web/features',name+'.js'),'utf8'));
 if(scenario==='storage'){
   w.indexedDB=new IDBFactory();
   await new Promise((resolve,reject)=>{const req=w.indexedDB.open('sapiens-remote',1);req.onupgradeneeded=()=>req.result.createObjectStore('device');req.onsuccess=()=>{const tx=req.result.transaction('device','readwrite');tx.objectStore('device').put({version:1,relay:'https://relay.example',room:'old',keys:{secretKey:new Uint8Array(32)},corpora:a},'trusted');tx.oncomplete=()=>{req.result.close();resolve();};};req.onerror=reject;});
   evaluate('remote-session');const before=await w.RemoteSession.list();
   await w.RemoteSession.save({relay:'https://relay.example',room:'new',keys:{secretKey:new Uint8Array(32)},corpora:b});
   const after=await w.RemoteSession.list();await w.RemoteSession.clear(w.RemoteSession.key(after.find(item=>item.corpora.id===b.id)));
   console.log(JSON.stringify({before:before.map(s=>s.corpora.name),after:after.map(s=>s.corpora.name),remaining:(await w.RemoteSession.list()).map(s=>s.corpora.name)}));dom.window.close();return;
 }
 if(['mobile','android','linux'].includes(scenario)){
   d.body.setAttribute('data-remote','');
   Object.defineProperty(w.navigator,'userAgent',{value:scenario==='mobile'?'Mozilla/5.0 (iPhone)':scenario==='android'?'Mozilla/5.0 (Linux; Android 16)':'Mozilla/5.0 (X11; Linux x86_64)'});
   w.RemoteSession={list:async()=>{credentialReads++;return [];}};
   Object.defineProperty(w.navigator,'serviceWorker',{value:{register:async path=>{workers.push(path);}}});
 }
 w.fetch=async(url,options={})=>{
   calls.push({url,method:options.method||'GET',data:options.body&&JSON.parse(options.body)});
   if(url==='/api/host')return {ok:true,json:async()=>({local_available:true,corpora:scenario==='pairing-only-remote'?[b]:scenario==='pairing-rows'?[a,b,c]:[a,b]})};
   const record=String(url).includes(a.id)?a:String(url).includes(c.id)?c:b;
   if(String(url).endsWith('/api/remote/revoke')){paired=false;return {ok:true,json:async()=>({revoked:true})};}
   if(String(url).endsWith('/api/remote'))return {ok:true,json:async()=>({paired:record===c&&paired,device_info:{name:'iPhone',platform:'iOS 26',client:'Home Screen app'},paired_at:1720000000,last_connected_at:1720003600,configured_relay:'https://relay.example'})};
   if(fail&&record===b)throw new Error('This device is unreachable. Try again later.');
   if(String(url).endsWith('/api/corpora/lifecycle')){if(scenario==='edit-activation-failed')return {ok:false,json:async()=>({error:'This device is unreachable. Try again later.'})};const data=JSON.parse(options.body);operations.set(data.operation,data);record.status=data.action==='pause'?'paused':'active';record.revision++;return {ok:true,json:async()=>({...record})};}
   if(String(url).endsWith('/api/state'))return {ok:true,json:async()=>snapshot(record)};
   if(String(url).includes('/api/agents/'))return {ok:true,json:async()=>({id:'message'})};
   return {ok:true,json:async()=>({...record})};
 };
 if(scenario==='restore'){
   w.localStorage.setItem('s4.records',JSON.stringify([{...a,key:a.id}]));w.localStorage.setItem('s4.active',JSON.stringify(a.id));
   w.localStorage.setItem('s4.snapshot.'+a.id,JSON.stringify(snapshot(a)));
   w.localStorage.setItem('s4.workspace.'+a.id,JSON.stringify({selected:'last-chat',drafts:{'last-chat':'Keep this draft'},panes:{chat:true,sidebar:false}}));
   w.fetch=()=>new Promise(()=>{});
 }
 let poll,pairFailure=false;
 const setup={enabled:false,local_relay:true,configured_relay:'https://relay.example'};
 const invitation={relay:'https://relay.example',expires:Date.now()/1000+3600};
 let pairData={...setup};
 if(scenario==='pairing-setup'){
   const baseFetch=w.fetch,setTimeout=w.setTimeout.bind(w);w.setTimeout=(fn,ms,...args)=>ms===2500?(poll=fn,1):setTimeout(fn,ms,...args);
   w.RemoteCode={link:()=> 'https://relay.example/#invitation'};w.RemoteVendor={QRCode:{toCanvas:async()=>{}}};w.HTMLCanvasElement.prototype.toDataURL=()=> 'data:image/png;base64,AAAA';
   w.fetch=async(url,options={})=>{
     if(!url.includes('/api/remote'))return baseFetch(url,options);
     calls.push({url,method:options.method||'GET',data:options.body&&JSON.parse(options.body)});
     if(url.endsWith('/pair')){if(pairFailure)return {ok:false,json:async()=>({error:'Relay unavailable'})};pairData={...setup,enabled:true,invitation:{...invitation}};}
     if(url.endsWith('/revoke'))pairData={...setup};
     return {ok:true,json:async()=>({...pairData})};
   };
 }
 let releaseSession,earlyError,transports=[];
 if(scenario==='resume-before-credentials'){
   d.body.setAttribute('data-remote','');
   Object.defineProperty(w.navigator,'standalone',{value:true});
   w.localStorage.setItem('s4.records',JSON.stringify([{...b,key:b.id}]));w.localStorage.setItem('s4.active',JSON.stringify(b.id));
   w.localStorage.setItem('s4.snapshot.'+b.id,JSON.stringify(snapshot(b)));
   w.RemoteSession={list:()=>new Promise(resolve=>{releaseSession=()=>resolve([{relay:'https://relay.example',corpora:b}]);}),key:s=>s.corpora.id};
   w.RemoteTransport=class{constructor(session){this.session=session;transports.push(!!session);}async authenticate(){return this.session.corpora;}async fetch(){return {ok:true,json:async()=>snapshot(this.session.corpora)};}};
 }
 evaluate('remote-install');evaluate('relay-servers');evaluate('corpora');
 if(scenario==='resume-before-credentials'){
   try{await w.SapiensConnections.fetch('/api/state');}catch(e){earlyError=e.message;}
   releaseSession();
 }
 for(let i=0;i<12;i++)await sleep();
 const click=selector=>d.querySelector(selector).click();
 if(scenario==='pairing-setup'){
   await w.SapiensConnections.remoteControl(a,true);for(let i=0;i<8;i++)await sleep();
   const out={saved:!!d.querySelector('[data-remote-action="pair"]')};
   pairFailure=true;click('[data-remote-action="pair"]');await sleep();await poll();await sleep();await sleep();out.error=d.querySelector('#remote-host-feedback').textContent;
   pairFailure=false;click('[data-remote-action="pair"]');for(let i=0;i<8;i++)await sleep();out.invitation={download:d.querySelector('#download-pair-qr')?.href,link:d.querySelector('#remote-host-content a[target]')?.href,expiry:d.querySelector('#remote-host-content').textContent.includes('Expires')};
   click('[data-remote-action="link"]');out.invitation.pairingLink=d.querySelector('#host-pair-link').value;
   pairData.pending={peer:'phone'};await poll();await sleep();await sleep();out.noCodeDisabled=d.querySelector('[data-remote-action="approve"]').disabled;
   pairData.pending.confirmation_code='CwnX · eCGC';await poll();await sleep();await sleep();out.code=d.querySelector('#remote-host-content strong').textContent;click('[data-remote-action="approve"]');await sleep();
   delete pairData.pending;pairData.invitation.expires=0;await poll();await sleep();await sleep();out.expiredQR=!!d.querySelector('canvas');
   click('[data-remote-action="revoke"]');await sleep();click('[data-remote-action="pair"]');await sleep();
   out.writes=calls.filter(c=>c.method==='POST').map(c=>({path:c.url.split('/api/remote')[1],data:c.data}));
   console.log(JSON.stringify(out));dom.window.close();return;
 }
 if(scenario==='resume-before-credentials'){
   console.log(JSON.stringify({earlyError,transports,connected:w.SapiensConnections.connected,status:d.querySelector('#connection-label').textContent}));
 }else if(scenario==='pairing-rows'){
   click('#corpora-picker');for(let i=0;i<12;i++)await sleep();
   const rows=Array.from(d.querySelectorAll('.corpora-record')).map(row=>({name:row.querySelector('.corpora-name').textContent,action:row.querySelector('[data-pairing]')?.textContent||null}));
   click('[data-pairing="'+c.id+'"]');for(let i=0;i<12;i++)await sleep();
   const details=d.querySelector('#remote-host-content').textContent,title=d.querySelector('#corpora-dialog-title').textContent;
   click('[data-remote-action="revoke"]');for(let i=0;i<12;i++)await sleep();
   console.log(JSON.stringify({rows,details,title,selected:w.SapiensConnections.active.name,column:!d.querySelector('.corpora-remote-column').hidden,revoke:calls.find(call=>call.url.endsWith('/remote/revoke'))?.url,after:d.querySelector('[data-pairing="'+c.id+'"]').textContent}));
 }else if(scenario==='pairing-only-remote'){
   click('#corpora-picker');for(let i=0;i<12;i++)await sleep();
   console.log(JSON.stringify({column:!d.querySelector('.corpora-remote-column').hidden,actions:d.querySelectorAll('[data-pairing]').length,requests:calls.filter(call=>call.url.endsWith('/api/remote')).length}));
 }else if(scenario==='cached-offline'){
   b.status='active';const cached=snapshot(b);cached.turns=[{id:'saved',output:'Saved remote reply'}];
   w.localStorage.setItem('s4.snapshot.'+b.id,JSON.stringify(cached));
   w.localStorage.setItem('s4.workspace.'+b.id,JSON.stringify({drafts:{'chief-b':'Unsent draft'}}));
   let delivered;w.SapiensConnections.subscribe(value=>{delivered=value;});
   fail=true;click('#corpora-picker');const before=calls.length;click('[data-enter="'+b.id+'"]');
   const out={active:w.SapiensConnections.active.name,status:d.querySelector('#connection-label').textContent,
     reply:delivered.turns[0]?.output,draft:delivered.preferences.drafts?.['chief-b'],requests:calls.length-before,
     lifecycleDisabled:d.querySelector('#connection-status').disabled,
     online:d.querySelector('#connection-status').dataset.online,
     rowStatus:d.querySelector('[data-selected="true"] .corpora-state').textContent,
     rowActive:d.querySelector('[data-selected="true"] .corpora-dot').dataset.active};
   try{await w.SapiensConnections.fetch('/api/agents/chief-b/messages',{method:'POST',body:'{}'});}catch(e){out.writeError=e.message;}
   out.writes=calls.slice(before).filter(c=>c.method!=='GET').length;
   fail=false;const response=await w.SapiensConnections.fetch('/api/state');w.SapiensConnections.snapshot(await response.json());
   out.reconnected=w.SapiensConnections.connected;out.liveStatus=d.querySelector('#connection-label').textContent;
   out.writesAfterReconnect=calls.slice(before).filter(c=>c.method!=='GET').length;
   console.log(JSON.stringify(out));
 }else if(['switch','unreachable','leave-unreachable'].includes(scenario)){
   fail=scenario==='unreachable';click('#corpora-picker');click('[data-enter="'+b.id+'"]');for(let i=0;i<15;i++)await sleep();
   let remoteRequests=0;
   if(scenario==='leave-unreachable'){
     const before=calls.length;fail=true;click('[data-enter="'+a.id+'"]');for(let i=0;i<15;i++)await sleep();
     remoteRequests=calls.slice(before).filter(c=>c.url.includes(b.id)).length;
   }
   console.log(JSON.stringify({states:[a.status,b.status],remoteRequests,active:w.SapiensConnections.active.name,menuOpen:!d.querySelector('#corpora-menu').hidden,status:d.querySelector('#connection-label').textContent,commands:calls.filter(c=>c.url.endsWith('/lifecycle')).map(c=>({target:c.url.includes(a.id)?'Home':'Studio',action:c.data.action})),notice:d.querySelector('#corpora-notice').open?d.querySelector('#corpora-notice-text').textContent:null}));
 }else if(scenario.startsWith('edit')){
   const target=scenario==='edit-paused-local'?a:b;
   target.status=scenario==='edit'?'active':scenario==='edit-archived'?'archived':'paused';
   click('#corpora-picker');if(scenario==='edit-archived'){d.querySelector('#corpora-archived').checked=true;d.querySelector('#corpora-archived').dispatchEvent(new w.Event('change'));}click('[data-edit="'+target.id+'"]');
   const message=d.querySelector('#chief-settings-form textarea').value;
   const form=d.querySelector('#chief-settings-form');form.dispatchEvent(new w.Event('submit',{cancelable:true}));form.dispatchEvent(new w.Event('submit',{cancelable:true}));for(let i=0;i<15;i++)await sleep();
   const writes=calls.filter(c=>['POST','PUT'].includes(c.method));
   console.log(JSON.stringify({message,target:calls.find(c=>c.url.includes('/messages'))?.url,selected:w.SapiensConnections.active.name,status:target.status,actions:writes.map(c=>c.data.action||'send'),writeTargets:writes.map(c=>c.url.includes(a.id)?'Home':'Studio'),sent:writes.find(c=>c.url.includes('/messages'))?.data.text,dialogOpen:d.querySelector('#corpora-dialog').open,draft:form.elements.message.value,feedback:form.querySelector('[role=status]').textContent}));
 }else if(scenario==='restore'){
   const restored=await w.SapiensConnections.initial;
   console.log(JSON.stringify({status:d.querySelector('#connection-label').textContent,preferences:restored.preferences,selected:w.SapiensConnections.active.name}));
 }else{
   console.log(JSON.stringify({gate:!d.querySelector('#mobile-install-gate').hidden,localVisible:!d.querySelector('#create-local-corpora').hidden,empty:!d.querySelector('#corpora-empty').hidden,networkCalls:calls.length,credentialReads,workers}));
 }
 dom.window.close();
})().catch(error=>{console.error(error);process.exitCode=1;});
