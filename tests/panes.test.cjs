const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {JSDOM}=require('../libs4/node_modules/jsdom');

function setup({touch=true,width=390,height=844,panes={sidebar:true,chat:true,workspace:true},tabs=true}={}){
  const {window}=new JSDOM(fs.readFileSync('web/shell/index.html','utf8'));
  window.innerWidth=width;window.innerHeight=height;
  window.matchMedia=()=>({matches:touch});
  const orientation=new window.EventTarget();orientation.type=height>=width?'portrait-primary':'landscape-primary';
  Object.defineProperty(window.screen,'orientation',{value:orientation});
  window.HTMLDialogElement.prototype.close=function(){this.removeAttribute('open');};
  window.HTMLDialogElement.prototype.showModal=function(){this.setAttribute('open','');};
  window.webkit={messageHandlers:{browser:{postMessage(){}}}};
  const tab={id:'tab-test',url:'about:blank',title:'Test'};
  const state={selected:'sapi_test',agents:[{id:'sapi_test',name:'Test',kind:'sapi'}],panes:{...panes},
    workspaces:{sapi_test:{tabs:tabs?[tab]:[],activeTab:tabs?tab.id:null,bookmarks:[]}}};
  const ctx=vm.createContext({window,document:window.document,setTimeout,clearTimeout,
    bootstrap:{preferences:{}},makeInitialState:()=>state,
    ResizeObserver:class{observe(){}},MutationObserver:class{observe(){}},
    getComputedStyle:()=>({getPropertyValue:()=> '#fff'}),
    closeActivityMenus(){},api:async(path,method,data)=>{
      if(data?.op==='workspace_close')tabs=false;
      if(data?.op==='workspace_open')tabs=true;
      return {preferences:{workspace_revision:++revision,workspaces:{sapi_test:{tabs:tabs?[tab]:[],activeTab:tabs?tab.id:null,bookmarks:[]}}}};
    }});
  let revision=0;
  vm.runInContext(fs.readFileSync('web/shell/app.js','utf8')+'\n'+fs.readFileSync('web/features/workspaces.js','utf8'),ctx);
  vm.runInContext("let chatView='conversation';save=()=>{};render=()=>{renderPanes();};renderPanes();",ctx);
  const visible=()=>['sidebar','chat','workspace'].filter(p=>window.document.querySelector(`[data-toggle-pane="${p}"]`).getAttribute('aria-pressed')==='true');
  return {window,state,ctx,visible,
    click:p=>window.document.querySelector(`[data-toggle-pane="${p}"]`).click(),
    rotate:(width,height)=>{window.innerWidth=width;window.innerHeight=height;orientation.type=height>=width?'portrait-primary':'landscape-primary';orientation.dispatchEvent(new window.Event('change'));window.dispatchEvent(new window.Event('resize'));}};
}

(async()=>{
  const phone=setup();
  assert.deepEqual(phone.visible(),['chat'],'Portrait starts with one useful panel despite desktop preferences');
  for(const pane of ['sidebar','workspace','chat']){
    phone.click(pane);assert.deepEqual(phone.visible(),[pane]);
    phone.click(pane);assert.deepEqual(phone.visible(),[pane],'The selected portrait panel stays open');
  }
  phone.click('sidebar');vm.runInContext("openChat('sapi_test')",phone.ctx);
  assert.deepEqual(phone.visible(),['chat'],'Selecting a Sapi replaces the list with its chat');
  await vm.runInContext("browserAction('focus',{id:'tab-test'})",phone.ctx);
  assert.deepEqual(phone.visible(),['workspace'],'Opening a workspace also obeys portrait exclusivity');
  phone.rotate(844,390);phone.click('chat');
  assert.deepEqual(phone.visible(),['chat','workspace']);
  phone.click('sidebar');assert.deepEqual(phone.visible(),['sidebar','chat'],'The third selection replaces the oldest');
  phone.click('chat');assert.deepEqual(phone.visible(),['sidebar']);
  phone.click('sidebar');assert.deepEqual(phone.visible(),['sidebar'],'Keep one panel available');
  phone.click('workspace');phone.rotate(390,844);
  assert.deepEqual(phone.visible(),['workspace'],'Rotation keeps the last selected panel');
  phone.window.innerHeight=300;phone.window.dispatchEvent(new phone.window.Event('resize'));
  assert.deepEqual(phone.visible(),['workspace'],'The keyboard must not turn portrait into two-panel mode');
  assert.equal(phone.window.document.body.dataset.paneLimit,'1');
  await vm.runInContext("browserAction('close',{id:'tab-test'})",phone.ctx);
  assert.deepEqual(phone.visible(),['chat'],'Closing the last workspace tab leaves a useful panel');
  phone.window.document.querySelector('.wordmark').click();
  assert.deepEqual(phone.visible(),['chat'],'Reset layout still obeys the mobile limit');
  const doc=phone.window.document;
  vm.runInContext('renderSidebar=()=>{}',phone.ctx);
  assert.equal(doc.body.hasAttribute('data-mobile-ui'),true);
  phone.state.mainSapiId='sapi_test';
  doc.querySelector('[data-scope=sapis]').click();
  assert.deepEqual(phone.visible(),['sidebar'],'Changing roster filters keeps the roster visible');
  doc.querySelector('#search-toggle').click();
  assert.equal(doc.activeElement.id,'agent-search');
  assert.equal(doc.querySelector('#corpora-search').classList.contains('search-open'),true);
  doc.querySelector('#agent-search').value='query';
  doc.querySelector('#agent-search').dispatchEvent(new phone.window.KeyboardEvent('keydown',{key:'Escape'}));
  assert.equal(doc.querySelector('#agent-search').value,'');
  assert.equal(doc.querySelector('#search-toggle').getAttribute('aria-expanded'),'false');
  const input=doc.querySelector('#message-input');let contentHeight=96;
  input.getClientRects=()=>[{}];Object.defineProperty(input,'scrollHeight',{get:()=>contentHeight});
  input.dispatchEvent(new phone.window.Event('input'));assert.equal(input.style.height,'96px');
  contentHeight=220;input.dispatchEvent(new phone.window.Event('input'));assert.equal(input.style.height,'140px');
  contentHeight=20;input.dispatchEvent(new phone.window.Event('input'));assert.equal(input.style.height,'44px');
  vm.runInContext('appMenu()',phone.ctx);
  assert.equal(doc.querySelector('#modal').open,true);
  assert.ok(doc.querySelector('[data-menu-target="resource-button"]'));
  console.log(JSON.stringify({mainMenuTargets:Array.from(doc.querySelectorAll('#modal-content [data-menu-target]'),button=>button.dataset.menuTarget)}));
  let opened=0;vm.runInContext('computerDialog=()=>{}',phone.ctx);
  doc.querySelector('#resource-button').addEventListener('click',()=>opened++);
  doc.querySelector('[data-menu-target="resource-button"]').click();assert.equal(opened,1);
  phone.state.workspaces.sapi_test={tabs:[{id:'one',title:'One',url:'about:blank'},{id:'two',title:'Two',url:'about:blank'}],activeTab:'two'};
  vm.runInContext('syncWorkspace();renderTabs()',phone.ctx);
  assert.equal(doc.querySelector('#browser-overflow').hidden,false);
  assert.equal(doc.querySelector('#browser-tabs .active .tab-select').textContent,'Two');
  assert.equal(doc.querySelector('#browser-tabs .workspace-tab:not(.active)').hidden,true);
  assert.equal(doc.querySelectorAll('#browser-all-tabs .tab-close').length,2,'Tab management remains accessible from the picker');
  phone.window.close();

  const landscape=setup({width:844,height:390});
  assert.deepEqual(landscape.visible(),['sidebar','chat']);
  landscape.click('workspace');assert.deepEqual(landscape.visible(),['chat','workspace']);
  landscape.window.close();
  const narrow=setup({touch:false,width:390,height:844});
  assert.deepEqual(narrow.visible(),['chat']);narrow.window.close();
  const desktop=setup({touch:false,width:1440,height:900});
  assert.deepEqual(desktop.visible(),['sidebar','chat','workspace']);
  desktop.click('sidebar');assert.deepEqual(desktop.visible(),['chat','workspace']);
  desktop.click('sidebar');assert.deepEqual(desktop.visible(),['sidebar','chat','workspace']);
  assert.equal(desktop.window.document.body.hasAttribute('data-mobile-ui'),false);
  desktop.window.close();
  const noTabs=setup({tabs:false,panes:{sidebar:false,chat:false,workspace:true}});
  assert.deepEqual(noTabs.visible(),['chat']);
  noTabs.click('workspace');await new Promise(resolve=>setImmediate(resolve));
  assert.deepEqual(noTabs.visible(),['workspace'],'Opening the first tab selects the workspace');
  noTabs.window.close();
  console.log('Mobile panes: portrait exclusivity, landscape capacity, rotation, keyboard, navigation and desktop controls pass');
})().catch(error=>{console.error(error);process.exitCode=1;});
