// Browser probe: RSpec owns the assertions; this reports rendered behavior.
const fs=require('node:fs'),path=require('node:path');
const {JSDOM}=require('../../tests/node_modules/jsdom');
const {IDBFactory}=require('../../tests/node_modules/fake-indexeddb');
const {webcrypto}=require('node:crypto');
const root=path.resolve(__dirname,'../..'),scenario=process.argv[2];
const sleep=()=>new Promise(resolve=>setTimeout(resolve,0));
const template=fs.readFileSync(path.join(root,'prompts/corpora-settings-request.md'),'utf8');
const a={id:'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',name:'Home',device:'This Mac',scope:'Home tasks',status:'active',revision:1,chief_id:'chief-a',location:'Local',settings_template:template};
const b={id:'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',name:'Studio',device:'Mac mini',scope:'Studio tasks',status:'paused',revision:1,chief_id:'chief-b',location:'Remote',settings_template:template};
const snapshot=record=>({corpora:{...record},preferences:{},agents:[],groups:[],turns:[]});
(async()=>{
 const dom=new JSDOM(fs.readFileSync(path.join(root,'web/shell/index.html'),'utf8'),{url:'https://relay.example/workspace/',runScripts:'outside-only',pretendToBeVisual:true});
 const w=dom.window,d=w.document,calls=[],operations=new Map();let fail=false;
 Object.defineProperty(w,'crypto',{value:webcrypto});w.AbortSignal=AbortSignal;w.Response=Response;
 w.HTMLDialogElement.prototype.showModal=function(){this.open=true;};w.HTMLDialogElement.prototype.close=function(){this.open=false;};
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
 if(scenario==='mobile'||scenario==='linux'){
   d.body.setAttribute('data-remote','');
   Object.defineProperty(w.navigator,'userAgent',{value:scenario==='mobile'?'Mozilla/5.0 (iPhone)':'Mozilla/5.0 (X11; Linux x86_64)'});
   w.RemoteSession={list:async()=>[]};
 }
 w.fetch=async(url,options={})=>{
   calls.push({url,method:options.method||'GET',data:options.body&&JSON.parse(options.body)});
   if(url==='/api/host')return {ok:true,json:async()=>({local_available:true,corpora:[a,b]})};
   const record=String(url).includes(a.id)?a:b;
   if(fail&&record===b)throw new Error('This device is unreachable. Try again later.');
   if(String(url).endsWith('/api/corpora/lifecycle')){const data=JSON.parse(options.body);operations.set(data.operation,data);record.status=data.action==='pause'?'paused':'active';record.revision++;return {ok:true,json:async()=>({...record})};}
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
 evaluate('remote-install');evaluate('corpora');
 for(let i=0;i<12;i++)await sleep();
 const click=selector=>d.querySelector(selector).click();
 if(scenario==='switch'||scenario==='unreachable'){
   fail=scenario==='unreachable';click('#corpora-picker');click('[data-enter="'+b.id+'"]');for(let i=0;i<15;i++)await sleep();
   console.log(JSON.stringify({active:w.SapiensConnections.active.name,menuOpen:!d.querySelector('#corpora-menu').hidden,status:d.querySelector('#connection-label').textContent,commands:calls.filter(c=>c.url.endsWith('/lifecycle')).map(c=>({target:c.url.includes(a.id)?'Home':'Studio',action:c.data.action})),notice:d.querySelector('#corpora-notice').open?d.querySelector('#corpora-notice-text').textContent:null}));
 }else if(scenario==='edit'){
   b.status='active';click('#corpora-picker');click('[data-edit="'+b.id+'"]');
   const message=d.querySelector('#chief-settings-form textarea').value;
   d.querySelector('#chief-settings-form').dispatchEvent(new w.Event('submit',{cancelable:true}));for(let i=0;i<8;i++)await sleep();
   console.log(JSON.stringify({message,target:calls.find(c=>c.url.includes('/messages'))?.url,selected:w.SapiensConnections.active.name}));
 }else if(scenario==='restore'){
   const restored=await w.SapiensConnections.initial;
   console.log(JSON.stringify({status:d.querySelector('#connection-label').textContent,preferences:restored.preferences,selected:w.SapiensConnections.active.name}));
 }else{
   console.log(JSON.stringify({gate:!d.querySelector('#mobile-install-gate').hidden,localVisible:!d.querySelector('#create-local-corpora').hidden,empty:!d.querySelector('#corpora-empty').hidden,networkCalls:calls.length}));
 }
 dom.window.close();
})().catch(error=>{console.error(error);process.exitCode=1;});
