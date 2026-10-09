const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
function element(tag = 'div') {
  return {tag, children:[], isConnected:true, textContent:'', attributes:{}, listeners:{},
    get firstElementChild(){return this.children[0];},
    setAttribute(k,v){this.attributes[k]=v;},
    append(...children){this.children.push(...children);},
    replaceChildren(...children){this.children.forEach(c=>c.isConnected=false);this.children=children;},
    addEventListener(event,fn){this.listeners[event]=fn;}};
}
function find(root, predicate) {
  if (predicate(root)) return root;
  for (const child of root.children) {const found=find(child,predicate);if(found)return found;}
}
const byClass=(root,name)=>find(root,n=>n.className?.split(' ').includes(name));
function fixture(fetch) {
  const messages = [];
  const ctx = vm.createContext({Map,Set,JSON,Date,AbortSignal,fetch,encodeURIComponent,
    document:{createElement:element},state:{selected:'chief',panel:'tasks',messages:{}},live:{workloads:[]},
    toast:message=>messages.push(message),agent:id=>({id,name:id}),displayTime:time=>time,formatText:text=>text});
  vm.runInContext(fs.readFileSync('web/features/tasks.js','utf8'),ctx);
  return {ctx,host:element(),messages};
}
const tick = () => new Promise(resolve=>setImmediate(resolve));
const task=(state,id=state)=>({id,state,title:'Research <script>bad</script>',owner:'researcher',sender:'chief',body:'objective: "<script>bad</script>"\n'});
(async () => {
  let requests=0;
  const rows=['Queued','Running','WaitingForAdmin','Completed','Unresolved','Failed','Interrupted','Cancelled'].map(s=>task(s));
  const f=fixture(async url=>{requests++;assert.equal(url,'/api/agents/chief/tasks?format=json');return{ok:true,json:async()=>({tasks:rows})};});
  f.ctx.renderTasks(f.host);await tick();
  let list=byClass(f.host,'task-list');
  assert.equal(list.children.length,3,'Upcoming includes queued, running, waiting tasks');
  assert.equal(byClass(list,'task-title').textContent,rows[0].title);
  assert.equal(byClass(list,'task-title').innerHTML,undefined,'Titles never become HTML');
  assert.equal(byClass(list,'task-body-yaml').textContent,rows[0].body);
  assert.equal(byClass(list,'task-body-yaml').innerHTML,undefined,'YAML never becomes HTML');
  const view=f.host.firstElementChild;
  f.ctx.renderTasks(f.host);assert.equal(f.host.firstElementChild,view,'Unchanged polling preserves DOM and focus');
  assert.equal(requests,1);
  const row=byClass(list,'task-row');row.open=true;row.listeners.toggle();
  vm.runInContext("taskPeriod='past'",f.ctx);f.ctx.renderTasks(f.host);
  assert.equal(byClass(f.host,'task-list').children.length,5,'Terminal outcomes appear in Past');
  vm.runInContext("taskPeriod='upcoming'",f.ctx);f.ctx.renderTasks(f.host);
  assert.equal(byClass(f.host,'task-row').open,true,'Expansion survives changing tabs');

  let finish;
  const pending=fixture(()=>new Promise(resolve=>{finish=resolve;}));
  pending.ctx.renderTasks(pending.host);pending.ctx.state.selected='other';
  finish({ok:true,json:async()=>({tasks:rows})});await tick();
  assert.equal(byClass(pending.host,'task-row'),undefined,'Late responses do not replace another Sapi view');

  const failed=fixture(async()=>({ok:false}));
  failed.ctx.renderTasks(failed.host);await tick();
  assert.equal(byClass(failed.host,'task-empty').children[0].textContent,'Could not load tasks.');
  assert.equal(byClass(failed.host,'task-copy').textContent,'Try again');
  const empty=fixture(async()=>({ok:true,json:async()=>({tasks:[]})}));
  empty.ctx.renderTasks(empty.host);await tick();
  assert.equal(byClass(empty.host,'task-empty').children[0].textContent,'No planned tasks');

  const routing=fixture();
  const turn={id:'child',agent:'researcher',status:'running',created:'2026-09-29T12:00:00Z'};
  routing.ctx.delegationMessages({turns:[turn],workloads:[{id:'w1',origin:{agent:'chief',call:'root'},callId:'child',owner:'researcher',state:'Running'}]});
  const message=routing.ctx.state.messages.chief[0];
  assert.equal(message.author,'researcher');assert.equal(message.requestTurn,turn);assert.equal(message.delegation.id,'w1');
  console.log('Tasks UI passed: Upcoming/Past filtering, clickable rows, safe YAML bodies, preserved expansion/focus, stale responses, errors, attribution.');
})().catch(error=>{console.error(error);process.exit(1);});
