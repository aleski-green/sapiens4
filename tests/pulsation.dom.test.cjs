const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {JSDOM}=require('jsdom');
const {window}=new JSDOM('<div id="composer-area"></div><div id="updates"></div><div id="agent-heading"></div><textarea id="message-input"></textarea><button id="attach-button"></button><button class="send-button"></button>');
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const pulse={pulse:'pulse-test',frequency:'bpm60',num:2,pulseId:'pulse-test:bpm60:2',agencyKind:'chatInput',slot:1,timestamp:'2026-10-08T12:00:00Z',agent:'a'};
const ctx=vm.createContext({document:window.document,Date,console,esc,$:s=>window.document.querySelector(s),
 state:{selected:'a',agents:[{id:'a',name:'Alpha',role:'Tester'}],messages:{},drafts:{}},
 live:{pulses:[pulse,{...pulse,agencyKind:'chatOutput',slot:2},{...pulse,agent:'b'}],turns:[{id:'busy',agent:'a',status:'running',input:'PRIVATE MESSAGE CONTENT'}],activity:{}},
 selected:()=>({id:'a',name:'Alpha',role:'Tester'}),avatar:()=>'',isMainSapi:()=>false,groupLabels:()=>'',renderActivityNavigation:()=>{},
 online:true,submitting:new Set(),uploading:0,blocksChat:t=>['running','queued'].includes(t.status)});
const groups=fs.readFileSync('web/features/groups.js','utf8');
vm.runInContext(groups.slice(groups.indexOf('function renderUpdates('),groups.indexOf('function renderWork(')),ctx);
const host=window.document.querySelector('#updates');
ctx.renderUpdates(host);
assert.equal(host.querySelectorAll('article').length,2);
assert.match(host.textContent,/bpm60/);assert.match(host.textContent,/Slot 2/);
assert.match(host.textContent,/pulse-test:bpm60:2/);
assert.doesNotMatch(host.textContent,/PRIVATE MESSAGE|Running|Runtime|Events|Archived/);
assert.equal(host.querySelectorAll('time').length,2);
ctx.live.pulses=[];ctx.renderUpdates(host);assert.match(host.textContent,/No dispatched pulses/);
ctx.live.pulses=[{...pulse,pulseId:'<img src=x onerror=alert(1)>'}];ctx.renderUpdates(host);assert.equal(host.querySelector('img'),null);
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
console.log('Pulse UI: metadata-only dispatches, escaping, available composer, and FIFO bubbles passed');
