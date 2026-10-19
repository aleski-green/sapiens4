if(document.body.hasAttribute('data-remote')&&navigator.standalone){
 const output=document.createElement('output');output.style.cssText='position:fixed;top:0;left:0;right:0;z-index:99999;background:#fff;color:#111;font:9px monospace;padding:2px;pointer-events:none;white-space:pre-wrap;overflow-wrap:anywhere';document.body.append(output);
 let events=JSON.parse(localStorage.getItem('scroll-check')||'[]');
 const note=event=>{
  const key=JSON.parse(localStorage.getItem('s4.active')||'null'),saved=JSON.parse(localStorage.getItem('s4.workspace.'+key)||'null'),v=document.querySelector('#conversation-body');
  events.push(event+':'+Math.round(v.scrollTop)+'/'+v.clientHeight+' '+(document.hidden?'H':'V')+' saved='+Math.round(saved?.scroll)+' '+saved?.chatPosition?.key?.slice(-6));events=events.slice(-7);localStorage.setItem('scroll-check',JSON.stringify(events));output.textContent=events.join('\n');
 };
 note('load');
 document.querySelector('#conversation-body').addEventListener('scroll',()=>note('scroll'),{passive:true});
 document.addEventListener('visibilitychange',()=>note('visibility'));
 for(const e of ['pagehide','pageshow','resize'])window.addEventListener(e,()=>note(e));
}
