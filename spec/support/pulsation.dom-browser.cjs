// Browser actions and observations; expectations are defined by RSpec.
const {observe,observeText,observeIdentity,attempt}=require('./observations.cjs');
const fs=require('node:fs'),vm=require('node:vm');
const {JSDOM}=require('../../libs4/node_modules/jsdom');
const {window}=new JSDOM('<div id="composer-area"></div><div id="updates"></div><div id="agent-heading"></div><textarea id="message-input"></textarea><button id="attach-button"></button><button class="send-button"></button>');
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const event={id:1,timestamp:'2026-10-09T09:10:00.047Z',actor:'system',entity:'a',event:'pulse.dispatched',agency:'chatInput',details:{frequency:'bph60',slot:1}};
const ctx=vm.createContext({document:window.document,Date,console,esc,$:s=>window.document.querySelector(s),
 state:{selected:'a',agents:[{id:'a',name:'Alpha',role:'Tester'}],messages:{},drafts:{}},
 live:{events:{a:[event,{...event,id:2,agency:'chatOutput'}],b:[{...event,id:3}]},turns:[{id:'busy',agent:'a',status:'running',input:'PRIVATE MESSAGE CONTENT'}],activity:{}},
 activityChevron:()=>'<svg></svg>',
 selected:()=>({id:'a',name:'Alpha',role:'Tester'}),avatar:()=>'',isMainSapi:()=>false,groupLabels:()=>'',renderActivityNavigation:()=>{},
 paneLimit:()=>3,resizeComposer:()=>{},online:true,submitting:new Set(),uploading:0,blocksChat:t=>['running','queued'].includes(t.status)});
require('./components.cjs').load(ctx,['work']);
const host=window.document.querySelector('#updates');
ctx.renderUpdates(host);
observe("pulsation.dom.test.cjs:16:1", host.querySelectorAll('details').length);
observe("pulsation.dom.test.cjs:17:2", host.querySelector('pre'));
const row=host.querySelector('details');row.open=true;row.dispatchEvent(new window.Event('toggle'));
observe("pulsation.dom.test.cjs:19:3", JSON.parse(row.querySelector('pre').textContent).frequency);
ctx.renderUpdates(host);observeIdentity("pulsation.dom.test.cjs:20:4", host.querySelector('details'), row);
ctx.live.events.a.unshift({...event,id:4});ctx.renderUpdates(host);
observe("pulsation.dom.test.cjs:22:5", host.querySelector('[data-event="1"]').open);
observe("pulsation.dom.test.cjs:23:6", host.querySelectorAll('pre').length);
observeText("pulsation.dom.test.cjs:24:7", host.querySelector('time').textContent);
observeText("pulsation.dom.test.cjs:25:8", host.textContent);
ctx.live.events.a=[];ctx.renderUpdates(host);observeText("pulsation.dom.test.cjs:26:9", host.textContent);
ctx.live.events.a=[{...event,id:5,entity:'<img src=x onerror=alert(1)>',details:{html:'<img src=x>'}}];ctx.renderUpdates(host);
const malicious=host.querySelector('details');malicious.open=true;malicious.dispatchEvent(new window.Event('toggle'));observe("pulsation.dom.test.cjs:28:10", host.querySelector('img'));
ctx.live.events.a=Array.from({length:105},(_,i)=>({...event,id:i+10}));ctx.renderUpdates(host);observe("pulsation.dom.test.cjs:29:11", host.querySelectorAll('details').length);
ctx.state.selected='b';ctx.renderUpdates(host);observe("pulsation.dom.test.cjs:30:12", host.querySelectorAll('details').length);observe("pulsation.dom.test.cjs:30:13", host.querySelector('details').open);ctx.state.selected='a';
require('./components.cjs').load(ctx,['conversation']);
ctx.submitting=[];
ctx.renderAgentHeader();observe("pulsation.dom.test.cjs:33:14", window.document.querySelector('.send-button').disabled);
ctx.submitting.push('a');ctx.renderAgentHeader();observe("pulsation.dom.test.cjs:34:15", window.document.querySelector('.send-button').disabled);
// Two outputs published within the same millisecond retain output FIFO order.
Object.assign(ctx,{agent:id=>ctx.state.agents.find(a=>a.id===id),receiveWorkspaces:()=>{},displayTime:v=>v,chatResult:t=>({text:t.output}),delegationMessages:()=>{}});
ctx.state.agents=[{id:'a'}];ctx.state.selected='a';

ctx.applySnapshot({agents:[{id:'a',created:'2026-10-08T12:00:00Z'}],preferences:{},turns:[
 {id:'first',agent:'a',flow:'chat',created:'2026-10-08T12:00:00Z',status:'done',input:'A',output:'Later',output_at:'2026-10-08T12:00:04Z',output_order:2},
 {id:'second',agent:'a',flow:'chat',created:'2026-10-08T12:00:02Z',status:'done',input:'B',output:'Earlier',output_at:'2026-10-08T12:00:04Z',output_order:1}
]});
observe("pulsation.dom.test.cjs:43:16", ctx.state.messages.a.filter(m=>m.role==='assistant').map(m=>m.text).join(','));
