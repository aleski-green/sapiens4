// Live adapters replace prototype behavior while retaining its UI and workspace renderer.
let live = bootstrap;
let cursor = 0;
let eventRows = [];
let online = true;
let refreshing = null;
let saveTimer;
let saving = false;
let savedPreferences = '';
const submitting = new Set();
const attachmentDrafts = bootstrap.attachment_drafts || {};
let uploading = 0;
const nameRule = /^[A-Z][A-Za-z0-9_.:#+|()&$^\-]*$/;
const nameHelp = 'Start with A–Z. Letters, numbers, and - _ . : # + | ( ) & $ ^ are allowed. No spaces.';
const attention = new Set(['failed','interrupted','conflict','budget_blocked']);
const statusNames = {queued:'Queued',running:'Running',done:'Completed',failed:'Failed',
  interrupted:'Interrupted',conflict:'Needs review',budget_blocked:'Budget blocked',cancelled:'Dismissed'};
const displayTime = value => new Date(value).toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'});
const originalConversation = renderConversation;

function preferences() {
  storeWorkspace();
  return {selected:state.selected,panel:state.panel,scope:state.scope,panes:state.panes,
    workspaces:state.workspaces,drafts:state.drafts,work_views:workViews,
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
    await api('/api/preferences', 'PUT', JSON.parse(value));
    savedPreferences = value;
  } catch (error) {
    toast(`Workspace changes are not saved yet: ${error.message}`);
  } finally {
    saving = false;
    if (JSON.stringify(preferences()) !== savedPreferences) saveTimer = setTimeout(flushPreferences, 2000);
  }
}
getMessages = id => state.messages[id] || [];

function jobActions(job) {
  if (attention.has(job.status)) return `<div class="actions"><button class="button" data-live-job="retry" data-id="${esc(job.id)}" data-owner="${esc(job.agent)}">Retry</button><button class="button" data-live-job="cancel" data-id="${esc(job.id)}" data-owner="${esc(job.agent)}">Dismiss</button></div>`;
  if (job.status === 'queued') return `<div class="actions"><button class="button" data-live-job="cancel" data-id="${esc(job.id)}" data-owner="${esc(job.agent)}">Cancel queued job</button></div>`;
  return '';
}

function applySnapshot(snapshot) {
  live = snapshot;
  const known = new Set(eventRows.map(e => e.id));
  eventRows.push(...snapshot.events.filter(e => !known.has(e.id)));
  eventRows = eventRows.slice(-1000);
  cursor = snapshot.cursor;
  const old = new Map(state.agents.map(a => [a.id,a]));
  state.agents = snapshot.agents.map(a => ({...old.get(a.id),...a,kind:'sapi',scope:'personal',
    autonomy:'assist',status:'online',lastActivity:Date.parse(a.created),preview:'Ready for your message.'}));
  state.messages = {};
  pending.clear();
  for (const job of snapshot.jobs) {
    const messages = state.messages[job.agent] ||= [];
    const timestamp = Date.parse(job.created);
    if (['chat','computer'].includes(job.flow)) messages.push({role:'user',text:job.input,time:displayTime(job.created),timestamp,attachments:job.attachments});
    if (['chat','computer'].includes(job.flow) && job.status === 'done' && job.output !== null) {
      messages.push({role:'assistant',text:job.output,time:displayTime(job.created),timestamp});
    }
    const a = state.agents.find(a => a.id === job.agent);
    if (a && ['chat','computer'].includes(job.flow)) {
      a.lastActivity = timestamp;
      a.preview = (job.status === 'done' && job.output !== null ? job.output : job.input).replace(/\s+/g,' ').slice(0,150);
    }
    if (a && job.status === 'running') a.status = 'busy';
    if (job.status === 'queued' || job.status === 'running') pending.add(job.agent);
  }
  for (const notice of snapshot.task_assignments || []) {
    for (const owner of new Set([notice.agent, notice.assigned_by])) {
      const timestamp=Date.parse(notice.time);
      (state.messages[owner] ||= []).push({role:'assistant',speaker:notice.agent,
        text:`New @${notice.name} assigned.`,time:displayTime(notice.time),timestamp,assignment:true});
      const a=state.agents.find(a=>a.id===owner);
      if (a && timestamp > a.lastActivity) {a.lastActivity=timestamp;a.preview=`New @${notice.name} assigned.`;}
    }
  }
  for (const update of snapshot.task_updates || []) {
    for (const owner of new Set([update.agent,update.assigned_by])) {
      const timestamp=Date.parse(update.time), text=`@${update.name} · ${update.text}`;
      (state.messages[owner] ||= []).push({role:'assistant',speaker:update.agent,text,
        time:displayTime(update.time),timestamp,assignment:true});
      const a=state.agents.find(a=>a.id===owner);
      if (a && timestamp>a.lastActivity) {a.lastActivity=timestamp;a.preview=text.replace(/\s+/g,' ').slice(0,150);}
    }
  }
  for (const messages of Object.values(state.messages)) messages.sort((a,b)=>a.timestamp-b.timestamp);
  if (!state.agents.some(a => a.id === state.selected)) state.selected = state.agents[0].id;
  state.logs = eventRows.slice().reverse().map(e => ({agent:e.agent,time:displayTime(e.time),title:e.kind,detail:e.detail}));
  state.computer.owner = snapshot.computer.owner;
  state.tasks = snapshot.jobs.map(j => ({id:j.id,agent:j.agent,status:statusNames[j.status]}));
}

renderGlobal = function() {
  $('#autonomy-label').textContent = online ? 'Connected' : 'Reconnecting…';
  $('#autonomy-button').classList.toggle('live-disconnected', !online);
  const owner = live.computer.owner;
  $('#resource-owner').textContent = owner ? `In use · ${agent(owner).name}` : live.computer.built ? 'Blindly4 · Available' : 'Blindly4 · Build required';
  $('#resource-status').classList.toggle('idle', !owner);
  $('#resource-status').classList.remove('paused');
  $('#workspace-owner').innerHTML = `${mention(workspaceOwner)}<span>’s workspace</span>`;
  $('#task-count').textContent = live.orchestration?.[state.selected]?.tasks.length || 0;
};

renderAgentHeader = function() {
  const a = selected();
  const job = live.jobs.find(j => j.agent === a.id && !['done','cancelled'].includes(j.status));
  $('#agent-heading').innerHTML = `${avatar(a,'large')}<div><h2>${esc(a.name)}</h2><p class="agent-role">${esc(a.role)}</p></div><button class="icon-button" data-action="agent-settings" aria-label="Sapi settings">···</button>`;
  $('#message-input').placeholder = `Message ${a.name}…`;
  $$('[data-panel]').forEach(b => {b.classList.toggle('active',b.dataset.panel === state.panel);b.setAttribute('aria-pressed',b.dataset.panel === state.panel);});
  $('.send-button').disabled = !online || Boolean(job) || submitting.has(a.id) || uploading > 0;
};

renderConversation = function() {
  const host = $('#conversation-body');
  const jobs = live.jobs.filter(j => j.agent === state.selected);
  const scroll = host.scrollTop;
  const bottom = host.scrollHeight - host.scrollTop - host.clientHeight < 80;
  if (state.panel === 'chat') {
    originalConversation();
    host.querySelector('.day-divider').textContent = 'CONVERSATION';
    host.querySelector('.suggestions')?.remove();
    host.querySelector('.typing')?.remove();
    host.querySelectorAll('.message').forEach((node,i) => {
      const message=getMessages(state.selected)[i];
      if (message?.assignment) {
        const speaker=agent(message.speaker);
        node.classList.add('assignment-message');
        node.querySelector('.message-meta').innerHTML=`${avatar(speaker,'mini')}<strong>${mention(speaker.id)}</strong><time>${esc(message.time)}</time>`;
      }
    });
    const humanMessages = getMessages(state.selected).filter(m => m.role === 'user');
    host.querySelectorAll('.message.user').forEach((node, i) => {
      node.querySelector('.message-meta strong').textContent = 'Human';
      const attachments = humanMessages[i]?.attachments || [];
      if (attachments.length) node.querySelector('.message-bubble').insertAdjacentHTML('beforeend', `<div class="message-attachments">${attachments.map(attachmentLabel).join('')}</div>`);
    });
    if (!getMessages(state.selected).length) host.insertAdjacentHTML('beforeend', '<div class="empty">Start a conversation.</div>');
    const job = jobs.find(j => !['done','cancelled'].includes(j.status));
    if (job) {
      const started = eventRows.slice().reverse().find(e => e.job === job.id && e.kind === 'started');
      const event = eventRows.slice().reverse().find(e => e.job === job.id && e.kind === 'codex' && (!started || e.time >= started.time));
      const detail = job.status === 'queued' ? 'Waiting for the local runner.' : job.error || event?.detail || 'Codex is working…';
      host.insertAdjacentHTML('beforeend', `<section class="live-status" role="status"><strong>${esc(statusNames[job.status])}</strong><p>${esc(detail)}</p>${job.status === 'interrupted' ? '<p>The previous run stopped. Check what happened before retrying a computer task.</p>' : ''}${jobActions(job)}</section>`);
    }
  } else {
    $('#composer-area').hidden = true;
    host.innerHTML = workPanel(state.panel, jobs);
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
  const info = live.orchestration[a.id];
  const schedule = info.schedule;
  const job = live.jobs.find(j => j.agent === a.id && !['done','cancelled'].includes(j.status));
  modal(`${a.name} settings`, `<form id="live-settings-form" data-id="${esc(a.id)}" class="form-stack">
    <label>Name<input name="name" value="${esc(a.name)}" required maxlength="24" aria-describedby="name-help" autocomplete="off"></label>
    ${nameSuggestions()}
    <label>Role<input name="role" value="${esc(a.role)}" required maxlength="60"></label>
    ${managerOptions(a)}
    <fieldset class="schedule-fields"><legend>Scheduled checks</legend>
      <label class="check-label"><input name="enabled" type="checkbox" ${schedule.enabled ? 'checked' : ''}> Enable checks</label>
      <label>Check every (minutes)<input name="minutes" type="number" min="1" max="1440" step="1" required value="${schedule.minutes}"></label>
      <label class="check-label"><input name="monitor_team" type="checkbox" ${schedule.monitor_team ? 'checked' : ''}> Include team progress</label>
    </fieldset>
    <fieldset class="schedule-fields"><legend>Recent memory</legend>
      <label class="check-label"><input name="recent_enabled" type="checkbox" ${info.recent.enabled ? 'checked' : ''}> Reuse recent results for follow-ups</label>
      <label>Fresh for (seconds)<input name="recent_seconds" type="number" min="1" max="3600" step="1" required value="${info.recent.seconds}"></label>
      <small>“Do it again” or “check current state” always checks afresh.</small>
    </fieldset>
    <dl class="sapi-details"><dt>Status</dt><dd>${esc(job ? statusNames[job.status] : 'Ready')}</dd><dt>Next check</dt><dd>${schedule.enabled && schedule.next_check ? esc(new Date(schedule.next_check).toLocaleString()) : 'Paused'}</dd><dt>Last check</dt><dd>${schedule.last_check ? esc(new Date(schedule.last_check).toLocaleString()) : 'Not yet'}</dd><dt>Memory</dt><dd>${info.memory_entries} ${info.memory_entries === 1 ? 'entry' : 'entries'}</dd></dl>
    <small class="form-hint">Checks run while the local server is running.</small>
    <button type="submit" class="button primary">Save</button></form>`, 'SAPIENS4');
};
actions['agent-settings'] = agentSettings;
computerDialog = function() {
  modal('Shared computer', `<p>Blindly4 is the main computer-use tool. Ask a Sapi in chat to work on your computer.</p><div class="settings-row"><span>${live.computer.built ? 'Blindly4 is built' : 'Build required: run ./start.sh'}</span><span class="tag">${live.computer.owner ? `In use · ${esc(agent(live.computer.owner).name)}` : 'Available'}</span></div><p>Jobs run one at a time. macOS Accessibility access is required for desktop interaction; permission failures appear in the job and activity log.</p>`, 'BLINDLY4');
};
autonomyDialog = function() {
  modal('Local workspace', '<p>Connected to your local Codex CLI. Chat can set wake-up intervals, assign managers, create tasks, inspect team progress, and request memory learning.</p><p>Scheduled checks run while this server is running. Ask a Sapi to pause its checks or change the interval. Sapi settings shows its saved schedule and memory count. Groups are planned for the next iteration.</p>', 'SAPIENS4');
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
      data.schedule = {enabled:form.elements.enabled.checked,minutes:Number(data.minutes),monitor_team:form.elements.monitor_team.checked};
      data.recent = {enabled:form.elements.recent_enabled.checked,seconds:Number(data.recent_seconds)};
      delete data.recent_enabled; delete data.recent_seconds;
      delete data.enabled; delete data.minutes; delete data.monitor_team;
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
  if (!b.dataset.liveJob) return;
  e.preventDefault(); e.stopImmediatePropagation(); b.disabled = true;
  try {
    await api(`/api/agents/${b.dataset.owner}/jobs/${b.dataset.id}/${b.dataset.liveJob}`, 'POST', {});
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

// Remove simulation entry points; workspace tabs and appearance remain upstream UI.
$('#attach-button').setAttribute('aria-label', 'Add attachment');
$('#profile-button').textContent = 'Human';
$('.composer-hint').remove();
$('[data-scope="groups"]').disabled = true;
$('[data-scope="groups"]').title = 'Groups are coming in the next iteration';
$('[data-panel="cron"]').hidden = false;
$('[data-panel="cron"]').textContent = 'Jobs';
$('.conversation-tabs').insertBefore($('[data-panel="cron"]'), $('[data-panel="log"]'));
$('[data-panel="tasks"]').innerHTML = 'Tasks <span id="task-count">0</span>';
$('#message-input').maxLength = 16000;
$('#message-input').value = state.drafts[state.selected] || '';
$('#message-input').addEventListener('input', () => {state.drafts[state.selected] = $('#message-input').value; save();});

async function refresh() {
  if (refreshing) return refreshing;
  refreshing = (async () => {
    try {
      const snapshot = await api(`/api/state?after=${cursor}`);
      const changed = JSON.stringify([snapshot.agents,snapshot.jobs,snapshot.computer,snapshot.orchestration,snapshot.task_assignments,snapshot.task_updates]) !== JSON.stringify([live.agents,live.jobs,live.computer,live.orchestration,live.task_assignments,live.task_updates]) || snapshot.events.length;
      const reconnected = !online;
      online = true;
      applySnapshot(snapshot);
      if (changed || reconnected) {
        renderSidebar(); renderConversation(); renderGlobal();
        if ($('#task-details-body')) refreshTaskDialog();
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
  setTimeout(poll, online ? 750 : 2000);
}
setTimeout(poll, 750);
