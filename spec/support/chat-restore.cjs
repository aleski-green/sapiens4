// Real workspace boot/reconnect with layout supplied by the browser boundary.
const fs=require('node:fs'),path=require('node:path');
const {JSDOM}=require('../../tests/node_modules/jsdom');
const root=path.resolve(__dirname,'../..'),read=name=>fs.readFileSync(path.join(root,name),'utf8');
const scripts=[...read('sapiens/corpora/host/assets.py').split('SCRIPTS = (')[1].split(')')[0].matchAll(/"([^"]+\.js)"/g)].map(m=>read('web/'+m[1])).join('\n');
const turns=Array.from({length:30},(_,i)=>({id:'turn-'+i,agent:'chief',flow:'chat',status:'done',created:`2026-10-01T00:${String(i).padStart(2,'0')}:00Z`,input:'Question '+i,output:'Answer '+i,output_at:`2026-10-01T00:${String(i).padStart(2,'0')}:01Z`}));
const full={corpora:{id:'corpora',name:'Test',status:'active'},main_agent_id:'chief',agents:[{id:'chief',name:'ChiefSapi',role:'Test',face:'^_^',color:'#48c99c'}],preferences:{selected:'chief',panes:{chat:true,sidebar:false,workspace:false}},turns,groups:[],computer:{built:false},orchestration:{},activity:{},run_activity:{},events:{},workloads:[],pulses:[],routines:[]};
async function boot(snapshot){
 const dom=new JSDOM(read('web/shell/index.html'),{url:'https://fixture.example/',runScripts:'outside-only',pretendToBeVisual:true});
 const w=dom.window,d=w.document,host=d.querySelector('#conversation-body');let position=0,saved,subscriber;
 w.matchMedia=()=>({matches:false,addEventListener(){}});w.ResizeObserver=class{observe(){} disconnect(){}};
 w.HTMLDialogElement.prototype.close=function(){this.open=false;};w.HTMLDialogElement.prototype.showModal=function(){this.open=true;};
 w.setTimeout=()=>1;w.clearTimeout=()=>{};
 Object.defineProperties(host,{clientHeight:{get:()=>200},scrollHeight:{get:()=>host.children.length*100},scrollTop:{get:()=>position,set:v=>{position=Math.max(0,Math.min(v,host.scrollHeight-200));}}});
 host.getBoundingClientRect=()=>({top:0,bottom:200});
 w.HTMLElement.prototype.getBoundingClientRect=function(){const i=[...host.children].indexOf(this);return {top:i*100-position,bottom:(i+1)*100-position};};
 w.SapiensConnections={initial:Promise.resolve(snapshot),connected:true,generation:0,remote:true,save:p=>{saved=JSON.parse(JSON.stringify(p));},snapshot(){},subscribe:fn=>{subscriber=fn;fn(snapshot);},fetch:async()=>({ok:true,json:async()=>full})};
 await w.eval('(async()=>{'+scripts+'})()');
 return {dom,w,d,host,get saved(){return saved;},live(){subscriber({...full,preferences:saved});},bookmark(){w.dispatchEvent(new w.Event('pagehide'));},visible(){const n=[...host.children].find(n=>n.dataset.chatKey&&n.getBoundingClientRect().bottom>0);return {text:n?.textContent,offset:n?.getBoundingClientRect().top};}};
}
(async()=>{
 const original=await boot(full);original.host.scrollTop=4825;
 const input=original.d.querySelector('#message-input');input.value='My unsent draft';input.dispatchEvent(new original.w.Event('input'));
 original.bookmark();const saved=original.saved,expected=original.visible(),results={};
 for(const [name,start] of [['cached',20],['missing',28]]){
  const app=await boot({...full,turns:turns.slice(start),preferences:saved});
  results[name]={before:app.visible(),pending:app.saved.chatPosition,draft:app.d.querySelector('#message-input').value};
  app.live();results[name].after=app.visible();results[name].expected=expected;
  app.dom.window.close();
 }
 const abandoned=await boot({...full,turns:turns.slice(28),preferences:saved});
 abandoned.host.dispatchEvent(new abandoned.w.Event('touchstart'));abandoned.host.scrollTop=100;
 const chosen=abandoned.visible();abandoned.live();results.manual={before:chosen,after:abandoned.visible()};abandoned.dom.window.close();
 original.host.scrollTop=original.host.scrollHeight;original.bookmark();
 const bottom=await boot({...full,turns:turns.slice(20),preferences:original.saved});bottom.live();
 results.bottom={scroll:bottom.host.scrollTop,max:bottom.host.scrollHeight-bottom.host.clientHeight};
 bottom.dom.window.close();original.dom.window.close();console.log(JSON.stringify(results));
})().catch(e=>{console.error(e);process.exitCode=1;});
