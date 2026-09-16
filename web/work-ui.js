const workViews = {tasks:'ongoing',cron:'ongoing',log:'ongoing',...bootstrap.preferences.work_views};
const watchStatus = {needs_plan:'Setup needed',baseline:'Watching',unchanged:'No changes',partial:'Partial coverage',reviewed:'Watching',changed:'Change detected',monitoring:'Watching',throttled:'Cooling down',budget_blocked:'Waiting for budget',blocked:'Needs attention',queued:'Queued',running:'Running',paused:'Paused',scheduled:'Scheduled',ready:'Ready'};
const timerStatus = (enabled, next) => !enabled ? 'Paused' : new Date(next) <= new Date() ? 'Waiting' : 'Scheduled';
const finished = run => !['queued','running'].includes(run.status);
const workButton = (op, id, label, extra='') => `<button type="button" class="button" data-work-op="${op}" data-work-id="${esc(id)}" ${extra}>${label}</button>`;
function workNav(panel) {
  return `<div class="work-views" role="group" aria-label="${panel === 'cron' ? 'Job' : panel === 'tasks' ? 'Task' : 'Run'} view">${['ongoing','past'].map(view => `<button type="button" data-work-view="${view}" aria-pressed="${workViews[panel] === view}" class="${workViews[panel] === view ? 'active' : ''}">${view === 'ongoing' ? 'Ongoing' : 'Past'}</button>`).join('')}</div>`;
}
function runCard(run) {
  const title = run.title || run.input || ({learning:'Memory update',chat:'Conversation',scheduled:'Scheduled run',reason:'Task run'}[run.flow]) || run.flow;
  return `<article class="live-job"><span class="tag">${esc(statusNames[run.status] || run.status)}</span><h3>${esc(title)}</h3><small>${esc(new Date(run.created).toLocaleString())}</small>${run.error ? `<p>${esc(run.error)}</p>` : ''}${run.output && run.flow !== 'learning' ? `<details><summary>Result</summary><p>${esc(run.output)}</p></details>` : ''}${jobActions(run)}</article>`;
}
function taskCardLive(task, runs, past) {
  const run = runs.find(r => r.id === task.job);
  const status = taskStatus({...task,past},run);
  return `<article class="live-job" id="task-${esc(task.id)}"><span class="tag">${esc(status)}</span><h3><button class="entity-mention" data-task-link="${esc(task.id)}" data-task-owner="${esc(state.selected)}" aria-label="Open task ${esc(task.name)}">@${esc(task.name)}</button></h3><p>${esc(task.title)}</p><small>${past ? `Completed ${esc(new Date(task.completed).toLocaleString())}` : task.due ? `Due ${esc(new Date(task.due).toLocaleString())}` : 'No due date'}</small><div class="actions"><button class="button" data-task-link="${esc(task.id)}" data-task-owner="${esc(state.selected)}">Open task</button></div></article>`;
}
function workPanel(panel, runs) {
  const info = live.orchestration[state.selected];
  const past = workViews[panel] === 'past';
  let heading = '', body = '';
  if (panel === 'tasks') {
    heading = `<div class="list-heading"><h3>Tasks</h3><button class="button" data-new-work="task">＋ Task</button></div>`;
    const tasks = past ? info.past_tasks : info.tasks;
    body = tasks.map(t => taskCardLive(t, runs, past)).join('') || `<div class="empty">${past ? 'No completed tasks.' : 'No ongoing tasks.'}</div>`;
  } else if (panel === 'cron') {
    heading = `<div class="list-heading"><h3>Jobs</h3><button class="button" data-new-work="recurring">＋ Job</button></div>`;
    if (past) {
      const history = info.recurring.flatMap(j => j.runs.filter(finished));
      history.push(...runs.filter(r => r.flow === 'learning' && finished(r)).map(r => ({...r,title:'Memory update'})));
      history.push(...eventRows.filter(e => e.agent === state.selected && e.kind === 'heartbeat').map(e => ({id:`check-${e.id}`,agent:e.agent,title:'Agent check',created:e.time,status:'done',output:e.detail,flow:'check'})));
      body = history.sort((a,b) => b.created.localeCompare(a.created)).slice(0,100).map(runCard).join('') || '<div class="empty">No past job runs.</div>';
    } else {
      const s = info.schedule;
      body = `<article class="live-job"><span class="tag">${esc(timerStatus(s.enabled,s.next_check))}</span><h3>Agent check</h3><p>Every ${s.minutes} min${s.monitor_team ? ' · Includes team progress' : ''}</p><small>${s.enabled ? `Next ${esc(new Date(s.next_check).toLocaleString())}` : 'Timer paused'}</small>${s.last_check ? `<p>Last check ${esc(new Date(s.last_check).toLocaleString())}</p>` : ''}<div class="actions"><button class="button" data-action="agent-settings">Settings</button></div></article>`;
      body += info.recurring.map(j => {
        const recent = j.runs[j.runs.length-1];
        const active = recent && (!finished(recent) || attention.has(recent.status));
        return `<article class="live-job"><span class="tag">${esc(watchStatus[j.health?.status] || j.health?.status || (active ? statusNames[recent.status] : timerStatus(j.enabled,j.next_run)))}</span><h3>${esc(j.title)}</h3>${j.health?.reason ? `<p class="usage-warning">${esc(j.health.reason)}</p>` : ''}<p>${esc(j.prompt)}</p><p>Check every ${j.minutes} min · ${j.watch?.mode === 'always' ? 'Scheduled generation' : 'Script first'}</p>${j.detector ? `<small>${j.detector.checks || 0} script checks · ${j.detector.skipped || 0} unchanged checks skipped${j.detector.last_check ? ` · last ${esc(new Date(j.detector.last_check).toLocaleTimeString())}` : ''}</small><p>${esc(j.detector.coverage || '')}</p>` : ''}<small>${j.enabled ? `Next ${esc(new Date(j.next_run).toLocaleString())}` : 'Timer paused'}</small><p>Last run: ${recent ? `${esc(statusNames[recent.status])} · ${esc(new Date(recent.created).toLocaleString())}` : 'Not yet'}</p>${j.checkpoint ? `<details><summary>Last observation · ${esc(j.checkpoint.status)}</summary><p>${esc(j.checkpoint.summary)}</p><small>${esc(new Date(j.checkpoint.time).toLocaleString())}</small></details>` : ''}<div class="actions">${workButton('run_job',j.id,'Run now',active?'disabled':'')}${workButton('toggle_job',j.id,j.enabled?'Pause':'Resume')}<button class="button" data-edit-recurring="${esc(j.id)}">Edit</button></div>${active ? jobActions(recent) : ''}</article>`;
      }).join('');
    }
  } else {
    heading = '<div class="list-heading"><h3>Activity log</h3></div>';
    const list = runs;
    body = list.slice().reverse().map(runCard).join('') || '<div class="empty">No activity yet.</div>';
    body += `<details class="event-history"><summary>Activity events</summary>${eventRows.filter(e=>e.agent===state.selected).slice(-100).reverse().map(e=>`<div class="log-row"><time>${esc(displayTime(e.time))}</time><strong>${esc(e.kind)}</strong><p>${esc(e.detail)}</p></div>`).join('')}</details>`;
  }
  return heading + (panel==='log' ? '' : workNav(panel)) + body;
}
function watchFields(row) {
  const w = row?.watch || {mode:'changes',cooldown_minutes:30,max_per_hour:2,max_per_day:8};
  return `<fieldset class="schedule-fields"><legend>When to wake the agent</legend>
    <label>Mode<select name="watch_mode"><option value="changes" ${w.mode==='changes'?'selected':''}>Only when the script detects changes</option><option value="always" ${w.mode==='always'?'selected':''}>Every interval (generative work)</option></select></label>
    <div data-watch-probe ${w.mode==='always'?'hidden':''}>
    <p>The Sapi can discover these settings once in chat. Until a plan is saved, automatic model runs are stopped.</p>
    <details><summary>Observation plan</summary><label>Application bundle ID<input name="watch_bundle" maxlength="200" value="${esc(w.probe?.bundle_id || '')}" placeholder="net.whatsapp.WhatsApp"></label>
    <label>Chat-list identifier<input name="watch_container" maxlength="200" value="${esc(w.probe?.container_id || '')}" placeholder="Discovered with Blindly"></label></details>
    <label>Chats to watch (one name per line)<textarea name="watch_names">${esc((w.probe?.names || []).join('\n'))}</textarea></label>
    <small>Blank watches visible list rows. Phone-number labels are checked first; they do not prove non-contact or DM status. Archived and off-screen chats need separate coverage.</small>
    </div>
    <label>Minimum minutes between model runs<input name="cooldown_minutes" type="number" min="1" max="1440" value="${w.cooldown_minutes}" required></label>
    <label>Maximum model runs per hour<input name="max_per_hour" type="number" min="1" max="12" value="${w.max_per_hour}" required></label>
    <label>Maximum model runs per day<input name="max_per_day" type="number" min="1" max="48" value="${w.max_per_day}" required></label>
    <small>No changes = no model tokens. Read failures back off without waking the agent. Run now explicitly bypasses the change detector.</small>
  </fieldset>`;
}
document.addEventListener('change', e => {
  if (e.target.name === 'watch_mode') e.target.form.querySelector('[data-watch-probe]').hidden=e.target.value==='always';
});
function workForm(kind, id) {
  const row = id ? live.orchestration[state.selected].recurring.find(j => j.id === id) : null;
  const recurring = kind === 'recurring';
  modal(row ? 'Edit job' : recurring ? 'New job' : 'New task', `<form id="work-form" data-kind="${kind}" data-id="${esc(id || '')}" data-agent="${esc(state.selected)}" class="form-stack"><label>Title<input name="title" required maxlength="${recurring ? 120 : 2000}" value="${esc(row?.title || '')}"></label>${recurring ? `<label>Instructions<textarea name="prompt" required maxlength="2000">${esc(row?.prompt || '')}</textarea></label><label>Run every (minutes)<input name="minutes" type="number" required min="1" max="10080" value="${row?.minutes || 60}"></label><label class="check-label"><input name="enabled" type="checkbox" ${!row || row.enabled ? 'checked' : ''}> Enabled</label>${watchFields(row)}` : '<label>Name (optional)<input name="name" maxlength="24" placeholder="Generated from title"></label><label>Due (optional)<input name="due" type="datetime-local"></label>'}<button type="submit" class="button primary">${row ? 'Save' : 'Create'}</button></form>`, recurring ? 'RECURRING' : 'ONE-OFF');
}
document.addEventListener('click', async e => {
  const b = e.target.closest('button');
  if (!b) return;
  const d = b.dataset;
  if (!d.workView && !d.newWork && !d.editRecurring && !d.workOp) return;
  e.preventDefault(); e.stopImmediatePropagation();
  if (d.workView) { workViews[state.panel] = d.workView; renderConversation(); save(); return; }
  if (d.newWork || d.editRecurring) { workForm(d.editRecurring ? 'recurring' : d.newWork, d.editRecurring); return; }
  b.disabled = true;
  try {
    let data = {op:d.workOp,id:d.workId};
    if (d.workOp === 'toggle_job') {
      const row = live.orchestration[state.selected].recurring.find(j => j.id === d.workId);
      data = {op:'recurring_job',id:row.id,enabled:!row.enabled};
    }
    await api(`/api/agents/${b.closest('#task-details-body')?.dataset.owner || state.selected}/control`, 'POST', data);
    await refresh();
    if ($('#task-details-body')) await refreshTaskDialog();
  } catch (error) { toast(error.message); }
  finally { b.disabled = false; }
}, true);
document.addEventListener('submit', async e => {
  const form = e.target;
  if (form.id !== 'work-form') return;
  e.preventDefault(); e.stopImmediatePropagation();
  const button = form.querySelector('button[type="submit"]');
  if (button.disabled) return;
  button.disabled = true;
  try {
    const data = Object.fromEntries(new FormData(form));
    if (form.dataset.kind === 'recurring') {
      data.op='recurring_job'; data.minutes=Number(data.minutes); data.enabled=form.elements.enabled.checked;
      const bundle = data.watch_bundle.trim(), container = data.watch_container.trim();
      if ((bundle || container) && !(bundle && container)) throw new Error('Provide both application and list identifiers.');
      data.watch={mode:data.watch_mode,probe:bundle&&container?{bundle_id:bundle,container_id:container,names:data.watch_names.split('\n').map(n=>n.trim()).filter(Boolean)}:null,
        cooldown_minutes:Number(data.cooldown_minutes),max_per_hour:Number(data.max_per_hour),max_per_day:Number(data.max_per_day)};
      for (const key of ['watch_mode','watch_bundle','watch_container','watch_names','cooldown_minutes','max_per_hour','max_per_day']) delete data[key];
      if (form.dataset.id) data.id=form.dataset.id;
    } else { data.op='task'; if (!data.name) delete data.name; data.due=data.due ? new Date(data.due).toISOString() : null; }
    await api(`/api/agents/${form.dataset.agent}/control`, 'POST', data);
    await refresh(); closeModal();
  } catch (error) { toast(error.message); }
  finally { button.disabled = false; }
}, true);
