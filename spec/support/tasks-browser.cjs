// Exercise the compiled task UI and report DOM/network observations to RSpec.
const fs = require('node:fs'), vm = require('node:vm');
const {JSDOM} = require('../../libs4/node_modules/jsdom');

const fixtures=[];
function fixture(fetch) {
  const dom = new JSDOM('<main></main>'); fixtures.push(dom);
  const window=dom.window,host=window.document.querySelector('main'),messages=[],urls=[];
  const ctx=vm.createContext({window,document:window.document,Map,Set,JSON,Date,AbortSignal,encodeURIComponent,setTimeout,clearTimeout,
    fetch:async(...args)=>{urls.push(args[0]);return fetch(...args);},
    state:{selected:'chief',panel:'tasks',messages:{}},live:{workloads:[]},
    toast:message=>messages.push(message),agent:id=>({id,name:id}),displayTime:time=>time,formatText:text=>text});
  require('./components.cjs').load(ctx,['activity','session','tasks']);
  return {ctx,host,messages,urls};
}
const tick=()=>new Promise(resolve=>setImmediate(resolve));
const task=(state,id=state)=>({id,state,title:'Research <script>bad</script>',owner:'researcher',sender:'chief',body:'objective: "<script>bad</script>"\n'});
(async()=>{
  const out={},rows=['Queued','Running','WaitingForAdmin','Completed','Unresolved','Failed','Interrupted','Cancelled'].map(s=>task(s));
  const f=fixture(async()=>({ok:true,json:async()=>({tasks:rows})}));
  f.ctx.renderTasks(f.host);await tick();
  let list=f.host.querySelector('.task-list');
  out.planned={count:list.children.length,title:list.querySelector('.task-title').textContent,
    titleElements:list.querySelector('.task-title').children.length,body:list.querySelector('.task-body-yaml').textContent,
    bodyElements:list.querySelector('.task-body-yaml').children.length};
  const view=f.host.firstElementChild;
  f.ctx.renderTasks(f.host);out.sameView=f.host.firstElementChild===view;out.urls=f.urls.slice();
  const row=list.querySelector('.task-row');row.open=true;row.dispatchEvent(new f.host.ownerDocument.defaultView.Event('toggle'));
  vm.runInContext("taskPeriod='past'",f.ctx);f.ctx.renderTasks(f.host);out.pastCount=f.host.querySelector('.task-list').children.length;
  vm.runInContext("taskPeriod='upcoming'",f.ctx);f.ctx.renderTasks(f.host);out.expanded=f.host.querySelector('.task-row').open;
  let finish;
  const pending=fixture(()=>new Promise(resolve=>{finish=resolve;}));
  pending.ctx.renderTasks(pending.host);pending.ctx.state.selected='other';
  finish({ok:true,json:async()=>({tasks:rows})});await tick();out.staleRows=pending.host.querySelectorAll('.task-row').length;
  const failed=fixture(async()=>({ok:false}));failed.ctx.renderTasks(failed.host);await tick();
  out.failed={message:failed.host.querySelector('.task-empty p').textContent,retry:failed.host.querySelector('.task-copy').textContent};
  const empty=fixture(async()=>({ok:true,json:async()=>({tasks:[]})}));empty.ctx.renderTasks(empty.host);await tick();
  out.empty=empty.host.querySelector('.task-empty p').textContent;
  const routing=fixture(),turn={id:'child',agent:'researcher',status:'running',created:'2026-09-29T12:00:00Z'};
  routing.ctx.delegationMessages({turns:[turn],workloads:[{id:'w1',origin:{agent:'chief',call:'root'},callId:'child',owner:'researcher',state:'Running'}]});
  const message=routing.ctx.state.messages.chief[0];out.delegation={author:message.author,sameTurn:message.requestTurn===turn,id:message.delegation.id};
  console.log(JSON.stringify(out));
})().catch(error=>{console.error(error);process.exitCode=1;}).finally(()=>fixtures.forEach(dom=>dom.window.close()));
