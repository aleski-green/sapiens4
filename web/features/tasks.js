// Task navigation is UI; each expanded task keeps its specification as YAML.
const taskDocuments = new Map();
const openTasks = new Set();
const pastTaskStates = new Set(['Completed', 'Unresolved', 'Failed', 'Interrupted', 'Cancelled']);
let taskPeriod = 'upcoming';
let clarificationWorkload = null;
function taskElement(tag, className, text) {
  const node = document.createElement(tag);
  node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}
function taskRow(task, sapi) {
  const row = taskElement('details', 'task-row');
  const key = sapi + ':' + task.id;
  row.open = openTasks.has(key);
  row.addEventListener('toggle', () => {
    if (row.isConnected) row.open ? openTasks.add(key) : openTasks.delete(key);
  });
  const summary = taskElement('summary', 'task-summary');
  const tone = task.state === 'Completed' ? 'complete' :
    ['Failed', 'Interrupted', 'Unresolved', 'WaitingForAdmin'].includes(task.state) ? 'attention' :
    ['Running', 'Queued'].includes(task.state) ? 'active' : 'neutral';
  const mark = taskElement('span', 'task-mark ' + tone, task.state === 'Completed' ? '✓' : tone === 'attention' ? '!' : '·');
  mark.setAttribute('aria-hidden', 'true');
  const copy = taskElement('span', 'task-row-copy');
  const title = taskElement('span', 'task-title', task.title); title.title = task.title;
  const owner = agent(task.owner).name;
  const route = task.sender === task.owner ? owner : `${agent(task.sender).name} → ${owner}`;
  const status = task.state === 'WaitingForAdmin' ? 'Needs input' : task.state;
  const meta = taskElement('span', 'task-meta');
  meta.append(taskElement('span', 'task-state ' + tone, status), taskElement('span', 'task-assignee', task.meta || route));
  copy.append(title, meta);
  const arrow = taskElement('span', 'task-chevron', '›'); arrow.setAttribute('aria-hidden', 'true');
  summary.append(mark, copy);
  if(task.editRoutine){
    const run=taskElement('button','task-copy','Run');run.type='button';run.dataset.runRoutine=task.editRoutine;
    run.setAttribute('aria-label','Run routine');
    run.addEventListener('click',e=>e.preventDefault());summary.append(run);
    const edit=taskElement('button','task-copy','Edit');edit.type='button';edit.dataset.editRoutine=task.editRoutine;
    edit.addEventListener('click',e=>e.preventDefault());summary.append(edit);
    const action=taskElement('button','task-copy task-routine-action');action.type='button';
    const paused=task.routineAction==='resume';
    action.dataset[paused?'resumeRoutine':'pauseRoutine']=task.editRoutine;
    action.title=paused?'Resume routine':'Pause routine';action.setAttribute('aria-label',action.title);
    action.innerHTML=`<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">${paused?'<path d="M5 3l7 5-7 5z"/>':'<path d="M5 3v10M11 3v10"/>'}</svg>`;
    action.addEventListener('click',e=>e.preventDefault());summary.append(action);
  }
  if(task.reference){
    row.classList.add('task-routine');
    const reference=taskElement('span','task-reference');
    reference.append(taskElement('code','',task.reference),taskElement('span','',`${task.runCount}/1000`));
    reference.title='Scheduled tasks queued in this allowance; pauses automatically at 1000.';
    summary.append(reference);
  }
  summary.append(arrow); row.append(summary);
  const content = taskElement('div', 'task-content');
  const heading = taskElement('div', 'task-body-heading');
  heading.append(taskElement('span', '', task.editRoutine?'Execution prompt':'Task body'), taskElement('span', 'task-format', task.editRoutine?'':'YAML'));
  const button = taskElement('button', 'task-copy', 'Copy'); button.type = 'button';
  button.setAttribute('aria-label', task.editRoutine?'Copy execution prompt':'Copy task YAML');
  button.addEventListener('click', async () => {
    try { await navigator.clipboard.writeText(task.body); toast(task.editRoutine?'Execution prompt copied.':'Task YAML copied.'); }
    catch (_) { toast('Could not copy. You can select the task body to copy it.'); }
  });
  heading.append(button);
  const body = taskElement('pre', 'task-body-yaml', task.body);
  body.setAttribute('aria-label', task.editRoutine?'Execution prompt':'Task body YAML');
  content.append(heading, body);
  if (task.result) {
    content.append(taskElement('h3', 'task-result-heading', 'Result'));
    const result = taskElement('div', 'task-result');
    result.innerHTML = formatText(task.result);
    content.append(result);
  }
  if (task.error) content.append(taskElement('p', 'task-error', task.error));
  row.append(content);
  return row;
}
function drawTasks(host, id, cached) {
  const automated=typeof workView!=='undefined'&&workView==='tasks-automated';
  const key = JSON.stringify([id, cached.revision, taskPeriod, automated, cached.pending, cached.error]);
  if (host.firstElementChild?.taskViewKey === key) return;
  const view = taskElement('section', 'task-browser'); view.taskViewKey = key;
  const rows = cached.rows || [];
  const inPeriod = (task, period) => pastTaskStates.has(task.state) === (period === 'past');
  const list = taskElement('div', 'task-list'); list.id = 'task-list';
  list.setAttribute('aria-label', taskPeriod==='past'?'Executed tasks':'Planned tasks');
  list.setAttribute('aria-busy', String(Boolean(cached.pending)));
  const visible = rows.filter(t => inPeriod(t, taskPeriod)&&(!automated||t.taskType==='automated'));
  if (cached.error) {
    const error = taskElement('div', 'task-empty');
    error.append(taskElement('p', '', 'Could not load tasks.'));
    const retry = taskElement('button', 'task-copy', 'Try again'); retry.type = 'button';
    retry.addEventListener('click', () => { taskDocuments.delete(id); renderTasks(host); });
    error.append(retry); list.append(error);
  } else if (!cached.rows) {
    list.append(taskElement('p', 'task-empty', 'Loading tasks…'));
  } else if (!visible.length) {
    const empty = taskElement('div', 'task-empty');
    empty.append(taskElement('p', '', taskPeriod === 'past' ? 'No executed tasks' : 'No planned tasks'),
      taskElement('small', '', taskPeriod === 'past' ? 'Completed and stopped tasks will appear here.' : 'Queued, running and waiting tasks will appear here.'));
    list.append(empty);
  } else visible.forEach(task => list.append(taskRow(task, id)));
  view.append(list); host.replaceChildren(view);
}
function renderTasks(host) {
  const id = state.selected;
  const revision = JSON.stringify((live.workloads || []).filter(w => w.participants.includes(id)));
  let cached = taskDocuments.get(id);
  if (cached?.revision === revision) { drawTasks(host, id, cached); return; }
  cached = {revision, rows:cached?.rows, pending:true};
  taskDocuments.set(id, cached); drawTasks(host, id, cached);
  (typeof apiFetch === 'function' ? apiFetch : fetch)(`/api/agents/${encodeURIComponent(id)}/tasks?format=json`, {signal:AbortSignal.timeout(15000)})
    .then(async response => {
      if (!response.ok) throw new Error('Could not load tasks');
      return response.json();
    }).then(data => { cached.rows = data.tasks; })
    .catch(error => { cached.error = error.message; })
    .finally(() => {
      cached.pending = false;
      if (taskDocuments.get(id) === cached && state.selected === id && ['tasks','work'].includes(state.panel) && host.isConnected) drawTasks(host, id, cached);
    });
}
function delegationMessages(snapshot) {
  for (const work of snapshot.workloads || []) {
    const call = snapshot.turns.find(t => t.id === work.callId);
    if (work.origin.agent !== state.selected && !state.messages[work.origin.agent]) state.messages[work.origin.agent] = [];
    // Original chat shows the responsible Sapi's actual outcome, not a second model summary.
    if (work.callId !== work.origin.call) {
      (state.messages[work.origin.agent] ||= []).push({role:'assistant', author:work.owner,
        text:work.output || work.error || `Delegated to ${agent(work.owner).name} · ${work.state}`,
        time:call ? displayTime(call.created) : '', timestamp:call ? Date.parse(call.created) : 0,
        delegation:work, requestTurn:call && !['done','warning'].includes(call.status) ? call : null});
    }
  }
}
function taskCallControls(host) {
  for (const work of live.workloads || []) {
    if (work.state !== 'WaitingForAdmin' || ![work.owner,work.origin.agent].includes(state.selected)) continue;
    const button = document.createElement('button');
    button.type = 'button'; button.className = 'button';
    button.textContent = 'Answer Chief';
    button.addEventListener('click', () => {
      openChat(work.owner); clarificationWorkload = work;
      $('#message-input').placeholder = `Clarify ${work.taskId} for Chief…`;
      $('#message-input').focus();
    });
    host.append(button);
  }
}
async function editDecisionPrompts() {
  try {
    const {prompts} = await api('/api/decision-prompts');
    modal('Decision prompts', '<form id="decision-prompt-form" class="form-stack"><label>Node<select name="node"></select></label><small class="prompt-path"></small><label>Prompt<textarea name="content" rows="16" maxlength="20000" required></textarea></label><p>Changes apply to subsequent decisions. Saved decision records keep their original prompt.</p><button class="button" type="submit">Save prompt</button></form>', 'CORPORA');
    const form = $('#decision-prompt-form');
    for (const row of prompts) {
      const option = document.createElement('option'); option.value = row.node; option.textContent = row.node;
      form.elements.node.append(option);
    }
    const show = () => {
      const row = prompts.find(p => p.node === form.elements.node.value);
      form.elements.content.value = row.content;
      form.querySelector('.prompt-path').textContent = row.path;
    };
    form.elements.node.addEventListener('change', show); show();
    form.addEventListener('submit', async e => {
      e.preventDefault();
      const button = form.querySelector('button'); button.disabled = true;
      try {
        const content = form.elements.content.value, node = form.elements.node.value;
        const saved = await api(`/api/decision-prompts/${encodeURIComponent(node)}`, 'PUT', {content});
        const row = prompts.find(p => p.node === node); row.content = content; row.path = saved.path;
        show(); toast('Prompt saved for subsequent decisions.');
      } catch (error) { toast(error.message); }
      finally { button.disabled = false; }
    });
  } catch (error) { toast(error.message); }
}
