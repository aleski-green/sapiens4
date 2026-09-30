// Connect the workspace renderer to the local Sapiens4 API.
let live = bootstrap;
let cursor = 0;
let eventRows = [];
let online = true;
let refreshing = null;
let saveTimer;
let saving = false;
let savedPreferences = '';
const submitting = new Set();
const expandedWarnings = new Set();
const attachmentDrafts = bootstrap.attachment_drafts || {};
let uploading = 0;
const nameRule = /^[A-Z][A-Za-z0-9_.:#+|()&$^\-]*$/;
const nameHelp = 'Start with A–Z. Letters, numbers, and - _ . : # + | ( ) & $ ^ are allowed. No spaces.';
const attention = new Set(['failed','interrupted','conflict']);
const blocksChat = turn => ['queued','running'].includes(turn.status);
const statusNames = {queued:'Queued',running:'Running',done:'Completed',warning:'Warning',failed:'Failed',
  interrupted:'Interrupted',conflict:'Needs review',cancelled:'Dismissed'};
const displayTime = value => new Date(value).toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'});
const originalConversation = renderConversation;

function preferences() {
  return {selected:state.selected,panel:state.panel,scope:state.scope,panes:state.panes,
    drafts:state.drafts,
    attachment_drafts:Object.fromEntries(Object.entries(attachmentDrafts).map(([id, items]) => [id, items.map(a => a.id)]))};
}
save = function() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(flushPreferences, 300);
};
async function flushPreferences() {
  if (saving) return;
  const value = JSON.stringify(preferences());
  if (value === savedPreferences) return;
  saving = true;
  try {
    const sent = JSON.parse(value);
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
getMessages = id => state.messages[id] || [];

function turnActions(turn) {
  if (turn.status === 'running') return `<div class="actions"><button class="button" data-live-turn="cancel" data-id="${esc(turn.id)}" data-owner="${esc(turn.agent)}" ${!online || live.activity?.[turn.agent]?.stopping ? 'disabled' : ''}>Stop</button><small>Already completed actions are not undone.</small></div>`;
  if (attention.has(turn.status)) return `<div class="actions"><button class="button" data-live-turn="retry" data-id="${esc(turn.id)}" data-owner="${esc(turn.agent)}">Retry</button><button class="button" data-live-turn="cancel" data-id="${esc(turn.id)}" data-owner="${esc(turn.agent)}">Dismiss</button></div>`;
  if (turn.status === 'queued') return `<div class="actions"><button class="button" data-live-turn="cancel" data-id="${esc(turn.id)}" data-owner="${esc(turn.agent)}">Cancel queued turn</button></div>`;
  return '';
}

function turnProgress(turn, now = Date.now()) {
  const current = live.activity?.[turn.agent];
  const a = current?.turn === turn.id ? current : {};
  const elapsed = Math.max(0, Math.floor((now - (a.started || Date.parse(turn.created))) / 1000));
  const quiet = Math.max(0, Math.floor((now - (a.updated || a.started || now)) / 1000));
  const phase = !online ? 'Disconnected' : a.stopping ? 'Stopping…' : turn.status === 'queued' ? 'Queued' : a.phase || 'Starting model';
  const detail = a.tool ? `Current tool: ${a.tool}` : a.last_action ? `Last completed action: ${a.last_action}` : '';
  return `<strong>${esc(phase)} · ${elapsed}s</strong><p>${esc(detail)}</p>${quiet >= 60 ? `<small>No recent update · ${quiet}s since last activity</small>` : ''}`;
}

function updateProgress() {
  $$('[data-turn-progress]').forEach(node => {
    const turn = live.turns.find(t => t.id === node.dataset.turnProgress);
    if (turn) node.innerHTML = turnProgress(turn);
  });
}

document.addEventListener('click', e => {
  const button = e.target.closest('[data-warning-toggle]');
  if (!button) return;
  const id = button.dataset.warningToggle;
  const expanded = !expandedWarnings.has(id);
  if (expanded) expandedWarnings.add(id); else expandedWarnings.delete(id);
  button.setAttribute('aria-expanded', String(expanded));
  document.getElementById(button.getAttribute('aria-controls')).hidden = !expanded;
});

function chatResult(turn) {
  const text = turn.output || '';
  if (turn.status !== 'warning') return {text};
  // Only split the host-generated limit notice; preserve ordinary Sapi answers.
  const notice = /^Warning — partial result\.\n\n(Saved: [\s\S]+?)\n\n(The (?:tool|time) limit was reached after [\s\S]+)$/.exec(text);
  return {text:notice ? notice[1] : text, warning:notice ? notice[2] : turn.error || 'Partial result; review before relying on it.'};
}

function requestStatus(turn) {
  if (!attention.has(turn.status) && turn.status !== 'cancelled') return null;
  const error = turn.error || '';
  const reason = /TimeoutError|time limit|exceeded \d+(?:\.\d+)?s/i.test(error) ? 'Timed out' :
    /tool-step limit|tool limit/i.test(error) ? 'Tool limit reached' : null;
  return {label: reason ? reason + (turn.status === 'cancelled' ? ' · Dismissed' : '') : statusNames[turn.status],
    detail: error.split('\n')[0] || (turn.status === 'cancelled' ? 'This request was dismissed.' : 'This request needs attention.')};
}

function applySnapshot(snapshot) {
  receiveWorkspaces(snapshot.preferences);
  live = snapshot;
  const known = new Set(eventRows.map(e => e.id));
  eventRows.push(...snapshot.events.filter(e => !known.has(e.id)));
  eventRows = eventRows.slice(-1000);
  cursor = snapshot.cursor;
  const old = new Map(state.agents.map(a => [a.id,a]));
  state.agents = snapshot.agents.map(a => ({...old.get(a.id),...a,kind:'sapi',scope:'personal',
    autonomy:'assist',status:'online',lastActivity:Date.parse(a.created),preview:'Ready for your message.'}));
  state.messages = {};
  for (const turn of snapshot.turns) {
    const messages = state.messages[turn.agent] ||= [];
    const timestamp = Date.parse(turn.created);
    if (['chat','computer'].includes(turn.flow)) messages.push({role:'user',text:turn.input,time:displayTime(turn.created),timestamp,attachments:turn.attachments,requestTurn:turn});
    if (['chat','computer'].includes(turn.flow) && ['done','warning'].includes(turn.status) && turn.output !== null) {
      messages.push({role:'assistant',...chatResult(turn),time:displayTime(turn.created),timestamp,turnId:turn.id});
    }
    const a = state.agents.find(a => a.id === turn.agent);
    if (a && (['chat','computer'].includes(turn.flow))) {
      a.lastActivity = timestamp;
      a.preview = (['done','warning'].includes(turn.status) && turn.output !== null ? chatResult(turn).text : turn.input).replace(/\s+/g,' ').slice(0,150);
    }
    if (a && turn.status === 'running') a.status = 'busy';
  }
  for (const messages of Object.values(state.messages)) messages.sort((a,b)=>a.timestamp-b.timestamp);
  if (!state.agents.some(a => a.id === state.selected) ||
      (agent(state.selected).retired && !old.get(state.selected)?.retired)) {
    state.drafts[state.selected] = $('#message-input').value;
    state.selected = snapshot.main_agent_id;
    $('#message-input').value = state.drafts[state.selected] || '';
    renderTabs(); renderWorkspace();
  }
}

renderGlobal = function() {
  $('#autonomy-label').textContent = online ? 'Connected' : 'Reconnecting…';
  $('#autonomy-button').classList.toggle('live-disconnected', !online);
  const owner = live.computer.owner;
  $('#resource-owner').textContent = owner ? `In use · ${agent(owner).name}` : live.computer.built ? 'Blindly4 · Available' : 'Blindly4 · Build required';
  $('#resource-status').classList.toggle('idle', !owner);
  $('#resource-status').classList.remove('paused');
};

renderAgentHeader = function() {
  const a = selected();
  const turn = live.turns.find(j => j.agent === a.id && blocksChat(j));
  $('#agent-heading').innerHTML = `${avatar(a,isMainSapi(a)?'large main-sapi-avatar':'large')}<div><h2>${esc(a.name)}</h2><p class="agent-role">${esc(a.role)}</p></div><button class="icon-button" data-action="agent-settings" aria-label="Sapi settings">···</button>`;
  $('#message-input').placeholder = `Message ${a.name}…`;
  $$('[data-panel]').forEach(b => {b.classList.toggle('active',b.dataset.panel === state.panel);b.setAttribute('aria-pressed',b.dataset.panel === state.panel);});
  $('.send-button').disabled = a.retired || !online || Boolean(turn) || submitting.has(a.id) || uploading > 0;
};

let renderedConversation = '';
renderConversation = function() {
  const host = $('#conversation-body');
  host.classList.toggle('notes-view', state.panel === 'notes');
  const turns = live.turns.filter(j => j.agent === state.selected);
  const key = state.selected + ':' + state.panel;
  const changedView = renderedConversation !== key;
  renderedConversation = key;
  const scroll = changedView ? 0 : host.scrollTop;
  const bottom = state.panel === 'chat' && (changedView || host.scrollHeight - host.scrollTop - host.clientHeight < 80);
  if (state.panel === 'chat') {
    originalConversation();
    host.querySelectorAll('.message').forEach((node,i) => {
      const message=getMessages(state.selected)[i];
      const request = message?.requestTurn, requestState = request && requestStatus(request);
      if (requestState) {
        const key = `request-${request.id}`, expanded = expandedWarnings.has(key);
        node.querySelector('.message-meta').insertAdjacentHTML('beforeend', `<button type="button" class="warning-badge" data-warning-toggle="${esc(key)}" aria-expanded="${expanded}" aria-controls="${esc(key)}">${esc(requestState.label)}</button>`);
        node.querySelector('.message-bubble').insertAdjacentHTML('afterbegin', `<div class="warning-details" id="${esc(key)}" ${expanded ? '' : 'hidden'}><p>${esc(requestState.detail)}</p><p>No final reply was saved for this request.</p>${turnActions(request)}</div>`);
      }
      if (message?.warning) {
        node.classList.add('warning-message');
        const expanded = expandedWarnings.has(message.turnId);
        node.querySelector('.message-meta').insertAdjacentHTML('beforeend', `<button type="button" class="warning-badge" data-warning-toggle="${esc(message.turnId)}" aria-expanded="${expanded}" aria-controls="warning-${esc(message.turnId)}">Warning</button>`);
        node.querySelector('.message-bubble').insertAdjacentHTML('afterbegin', `<div class="warning-details" id="warning-${esc(message.turnId)}" ${expanded ? '' : 'hidden'}>${esc(message.warning)}</div>`);
      }
    });
    const humanMessages = getMessages(state.selected).filter(m => m.role === 'user');
    host.querySelectorAll('.message.user').forEach((node, i) => {
      node.querySelector('.message-meta strong').textContent = 'Admin';
      const attachments = humanMessages[i]?.attachments || [];
      if (attachments.length) node.querySelector('.message-bubble').insertAdjacentHTML('beforeend', `<div class="message-attachments">${attachments.map(attachmentLabel).join('')}</div>`);
    });
    if (!getMessages(state.selected).length) host.insertAdjacentHTML('beforeend', '<div class="empty">Start a conversation.</div>');
    const turn = turns.find(j => blocksChat(j) && !(attention.has(j.status) && ['chat','computer'].includes(j.flow)));
    if (turn) {
      host.insertAdjacentHTML('beforeend', `<section class="live-status"><div data-turn-progress="${esc(turn.id)}">${turnProgress(turn)}</div>${turnActions(turn)}</section>`);
    }
  } else if (state.panel === 'notes') {
    $('#composer-area').hidden = true;
    renderNotes(host);
  } else {
    $('#composer-area').hidden = true;
    host.innerHTML = activityLog(turns);
  }
  renderAgentHeader(); renderGlobal();
  host.scrollTop = bottom ? host.scrollHeight : scroll;
};

sendChat = async function(value) {
  const text = value.trim();
  const id = state.selected;
  const attachments = [...(attachmentDrafts[id] || [])];
  if ((!text && !attachments.length) || submitting.has(id) || uploading) return;
  submitting.add(id); renderAgentHeader();
  try {
    await api(`/api/agents/${id}/messages`, 'POST', {text,attachments:attachments.map(a => a.id)});
    attachmentDrafts[id] = (attachmentDrafts[id] || []).filter(a => !attachments.some(sent => sent.id === a.id));
    renderAttachment();
    if (state.drafts[id]?.trim() === text) state.drafts[id] = '';
    if (state.selected === id && $('#message-input').value.trim() === text) {
      $('#message-input').value = ''; state.drafts[id] = '';
    }
    closeMentions(); save();
    await refresh();
  } catch (error) { toast(error.message); }
  finally { submitting.delete(id); renderAgentHeader(); }
};

addAgent = function() {
  modal('Create Sapi', `<form id="live-agent-form" class="form-stack"><label>Name<input name="name" required maxlength="24" placeholder="e.g. Nova" aria-describedby="name-help" autocomplete="off"></label>${nameSuggestions()}<label>Role<input name="role" required maxlength="60" placeholder="e.g. Research assistant"></label><button type="submit" class="button primary">Create Sapi</button></form>`, 'SAPIENS4');
};
agentSettings = function() {
  const a = selected();
  const execution = live.orchestration[a.id].execution;
  modal(`${a.name} settings`, `<form id="live-settings-form" data-id="${esc(a.id)}" class="form-stack">
    <div class="settings-tabs" role="tablist" aria-label="Sapi settings">${[['profile','Profile'],['context','Context'],['usage','Usage'],['limits','Limits']].map(([key,label],i)=>`<button type="button" role="tab" id="settings-tab-${key}" aria-controls="settings-panel-${key}" aria-selected="${i===0}" tabindex="${i===0?0:-1}" ${i ? 'disabled aria-disabled="true" title="Inactive"' : ''}>${label}</button>`).join('')}</div>
    <section class="settings-panel form-stack" role="tabpanel" id="settings-panel-profile" aria-labelledby="settings-tab-profile" data-settings-panel="profile">
    <label>Name<input name="name" value="${esc(a.name)}" required maxlength="24" aria-describedby="name-help" autocomplete="off"></label>
    ${nameSuggestions()}
    <label>Role<input name="role" value="${esc(a.role)}" required maxlength="60"></label>
    ${managerOptions(a)}
    <label>Work mode<select name="mode"><option value="normal" ${execution.mode === 'normal' ? 'selected' : ''}>Normal · high · up to 5 minutes</option><option value="deep" ${execution.mode === 'deep' ? 'selected' : ''}>Deep work · xhigh · up to 20 minutes</option></select></label>
    <label>Call timeout (seconds)<input name="timeout_seconds" type="number" min="15" max="${execution.mode === 'deep' ? 1200 : 300}" required value="${execution.timeout_seconds}"></label>
    </section>
    ${['context','usage','limits'].map(key => `<section class="settings-panel" role="tabpanel" id="settings-panel-${key}" aria-labelledby="settings-tab-${key}" hidden>Inactive</section>`).join('')}
    <button type="submit" class="button primary">Save</button></form>`, 'SAPIENS4');
};
actions['agent-settings'] = agentSettings;
document.addEventListener('change', e => {
  if (e.target.name !== 'mode') return;
  const timeout = e.target.form.elements.timeout_seconds;
  timeout.value = timeout.max = e.target.value === 'deep' ? 1200 : 300;
});
computerDialog = function() {
  modal('Shared computer', `<p>Blindly4 is the main computer-use tool. Ask a Sapi in chat to work on your computer.</p><div class="settings-row"><span>${live.computer.built ? 'Blindly4 is built' : 'Build required: run ./start.sh'}</span><span class="tag">${live.computer.owner ? `In use · ${esc(agent(live.computer.owner).name)}` : 'Available'}</span></div><p>Sapis share one computer. macOS Accessibility access is required for desktop interaction; permission failures appear in chat and the activity log.</p>`, 'BLINDLY4');
};
autonomyDialog = function() {
  modal('Local workspace', '<p>Connected to your local Codex CLI. Talk to your Sapis in chat, manage their notes, and save documents in their workspaces.</p><p>Tasks and Jobs are inactive. Sapis respond only to chat messages.</p>', 'SAPIENS4');
};

document.addEventListener('submit', async e => {
  const form = e.target;
  if (!['live-agent-form','live-settings-form'].includes(form.id)) return;
  e.preventDefault(); e.stopImmediatePropagation();
  const button = form.querySelector('button[type="submit"]') || form.querySelector('button');
  if (button.disabled) return;
  button.disabled = true;
  try {
    const data = Object.fromEntries(new FormData(form));
    if (!nameRule.test(data.name)) throw new Error(nameHelp);
    const created = form.id === 'live-agent-form';
    if (!created) {
      data.manager = data.manager || null;
      data.execution = {mode:data.mode, timeout_seconds:Number(data.timeout_seconds)};
      for (const key of Object.keys(data.execution)) delete data[key];
    }
    const row = await api(created ? '/api/agents' : `/api/agents/${form.dataset.id}`, created ? 'POST' : 'PUT', data);
    await refresh();
    closeModal();
    if (created) openChat(row.id);
    toast(created ? `${row.name} is ready.` : 'Sapi saved.');
  } catch (error) { toast(error.message); }
  finally { button.disabled = false; }
}, true);

document.addEventListener('click', async e => {
  const b = e.target.closest('button');
  if (!b) return;
  if (b.id === 'profile-button' || b.id === 'app-menu') {
    e.preventDefault(); e.stopImmediatePropagation(); autonomyDialog(); return;
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
renderAttachment = function() {
  const items = attachmentDrafts[state.selected] || [];
  $('#attachment-chip').innerHTML = items.map(a => `<div class="attachment-chip">${attachmentLabel(a)}<button type="button" data-remove-upload="${esc(a.id)}" aria-label="Remove ${esc(a.name)}">×</button></div>`).join('');
};
function attachmentMenu() {
  modal('Attach', `<div class="attachment-menu">${['image','document','link','filepath'].map(kind => `<button class="button" data-attachment-kind="${kind}">${kind === 'filepath' ? 'Filepath' : kind[0].toUpperCase() + kind.slice(1)}</button>`).join('')}</div>`, 'CHAT');
}
async function saveAttachment(id, data) {
  if ((attachmentDrafts[id] || []).length >= 8) throw new Error('Attach up to 8 items per message.');
  const item = await api(`/api/agents/${id}/attachments`, 'POST', data);
  (attachmentDrafts[id] ||= []).push(item);
  if (state.selected === id) renderAttachment();
  save();
}
async function pickAttachment(kind) {
  const id = state.selected;
  if (kind === 'link' || kind === 'filepath') {
    modal(kind === 'link' ? 'Add link' : 'Add filepath', `<form id="attachment-reference-form" data-id="${esc(id)}" data-kind="${kind}" class="form-stack"><label>${kind === 'link' ? 'Link' : 'Local filepath'}<input name="value" type="${kind === 'link' ? 'url' : 'text'}" placeholder="${kind === 'link' ? 'https://…' : '/Users/…/file.pdf'}" required maxlength="4096"></label><button class="button primary">Attach</button></form>`, 'CHAT');
    return;
  }
  const input = document.createElement('input');
  input.type = 'file';
  input.accept = kind === 'image' ? 'image/png,image/jpeg,image/gif,image/webp' : '.pdf,.txt,.md,.csv,.json,.doc,.docx,.xls,.xlsx,.ppt,.pptx,.rtf,.odt';
  input.addEventListener('change', async () => {
    const file = input.files[0];
    if (!file) return;
    uploading++; renderAgentHeader();
    try {
      if (file.size > 10 * 1024 * 1024) throw new Error('Files must be 10 MB or smaller.');
      const data = await new Promise((resolve, reject) => {
        const reader = new FileReader();
        reader.onload = () => resolve(reader.result.split(',')[1]);
        reader.onerror = () => reject(new Error('Could not read this file.'));
        reader.readAsDataURL(file);
      });
      await saveAttachment(id, {kind,name:file.name,data});
      closeModal();
    } catch (error) { toast(error.message); }
    finally { uploading--; renderAgentHeader(); }
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
      attachmentDrafts[state.selected] = (attachmentDrafts[state.selected] || []).filter(a => a.id !== b.dataset.removeUpload);
      renderAttachment(); save();
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
$('#message-input').addEventListener('input', () => {state.drafts[state.selected] = $('#message-input').value; save();});

async function refresh() {
  if (refreshing) return refreshing;
  refreshing = (async () => {
    try {
      const snapshot = await api(`/api/state?after=${cursor}`);
      const changed = ['agents','turns','computer','orchestration','activity'].some(k => JSON.stringify(snapshot[k]) !== JSON.stringify(live[k])) || snapshot.events.length;
      const reconnected = !online;
      online = true;
      const tabsChanged = (snapshot.preferences.workspace_revision || 0) > workspaceRevision;
      applySnapshot(snapshot);
      if (tabsChanged) {renderTabs(); renderWorkspace();}
      if (changed || reconnected) {
        renderSidebar(); renderConversation(); renderGlobal();
        if ($('#modal').open && $('#modal-title')?.textContent === 'Shared computer') computerDialog();
      }
    } catch (error) {
      online = false; renderGlobal(); renderAgentHeader();
    } finally { refreshing = null; }
  })();
  return refreshing;
}
applySnapshot(bootstrap);
savedPreferences = JSON.stringify(preferences());
render();
async function poll() {
  await refresh();
  updateProgress();
  setTimeout(poll, online ? 750 : 2000);
}
setTimeout(poll, 750);
