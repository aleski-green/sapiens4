// Observe the shipped installation screen; assertions live in RSpec.
const fs=require('node:fs'),path=require('node:path');
const {JSDOM}=require('../../libs4/node_modules/jsdom');
const root=path.join(__dirname,'../..'),[platform,mode='browser']=process.argv.slice(2);
const dom=new JSDOM(fs.readFileSync(path.join(root,'web/shell/index.html'),'utf8'),{url:'https://relay.example/ios',runScripts:'outside-only'});
const w=dom.window,d=w.document;
const ua={ios:'Mozilla/5.0 (iPhone)',ipad:'Mozilla/5.0 (Macintosh)',android:'Mozilla/5.0 (Linux; Android 16)',linux:'Mozilla/5.0 (X11; Linux x86_64)'};
Object.defineProperty(w.navigator,'userAgent',{value:ua[platform]});
Object.defineProperty(w.navigator,'platform',{value:platform==='ipad'?'MacIntel':''});
Object.defineProperty(w.navigator,'maxTouchPoints',{value:platform==='ipad'?5:0});
w.matchMedia=()=>({matches:mode==='standalone'});
let network=0,prompts=0;
w.fetch=()=>{network++;throw new Error('Unexpected request');};
w.eval(fs.readFileSync(path.join(root,'web/features/remote-install.js'),'utf8'));
let legacyGuideOpened=false;
if(mode==='legacy'){
 // The previous cached workspace expects this control in the network HTML.
 d.querySelector('#mobile-install-gate').hidden=false;
 d.querySelector('#mobile-install-action').onclick=()=>legacyGuideOpened=true;
 d.querySelector('#mobile-install-action').click();
}else w.RemoteInstall.mount();
(async()=>{
 if(mode==='prompt'){
   const event=new w.Event('beforeinstallprompt',{cancelable:true});event.prompt=async()=>{prompts++;};w.dispatchEvent(event);
   const button=d.querySelector('#install-app'),offered=!button.hidden;button.click();await Promise.resolve();
   console.log(JSON.stringify({offered,prompts,hiddenAfter:button.hidden,gate:!d.querySelector('#mobile-install-gate').hidden,prevented:event.defaultPrevented}));
 }else{
   const gate=d.querySelector('#mobile-install-gate'),help=gate.querySelector('a');
   console.log(JSON.stringify({legacyGuideOpened,gate:!gate.hidden,title:gate.querySelector('h1')?.textContent,instructions:gate.querySelector('ol')?.textContent,help:help&&{href:help.href,target:help.target,rel:help.rel},words:gate.textContent.trim().split(/\s+/).length,network,storage:w.localStorage.length+w.sessionStorage.length,cookie:d.cookie}));
 }
 dom.window.close();
})();
