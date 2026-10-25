dispatchUI({type:'Connection',online:window.SapiensConnections?SapiensConnections.connected:true});
dispatchUI({type:'Clock',now:Date.now()});
let refreshing = null;
let saveTimer;
let saving = false;
let savedPreferences = '';
let pendingChatPosition = bootstrap.preferences.chatPosition || null;
let lastChatPosition = pendingChatPosition;
let lastChatGeometry = null;
let resumingChat = false, resumeChatFrame;
const nameRule = /^[A-Z][A-Za-z0-9_.:#+|()&$^\-]*$/;
const nameHelp = 'Start with A–Z. Letters, numbers, and - _ . : # + | ( ) & $ ^ are allowed. No spaces.';
const displayTime = value => new Date(value).toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'});

function preferences() {
  return {selected:state.selected,panel:state.panel,scope:state.scope,groupView:state.groupView,panes:state.panes,
    drafts:state.drafts,
    attachment_drafts:Object.fromEntries(Object.entries(state.composer.attachments).map(([id, items]) => [id, items.map(a => a.id)]))};
}
// Pixel offsets alone cannot survive the shortened offline transcript. Persist
// a message identity and its position inside the viewport instead.
function chatPosition() {
  if (pendingChatPosition) return pendingChatPosition;
  const viewport = $('#conversation-body');
  if (state.panel !== 'chat' || state.view !== 'conversation') return null;
  if (document.hidden || !viewport.clientHeight) return lastChatPosition;
  const geometry = `${viewport.clientWidth}:${viewport.clientHeight}`;
  // iOS reflows its app-switcher snapshot BEFORE visibilitychange. The resulting
  // scroll event is not a reading gesture and must not replace the bookmark.
  if (lastChatPosition?.selected === state.selected && lastChatGeometry && lastChatGeometry !== geometry) return lastChatPosition;
  lastChatGeometry = geometry;
  const top = viewport.getBoundingClientRect().top;
  const node = [...viewport.children].find(node => node.dataset.chatKey && node.getBoundingClientRect().bottom > top);
  return lastChatPosition = {selected:state.selected,
    bottom:viewport.scrollHeight - viewport.scrollTop - viewport.clientHeight < 2,
    key:node?.dataset.chatKey,offset:node ? node.getBoundingClientRect().top - top : 0};
}
function restoreChatPosition() {
  const saved = pendingChatPosition, viewport = $('#conversation-body');
  if (!saved || document.hidden) return;
  if (saved.selected !== state.selected || state.panel !== 'chat' || state.view !== 'conversation') {
    pendingChatPosition = null;return;
  }
  if (!viewport.clientHeight) return;
  const node = [...viewport.children].find(node => node.dataset.chatKey === saved.key);
  // An older message may not exist in the offline cache. Keep the bookmark
  // until live history arrives, without overwriting it with a clamped offset.
  if (!saved.bottom && !node) return;
  viewport.scrollTop = saved.bottom ? viewport.scrollHeight - viewport.clientHeight :
    viewport.scrollTop + node.getBoundingClientRect().top - viewport.getBoundingClientRect().top - (saved.offset || 0);
  lastChatPosition = saved;
  lastChatGeometry = `${viewport.clientWidth}:${viewport.clientHeight}`;
  if (!resumingChat) pendingChatPosition = null;
}
function workspacePreferences() {
  return {...preferences(),view:state.view,period:state.period,workspaces:state.workspaces,scroll:$('#conversation-body').scrollTop,chatPosition:chatPosition()};
}
function save() {
  window.SapiensConnections?.save(workspacePreferences());
  clearTimeout(saveTimer);
  saveTimer = setTimeout(flushPreferences, 300);
};
async function flushPreferences() {
  if (saving || !state.online || window.SapiensConnections?.busy) return;
  const value = JSON.stringify(preferences());
  if (value === savedPreferences) return;
  saving = true;
  try {
    const sent = window.SapiensConnections ? {attachment_drafts:JSON.parse(value).attachment_drafts} : JSON.parse(value);
    const response = await api('/api/preferences', 'PUT', sent);
    receiveWorkspaces(response.preferences);
    savedPreferences = value;
  } catch (error) {
    toast(`Settings are not saved yet: ${error.message}`);
  } finally {
    saving = false;
    if (JSON.stringify(preferences()) !== savedPreferences) saveTimer = setTimeout(flushPreferences, 2000);
  }
}
const getMessages = id => state.messages[id] || [];

function updateProgress() {
  dispatchUI({type:'Clock',now:Date.now()});
  $$('[data-turn-progress]').forEach(node => {
    const turn = state.snapshot.turns.find(t => t.id === node.dataset.turnProgress);
    if (turn) node.innerHTML = turnProgress(turn);
  });
}

document.addEventListener('click', e => {
  const button = e.target.closest('[data-warning-toggle]');
  if (!button) return;
  const id = button.dataset.warningToggle;
  const expanded = !state.expanded['warning:'+id];
  dispatchUI({type:'Expand',key:'warning:'+id,open:expanded});
  button.setAttribute('aria-expanded', String(expanded));
  document.getElementById(button.getAttribute('aria-controls')).hidden = !expanded;
});

function applySnapshot(snapshot) {
  const identity=$('#corpora-identity');
  if(identity&&snapshot.corpora){identity.hidden=false;identity.textContent=snapshot.corpora.name;identity.title=snapshot.corpora.id;}
  const previous=state.selected;
  dispatchUI({type:'Snapshot',snapshot});
  if(previous!==state.selected){syncComposer();renderTabs();renderWorkspace();}
}

function renderGlobal() {
  if(!window.SapiensConnections) {
    $('#connection-label').textContent = `Local · ${state.online ? 'Online' : 'Reconnecting…'}`;
    $('#connection-status').dataset.online = String(state.online);
  }
  const owner = state.snapshot.computer.owner;
  $('#resource-owner').textContent = owner ? `In use · ${agent(owner).name}` : state.snapshot.computer.built ? 'Blindly4 · Available' : 'Blindly4 · Build required';
  $('#resource-status').classList.toggle('idle', !owner);
  $('#resource-status').classList.remove('paused');
};

window.addEventListener('sapiens-connection-change', () => {if(window.SapiensConnections)dispatchUI({type:'Connection',online:SapiensConnections.connected&&!SapiensConnections.busy});renderGlobal();renderAgentHeader();});

function renderAgentHeader() {
  const a = selected();
  const turn = a.kind==='group'?null:state.snapshot.turns.find(j => j.agent === a.id && blocksChat(j));
  $('#agent-heading').innerHTML = `${avatar(a,isMainSapi(a)?'large main-sapi-avatar':'large',true)}<div><div class="agent-title"><h2>${esc(a.name)}</h2>${a.kind==='group'?'':groupLabels(a)}</div><p class="agent-role">${esc(a.kind==='group'?a.description:a.role)}</p></div><button class="icon-button" data-action="agent-settings" aria-label="Sapi settings">···</button>`;
  $('#message-input').placeholder = paneLimit()<3 ? 'Message…' : `Message ${a.name}…`;
  $('#message-input').setAttribute('aria-label',`Message ${a.name}`);
  resizeComposer();
  renderActivityNavigation();
  $('#attach-button').hidden = Boolean(a.archived);
  $('.send-button').disabled = a.retired || a.archived || state.snapshot.corpora?.status==='paused' || state.snapshot.corpora?.status==='archived' || !state.online || state.composer.sending[a.id] || state.composer.uploading > 0;
};

// Keep existing messages mounted: clearing the scroll container interrupts iOS
// momentum scrolling, even when scrollTop is restored in the same JavaScript turn.
function commitChat(viewport, content, changedView, bottom, scroll, anchor) {
  const latestChanged = changedView || !viewport.lastElementChild?.isEqualNode(content.lastElementChild);
  const key = (node, index) => node.dataset.chatKey || node.className + ':' + index;
  const existing = new Map([...viewport.children].map((node, index) => [key(node, index), node]));
  const keep = new Set();
  let changed = changedView;
  let cursor = viewport.firstElementChild;
  [...content.children].forEach((fresh, index) => {
    const old = changedView ? null : existing.get(key(fresh, index));
    const node = old?.isEqualNode(fresh) ? old : fresh;
    if (old && node !== old) {
      changed = true;
      if (cursor === old) cursor = fresh;
      old.replaceWith(fresh);
    }
    if (node !== cursor) {viewport.insertBefore(node, cursor);changed = true;}
    cursor = node.nextElementSibling;
    keep.add(node);
  });
  [...viewport.children].forEach(node => { if (!keep.has(node)) {node.remove();changed = true;} });
  let target = scroll;
  if (bottom && changed && latestChanged) target = viewport.scrollHeight - viewport.clientHeight;
  else if (anchor?.node.isConnected) {
    target = viewport.scrollTop + anchor.node.getBoundingClientRect().top - anchor.top;
  }
  // Writing scrollTop during every poll also cancels momentum in WebKit.
  if (Math.abs(viewport.scrollTop - target) > 1) viewport.scrollTop = target;
}

let renderedConversation = '';
function renderConversation() {
  // Background layout is not a reading position. Reconcile the transcript when
  // visible again, after the phone has restored its viewport.
  if (document.hidden) return;
  const viewport = $('#conversation-body');
  viewport.classList.toggle('notes-view', state.panel === 'notes');
  const key = state.selected + ':' + state.panel + ':'+state.view;
  const changedView = renderedConversation !== key;
  if (changedView) lastChatGeometry = null;
  renderedConversation = key;
  const scroll = changedView ? 0 : viewport.scrollTop;
  const bottom = state.panel === 'chat' && (changedView || viewport.scrollHeight - viewport.scrollTop - viewport.clientHeight < 80);
  const firstVisible = !changedView && [...viewport.children].find(node => node.getBoundingClientRect().bottom > viewport.getBoundingClientRect().top);
  const anchor = firstVisible ? {node:firstVisible,top:firstVisible.getBoundingClientRect().top} : null;
  const chat = state.panel === 'chat' && state.view === 'conversation';
  const host = chat ? document.createElement('div') : viewport;
  const finish = () => { if (chat) {commitChat(viewport, host, changedView, bottom, scroll, anchor);restoreChatPosition();} };
  if(renderChatCollection(host)){renderAgentHeader();renderGlobal();return;}
  if(state.panel==='work' || state.panel==='updates') {renderWork(host);renderAgentHeader();renderGlobal();if(changedView)host.scrollTop=0;return;}
  $('#composer-area').hidden=!!selected().archived;
  host.innerHTML=conversationView(state);
  if(selected().kind!=='group')taskCallControls(host);renderAttachment();

  renderAgentHeader(); renderGlobal();
  finish();
};

function sendChat(value) {dispatchUI({type:'Send',value});}

function addAgent() {
  leaveGroup('all');
  const input=$('#message-input');
  if(!input.value.trim())input.value=bootstrap.creation_template;
  saveDraft();
  input.focus();
  const start=input.value.indexOf('WORKFLOW');
  if(start>=0)input.setSelectionRange(start,start+8);
  save();
};
function agentSettings() {
  const a = selected();
  if(a.kind==='group'){groupDialog(a);return;}
  const execution = state.snapshot.orchestration[a.id].execution;
  modal(`${a.name} settings`, `<form id="live-settings-form" data-id="${esc(a.id)}" class="form-stack">
    <div class="settings-tabs" role="tablist" aria-label="Sapi settings">${[['profile','Profile'],['context','Context'],['usage','Usage'],['limits','Limits']].map(([key,label],i)=>`<button type="button" role="tab" id="settings-tab-${key}" aria-controls="settings-panel-${key}" aria-selected="${i===0}" tabindex="${i===0?0:-1}" ${i ? 'disabled aria-disabled="true" title="Inactive"' : ''}>${label}</button>`).join('')}</div>
    <section class="settings-panel form-stack" role="tabpanel" id="settings-panel-profile" aria-labelledby="settings-tab-profile" data-settings-panel="profile">
    <label>Name<input name="name" value="${esc(a.name)}" required maxlength="24" aria-describedby="name-help" autocomplete="off"></label>
    ${nameSuggestions()}
    <label>Role<input name="role" value="${esc(a.role)}" required maxlength="60"></label>
    ${managerOptions(a)}
    <label>Work mode<select name="mode"><option value="normal" ${execution.mode === 'normal' ? 'selected' : ''}>Normal · high</option><option value="deep" ${execution.mode === 'deep' ? 'selected' : ''}>Deep work · xhigh</option></select></label>
    <p class="form-hint">Each call has a ${execution.timeout_seconds / 60}-minute limit in either mode.</p>
    </section>
    ${['context','usage','limits'].map(key => `<section class="settings-panel" role="tabpanel" id="settings-panel-${key}" aria-labelledby="settings-tab-${key}" hidden>Inactive</section>`).join('')}
    <button type="submit" class="button primary">Save</button></form>`, 'SAPIENS4');
};
actions['agent-settings'] = agentSettings;
function computerDialog() {
  const windows = state.snapshot.computer.platform === 'win32';
  modal('Shared computer', `<p>Blindly4 is the main computer-use tool. Ask a Sapi in chat to work on your computer.</p><div class="settings-row"><span>${state.snapshot.computer.built ? 'Blindly4 is built' : `Build required: run ${windows ? '.\\start.ps1' : './start.sh'}`}</span><span class="tag">${state.snapshot.computer.owner ? `In use · ${esc(agent(state.snapshot.computer.owner).name)}` : 'Available'}</span></div><p>Sapis share one computer. ${windows ? 'Windows UI Automation works with accessible apps on your desktop. Elevated apps and secure system dialogs cannot be controlled.' : 'macOS Accessibility access is required for desktop interaction; permission failures appear in chat.'}</p>`, 'BLINDLY4');
};
function autonomyDialog() {
  modal('Workspace & settings', '<p>Talk to your Sapis in chat, manage their notes, and save documents in their workspaces. Sapis can delegate requests through ChiefSapi.</p><p>Use the corpora menu to switch workspaces. Active and Paused describe execution on the host; Connecting means this device is restoring its connection.</p><button type="button" class="button" id="edit-decision-prompts">Edit decision prompts</button>', 'SAPIENS4');
  $('#edit-decision-prompts').addEventListener('click', editDecisionPrompts);
};

document.addEventListener('submit', async e => {
  const form = e.target;
  if (form.id !== 'live-settings-form') return;
  e.preventDefault(); e.stopImmediatePropagation();
  const button = form.querySelector('button[type="submit"]') || form.querySelector('button');
  if (button.disabled) return;
  button.disabled = true;
  try {
    const data = Object.fromEntries(new FormData(form));
    if (!nameRule.test(data.name)) throw new Error(nameHelp);
    data.manager = data.manager || null;
    data.execution = {mode:data.mode};
    delete data.mode;
    await api(`/api/agents/${form.dataset.id}`, 'PUT', data);
    await refresh();closeModal();toast('Sapi saved.');
  } catch (error) { toast(error.message); }
  finally { button.disabled = false; }
}, true);

document.addEventListener('click', async e => {
  const b = e.target.closest('button');
  if (!b) return;
  if (b.id === 'app-menu') {
    e.preventDefault(); e.stopImmediatePropagation(); appMenu(); return;
  }
  if (!b.dataset.liveTurn) return;
  e.preventDefault(); e.stopImmediatePropagation(); b.disabled = true;
  try {
    await api(`/api/agents/${b.dataset.owner}/turns/${b.dataset.id}/${b.dataset.liveTurn}`, 'POST', {});
    await refresh();
  } catch (error) { toast(error.message); }
  finally { b.disabled = false; }
}, true);

function attachmentLabel(item) {
  const label = `${item.kind === 'filepath' ? 'Filepath' : item.kind[0].toUpperCase() + item.kind.slice(1)} · ${item.name}`;
  return item.kind === 'link' ? `<a class="attachment-item" href="${esc(item.value)}" target="_blank" rel="noopener noreferrer">${esc(label)} ↗</a>` : `<span class="attachment-item" title="${esc(item.value)}">${esc(label)}</span>`;
}
function renderAttachment() {
  const items = state.composer.attachments[state.selected] || [];
  $('#attachment-chip').innerHTML = items.map(a => `<div class="attachment-chip">${attachmentLabel(a)}<button type="button" data-remove-upload="${esc(a.id)}" aria-label="Remove ${esc(a.name)}">×</button></div>`).join('');
};
function attachmentMenu() {
  modal('Attach', `<div class="attachment-menu">${['image','document','link','filepath'].map(kind => `<button class="button" data-attachment-kind="${kind}">${kind === 'filepath' ? 'Filepath' : kind[0].toUpperCase() + kind.slice(1)}</button>`).join('')}</div>`, 'CHAT');
}
async function saveAttachment(id, data, epoch=state.epoch) {
  if(epoch!==state.epoch)return;
  if ((state.composer.attachments[id] || []).length >= 8) throw new Error('Attach up to 8 items per message.');
  const item = await api(`/api/${id.startsWith('group_')?'groups':'agents'}/${id}/attachments`, 'POST', data);
  dispatchUI({type:'Attachment',id,item,epoch});
}
async function pickAttachment(kind) {
  const id=state.selected,epoch=state.epoch;
  if (kind === 'link' || kind === 'filepath') {
    modal(kind === 'link' ? 'Add link' : 'Add filepath', `<form id="attachment-reference-form" data-id="${esc(id)}" data-kind="${kind}" class="form-stack"><label>${kind === 'link' ? 'Link' : 'Local filepath'}<input name="value" type="${kind === 'link' ? 'url' : 'text'}" placeholder="${kind === 'link' ? 'https://…' : '/Users/…/file.pdf'}" required maxlength="4096"></label><button class="button primary">Attach</button></form>`, 'CHAT');
    return;
  }
  const input = document.createElement('input');
  input.type = 'file';
  input.accept = kind === 'image' ? 'image/png,image/jpeg,image/gif,image/webp' : '.pdf,.txt,.md,.csv,.json,.doc,.docx,.xls,.xlsx,.ppt,.pptx,.rtf,.odt';
  input.addEventListener('change', async () => {
    const file = input.files[0];
    if(!file||epoch!==state.epoch)return;
    dispatchUI({type:'Uploading',delta:1});
    try {
      if (file.size > 10 * 1024 * 1024) throw new Error('Files must be 10 MB or smaller.');
      const data = await new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result.split(',')[1]);
        reader.onerror = () => reject(new Error('Could not read this file.'));
        reader.readAsDataURL(file);
      });
      await saveAttachment(id, {kind,name:file.name,data},epoch);
      closeModal();
    } catch (error) { toast(error.message); }
    finally {if(state.epoch===epoch)dispatchUI({type:'Uploading',delta:-1});}
  }, {once:true});
  input.click();
}
document.addEventListener('click', e => {
  const b = e.target.closest('button');
  if (!b) return;
  if (b.id === 'attach-button' || b.dataset.attachmentKind || b.dataset.removeUpload) {
    e.preventDefault(); e.stopImmediatePropagation();
    if (b.id === 'attach-button') attachmentMenu();
    else if (b.dataset.attachmentKind) pickAttachment(b.dataset.attachmentKind);
    else {
      dispatchUI({type:'Attachment',id:state.selected,remove:b.dataset.removeUpload});
    }
  }
}, true);
document.addEventListener('submit', async e => {
  const form = e.target;
  if (form.id !== 'attachment-reference-form') return;
  e.preventDefault(); e.stopImmediatePropagation();
  const button = form.querySelector('button[type="submit"]') || form.querySelector('button');
  if (button.disabled) return;
  button.disabled = true;
  try {
    await saveAttachment(form.dataset.id, {kind:form.dataset.kind,value:form.elements.value.value});
    closeModal();
  } catch (error) { toast(error.message); }
  finally { button.disabled = false; }
}, true);

$('.wordmark').addEventListener('click', () => {
  const main = state.agents.find(isMainSapi);
  if (main) openChat(main.id);
});

$('#message-input').value = state.drafts[state.selected] || '';
$('#message-input').addEventListener('input',()=>saveDraft());

async function refresh() {
  if (refreshing) return refreshing;
  const connectionGeneration=window.SapiensConnections?.generation;
  refreshing = (async () => {
    try {
      const snapshot = await api('/api/state');
      if(connectionGeneration!==window.SapiensConnections?.generation)return;
      window.SapiensConnections?.snapshot(snapshot);
      const changed = ['corpora','agents','groups','turns','computer','orchestration','activity','run_activity','workloads','pulses','routines','events'].some(k => JSON.stringify(snapshot[k]) !== JSON.stringify(state.snapshot[k]));
      const reconnected = !state.online;
      dispatchUI({type:'Connection',online:true});
      const tabsChanged = (snapshot.preferences.workspace_revision || 0) > state.workspaceRevision;
      applySnapshot(snapshot);
      if (tabsChanged) {renderTabs(); renderWorkspace();}
      else refreshWorkspacePreview();
      if (changed || reconnected) {
        renderSidebar(); renderConversation(); renderGlobal();
        if ($('#modal').open && $('#modal-title')?.textContent === 'Shared computer') computerDialog();
      }
    } catch (error) {
      if(connectionGeneration!==window.SapiensConnections?.generation)return;
      dispatchUI({type:'Connection',online:false}); window.SapiensConnections?.offline(error); renderGlobal(); renderAgentHeader();
    } finally { refreshing = null; }
  })();
  return refreshing;
}
applySnapshot(bootstrap);
savedPreferences = JSON.stringify(preferences());
render();
if (!bootstrap.preferences.chatPosition && Number.isFinite(bootstrap.preferences.scroll)) {
  $('#conversation-body').scrollTop = bootstrap.preferences.scroll;
  save();
}
async function poll() {
  await refresh();
  updateProgress();
  setTimeout(poll, window.SapiensConnections?.remote ? 2000 : state.online ? 750 : 2000);
}
setTimeout(poll, 750);

window.sapiensWorkspace = {save:()=>{
  saveDraft();
  window.SapiensConnections?.save(workspacePreferences());
}};
// iOS can collapse/reflow a backgrounded web app before pagehide. Capture the
// reading position while visible, rather than measuring that hidden layout.
let scrollSaveTimer;
$('#conversation-body').addEventListener('scroll',()=>{
  if (document.hidden) return;
  chatPosition();
  clearTimeout(scrollSaveTimer);
  scrollSaveTimer=setTimeout(()=>window.SapiensConnections?.save(workspacePreferences()),100);
},{passive:true});
// Explicit reading/navigation takes precedence over a bookmark awaiting history.
for (const event of ['pointerdown','touchstart','wheel','keydown']) $('#conversation-body').addEventListener(event,()=>{pendingChatPosition=null;lastChatGeometry=null;},{passive:true});
function suspendChat() {
  cancelAnimationFrame(resumeChatFrame);
  resumingChat = false;
  pendingChatPosition = chatPosition();
  window.sapiensWorkspace.save();
}
function resumeChat() {
  if (document.hidden) return;
  cancelAnimationFrame(resumeChatFrame);
  resumingChat = true;
  syncMobileViewport();
  renderConversation();
  // WebKit restores the scrolling layer after visibilitychange. Keep the
  // bookmark through the first paint so that its scroll events cannot replace
  // the user's position with the temporary foreground layout.
  resumeChatFrame = requestAnimationFrame(() => {
    restoreChatPosition();
    resumeChatFrame = requestAnimationFrame(() => {
      resumingChat = false;
      restoreChatPosition();
    });
  });
  refresh();
}
window.addEventListener('pagehide',suspendChat);
window.addEventListener('pageshow',resumeChat);
document.addEventListener('visibilitychange',()=>{if(document.hidden)suspendChat();else resumeChat();});
window.SapiensConnections?.subscribe(snapshot=>{
  clearTimeout(saveTimer);
  if (snapshot.corpora?.id === state.snapshot.corpora?.id) {
    // A cached workspace becoming live is a refresh, not navigation. Keep the
    // chat, draft and reading position the user chose while reconnecting.
    dispatchUI({type:'Connection',online:SapiensConnections.connected});
    applySnapshot(snapshot);renderSidebar();renderConversation();renderTabs();renderWorkspace();renderGlobal();
    return;
  }
  pendingChatPosition=snapshot.preferences.chatPosition || null;lastChatPosition=pendingChatPosition;
  dispatchUI({type:'Reset',snapshot});dispatchUI({type:'Connection',online:SapiensConnections.connected});
  renderedConversation='';$('#agent-search').value='';
  $('#message-input').value=state.drafts[state.selected]||'';
  applySnapshot(snapshot);savedPreferences=JSON.stringify(preferences());render();
  if(!snapshot.preferences.chatPosition && Number.isFinite(snapshot.preferences.scroll))$('#conversation-body').scrollTop=snapshot.preferences.scroll;
  save();
});
