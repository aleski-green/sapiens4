if(document.body.hasAttribute('data-remote')&&navigator.standalone){
 const output=document.createElement('output');output.style.cssText='position:fixed;top:0;left:0;right:0;z-index:99999;background:#fff;color:#111;font:10px monospace;padding:2px;pointer-events:none';document.body.append(output);
 setInterval(()=>{
  const key=JSON.parse(localStorage.getItem('s4.active')||'null'),saved=JSON.parse(localStorage.getItem('s4.workspace.'+key)||'null'),viewport=document.querySelector('#conversation-body');
  output.textContent='SC1 anchorCode='+String(window.sapiensWorkspace?.save).includes('workspacePreferences')+' saved='+JSON.stringify(saved?.chatPosition)+' y='+Math.round(viewport?.scrollTop)+' oldY='+Math.round(saved?.scroll);
 },500);
}
