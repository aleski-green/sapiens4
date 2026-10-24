// Runs the shipped workspace with fixture API responses; RSpec owns assertions.
const fs=require('node:fs'),path=require('node:path');
const {JSDOM}=require('../../libs4/node_modules/jsdom');
const root=path.resolve(__dirname,'../..');
const read=name=>fs.readFileSync(path.join(root,name),'utf8');
const sapi=(id,name)=>({id,name,created:'2026-10-01T00:00:00Z',role:'Test',face:'^_^',color:'#48c99c'});
const turn=(id,agent='chief')=>({id,agent,flow:'chat',status:'done',created:'2026-10-01T00:00:00Z',input:'Request '+id,output:'Reply '+id,output_at:'2026-10-01T00:00:01Z'});
let snapshot={corpora:{id:'corpora',name:'Test',status:'active'},main_agent_id:'chief',agents:[sapi('chief','ChiefSapi'),sapi('other','Other')],
 preferences:{selected:'chief',panes:{chat:true,sidebar:false,workspace:false}},turns:[turn('one'),turn('two'),turn('three')],
 groups:[{id:'group_test',name:'Group',kind:'group',lead:'chief',members:['chief','other'],color:'#48c99c',face:'^_^',updated:'2026-10-01T00:00:00Z',
 messages:[{id:'g1',author:'admin',text:'Hello group',created:'2026-10-01T00:00:00Z'},{id:'g2',author:'chief',text:'Group reply',created:'2026-10-01T00:00:01Z'}],requests:[],tasks:[],events:[]}],
 computer:{built:false},orchestration:{},activity:{},run_activity:{},events:{},workloads:[],pulses:[],routines:[]};
const copy=()=>JSON.parse(JSON.stringify(snapshot));
(async()=>{
 const dom=new JSDOM(read('web/shell/index.html'),{url:'https://fixture.example/',runScripts:'outside-only',pretendToBeVisual:true});
 const w=dom.window,d=w.document,timers=[],errors=[];let subscriber;
 w.addEventListener('error',e=>errors.push(e.message));
 w.matchMedia=()=>({matches:false,addEventListener(){}});
 w.ResizeObserver=class{observe(){} disconnect(){}};
 w.HTMLDialogElement.prototype.close=function(){this.open=false;};w.HTMLDialogElement.prototype.showModal=function(){this.open=true;};
 w.setTimeout=(fn,ms)=>{timers.push({fn,ms});return timers.length;};w.clearTimeout=()=>{};
 w.SapiensConnections={initial:Promise.resolve(copy()),connected:true,generation:0,remote:true,active:{location:'Remote'},save(){},snapshot(){},
   subscribe(fn){subscriber=fn;fn(copy());},fetch:async()=>({ok:true,json:async()=>copy()})};
 const scripts=[...read('sapiens/corpora/host/assets.py').split('SCRIPTS = (')[1].split(')')[0].matchAll(/"([^"]+\.js)"/g)].map(m=>read('web/'+m[1])).join('\n');
 await w.eval('(async()=>{'+scripts+'})()');
 const host=d.querySelector('#conversation-body');
 // Layout boundary: JSDOM has no layout. Simulate fixed-height rows and count
 // scroll writes separately from the real browser visual check.
 let position=0,writes=0;
 Object.defineProperties(host,{clientHeight:{get:()=>200},scrollHeight:{get:()=>host.children.length*100},scrollTop:{get:()=>position,set:v=>{writes++;position=Math.max(0,Math.min(v,host.scrollHeight-200));}}});
 host.getBoundingClientRect=()=>({top:0,bottom:200});
 w.HTMLElement.prototype.getBoundingClientRect=function(){const i=[...host.children].indexOf(this);return {top:i*100-position,bottom:(i+1)*100-position};};
 const poll=async()=>{const timer=timers.findLast(t=>t.ms===750||t.ms===2000);await timer.fn();};
 const mark=()=>{host.scrollTop=220;writes=0;return [...host.querySelectorAll('.message')];};
 const retained=nodes=>nodes.every(node=>node.isConnected);
 const results={};
 let nodes=mark();snapshot.events={chief:[{id:1}]};await poll();
 results.unrelated={retained:retained(nodes),writes,scroll:position};
 host.scrollTop=host.scrollHeight-host.clientHeight-30;const nearBottom=position;writes=0;
 snapshot.events={chief:[{id:2}]};await poll();results.nearBottom={writes,before:nearBottom,after:position};
 nodes=mark();snapshot.turns.push(turn('four'));await poll();
 results.append={retained:retained(nodes),writes,scroll:position,messages:host.querySelectorAll('.message').length};
 host.scrollTop=host.scrollHeight;writes=0;snapshot.turns.push(turn('five'));await poll();
 results.bottom={scroll:position,max:host.scrollHeight-host.clientHeight};
 nodes=mark();snapshot.turns[0].output='Changed reply';await poll();
 results.update={laterRetained:nodes.filter(node=>!node.textContent.includes('Reply one')).every(node=>node.isConnected),text:host.textContent,scroll:position};
 nodes=mark();const input=d.querySelector('#message-input');input.value='Keep my draft';input.dispatchEvent(new w.Event('input'));input.focus();
 subscriber(copy());results.reconnect={retained:retained(nodes),scroll:position,draft:input.value,focused:d.activeElement===input};
 nodes=mark();const anchor=nodes[1],offset=anchor.getBoundingClientRect().top;
 const older=turn('older');older.created='2026-09-01T00:00:00Z';older.output_at='2026-09-01T00:00:01Z';snapshot.turns.unshift(older);await poll();
 results.prepend={retained:retained(nodes),offset,after:anchor.getBoundingClientRect().top};
 d.querySelector('.wordmark').click();results.navigate={scroll:position,max:host.scrollHeight-host.clientHeight};
 // Select group through the normal chat list.
 d.querySelector('[data-scope="groups"]').click();d.querySelector('[data-agent="group_test"] .agent-name').click();
 nodes=mark();snapshot.groups[0].messages.push({id:'g3',author:'chief',text:'Another group reply',created:'2026-10-01T00:00:02Z'});await poll();
 results.group={retained:retained(nodes),messages:host.querySelectorAll('.message').length,text:host.textContent};
 // A clarification button must follow a changed assignee, not a retained callback.
 d.querySelector('.wordmark').click();
 snapshot.workloads=[{id:'work',callId:'one',taskId:'task',owner:'chief',participants:['chief','other'],state:'WaitingForAdmin',origin:{agent:'chief',call:'one'}}];await poll();
 snapshot.workloads[0].owner='other';await poll();
 [...host.querySelectorAll('button')].find(button=>button.textContent==='Answer Chief').click();
 results.clarify={heading:d.querySelector('#agent-heading h2').textContent};
 results.errors=errors;
 console.log(JSON.stringify(results));dom.window.close();
})().catch(e=>{console.error(e);process.exitCode=1;});
