const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {JSDOM}=require('jsdom');
const {window}=new JSDOM(fs.readFileSync('web/shell/index.html','utf8'));
let now=10000,requests=[];
const tab={id:'file1',path:'/tmp/jokes.txt',title:'jokes.txt',url:'file:///tmp/jokes.txt',command:{seq:'1'},zoom:1};
const state={selected:'sapi_one',activeTab:'file1',tabs:[tab],panes:{workspace:true}};
const ctx=vm.createContext({document:window.document,window,state,Date:{now:()=>now},workspaceOwner:'sapi_one',
 $:selector=>window.document.querySelector(selector),$$:selector=>window.document.querySelectorAll(selector),
 mention:()=>'',syncWorkspace:()=>{},syncNativeBrowser:()=>{},api:url=>new Promise((resolve,reject)=>requests.push({url,resolve,reject}))});
const source=fs.readFileSync('web/features/workspaces.js','utf8');
vm.runInContext('let editingAddress=null;'+source.slice(source.indexOf('function renderWorkspace()'),source.indexOf('function syncNativeBrowser()')),ctx);
const flush=()=>new Promise(resolve=>setImmediate(resolve));
(async()=>{
 ctx.renderWorkspace();assert.equal(requests.length,1);assert.match(requests[0].url,/sapi_one\/browser\/file1\/content/);
 requests[0].resolve({content:'Joke one\n<script>alert(1)</script>'});await flush();
 let pre=window.document.querySelector('.workspace-text');assert.match(pre.textContent,/<script>/);assert.equal(pre.querySelector('script'),null);
 ctx.renderWorkspace();assert.equal(requests.length,1);assert.equal(window.document.querySelector('.workspace-text'),pre);
 now+=2100;ctx.refreshWorkspacePreview();requests[1].resolve({content:'Joke one\nJoke two'});await flush();assert.equal(pre.textContent,'Joke one\nJoke two');
 now+=2100;ctx.refreshWorkspacePreview();state.selected='sapi_two';state.tabs=[{...tab,id:'file2',path:'/tmp/other.txt'}];state.activeTab='file2';ctx.renderWorkspace();
 requests[2].resolve({content:'Stale reply'});requests[3].resolve({content:'Other file'});await flush();assert.equal(window.document.querySelector('.workspace-text').textContent,'Other file');
 now+=2100;ctx.refreshWorkspacePreview();requests[4].reject(new Error('File not found'));await flush();assert.equal(window.document.querySelector('.workspace-text').textContent,'File not found');
 state.panes.workspace=false;now+=2100;ctx.refreshWorkspacePreview();assert.equal(requests.length,5);
 window.webkit={messageHandlers:{browser:{}}};ctx.renderWorkspace();assert.equal(window.document.querySelector('#workspace-content').textContent,'');assert.equal(requests.length,5);
 console.log('Workspace preview: scoped requests, literal text, updates, stale responses, errors and native rendering passed');
})().catch(error=>{console.error(error);process.exitCode=1;});
