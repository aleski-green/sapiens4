// Shipped UI + controllable HTTP boundary; assertions belong to RSpec.
const fs=require('node:fs');
const {JSDOM}=require('../../libs4/node_modules/jsdom');
const read=p=>fs.readFileSync(p,'utf8');
const scripts=[...read('sapiens/corpora/host/assets.py').split('SCRIPTS = (')[1].split(')')[0].matchAll(/"([^"]+\.js)"/g)].map(m=>read('web/'+m[1])).join('\n');
const tick=()=>new Promise(resolve=>setImmediate(resolve));
const task=title=>({id:title,title,body:'<script>literal YAML</script>',state:'Completed',owner:'chief',sender:'chief'});
async function fixture(preferences={panel:'work',view:'tasks'}) {
  const dom=new JSDOM(read('web/shell/index.html'),{url:'https://fixture.example/',runScripts:'outside-only',pretendToBeVisual:true});
  const w=dom.window,d=w.document,requests=[],errors=[],saves=[];
  const snapshot={corpora:{id:'first',name:'First',status:'active'},main_agent_id:'chief',
    agents:['chief','other'].map(id=>({id,name:id,created:'2026-10-01T00:00:00Z',role:'Test',face:'^_^',color:'#48c99c'})),
    preferences:{selected:'chief',...preferences},turns:[],groups:[],computer:{built:false},orchestration:{},
    workloads:[{participants:['chief'],state:'Queued',origin:{agent:'chief'},callId:'call'}],routines:[],events:{}};
  w.addEventListener('error',e=>errors.push(e.message));
  w.matchMedia=()=>({matches:false,addEventListener(){}});
  w.ResizeObserver=class{observe(){} disconnect(){}};
  w.HTMLDialogElement.prototype.close=function(){this.open=false;};
  w.HTMLDialogElement.prototype.showModal=function(){this.open=true;};
  w.setTimeout=()=>0;w.clearTimeout=()=>{};
  let subscribe;
  w.SapiensConnections={initial:Promise.resolve(snapshot),connected:true,generation:0,active:{location:'Remote'},
    save:value=>saves.push(value),snapshot(){},subscribe:fn=>subscribe=fn,
    fetch:path=>path.includes('/tasks?')?new Promise(resolve=>requests.push(resolve)):Promise.resolve({ok:true,json:async()=>snapshot})};
  await w.eval('(async()=>{'+scripts+'})()');
  return {w,d,requests,errors,saves,close:()=>w.close(),
    click:selector=>d.querySelector(selector).click(),
    complete:async(index,tasks,ok=true)=>{requests[index]({ok,json:async()=>({tasks})});await tick();},
    switch:()=>{w.SapiensConnections.generation++;subscribe({...snapshot,corpora:{...snapshot.corpora,id:'second',name:'Second'}});},
    text:()=>d.querySelector('#conversation-body').textContent};
}
(async()=>{
  const results={};
  const restored=await fixture({panel:'work',view:'tasks',period:'past'});
  await restored.complete(0,[task('Saved task')]);
  results.restored={panel:restored.d.querySelector('[data-panel][aria-pressed=true]').dataset.panel,
    filter:restored.d.querySelector('[aria-label="Task history"]').textContent.trim(),text:restored.text(),
    scripts:restored.d.querySelector('#conversation-body').querySelectorAll('script').length};
  restored.close();
  const invalid=await fixture({panel:'toString',view:'constructor',period:'paused'});
  results.invalid={panel:invalid.d.querySelector('[data-panel][aria-pressed=true]').dataset.panel,errors:invalid.errors};invalid.close();
  const filter=await fixture({panel:'work',view:'tasks',period:'deleted'});
  results.filter={text:filter.d.querySelector('[aria-label="Task history"]').textContent.trim(),errors:filter.errors};filter.close();
  const panes=await fixture({panel:'chat',workspaces:{other:{tabs:[{id:'tab-new',url:'about:blank',title:'New tab'}],activeTab:'tab-new'}}});
  const before=panes.d.querySelector('#workspace-panel').hidden;
  panes.click('.agent-name[data-agent=other]');
  results.panes={before,after:panes.d.querySelector('#workspace-panel').hidden,errors:panes.errors};panes.close();
  const mounted=await fixture();
  mounted.click('[data-panel=chat]');mounted.click('[data-panel=work]');
  await mounted.complete(0,[{...task('Returned task'),state:'Queued'}]);
  results.remounted={requests:mounted.requests.length,text:mounted.text(),errors:mounted.errors};mounted.close();
  const switched=await fixture();switched.switch();
  await switched.complete(1,[{...task('Current corpora'),state:'Queued'}]);
  await switched.complete(0,[{...task('Stale corpora'),state:'Queued'}]);
  results.switched={requests:switched.requests.length,text:switched.text(),errors:switched.errors};switched.close();
  const failed=await fixture();await failed.complete(0,null,false);
  const failure=failed.text();failed.click('.task-copy');await failed.complete(1,[{id:'malformed'}]);
  const malformed=failed.text();failed.click('.task-copy');await failed.complete(2,[]);
  results.retry={failure,malformed,recovered:failed.text(),requests:failed.requests.length,errors:failed.errors};failed.close();
  console.log(JSON.stringify(results));
})().catch(error=>{console.error(error);process.exitCode=1;});
