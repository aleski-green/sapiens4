// Browser state has one writer: the host API. Native views report live navigation.
let workspaceRevision = bootstrap.preferences.workspace_revision || 0;
function receiveWorkspaces(prefs) {
  if ((prefs.workspace_revision || 0) <= workspaceRevision) return;
  workspaceRevision = prefs.workspace_revision;
  state.workspaces = prefs.workspaces || {};
  syncWorkspace();
}
function browserDestination(value) {
  return /^(https?:|file:|about:)/i.test(value) ? {url:value} : {path:value};
}
async function browserAction(action, fields={}, owner=state.selected) {
  try {
    await api(`/api/agents/${owner}/control`, 'POST', {op:`workspace_${action}`,...fields});
    const snapshot=await api('/api/state');
    receiveWorkspaces(snapshot.preferences);
    if (action==='open' || action==='focus') state.panes.workspace=true;
    renderPanes();renderTabs();renderWorkspace();save();
  } catch (error) {toast(error.message);}
}
function renderTabs() {
  syncWorkspace();
  $('#browser-tabs').innerHTML=state.tabs.map(t=>`<div class="workspace-tab ${t.id===state.activeTab?'active':''}"><button class="tab-select" data-tab="${esc(t.id)}" aria-pressed="${t.id===state.activeTab}" title="${esc(t.path || t.url)}">${esc(t.title || 'New tab')}</button><button class="tab-close" data-close-tab="${esc(t.id)}" aria-label="Close ${esc(t.title)}">×</button></div>`).join('');
}
function renderWorkspace() {
  syncWorkspace();
  $('#workspace-owner').innerHTML=`${mention(workspaceOwner)}<span>’s browser</span>`;
  const t=state.tabs.find(t=>t.id===state.activeTab);
  if (document.activeElement!==$('#browser-address')) $('#browser-address').value=t?.path || (t?.url==='about:blank'?'':t?.url) || '';
  $('#browser-zoom').textContent=`${Math.round((t?.zoom || 1)*100)}%`;
  $('#browser-status').textContent=t?.error || (t?.loading?'Loading…':'');
  $$('[data-browser-action]').forEach(b=>b.disabled=!t || (b.dataset.browserAction==='back'&&!t.can_back) || (b.dataset.browserAction==='forward'&&!t.can_forward));
  $('#workspace-content').textContent=window.webkit?.messageHandlers?.browser ? (t?'':'Open a URL or file to get started.') : 'Open Sapiens4 desktop to use the tabbed browser.';
  syncNativeBrowser();
}
function syncNativeBrowser() {
  const bridge=window.webkit?.messageHandlers?.browser;
  if (!bridge) return;
  const rect=$('#workspace-content').getBoundingClientRect();
  bridge.postMessage({workspaces:state.workspaces,owner:state.selected,active:state.activeTab,
    visible:!!state.panes.workspace && !$('#modal').open, dark:document.documentElement.dataset.theme==='dark',
    rect:{x:rect.x,y:rect.y,width:rect.width,height:rect.height}});
}
// Only the trusted app webview owns this callback; guest browser views have no bridge.
let browserReports=Promise.resolve();
window.sapiensBrowserEvent = data => {
  browserReports=browserReports.then(async()=>{
    if (data.open) return browserAction('open',{url:data.open},data.owner);
    if (data.file) return browserAction('open',{path:data.file},data.owner);
    if (data.action) return browserAction(data.action,data.fields || {},data.owner);
    await api(`/api/agents/${data.owner}/browser`,'POST',data);
    const snapshot=await api('/api/state');receiveWorkspaces(snapshot.preferences);
    renderTabs();renderWorkspace();
  }).catch(error=>toast(error.message));
};
function addTabDialog() {
  modal('Open tab',`<form id="browser-open-form" class="form-stack"><label>URL or file path<input name="address" placeholder="https://… or /Users/…" required autofocus></label><button class="button primary">Open</button></form>`);
}
function showBookmarks() {
  const bookmarks=state.workspaces[state.selected]?.bookmarks || [];
  modal('Bookmarks',bookmarks.length ? bookmarks.map(b=>`<div class="bookmark-row"><button data-bookmark-open="${esc(b.url)}">${esc(b.title)}</button><button data-bookmark-remove="${esc(b.id)}" aria-label="Remove bookmark">×</button></div>`).join('') : '<p>No bookmarks yet. Use ☆ to bookmark the current tab.</p>');
}
$('#browser-address-form').addEventListener('submit',e=>{
  e.preventDefault();const value=$('#browser-address').value.trim();if(!value)return;
  browserAction('open',{...browserDestination(value),...(state.activeTab?{id:state.activeTab}:{})});
});
$('#add-tab').addEventListener('click',addTabDialog);
$('#open-file').addEventListener('click',()=>{
  const bridge=window.webkit?.messageHandlers?.browser;
  if(bridge)bridge.postMessage({pickFile:true,owner:state.selected});else addTabDialog();
});
document.addEventListener('submit',e=>{
  if(e.target.id!=='browser-open-form')return;
  e.preventDefault();const value=new FormData(e.target).get('address').trim();closeModal();
  browserAction('open',browserDestination(value));
});
document.addEventListener('click',e=>{
  const b=e.target.closest('button');if(!b)return;
  if(b.dataset.browserAction)browserAction(b.dataset.browserAction);
  if(b.dataset.zoom){
    const tab=state.tabs.find(t=>t.id===state.activeTab);if(!tab)return;
    const factor=b.dataset.zoom==='reset'?1:Math.max(.25,Math.min(5,Math.round(((tab.zoom || 1)+Number(b.dataset.zoom))*100)/100));
    browserAction('zoom',{factor});
  }
  if(b.dataset.bookmarkOpen){closeModal();browserAction('open',{url:b.dataset.bookmarkOpen});}
  if(b.dataset.bookmarkRemove)browserAction('unbookmark',{id:b.dataset.bookmarkRemove}).then(showBookmarks);
});
new ResizeObserver(syncNativeBrowser).observe($('#workspace-content'));
new MutationObserver(syncNativeBrowser).observe(document.documentElement,{attributes:true,attributeFilter:['data-theme']});
new MutationObserver(syncNativeBrowser).observe($('#modal'),{attributes:true,attributeFilter:['open']});
window.addEventListener('resize',syncNativeBrowser);

window.addEventListener('scroll',syncNativeBrowser,true);
