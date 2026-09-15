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
const attention = new Set(['failed','interrupted','conflict','budget_blocked']);
const statusNames = {queued:'Queued',running:'Running',done:'Completed',failed:'Failed',
  interrupted:'Interrupted',conflict:'Needs review',budget_blocked:'Budget blocked',cancelled:'Dismissed'};
const displayTime = value => new Date(value).toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'});
const originalConversation = renderConversation;

function preferences() {
  storeWorkspace();
  return {selected:state.selected,panel:state.panel,scope:state.scope,panes:state.panes,
    workspaces:state.workspaces,drafts:state.drafts};
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
    messages.push({role:'user',text:job.input,time:displayTime(job.created),timestamp});
    if (job.status === 'done' && job.output !== null) {
      messages.push({role:'assistant',text:job.output,time:displayTime(job.created),timestamp});
    }
    const a = state.agents.find(a => a.id === job.agent);
    if (a) {
      a.lastActivity = timestamp;
      a.preview = (job.status === 'done' && job.output !== null ? job.output : job.input).replace(/\s+/g,' ').slice(0,150);
      a.status = job.status === 'running' ? 'busy' : 'online';
    }
    if (job.status === 'queued' || job.status === 'running') pending.add(job.agent);
  }
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
  $('#task-count').textContent = live.jobs.filter(j => j.agent === state.selected && !['done','cancelled'].includes(j.status)).length;
};

renderAgentHeader = function() {
  const a = selected();
  const job = live.jobs.find(j => j.agent === a.id && !['done','cancelled'].includes(j.status));
  const status = job ? statusNames[job.status] : 'Ready';
  $('#agent-heading').innerHTML = `${avatar(a,'large')}<div><h2>${esc(a.name)} <span class="muted" style="font-weight:400">/ ${esc(a.role)}</span></h2><p><span class="status-dot"></span> ${esc(status)}</p></div><button class="icon-button" data-action="agent-settings" aria-label="Agent settings">···</button>`;
  $('#message-input').placeholder = `Message ${a.name}…`;
  $$('[data-panel]').forEach(b => {b.classList.toggle('active',b.dataset.panel === state.panel);b.setAttribute('aria-pressed',b.dataset.panel === state.panel);});
  $('.composer-hint span').textContent = $('#live-flow').value === 'computer' ? 'Runs with Blindly4' : 'Conversation · text only';
  $('.send-button').disabled = !online || Boolean(job) || submitting.has(a.id);
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
    if (!jobs.length) host.insertAdjacentHTML('beforeend', '<div class="empty">Start a conversation, or choose Computer task to work with Blindly4.</div>');
    const job = jobs.find(j => !['done','cancelled'].includes(j.status));
    if (job) {
      const started = eventRows.slice().reverse().find(e => e.job === job.id && e.kind === 'started');
      const event = eventRows.slice().reverse().find(e => e.job === job.id && e.kind === 'codex' && (!started || e.time >= started.time));
      const detail = job.status === 'queued' ? 'Waiting for the local runner.' : job.error || event?.detail || 'Codex is working…';
      host.insertAdjacentHTML('beforeend', `<section class="live-status" role="status"><strong>${esc(statusNames[job.status])}</strong><p>${esc(detail)}</p>${job.status === 'interrupted' ? '<p>The previous run stopped. Check what happened before retrying a computer task.</p>' : ''}${jobActions(job)}</section>`);
    }
  } else if (state.panel === 'tasks') {
    $('#composer-area').hidden = true;
    host.innerHTML = '<div class="list-heading"><h3>Jobs</h3><span class="tag">LIVE</span></div>' + jobs.slice().reverse().map(j => `<article class="live-job"><span class="tag">${esc(statusNames[j.status])}</span><h3>${esc(j.input)}</h3><small>${j.flow === 'computer' ? 'Computer task · Blindly4' : 'Chat'} · ${esc(new Date(j.created).toLocaleString())} · ${j.tokens} tokens</small>${j.error ? `<p>${esc(j.error)}</p>` : ''}${jobActions(j)}</article>`).join('') + (jobs.length ? '' : '<div class="empty">Chat and computer jobs will appear here.</div>');
  } else {
    $('#composer-area').hidden = true;
    host.innerHTML = '<div class="list-heading"><h3>Activity log</h3><span class="tag">LIVE</span></div>' + eventRows.filter(e => e.agent === state.selected).slice(-200).reverse().map(e => `<div class="log-row"><time>${esc(displayTime(e.time))}</time><strong>${esc(e.kind)}</strong><p>${esc(e.detail)}</p></div>`).join('');
  }
  renderAgentHeader(); renderGlobal();
  host.scrollTop = bottom ? host.scrollHeight : scroll;
};

sendChat = async function(value) {
  const text = value.trim();
  const id = state.selected;
  if (!text || submitting.has(id)) return;
  submitting.add(id); renderAgentHeader();
  try {
    await api(`/api/agents/${id}/messages`, 'POST', {text,flow:$('#live-flow').value});
    if (state.drafts[id]?.trim() === text) state.drafts[id] = '';
    if (state.selected === id && $('#message-input').value.trim() === text) {
      $('#message-input').value = ''; state.drafts[id] = '';
    }
    save();
    await refresh();
  } catch (error) { toast(error.message); }
  finally { submitting.delete(id); renderAgentHeader(); }
};

addAgent = function() {
  modal('Create Sapi', `<form id="live-agent-form" class="form-stack"><label>Name<input name="name" required maxlength="24" placeholder="e.g. Nova"></label><label>Role<input name="role" required maxlength="60" placeholder="e.g. Research assistant"></label><label>Personality<select name="face"><option value="◠‿◠">(◠‿◠) Calm</option><option value="◕‿◕">(◕‿◕) Curious</option><option value="•̀ᴗ•́">(•̀ᴗ•́) Focused</option></select></label><label>Color<select name="color"><option value="#d8e5f4">Pale sky blue</option><option value="#dbd0f7">Lavender</option><option value="#fdd997">Golden haze</option></select></label><button class="button primary">Create Sapi</button></form>`, 'SAPIENS4');
};
agentSettings = function() {
  const a = selected();
  modal(`${a.name} settings`, `<form id="live-settings-form" data-id="${esc(a.id)}" class="form-stack"><label>Name<input name="name" value="${esc(a.name)}" required maxlength="24"></label><label>Role<input name="role" value="${esc(a.role)}" required maxlength="60"></label><button class="button primary">Save Sapi</button></form>`, 'SAPIENS4');
};
actions['agent-settings'] = agentSettings;
computerDialog = function() {
  modal('Shared computer', `<p>Blindly4 is the main computer-use tool. Choose <strong>Computer task</strong> beside the message box to give a Sapi a task.</p><div class="settings-row"><span>${live.computer.built ? 'Blindly4 is built' : 'Build required: run ./start.sh'}</span><span class="tag">${live.computer.owner ? `In use · ${esc(agent(live.computer.owner).name)}` : 'Available'}</span></div><p>Jobs run one at a time. macOS Accessibility access is required for desktop interaction; permission failures appear in the job and activity log.</p>`, 'BLINDLY4');
};
autonomyDialog = function() {
  modal('Local workspace', '<p>Connected to your local Codex CLI. Sapis run when you send a message or a computer task.</p><p>Agent profiles, conversations, job results, tabs and drafts are saved locally. Groups and scheduling are planned for the next iteration.</p>', 'SAPIENS4');
};

document.addEventListener('submit', async e => {
  const form = e.target;
  if (!['live-agent-form','live-settings-form'].includes(form.id)) return;
  e.preventDefault(); e.stopImmediatePropagation();
  const button = form.querySelector('button');
  if (button.disabled) return;
  button.disabled = true;
  try {
    const data = Object.fromEntries(new FormData(form));
    const created = form.id === 'live-agent-form';
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

// Remove simulation entry points; workspace tabs and appearance remain upstream UI.
$('#attach-button').hidden = true;
$('#profile-button').textContent = 'You';
$('[data-scope="groups"]').disabled = true;
$('[data-scope="groups"]').title = 'Groups are coming in the next iteration';
$('[data-panel="cron"]').hidden = true;
$('[data-panel="tasks"]').innerHTML = 'Jobs <span id="task-count">0</span>';
$('.composer-bottom').insertAdjacentHTML('afterbegin', '<label class="live-flow">Mode <select id="live-flow" aria-label="Message mode"><option value="chat">Chat</option><option value="computer">Computer task</option></select></label>');
$('#live-flow').addEventListener('change', renderAgentHeader);
$('#message-input').maxLength = 16000;
$('#message-input').value = state.drafts[state.selected] || '';
$('#message-input').addEventListener('input', () => {state.drafts[state.selected] = $('#message-input').value; save();});

async function refresh() {
  if (refreshing) return refreshing;
  refreshing = (async () => {
    try {
      const snapshot = await api(`/api/state?after=${cursor}`);
      const changed = JSON.stringify([snapshot.agents,snapshot.jobs,snapshot.computer]) !== JSON.stringify([live.agents,live.jobs,live.computer]) || snapshot.events.length;
      const reconnected = !online;
      online = true;
      applySnapshot(snapshot);
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
  setTimeout(poll, online ? 750 : 2000);
}
setTimeout(poll, 750);
