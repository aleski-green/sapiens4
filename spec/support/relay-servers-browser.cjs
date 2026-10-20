// Drive the shipped selector against a real isolated host; assertions live in RSpec.
const fs=require('node:fs'),path=require('node:path'),{webcrypto}=require('node:crypto');
const {JSDOM}=require('../../tests/node_modules/jsdom');
const root=path.resolve(__dirname,'../..'),url=process.argv[2],scenario=process.argv[3];
const wait=async fn=>{for(let i=0;i<250;i++){if(fn())return;await new Promise(r=>setTimeout(r,20));}throw new Error('Browser action timed out');};
(async()=>{
 const dom=new JSDOM(fs.readFileSync(path.join(root,'web/shell/index.html'),'utf8'),{url:url+'/workspace/',runScripts:'outside-only',pretendToBeVisual:true});
 const w=dom.window,d=w.document,writes=[];
 Object.defineProperty(w,'crypto',{value:webcrypto});w.AbortSignal=AbortSignal;
 w.HTMLDialogElement.prototype.showModal=function(){this.open=true;};w.HTMLDialogElement.prototype.close=function(){this.open=false;};
 w.matchMedia=()=>({matches:false,addEventListener(){}});
 w.fetch=async(p,options={})=>{if(options.method==='POST')writes.push({url:p,data:JSON.parse(options.body)});return fetch(new URL(p,url),options);};
 for(const script of ['remote-install','relay-servers','corpora'])w.eval(fs.readFileSync(path.join(root,'web/features',script+'.js'),'utf8'));
 const click=selector=>{const el=d.querySelector(selector);if(!el)throw new Error('Missing '+selector);el.click();};
 const text=selector=>d.querySelector(selector)?.textContent;
 const rows=()=>Array.from(d.querySelectorAll('.relay-row')).map(row=>({name:row.querySelector('strong').textContent,current:row.dataset.current==='true',disabled:row.querySelector('input').disabled}));
 const submit=()=>d.querySelector('#relay-editor').dispatchEvent(new w.Event('submit',{bubbles:true,cancelable:true}));
 const listed=()=>wait(()=>d.querySelector('#relay-list'));
 await wait(()=>w.SapiensConnections.connected);
 click('#corpora-picker');click('#manage-relay-servers');await listed();
 const out={heading:text('#corpora-dialog-title'),initial:rows(),archivedDefault:d.querySelector('#relay-archived').checked};
 if(scenario==='terms'){
   click('#corpora-dialog-close');await new Promise(r=>setTimeout(r,30));
   await w.SapiensConnections.remoteControl(w.SapiensConnections.active);await listed();click('#relay-continue');
   out.terms=text('#corpora-dialog-body');out.gated=d.querySelector('#relay-beta-use').disabled;
   click('#relay-accept');out.acceptEnabled=!d.querySelector('#relay-beta-use').disabled;click('#relay-beta-use');
   await wait(()=>d.querySelector('[data-remote-action="pair"]'));out.accepted=writes.some(row=>row.data.action==='accept-beta'&&row.data.accepted===true);
 }else{
   click('#relay-add');out.guide=d.querySelector('#corpora-dialog-body a').href;
   let form=d.querySelector('#relay-editor');form.elements.name.value='Office';form.elements.connection.value=JSON.stringify({format:'sapiens-relay-connection-v1',relay:'http://public.example',token:'t'.repeat(32)});submit();
   out.invalid=text('#relay-feedback');out.invalidWrites=writes.length;
   const config={format:'sapiens-relay-connection-v1',relay:'http://127.0.0.1:4180',token:'t'.repeat(32)};
   Object.defineProperty(form.elements.file,'files',{value:[{size:200,text:async()=>JSON.stringify(config)}],configurable:true});
   form.elements.file.dispatchEvent(new w.Event('change'));await wait(()=>form.elements.connection.value.includes('127.0.0.1'));submit();await listed();
   out.saved=rows();out.scrolling=d.querySelector('#relay-list').classList.contains('relay-scroll');
   let id=d.querySelector('.relay-row:last-child input').value;
   click('[data-edit-relay="'+id+'"]');await wait(()=>d.querySelector('#relay-editor'));
   form=d.querySelector('#relay-editor');out.prefill={name:form.elements.name.value,connection:JSON.parse(form.elements.connection.value)};
   form.elements.name.value='Office renamed';submit();await listed();
   click('[data-archive-relay="'+id+'"]');await wait(()=>!d.querySelector('[data-edit-relay="'+id+'"]'));
   out.hidden=rows().length;click('#relay-archived');out.archived=rows().find(row=>row.name==='Office renamed');
   click('[data-archive-relay="'+id+'"]');await wait(()=>d.querySelector('[data-archive-relay="'+id+'"]')?.textContent==='Archive');
   click('input[value="'+id+'"]');out.warning=text('#corpora-dialog-body');out.focus=d.activeElement.textContent;
   click('#relay-cancel');out.cancelled=rows().find(row=>row.current).name;
   click('input[value="'+id+'"]');click('#relay-confirm');await wait(()=>d.querySelector('.relay-row[data-current="true"] strong')?.textContent==='Office renamed');
   out.selected=rows().find(row=>row.current).name;
   click('[data-edit-relay="'+id+'"]');await wait(()=>d.querySelector('#relay-editor'));
   form=d.querySelector('#relay-editor');form.elements.connection.value=JSON.stringify({...config,token:'u'.repeat(32)});submit();out.editWarning=text('#corpora-dialog-title');
   click('#relay-cancel');out.keptDraft=JSON.parse(d.querySelector('#relay-editor').elements.connection.value).token==='u'.repeat(32);
   submit();click('#relay-confirm');await listed();
   out.resetWrites=writes.filter(row=>row.data.confirm_revoke).map(row=>row.data.action);
   out.cached=JSON.parse(w.localStorage.getItem('s4.records')).map(row=>row.location);
   out.bodyHasToken=text('#corpora-dialog-body').includes('t'.repeat(32));
 }
 console.log(JSON.stringify(out));dom.window.close();
})().catch(error=>{console.error(error);process.exit(1);});
