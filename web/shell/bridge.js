let live = bootstrap;
let online = window.SapiensConnections ? SapiensConnections.connected : true;
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
const blocksChat = turn => ['queued','running','output_pending'].includes(turn.status);
const statusNames = {output_pending:'Awaiting output pulse',queued:'Queued',running:'Running',done:'Completed',warning:'Warning',failed:'Failed',
  interrupted:'Interrupted',conflict:'Needs review',cancelled:'Dismissed'};
const displayTime = value => new Date(value).toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'});
const originalConversation = renderConversation;

function preferences() {
  return {selected:state.selected,panel:state.panel,scope:state.scope,groupView:state.groupView,panes:state.panes,
    drafts:state.drafts,
    attachment_drafts:Object.fromEntries(Object.entries(attachmentDrafts).map(([id, items]) => [id, items.map(a => a.id)]))};
}
save = function() {
  window.SapiensConnections?.save({...preferences(),workspaces:state.workspaces,scroll:$('#conversation-body').scrollTop});
  clearTimeout(saveTimer);
  saveTimer = setTimeout(flushPreferences, 300);
};
async function flushPreferences() {
  if (saving || !online || window.SapiensConnections?.busy) return;
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
getMessages = id => state.messages[id] || [];

function turnActions(turn) {
  if (turn.status === 'running') return `<div class="actions"><button class="button" data-live-turn="cancel" data-id="${esc(turn.id)}" data-owner="${esc(turn.agent)}" ${!online || (live.run_activity?.[turn.batch_id || turn.id] || live.activity?.[turn.agent])?.stopping ? 'disabled' : ''}>Stop</button><small>Already completed actions are not undone.</small></div>`;
  if (attention.has(turn.status)) return `<div class="actions"><button class="button" data-live-turn="retry" data-id="${esc(turn.id)}" data-owner="${esc(turn.agent)}">Retry</button><button class="button" data-live-turn="cancel" data-id="${esc(turn.id)}" data-owner="${esc(turn.agent)}">Dismiss</button></div>`;
  if (turn.status === 'queued') return `<div class="actions"><button class="button" data-live-turn="cancel" data-id="${esc(turn.id)}" data-owner="${esc(turn.agent)}">Cancel queued turn</button></div>`;
  return '';
}

function turnProgress(turn, now = Date.now()) {
  const current = live.run_activity?.[turn.batch_id || turn.id] || live.activity?.[turn.agent];
  const a = current?.turn === turn.id ? current : {};
  const elapsed = Math.max(0, Math.floor((now - (a.started || Date.parse(turn.created))) / 1000));
  const quiet = Math.max(0, Math.floor((now - (a.updated || a.started || now)) / 1000));
  const phase = !online ? 'Disconnected' : a.stopping ? 'Stopping…' : turn.status === 'output_pending' ? 'Awaiting output pulse' : turn.status === 'queued' ? 'Queued' : a.phase || 'Starting model';
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
  const identity=document.getElementById('corpora-identity');
  if(identity && snapshot.corpora) {
    identity.hidden=false;identity.textContent=snapshot.corpora.name;identity.title=snapshot.corpora.id;
  }
  receiveWorkspaces(snapshot.preferences);
  live = snapshot;
  const old = new Map(state.agents.map(a => [a.id,a]));
  state.agents = snapshot.agents.map(a => ({...old.get(a.id),...a,kind:'sapi',scope:'personal',
    autonomy:'assist',status:'online',lastActivity:Date.parse(a.created),preview:'Ready for your message.'}));
  state.messages = {};
  for (const turn of snapshot.turns) {
    if(turn.group) continue;
    const messages = state.messages[turn.agent] ||= [];
    const timestamp = Date.parse(turn.created);
    if (['chat','computer'].includes(turn.flow)) messages.push({role:'user',author:turn.origin?.caller,text:turn.input,time:displayTime(turn.created),timestamp,attachments:turn.attachments,requestTurn:turn});
    if (['chat','computer'].includes(turn.flow) && ['done','warning'].includes(turn.status) && turn.output !== null) {
      messages.push({role:'assistant',...chatResult(turn),time:displayTime(turn.output_at || turn.created),timestamp:Date.parse(turn.output_at || turn.created),outputOrder:turn.output_order,turnId:turn.id});
    }
    const a = state.agents.find(a => a.id === turn.agent);
    if (a && (['chat','computer'].includes(turn.flow))) {
      a.lastActivity = timestamp;
      a.preview = (['done','warning'].includes(turn.status) && turn.output !== null ? chatResult(turn).text : turn.input).replace(/\s+/g,' ').slice(0,150);
    }
    if (a && turn.status === 'running') a.status = 'busy';
  }
  for(const group of snapshot.groups || []) {
    state.agents.push({...group,status:group.requests.some(r=>r.status==='running')?'busy':'online',lastActivity:Date.parse(group.updated),preview:group.messages.at(-1)?.text || group.description || 'Shared workspace'});
    state.messages[group.id]=group.messages.map(m=>({role:m.author==='admin'?'user':'assistant',author:m.author==='admin'?null:m.author,text:m.text,time:displayTime(m.created),timestamp:Date.parse(m.created)}));
  }
  delegationMessages(snapshot);
  for (const messages of Object.values(state.messages)) messages.sort((a,b)=>a.timestamp-b.timestamp || (a.outputOrder || 0)-(b.outputOrder || 0));
  if (!state.agents.some(a => a.id === state.selected) ||
      (agent(state.selected).retired && !old.get(state.selected)?.retired)) {
    state.drafts[state.selected] = $('#message-input').value;
    state.selected = snapshot.main_agent_id;
    $('#message-input').value = state.drafts[state.selected] || '';
    renderTabs(); renderWorkspace();
  }
}

renderGlobal = function() {
  if(!window.SapiensConnections) {
    const remote = $('#remote-status');
    const connected = online && (!remote || remote.dataset.connected === 'true');
    $('#connection-label').textContent = `${remote ? 'Remote' : 'Local'} · ${connected ? 'Online' : 'Reconnecting…'}`;
    $('#connection-status').dataset.online = String(connected);
  }
  const owner = live.computer.owner;
  $('#resource-owner').textContent = owner ? `In use · ${agent(owner).name}` : live.computer.built ? 'Blindly4 · Available' : 'Blindly4 · Build required';
  $('#resource-status').classList.toggle('idle', !owner);
  $('#resource-status').classList.remove('paused');
};

window.addEventListener('sapiens-connection-change', () => {if(window.SapiensConnections)online=SapiensConnections.connected&&!SapiensConnections.busy;renderGlobal();renderAgentHeader();});

renderAgentHeader = function() {
  const a = selected();
  const turn = a.kind==='group'?null:live.turns.find(j => j.agent === a.id && blocksChat(j));
  $('#agent-heading').innerHTML = `${avatar(a,isMainSapi(a)?'large main-sapi-avatar':'large',true)}<div><div class="agent-title"><h2>${esc(a.name)}</h2>${a.kind==='group'?'':groupLabels(a)}</div><p class="agent-role">${esc(a.kind==='group'?a.description:a.role)}</p></div><button class="icon-button" data-action="agent-settings" aria-label="Sapi settings">···</button>`;
  $('#message-input').placeholder = paneLimit()<3 ? 'Message…' : `Message ${a.name}…`;
  $('#message-input').setAttribute('aria-label',`Message ${a.name}`);
  resizeComposer();
  renderActivityNavigation();
  $('#attach-button').hidden = Boolean(a.archived);
  $('.send-button').disabled = a.retired || a.archived || live.corpora?.status==='paused' || live.corpora?.status==='archived' || !online || submitting.has(a.id) || uploading > 0;
};

// Keep existing messages mounted: clearing the scroll container interrupts iOS
// momentum scrolling, even when scrollTop is restored in the same JavaScript turn.
function commitChat(viewport, content, changedView, bottom, scroll, anchor) {
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
  if (bottom && changed) target = viewport.scrollHeight - viewport.clientHeight;
  else if (anchor?.node.isConnected) {
    target = viewport.scrollTop + anchor.node.getBoundingClientRect().top - anchor.top;
  }
  // Writing scrollTop during every poll also cancels momentum in WebKit.
  if (Math.abs(viewport.scrollTop - target) > 1) viewport.scrollTop = target;
}

let renderedConversation = '';
renderConversation = function() {
  const viewport = $('#conversation-body');
  if(['tasks','notes'].includes(state.panel)){workView=state.panel==='notes'?'memo':'tasks';state.panel='work';}
  viewport.classList.toggle('notes-view', state.panel === 'notes');
  const turns = live.turns.filter(j => j.agent === state.selected);
  const key = state.selected + ':' + state.panel + ':'+(state.panel==='work'?workView:state.panel==='chat'?chatView:updatesView);
  const changedView = renderedConversation !== key;
  renderedConversation = key;
  const scroll = changedView ? 0 : viewport.scrollTop;
  const bottom = state.panel === 'chat' && (changedView || viewport.scrollHeight - viewport.scrollTop - viewport.clientHeight < 80);
  const firstVisible = !changedView && !bottom && [...viewport.children].find(node => node.getBoundingClientRect().bottom > viewport.getBoundingClientRect().top);
  const anchor = firstVisible ? {node:firstVisible,top:firstVisible.getBoundingClientRect().top} : null;
  const chat = state.panel === 'chat' && chatView === 'conversation';
  const host = chat ? document.createElement('div') : viewport;
  const finish = () => { if (chat) commitChat(viewport, host, changedView, bottom, scroll, anchor); };
  if(renderChatCollection(host)){renderAgentHeader();renderGlobal();return;}
  if(selected().kind==='group') {renderGroupPanel(host);renderAgentHeader();renderGlobal();if(chat)finish();else if(changedView)viewport.scrollTop=0;return;}
  if(state.panel==='work' || state.panel==='updates') {renderWork(host);renderAgentHeader();renderGlobal();if(changedView)host.scrollTop=0;return;}
  if (state.panel === 'chat') {
    originalConversation(host);
    host.querySelectorAll('.message').forEach((node,i) => {
      const message=getMessages(state.selected)[i];
      if (message?.author) node.querySelector('.message-meta strong').textContent = agent(message.author).name;
      if (message?.delegation && message.requestTurn && blocksChat(message.requestTurn)) node.querySelector('.message-bubble').insertAdjacentHTML('beforeend', turnActions(message.requestTurn));
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
      node.querySelector('.message-meta strong').textContent = humanMessages[i]?.author ? agent(humanMessages[i].author).name : 'Admin';
      const attachments = humanMessages[i]?.attachments || [];
      if (attachments.length) node.querySelector('.message-bubble').insertAdjacentHTML('beforeend', `<div class="message-attachments">${attachments.map(attachmentLabel).join('')}</div>`);
    });
    taskCallControls(host);
    if (!getMessages(state.selected).length) host.insertAdjacentHTML('beforeend', '<div class="empty">Start a conversation.</div>');
    const activeTurns = turns.filter(j => blocksChat(j) && (!j.batch_id || j.batch_id===j.id));
    for (const turn of activeTurns) {
      host.insertAdjacentHTML('beforeend', `<section data-chat-key="progress:${esc(turn.id)}" class="live-status"><div data-turn-progress="${esc(turn.id)}">${turnProgress(turn)}</div>${turnActions(turn)}</section>`);
    }
  } else if (state.panel === 'tasks') {
    $('#composer-area').hidden = true;
    renderTasks(host);
  } else if (state.panel === 'notes') {
    $('#composer-area').hidden = true;
    renderNotes(host);
  }
  renderAgentHeader(); renderGlobal();
  finish();
};

sendChat = async function(value) {
  const text = value.trim();
  const id = state.selected;
  const attachments = [...(attachmentDrafts[id] || [])];
  if ((!text && !attachments.length) || submitting.has(id) || uploading) return;
  submitting.add(id); renderAgentHeader();
  try {
    if(selected().kind==='group') await api(`/api/groups/${id}/messages`, 'POST', {text,attachments:attachments.map(a=>a.id)});
    else await api(`/api/agents/${id}/messages`, 'POST', {text,attachments:attachments.map(a => a.id),
      ...(clarificationWorkload?.owner === id ? {workload:clarificationWorkload.id} : {})});
    clarificationWorkload = null;
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
  leaveGroup('all');
  const input=$('#message-input');
  if(!input.value.trim())input.value=bootstrap.creation_template;
  state.drafts[state.mainSapiId]=input.value;
  input.focus();
  const start=input.value.indexOf('WORKFLOW');
  if(start>=0)input.setSelectionRange(start,start+8);
  save();
};
agentSettings = function() {
  const a = selected();
  if(a.kind==='group'){groupDialog(a);return;}
  const execution = live.orchestration[a.id].execution;
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
computerDialog = function() {
  const windows = live.computer.platform === 'win32';
  modal('Shared computer', `<p>Blindly4 is the main computer-use tool. Ask a Sapi in chat to work on your computer.</p><div class="settings-row"><span>${live.computer.built ? 'Blindly4 is built' : `Build required: run ${windows ? '.\\start.ps1' : './start.sh'}`}</span><span class="tag">${live.computer.owner ? `In use · ${esc(agent(live.computer.owner).name)}` : 'Available'}</span></div><p>Sapis share one computer. ${windows ? 'Windows UI Automation works with accessible apps on your desktop. Elevated apps and secure system dialogs cannot be controlled.' : 'macOS Accessibility access is required for desktop interaction; permission failures appear in chat.'}</p>`, 'BLINDLY4');
};
autonomyDialog = function() {
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
renderAttachment = function() {
  const items = attachmentDrafts[state.selected] || [];
  $('#attachment-chip').innerHTML = items.map(a => `<div class="attachment-chip">${attachmentLabel(a)}<button type="button" data-remove-upload="${esc(a.id)}" aria-label="Remove ${esc(a.name)}">×</button></div>`).join('');
};
function attachmentMenu() {
  modal('Attach', `<div class="attachment-menu">${['image','document','link','filepath'].map(kind => `<button class="button" data-attachment-kind="${kind}">${kind === 'filepath' ? 'Filepath' : kind[0].toUpperCase() + kind.slice(1)}</button>`).join('')}</div>`, 'CHAT');
}
async function saveAttachment(id, data) {
  if ((attachmentDrafts[id] || []).length >= 8) throw new Error('Attach up to 8 items per message.');
  const item = await api(`/api/${id.startsWith('group_')?'groups':'agents'}/${id}/attachments`, 'POST', data);
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
  const connectionGeneration=window.SapiensConnections?.generation;
  refreshing = (async () => {
    try {
      const snapshot = await api('/api/state');
      if(connectionGeneration!==window.SapiensConnections?.generation)return;
      window.SapiensConnections?.snapshot(snapshot);
      const changed = ['corpora','agents','groups','turns','computer','orchestration','activity','run_activity','workloads','pulses','routines','events'].some(k => JSON.stringify(snapshot[k]) !== JSON.stringify(live[k]));
      const reconnected = !online;
      online = true;
      const tabsChanged = (snapshot.preferences.workspace_revision || 0) > workspaceRevision;
      applySnapshot(snapshot);
      if (tabsChanged) {renderTabs(); renderWorkspace();}
      else refreshWorkspacePreview();
      if (changed || reconnected) {
        renderSidebar(); renderConversation(); renderGlobal();
        if ($('#modal').open && $('#modal-title')?.textContent === 'Shared computer') computerDialog();
      }
    } catch (error) {
      if(connectionGeneration!==window.SapiensConnections?.generation)return;
      online = false; window.SapiensConnections?.offline(error); renderGlobal(); renderAgentHeader();
    } finally { refreshing = null; }
  })();
  return refreshing;
}
applySnapshot(bootstrap);
savedPreferences = JSON.stringify(preferences());
render();
if (Number.isFinite(bootstrap.preferences.scroll)) {
  $('#conversation-body').scrollTop = bootstrap.preferences.scroll;
  save();
}
async function poll() {
  await refresh();
  updateProgress();
  setTimeout(poll, (window.sapiensRemote||window.SapiensConnections?.remote) ? 2000 : online ? 750 : 2000);
}
setTimeout(poll, 750);

window.sapiensWorkspace = {save:()=>{
  state.drafts[state.selected]=$('#message-input').value;
  window.SapiensConnections?.save({...preferences(),workspaces:state.workspaces,scroll:$('#conversation-body').scrollTop});
}};
window.addEventListener('pagehide',()=>window.sapiensWorkspace.save());
document.addEventListener('visibilitychange',()=>{if(document.hidden)window.sapiensWorkspace.save();else refresh();});
window.SapiensConnections?.subscribe(snapshot=>{
  clearTimeout(saveTimer);
  if (snapshot.corpora?.id === live.corpora?.id) {
    // A cached workspace becoming live is a refresh, not navigation. Keep the
    // chat, draft and reading position the user chose while reconnecting.
    online=SapiensConnections.connected;
    applySnapshot(snapshot);renderSidebar();renderConversation();renderTabs();renderWorkspace();renderGlobal();
    return;
  }
  state=makeInitialState(snapshot);live=snapshot;online=SapiensConnections.connected;
  workspaceRevision=snapshot.preferences.workspace_revision||0;
  workspaceOwner=state.selected;renderedConversation='';search='';$('#agent-search').value='';
  Object.keys(attachmentDrafts).forEach(key=>delete attachmentDrafts[key]);Object.assign(attachmentDrafts,snapshot.attachment_drafts||{});
  $('#message-input').value=state.drafts[state.selected]||'';
  applySnapshot(snapshot);savedPreferences=JSON.stringify(preferences());render();
  if(Number.isFinite(snapshot.preferences.scroll))$('#conversation-body').scrollTop=snapshot.preferences.scroll;
  save();
});
