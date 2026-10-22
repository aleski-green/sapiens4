// Exercise the shipped click handler at the service-worker/navigation boundary.
const fs=require('node:fs'),vm=require('node:vm');
const {JSDOM}=require('../../tests/node_modules/jsdom');
const scenario=process.argv[2];
const dom=new JSDOM(fs.readFileSync('web/shell/index.html','utf8'),{url:'https://relay.example/beta'});
const w=dom.window,d=w.document,events=[];
const ios=!['android','desktop'].includes(scenario),installed=scenario!=='browser';
const navigator={userAgent:ios?'iPhone':scenario==='android'?'Android':'Linux',standalone:installed};
w.matchMedia=()=>({matches:installed});
if(scenario!=='desktop')d.body.setAttribute('data-remote','');
const input=d.querySelector('#message-input');input.value='Unsent draft';
w.localStorage.setItem('saved-connection','unchanged');
w.sapiensWorkspace={save(){w.localStorage.setItem('saved-draft',input.value);events.push('save');}};
const worker=new w.EventTarget();worker.state=['update','failed'].includes(scenario)?'installing':'activated';
let deadline,updates=0,reloads=0,normalClicks=0;
const registration={active:worker.state==='activated'?worker:null,installing:worker.state==='installing'?worker:null,
 update:async()=>{updates++;events.push('check');if(scenario==='offline')throw new Error('Offline');if(scenario==='timeout')await new Promise(()=>{});}};
if(scenario!=='no-worker')navigator.serviceWorker={getRegistration:async()=>registration};
vm.runInNewContext(fs.readFileSync('web/features/remote-install.js','utf8'),{
 window:w,document:d,navigator,location:{reload(){reloads++;events.push('reload');}},
 setTimeout:fn=>{deadline=fn;return 1;},clearTimeout:()=>{deadline=null;}
});
d.querySelector('.wordmark').addEventListener('click',event=>{event.preventDefault();normalClicks++;});
const settle=async()=>{for(let i=0;i<6;i++)await new Promise(setImmediate);};
(async()=>{
 d.querySelector('.brand-name').click();await settle();
 const beforeActivation=reloads;
 if(['update','failed'].includes(scenario)){
   d.querySelector('.wordmark').click();input.value='Draft edited while checking';
   worker.state=scenario==='failed'?'redundant':'activated';events.push(worker.state);
   worker.dispatchEvent(new w.Event('statechange'));
 }
 if(scenario==='timeout')deadline();
 await settle();
 console.log(JSON.stringify({updates,reloads,normalClicks,beforeActivation,events,
   draft:w.localStorage.getItem('saved-draft'),connection:w.localStorage.getItem('saved-connection'),
   label:d.querySelector('.wordmark').getAttribute('aria-label')}));
 dom.window.close();
})().catch(error=>{console.error(error);process.exitCode=1;});
