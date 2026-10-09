const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {JSDOM}=require('jsdom');
const {window}=new JSDOM('<div id="composer-area"></div><div id="updates"></div><div id="agent-heading"></div><textarea id="message-input"></textarea><button id="attach-button"></button><button class="send-button"></button>');
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const event={id:1,timestamp:'2026-10-09T09:10:00.047Z',actor:'system',entity:'a',event:'pulse.dispatched',agency:'chatInput',details:{frequency:'bph60',slot:1}};
const ctx=vm.createContext({document:window.document,Date,console,esc,$:s=>window.document.querySelector(s),
 state:{selected:'a',agents:[{id:'a',name:'Alpha',role:'Tester'}],messages:{},drafts:{}},
 live:{events:{a:[event,{...event,id:2,agency:'chatOutput'}],b:[{...event,id:3}]},turns:[{id:'busy',agent:'a',status:'running',input:'PRIVATE MESSAGE CONTENT'}],activity:{}},
 activityChevron:()=>'<svg></svg>',
 selected:()=>({id:'a',name:'Alpha',role:'Tester'}),avatar:()=>'',isMainSapi:()=>false,groupLabels:()=>'',renderActivityNavigation:()=>{},
 online:true,submitting:new Set(),uploading:0,blocksChat:t=>['running','queued'].includes(t.status)});
const groups=fs.readFileSync('web/features/groups.js','utf8');
vm.runInContext(groups.slice(groups.indexOf('function eventTimestamp('),groups.indexOf('function renderWork(')),ctx);
const host=window.document.querySelector('#updates');
ctx.renderUpdates(host);
assert.equal(host.querySelectorAll('details').length,2);
assert.equal(host.querySelector('pre'),null,'JSON must not render while collapsed');
const row=host.querySelector('details');row.open=true;row.dispatchEvent(new window.Event('toggle'));
assert.equal(JSON.parse(row.querySelector('pre').textContent).frequency,'bph60');
ctx.renderUpdates(host);assert.equal(host.querySelector('details'),row,'Polling must preserve focus and open rows');
ctx.live.events.a.unshift({...event,id:4});ctx.renderUpdates(host);
assert.equal(host.querySelector('[data-event="1"]').open,true,'New events must preserve expansion');
assert.equal(host.querySelectorAll('pre').length,1);
assert.match(host.querySelector('time').textContent,/09 Oct \d{2}:10 00s \.047/);
assert.doesNotMatch(host.textContent,/PRIVATE MESSAGE/);
ctx.live.events.a=[];ctx.renderUpdates(host);assert.match(host.textContent,/No events yet/);
ctx.live.events.a=[{...event,id:5,entity:'<img src=x onerror=alert(1)>',details:{html:'<img src=x>'}}];ctx.renderUpdates(host);
const malicious=host.querySelector('details');malicious.open=true;malicious.dispatchEvent(new window.Event('toggle'));assert.equal(host.querySelector('img'),null);
ctx.live.events.a=Array.from({length:105},(_,i)=>({...event,id:i+10}));ctx.renderUpdates(host);assert.equal(host.querySelectorAll('details').length,100);
ctx.state.selected='b';ctx.renderUpdates(host);assert.equal(host.querySelectorAll('details').length,1);assert.equal(host.querySelector('details').open,false);ctx.state.selected='a';
const bridge=fs.readFileSync('web/shell/bridge.js','utf8');
vm.runInContext(bridge.slice(bridge.indexOf('renderAgentHeader = function()'),bridge.indexOf('let renderedConversation')),ctx);
ctx.renderAgentHeader();assert.equal(window.document.querySelector('.send-button').disabled,false,'Running chat must keep accepting messages');
ctx.submitting.add('a');ctx.renderAgentHeader();assert.equal(window.document.querySelector('.send-button').disabled,true);
// Two outputs published within the same millisecond retain output FIFO order.
Object.assign(ctx,{agent:id=>ctx.state.agents.find(a=>a.id===id),receiveWorkspaces:()=>{},displayTime:v=>v,chatResult:t=>({text:t.output}),delegationMessages:()=>{}});
ctx.state.agents=[{id:'a'}];ctx.state.selected='a';
vm.runInContext(bridge.slice(bridge.indexOf('function applySnapshot('),bridge.indexOf('renderGlobal = function()')),ctx);
ctx.applySnapshot({agents:[{id:'a',created:'2026-10-08T12:00:00Z'}],preferences:{},turns:[
 {id:'first',agent:'a',flow:'chat',created:'2026-10-08T12:00:00Z',status:'done',input:'A',output:'Later',output_at:'2026-10-08T12:00:04Z',output_order:2},
 {id:'second',agent:'a',flow:'chat',created:'2026-10-08T12:00:02Z',status:'done',input:'B',output:'Earlier',output_at:'2026-10-08T12:00:04Z',output_order:1}
]});
assert.equal(ctx.state.messages.a.filter(m=>m.role==='assistant').map(m=>m.text).join(','),'Earlier,Later');
console.log('Events UI: scoped rows, exact timestamps, lazy JSON, stable polling, escaping, composer and FIFO passed');
