// Browser actions and observations; expectations are defined by RSpec.
const {observe,observeText,observeIdentity,attempt}=require('./observations.cjs');
const fs=require('node:fs'),vm=require('node:vm');
const {JSDOM}=require('../../libs4/node_modules/jsdom');
const {window}=new JSDOM(fs.readFileSync('web/shell/index.html','utf8'));
let now=10000,requests=[];
const tab={id:'file1',path:'/tmp/jokes.txt',title:'jokes.txt',url:'file:///tmp/jokes.txt',command:{seq:'1'},zoom:1};
const state={selected:'sapi_one',activeTab:'file1',tabs:[tab],panes:{workspace:true}};
const ctx=vm.createContext({document:window.document,window,state,Date:{now:()=>now},workspaceOwner:'sapi_one',
 $:selector=>window.document.querySelector(selector),$$:selector=>window.document.querySelectorAll(selector),
 paneLimit:()=>3,mention:()=>'',syncWorkspace:()=>{},syncNativeBrowser:()=>{},api:url=>new Promise((resolve,reject)=>requests.push({url,resolve,reject}))});
require('./components.cjs').load(ctx,['workspace']);ctx.syncNativeBrowser=()=>{};
const flush=()=>new Promise(resolve=>setImmediate(resolve));
(async()=>{
 ctx.renderWorkspace();observe("workspace_preview.test.cjs:14:1", requests.length);observeText("workspace_preview.test.cjs:14:2", requests[0].url);
 requests[0].resolve({content:'Joke one\n<script>alert(1)</script>'});await flush();
 let pre=window.document.querySelector('.workspace-text');observeText("workspace_preview.test.cjs:16:3", pre.textContent);observe("workspace_preview.test.cjs:16:4", pre.querySelector('script'));
 ctx.renderWorkspace();observe("workspace_preview.test.cjs:17:5", requests.length);observeIdentity("workspace_preview.test.cjs:17:6", window.document.querySelector('.workspace-text'), pre);
 now+=2100;ctx.refreshWorkspacePreview();requests[1].resolve({content:'Joke one\nJoke two'});await flush();observe("workspace_preview.test.cjs:18:7", pre.textContent);
 now+=2100;ctx.refreshWorkspacePreview();state.selected='sapi_two';state.tabs=[{...tab,id:'file2',path:'/tmp/other.txt'}];state.activeTab='file2';ctx.renderWorkspace();
 requests[2].resolve({content:'Stale reply'});requests[3].resolve({content:'Other file'});await flush();observe("workspace_preview.test.cjs:20:8", window.document.querySelector('.workspace-text').textContent);
 now+=2100;ctx.refreshWorkspacePreview();requests[4].reject(new Error('File not found'));await flush();observe("workspace_preview.test.cjs:21:9", window.document.querySelector('.workspace-text').textContent);
 state.panes.workspace=false;now+=2100;ctx.refreshWorkspacePreview();observe("workspace_preview.test.cjs:22:10", requests.length);
 window.webkit={messageHandlers:{browser:{}}};ctx.renderWorkspace();observe("workspace_preview.test.cjs:23:11", window.document.querySelector('#workspace-content').textContent);observe("workspace_preview.test.cjs:23:12", requests.length);

})().catch(error=>{console.error(error);process.exitCode=1;});
