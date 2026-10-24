// Browser actions and observations; expectations are defined by RSpec.
const {observe,observeText,observeIdentity,attempt}=require('./observations.cjs');
const fs=require('node:fs'),vm=require('node:vm');
const {JSDOM}=require('../../libs4/node_modules/jsdom');
const {window}=new JSDOM(fs.readFileSync('web/shell/index.html','utf8'));
const messages=[],state={selected:'sapi_one',activeTab:null,workspaces:{},tabs:[],panes:{workspace:true}};
let owner={kind:'sapi'};
window.webkit={messageHandlers:{browser:{postMessage:message=>messages.push(message)}}};
const live={orchestration:{sapi_one:{notes:{path:''}}}};
const ctx=vm.createContext({window,document:window.document,state,live,bootstrap:{preferences:{}},
 $:s=>window.document.querySelector(s),selected:()=>owner,openNewTab:()=>{},
 ResizeObserver:class{observe(){}},MutationObserver:class{observe(){}},
 getComputedStyle:()=>({getPropertyValue:name=>name==='--sapi-white'?'#212121':'#ececec'})});
require('./components.cjs').load(ctx,['workspace','mountWorkspace']);
for(const path of ['C:\\Users\\Test user\\مرحبا\\Notes.html','/Users/Test user/مرحبا/Notes.html']) {
 live.orchestration.sapi_one.notes.path=path;
 window.document.querySelector('#open-file').click();
 const request=messages.at(-1);
 observe("workspace_bridge.test.cjs:17:1", request.owner);
 observe("workspace_bridge.test.cjs:18:2", request.directory);
 observe("workspace_bridge.test.cjs:19:3", request.pickFile);
}
state.selected='group_test';owner={kind:'group',workspace:'C:\\Groups\\Shared files'};
window.document.querySelector('#open-file').click();
observe("workspace_bridge.test.cjs:23:4", messages.at(-1).directory);
observe("workspace_bridge.test.cjs:24:5", messages.at(-1).owner);
window.document.documentElement.dataset.theme='dark';ctx.syncNativeBrowser();
observe("workspace_bridge.test.cjs:26:6", messages.at(-1).dark);
observe("workspace_bridge.test.cjs:27:7", messages.at(-1).background);
observe("workspace_bridge.test.cjs:28:8", messages.at(-1).foreground);
window.close();
