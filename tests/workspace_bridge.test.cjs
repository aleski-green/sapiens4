const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {JSDOM}=require('jsdom');
const {window}=new JSDOM(fs.readFileSync('web/shell/index.html','utf8'));
const messages=[],state={selected:'sapi_one',activeTab:null,workspaces:{},tabs:[],panes:{workspace:true}};
let owner={kind:'sapi'};
window.webkit={messageHandlers:{browser:{postMessage:message=>messages.push(message)}}};
const live={orchestration:{sapi_one:{notes:{path:''}}}};
const ctx=vm.createContext({window,document:window.document,state,live,bootstrap:{preferences:{}},
 $:s=>window.document.querySelector(s),selected:()=>owner,openNewTab:()=>{},
 ResizeObserver:class{observe(){}},MutationObserver:class{observe(){}},
 getComputedStyle:()=>({getPropertyValue:name=>name==='--sapi-white'?'#212121':'#ececec'})});
vm.runInContext(fs.readFileSync('web/features/workspaces.js','utf8'),ctx);
for(const path of ['C:\\Users\\Test user\\مرحبا\\Notes.html','/Users/Test user/مرحبا/Notes.html']) {
 live.orchestration.sapi_one.notes.path=path;
 window.document.querySelector('#open-file').click();
 const request=messages.at(-1);
 assert.equal(request.owner,'sapi_one');
 assert.equal(request.directory,path.slice(0,-11));
 assert.equal(request.pickFile,true);
}
state.selected='group_test';owner={kind:'group',workspace:'C:\\Groups\\Shared files'};
window.document.querySelector('#open-file').click();
assert.equal(messages.at(-1).directory,owner.workspace);
assert.equal(messages.at(-1).owner,'group_test');
window.document.documentElement.dataset.theme='dark';ctx.syncNativeBrowser();
assert.equal(messages.at(-1).dark,true);
assert.equal(messages.at(-1).background,'#212121');
assert.equal(messages.at(-1).foreground,'#ececec');
window.close();
console.log('Native bridge: Windows/macOS file directories, Group ownership and theme palette passed');
