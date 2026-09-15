const workViews = {tasks:'ongoing',cron:'ongoing',log:'ongoing',...bootstrap.preferences.work_views};
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
  const status = past ? 'Completed' : run ? (run.status === 'done' ? 'Ready for review' : run.status === 'running' ? 'In progress' : statusNames[run.status]) : 'Planned';
  return `<article class="live-job"><span class="tag">${esc(status)}</span><h3>${esc(task.title)}</h3><small>${past ? `Completed ${esc(new Date(task.completed).toLocaleString())}` : task.due ? `Due ${esc(new Date(task.due).toLocaleString())}` : 'No due date'}</small>${run?.output ? `<details><summary>Result</summary><p>${esc(run.output)}</p></details>` : ''}${run ? jobActions(run) : ''}${!past ? `<div class="actions">${!task.job ? workButton('run_task',task.id,'Start') : ''}${!run || !['queued','running'].includes(run.status) ? workButton('finish_task',task.id,'Mark complete') : ''}</div>` : ''}</article>`;
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
        return `<article class="live-job"><span class="tag">${active ? esc(statusNames[recent.status]) : esc(timerStatus(j.enabled,j.next_run))}</span><h3>${esc(j.title)}</h3><p>${esc(j.prompt)}</p><p>Every ${j.minutes} min</p><small>${j.enabled ? `Next ${esc(new Date(j.next_run).toLocaleString())}` : 'Timer paused'}</small><p>Last run: ${recent ? `${esc(statusNames[recent.status])} · ${esc(new Date(recent.created).toLocaleString())}` : 'Not yet'}</p><div class="actions">${workButton('run_job',j.id,'Run now',active?'disabled':'')}${workButton('toggle_job',j.id,j.enabled?'Pause':'Resume')}<button class="button" data-edit-recurring="${esc(j.id)}">Edit</button></div>${active ? jobActions(recent) : ''}</article>`;
      }).join('');
    }
  } else {
    heading = '<div class="list-heading"><h3>Runs</h3></div>';
    const list = runs.filter(r => past ? finished(r) : !finished(r));
    body = list.slice().reverse().map(runCard).join('') || `<div class="empty">${past ? 'No past runs.' : 'No ongoing runs.'}</div>`;
    body += `<details class="event-history"><summary>Activity events</summary>${eventRows.filter(e=>e.agent===state.selected).slice(-100).reverse().map(e=>`<div class="log-row"><time>${esc(displayTime(e.time))}</time><strong>${esc(e.kind)}</strong><p>${esc(e.detail)}</p></div>`).join('')}</details>`;
  }
  return heading + workNav(panel) + body;
}
function workForm(kind, id) {
  const row = id ? live.orchestration[state.selected].recurring.find(j => j.id === id) : null;
  const recurring = kind === 'recurring';
  modal(row ? 'Edit job' : recurring ? 'New job' : 'New task', `<form id="work-form" data-kind="${kind}" data-id="${esc(id || '')}" data-agent="${esc(state.selected)}" class="form-stack"><label>Title<input name="title" required maxlength="${recurring ? 120 : 2000}" value="${esc(row?.title || '')}"></label>${recurring ? `<label>Instructions<textarea name="prompt" required maxlength="2000">${esc(row?.prompt || '')}</textarea></label><label>Run every (minutes)<input name="minutes" type="number" required min="1" max="10080" value="${row?.minutes || 60}"></label><label class="check-label"><input name="enabled" type="checkbox" ${!row || row.enabled ? 'checked' : ''}> Enabled</label>` : '<label>Due (optional)<input name="due" type="datetime-local"></label>'}<button type="submit" class="button primary">${row ? 'Save' : 'Create'}</button></form>`, recurring ? 'RECURRING' : 'ONE-OFF');
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
    await api(`/api/agents/${state.selected}/control`, 'POST', data);
    await refresh();
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
      if (form.dataset.id) data.id=form.dataset.id;
    } else { data.op='task'; data.due=data.due ? new Date(data.due).toISOString() : null; }
    await api(`/api/agents/${form.dataset.agent}/control`, 'POST', data);
    await refresh(); closeModal();
  } catch (error) { toast(error.message); }
  finally { button.disabled = false; }
}, true);
