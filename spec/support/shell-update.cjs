const fs=require('node:fs'),vm=require('node:vm');
const source=fs.readFileSync('web/shell/sw.js','utf8');
async function scenario(fail,online=false){
 const handlers={},events=[];let ready,assets=[];
 const scope={self:{location:{origin:'https://app.example'},addEventListener:(name,fn)=>handlers[name]=fn,skipWaiting:()=>events.push('activate-ready')},URL,
  caches:{open:async()=>({addAll:async paths=>{assets=Array.from(paths);events.push('download');if(fail)throw new Error('offline');events.push('complete');},match:async()=> 'new shell'}),match:async()=> 'old shell',keys:async()=>[]},fetch:async()=>{if(online){events.push('network-newer-shell');return 'newer incompatible shell';}throw new Error('offline');}};
 vm.runInNewContext(source,scope);
 handlers.install({waitUntil:p=>ready=p});await ready.catch(()=>events.push('failed'));
 let response;handlers.fetch({request:{method:'GET',url:'https://app.example/workspace/app.js'},respondWith:p=>response=p});
 const asset=await response;
 handlers.fetch({request:{method:'GET',url:'https://app.example/',mode:'navigate'},respondWith:p=>response=p});
 return {events,assets,asset,offlinePage:await response};
}
Promise.all([scenario(false),scenario(true),scenario(false,true)]).then(([success,failure,online])=>console.log(JSON.stringify({success,failure,online})));
