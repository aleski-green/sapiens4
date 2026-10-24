// Browser actions and observations; expectations are defined by RSpec.
const {observe,observeText,observeIdentity,attempt}=require('./observations.cjs');
const fs=require('node:fs'),vm=require('node:vm');
const {JSDOM}=require('../../libs4/node_modules/jsdom');

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
  require('./components.cjs').load(ctx,['panes','shell','workspace']);
  ctx.makeInitialState=()=>state;ctx.SapiensComponents.mountShell();ctx.SapiensComponents.mountWorkspace();
  ctx.save=()=>{};ctx.renderPanes();ctx.renderTabs();ctx.renderWorkspace();
  observe("workspace_keyboard.test.cjs:22:1", window.document.querySelector('#workspace-panel').hidden);
  const event=new window.KeyboardEvent('keydown',{key:'l',[modifier]:true,bubbles:true,cancelable:true});
  window.document.dispatchEvent(event);
  await new Promise(resolve=>setImmediate(resolve));
  observe("workspace_keyboard.test.cjs:26:2", event.defaultPrevented);
  observe("workspace_keyboard.test.cjs:27:3", window.document.querySelector('#workspace-panel').hidden);
  observe("workspace_keyboard.test.cjs:28:4", window.document.querySelector('#browser-address-form').hidden);
  observe("workspace_keyboard.test.cjs:29:5", window.document.activeElement.id);
  observe("workspace_keyboard.test.cjs:30:6", state.activeTab);
  observe("workspace_keyboard.test.cjs:31:7", requests.length);
  if(!existing)observe("workspace_keyboard.test.cjs:32:8", requests[0][2].op);
  window.close();
}
(async()=>{
  for(const modifier of ['metaKey','ctrlKey'])for(const existing of [false,true])await check(modifier,existing);

})().catch(error=>{console.error(error);process.exitCode=1;});
