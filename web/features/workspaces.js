// Browser state has one writer: the host API. Native views report live navigation.
let workspaceRevision = bootstrap.preferences.workspace_revision || 0;
let editingAddress = null;
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
    await api(`/api/${owner.startsWith('group_')?'groups':'agents'}/${owner}/control`, 'POST', {op:`workspace_${action}`,...fields});
    const snapshot=await api('/api/state');
    receiveWorkspaces(snapshot.preferences);
    if (['open','focus','close','back','forward','reload'].includes(action)) {setBrowserMenu();state.panes.workspace=true;}
    renderPanes();renderTabs();renderWorkspace();save();return true;
  } catch (error) {toast(error.message);}
}
const bookmarks = () => state.workspaces[state.selected]?.bookmarks || [];
const tabBookmark = t => bookmarks().find(b=>b.url===t.url && (state.tabs.find(s=>s.id===b.tab_id&&s.url===b.url) || state.tabs.find(s=>s.url===b.url))?.id===t.id);
function starButton(t) {
  const saved=!!tabBookmark(t);
  return `<button class="tab-star" data-star-tab="${esc(t.id)}" aria-label="${saved?'Unbookmark':'Bookmark'} ${esc(t.title)}" aria-pressed="${saved}" ${t.url==='about:blank'?'disabled':''}>${saved?'★':'☆'}</button>`;
}
function layoutTabs() {
  const host=$('#browser-tabs'), overflow=$('#browser-overflow');
  const rows=[...host.children];rows.forEach(row=>row.hidden=false);host.scrollLeft=0;
  overflow.hidden=true;overflow.hidden=host.scrollWidth<=host.clientWidth+1;
  overflow.textContent=`› ${state.tabs.length}`;overflow.setAttribute('aria-label',`All ${state.tabs.length} open tabs`);
  const visible=rows.slice(0,Math.max(1,Math.floor((host.clientWidth+3)/134))), active=host.querySelector('.active');
  if(active&&!visible.includes(active))visible.splice(-1,1,active);
  rows.forEach(row=>row.hidden=!visible.includes(row));
}
function setBrowserMenu(mode=null) {
  $('#browser-menu').hidden=!mode;$('#browser-options').hidden=mode!=='options';$('#browser-all-tabs').hidden=mode!=='tabs';
  $('#workspace-menu').setAttribute('aria-expanded',String(mode==='options'));$('#browser-overflow').setAttribute('aria-expanded',String(mode==='tabs'));
  syncNativeBrowser();
}
function renderTabs() {
  renderPanes();
  const rows=tabs=>tabs.map(t=>`<div class="workspace-tab ${t.id===state.activeTab?'active':''}">${starButton(t)}<button class="tab-select" data-tab="${esc(t.id)}" aria-pressed="${t.id===state.activeTab}" title="${esc(t.path || t.url)}">${esc(t.title || 'New tab')}</button><button class="tab-close" data-close-tab="${esc(t.id)}" aria-label="Close ${esc(t.title)}">×</button></div>`).join('');
  $('#browser-tabs').innerHTML=rows([...state.tabs].sort((a,b)=>Number(!!tabBookmark(b))-Number(!!tabBookmark(a)))) || '<div class="workspace-tab active"><button class="tab-select" data-action="new-tab" aria-pressed="true">New tab</button></div>';
  $('#browser-all-tabs').innerHTML=`<div class="browser-menu-label">Open tabs · ${state.tabs.length}</div>${rows(state.tabs)}`;
  $('#browser-bookmarks').innerHTML=bookmarks().map(b=>`<div class="bookmark-row"><button data-bookmark-open="${esc(b.url)}">★ ${esc(b.title)}</button><button data-bookmark-remove="${esc(b.id)}" aria-label="Remove ${esc(b.title)} bookmark">×</button></div>`).join('') || '<p>No bookmarks yet.</p>';
  layoutTabs();
}
function renderWorkspace() {
  syncWorkspace();
  $('#workspace-owner').innerHTML=`${mention(workspaceOwner)}<span>’s browser</span>`;
  const t=state.tabs.find(t=>t.id===state.activeTab);
  $('#browser-address-form').hidden=!!t && t.url!=='about:blank' && editingAddress!==t.id;
  if (document.activeElement!==$('#browser-address')) $('#browser-address').value=t?.path || (t?.url==='about:blank'?'':t?.url) || '';
  $('#browser-zoom').textContent=`${Math.round((t?.zoom || 1)*100)}%`;
  $('#browser-status').textContent=t?.error || (t?.loading?'Loading…':'');
  $$('[data-browser-action]').forEach(b=>b.disabled=!t || (b.dataset.browserAction==='back'&&!t.can_back) || (b.dataset.browserAction==='forward'&&!t.can_forward));
  if(window.webkit?.messageHandlers?.browser)$('#workspace-content').textContent=t?'':'Open a URL or file to get started.';
  else refreshWorkspacePreview();
  syncNativeBrowser();
}
let workspacePreview = null;
async function refreshWorkspacePreview() {
  if(window.webkit?.messageHandlers?.browser)return;
  const host=$('#workspace-content'),tab=state.tabs.find(t=>t.id===state.activeTab);
  const key=JSON.stringify([state.selected,tab?.id,tab?.path,tab?.command?.seq]);
  if(workspacePreview?.key!==key){
    workspacePreview={key,checked:0,pending:false};
    host.replaceChildren();
    if(!tab?.path){host.textContent=tab&&tab.url!=='about:blank'?'Open Sapiens4 desktop to browse this web page.':'Open a URL or file to get started.';return;}
    const pre=document.createElement('pre');pre.className='workspace-text';
    pre.setAttribute('aria-label',tab.title);pre.textContent='Loading…';host.append(pre);
  }
  if(!tab?.path||!state.panes.workspace)return;
  const pre=host.querySelector('.workspace-text'),current=workspacePreview;
  pre.style.fontSize=`${13*(tab.zoom||1)}px`;
  $('#browser-status').textContent='';
  if(current.pending||Date.now()-current.checked<2000)return;
  current.pending=true;current.checked=Date.now();
  try{
    const type=state.selected.startsWith('group_')?'groups':'agents';
    const data=await api(`/api/${type}/${encodeURIComponent(state.selected)}/browser/${encodeURIComponent(tab.id)}/content`);
    if(workspacePreview===current&&pre.textContent!==data.content)pre.textContent=data.content;
  }catch(error){if(workspacePreview===current)pre.textContent=error.message;}
  finally{current.pending=false;}
}
function syncNativeBrowser() {
  const bridge=window.webkit?.messageHandlers?.browser;
  if (!bridge) return;
  const rect=$('#workspace-content').getBoundingClientRect();
  const palette=getComputedStyle($('.workspace'));
  bridge.postMessage({workspaces:state.workspaces,owner:state.selected,active:state.activeTab,
    visible:!$('#workspace-panel').hidden && !$('#modal').open && $('#browser-menu').hidden, dark:document.documentElement.dataset.theme==='dark',
    background:palette.getPropertyValue('--sapi-white').trim(),foreground:palette.getPropertyValue('--sapi-ink').trim(),
    captionBackground:palette.getPropertyValue('--sapi-bg').trim(),
    rect:{x:rect.x,y:rect.y,width:rect.width,height:rect.height}});
}
// Only the trusted app webview owns this callback; guest browser views have no bridge.
let browserReports=Promise.resolve();
window.sapiensBrowserEvent = data => {
  browserReports=browserReports.then(async()=>{
    if (data.open) return browserAction('open',{url:data.open},data.owner);
    if (data.file) return browserAction('open',{path:data.file},data.owner);
    if (data.action) return browserAction(data.action,data.fields || {},data.owner);
    await api(`/api/${data.owner.startsWith('group_')?'groups':'agents'}/${data.owner}/browser`,'POST',data);
    const snapshot=await api('/api/state');receiveWorkspaces(snapshot.preferences);
    renderTabs();renderWorkspace();
  }).catch(error=>toast(error.message));
};
async function openNewTab() {
  const owner=state.selected;
  if (await browserAction('open',{url:'about:blank'},owner) && state.selected===owner) {
    $('#browser-address').value='';$('#browser-address').focus();
  }
}
$('#browser-address-form').addEventListener('submit',async e=>{
  e.preventDefault();const value=$('#browser-address').value.trim();if(!value)return;$('#browser-address').blur();
  if(await browserAction('open',{...browserDestination(value),...(state.activeTab?{id:state.activeTab}:{})})){editingAddress=null;renderWorkspace();}
});
$('#add-tab').addEventListener('click',openNewTab);
$('#open-file').addEventListener('click',()=>{
  const bridge=window.webkit?.messageHandlers?.browser, directory=selected().kind==='group'?selected().workspace:live.orchestration[state.selected].notes.path.replace(/[\\/][^\\/]+$/, '');
  setBrowserMenu();
  if(bridge)bridge.postMessage({pickFile:true,owner:state.selected,directory});else {editingAddress=state.activeTab;renderWorkspace();$('#browser-address').value=directory+'/';$('#browser-address').focus();}
});
document.addEventListener('click',e=>{
  if(!e.target.closest('.browser-menu,.browser-tabs-wrap'))setBrowserMenu();
  const b=e.target.closest('button');if(!b)return;
  if(b.id==='workspace-menu'||b.id==='browser-overflow'){const mode=b.id==='workspace-menu'?'options':'tabs';setBrowserMenu(b.getAttribute('aria-expanded')==='true'?null:mode);if(!$('#browser-menu').hidden)$(mode==='options'?'#browser-options button:not(:disabled)':'#browser-all-tabs button:not(:disabled)')?.focus();}
  if(b.hasAttribute('data-edit-address')){editingAddress=state.activeTab;setBrowserMenu();renderWorkspace();$('#browser-address').focus();$('#browser-address').select();}
  if(b.dataset.starTab){const tab=state.tabs.find(t=>t.id===b.dataset.starTab);if(!tab)return;const saved=tabBookmark(tab);browserAction(saved?'unbookmark':'bookmark',{id:saved?.id || tab.id});}
  if(b.dataset.browserAction)browserAction(b.dataset.browserAction);
  if(b.dataset.zoom){
    const tab=state.tabs.find(t=>t.id===state.activeTab);if(!tab)return;
    const factor=b.dataset.zoom==='reset'?1:Math.max(.25,Math.min(5,Math.round(((tab.zoom || 1)+Number(b.dataset.zoom))*100)/100));
    browserAction('zoom',{factor});
  }
  if(b.dataset.bookmarkOpen){const tab=state.tabs.find(t=>t.url===b.dataset.bookmarkOpen);browserAction(tab?'focus':'open',tab?{id:tab.id}:{url:b.dataset.bookmarkOpen});}
  if(b.dataset.bookmarkRemove)browserAction('unbookmark',{id:b.dataset.bookmarkRemove});
});
document.addEventListener('keydown',e=>{if(e.key==='Escape'&&!$('#browser-menu').hidden){setBrowserMenu();$('#workspace-menu').focus();}if((e.metaKey||e.ctrlKey)&&e.key.toLowerCase()==='l'&&state.panes.workspace&&!$('#modal').open){e.preventDefault();if(state.activeTab)$('[data-edit-address]').click();else openNewTab();}});
const browserResize=new ResizeObserver(()=>{layoutTabs();syncNativeBrowser();});
browserResize.observe($('#workspace-content'));browserResize.observe($('.browser-tabs-wrap'));
new MutationObserver(syncNativeBrowser).observe(document.documentElement,{attributes:true,attributeFilter:['data-theme']});
new MutationObserver(syncNativeBrowser).observe($('#modal'),{attributes:true,attributeFilter:['open']});
window.addEventListener('resize',syncNativeBrowser);

window.addEventListener('scroll',syncNativeBrowser,true);
