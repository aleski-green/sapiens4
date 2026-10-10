const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {JSDOM}=require('jsdom');

async function check(modifier,existing=false) {
  const {window}=new JSDOM(fs.readFileSync('web/shell/index.html','utf8'));
  const tab={id:'tab-test',url:existing?'https://example.com':'about:blank',title:'Test'};
  const state={selected:'sapi_test',agents:[{id:'sapi_test',name:'Test',kind:'sapi'}],
    panes:{sidebar:true,chat:true,workspace:true},
    workspaces:{sapi_test:{tabs:existing?[tab]:[],activeTab:existing?tab.id:null,bookmarks:[]}}};
  const requests=[];
  window.webkit={messageHandlers:{browser:{postMessage(){}}}};
  const ctx=vm.createContext({window,document:window.document,setTimeout,clearTimeout,
    bootstrap:{preferences:{}},makeInitialState:()=>state,
    ResizeObserver:class{observe(){}},MutationObserver:class{observe(){}},
    getComputedStyle:()=>({getPropertyValue:()=> '#fff'}),
    api:async (...args)=>{
      requests.push(args);
      return {preferences:{workspace_revision:1,workspaces:{sapi_test:{tabs:[tab],activeTab:tab.id,bookmarks:[]}}}};
    }});
  vm.runInContext(fs.readFileSync('web/shell/app.js','utf8')+'\n'+fs.readFileSync('web/features/workspaces.js','utf8'),ctx);
  vm.runInContext('save=()=>{};renderPanes();renderTabs();renderWorkspace();',ctx);
  assert.equal(window.document.querySelector('#workspace-panel').hidden,!existing);
  const event=new window.KeyboardEvent('keydown',{key:'l',[modifier]:true,bubbles:true,cancelable:true});
  window.document.dispatchEvent(event);
  await new Promise(resolve=>setImmediate(resolve));
  assert.equal(event.defaultPrevented,true);
  assert.equal(window.document.querySelector('#workspace-panel').hidden,false);
  assert.equal(window.document.querySelector('#browser-address-form').hidden,false);
  assert.equal(window.document.activeElement.id,'browser-address');
  assert.equal(state.activeTab,tab.id);
  assert.equal(requests.length,existing?0:2);
  if(!existing)assert.equal(requests[0][2].op,'workspace_open');
  window.close();
}
(async()=>{
  for(const modifier of ['metaKey','ctrlKey'])for(const existing of [false,true])await check(modifier,existing);
  console.log('Workspace keyboard: Cmd/Ctrl+L opens an empty workspace and edits an existing tab');
})().catch(error=>{console.error(error);process.exitCode=1;});
