// Browser actions and observations only; expectations are in panes_spec.rb.
const fs=require('node:fs'),vm=require('node:vm');
const {JSDOM}=require('../../libs4/node_modules/jsdom');

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
  require('./components.cjs').load(ctx,['panes','shell','workspace']);
  ctx.makeInitialState=()=>state;ctx.SapiensComponents.mountShell();ctx.SapiensComponents.mountWorkspace();
  Object.assign(ctx,{chatView:'conversation',save:()=>{},render:()=>ctx.renderPanes()});ctx.renderPanes();
  const visible=()=>['sidebar','chat','workspace'].filter(p=>window.document.querySelector(`[data-toggle-pane="${p}"]`).getAttribute('aria-pressed')==='true');
  return {window,state,ctx,visible,
    click:p=>window.document.querySelector(`[data-toggle-pane="${p}"]`).click(),
    rotate:(width,height)=>{window.innerWidth=width;window.innerHeight=height;orientation.type=height>=width?'portrait-primary':'landscape-primary';orientation.dispatchEvent(new window.Event('change'));window.dispatchEvent(new window.Event('resize'));}};
}

(async()=>{
  const out={},phone=setup();
  out.initial=phone.visible();out.selected=[];
  for(const pane of ['sidebar','workspace','chat']){
    phone.click(pane);const opened=phone.visible();
    phone.click(pane);out.selected.push({pane,opened,repeated:phone.visible()});
  }
  phone.click('sidebar');vm.runInContext("openChat('sapi_test')",phone.ctx);out.openChat=phone.visible();
  await vm.runInContext("browserAction('focus',{id:'tab-test'})",phone.ctx);out.focusWorkspace=phone.visible();
  phone.rotate(844,390);phone.click('chat');out.rotatedLandscape=phone.visible();
  phone.click('sidebar');out.thirdPane=phone.visible();
  phone.click('chat');out.closedChat=phone.visible();
  phone.click('sidebar');out.lastPane=phone.visible();
  phone.click('workspace');phone.rotate(390,844);out.rotatedPortrait=phone.visible();
  phone.window.innerHeight=300;phone.window.dispatchEvent(new phone.window.Event('resize'));
  out.keyboard={panes:phone.visible(),limit:phone.window.document.body.dataset.paneLimit};
  await vm.runInContext("browserAction('close',{id:'tab-test'})",phone.ctx);out.closedLastTab=phone.visible();
  phone.window.document.querySelector('.wordmark').click();out.resetLayout=phone.visible();
  const doc=phone.window.document;
  vm.runInContext('renderSidebar=()=>{}',phone.ctx);
  out.mobile=doc.body.hasAttribute('data-mobile-ui');phone.state.mainSapiId='sapi_test';
  doc.querySelector('[data-scope=sapis]').click();out.rosterFilter=phone.visible();
  doc.querySelector('#search-toggle').click();
  out.search={focused:doc.activeElement.id,open:doc.querySelector('#corpora-search').classList.contains('search-open')};
  doc.querySelector('#agent-search').value='query';
  doc.querySelector('#agent-search').dispatchEvent(new phone.window.KeyboardEvent('keydown',{key:'Escape'}));
  out.search.closedValue=doc.querySelector('#agent-search').value;
  out.search.expanded=doc.querySelector('#search-toggle').getAttribute('aria-expanded');
  const input=doc.querySelector('#message-input');let contentHeight=96;
  input.getClientRects=()=>[{}];Object.defineProperty(input,'scrollHeight',{get:()=>contentHeight});
  out.composer=[];
  for(const height of [96,220,20]){contentHeight=height;input.dispatchEvent(new phone.window.Event('input'));out.composer.push(input.style.height);}
  vm.runInContext('appMenu()',phone.ctx);
  out.menu={open:doc.querySelector('#modal').open,resource:!!doc.querySelector('[data-menu-target="resource-button"]'),
    targets:Array.from(doc.querySelectorAll('#modal-content [data-menu-target]'),button=>button.dataset.menuTarget)};
  let opened=0;vm.runInContext('computerDialog=()=>{}',phone.ctx);
  doc.querySelector('#resource-button').addEventListener('click',()=>opened++);
  doc.querySelector('[data-menu-target="resource-button"]').click();out.menu.opened=opened;
  phone.state.workspaces.sapi_test={tabs:[{id:'one',title:'One',url:'about:blank'},{id:'two',title:'Two',url:'about:blank'}],activeTab:'two'};
  vm.runInContext('syncWorkspace();renderTabs()',phone.ctx);
  out.tabs={overflowHidden:doc.querySelector('#browser-overflow').hidden,selected:doc.querySelector('#browser-tabs .active .tab-select').textContent,
    otherHidden:doc.querySelector('#browser-tabs .workspace-tab:not(.active)').hidden,closeButtons:doc.querySelectorAll('#browser-all-tabs .tab-close').length};
  phone.window.close();
  const landscape=setup({width:844,height:390});out.landscape={initial:landscape.visible()};
  landscape.click('workspace');out.landscape.selected=landscape.visible();landscape.window.close();
  const narrow=setup({touch:false,width:390,height:844});out.narrow=narrow.visible();narrow.window.close();
  const desktop=setup({touch:false,width:1440,height:900});out.desktop={initial:desktop.visible()};
  desktop.click('sidebar');out.desktop.closed=desktop.visible();
  desktop.click('sidebar');out.desktop.reopened=desktop.visible();
  out.desktop.mobile=desktop.window.document.body.hasAttribute('data-mobile-ui');desktop.window.close();
  const noTabs=setup({tabs:false,panes:{sidebar:false,chat:false,workspace:true}});out.noTabs={initial:noTabs.visible()};
  noTabs.click('workspace');await new Promise(resolve=>setImmediate(resolve));out.noTabs.opened=noTabs.visible();noTabs.window.close();
  console.log(JSON.stringify(out));
})().catch(error=>{console.error(error);process.exitCode=1;});
