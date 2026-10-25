// Pure view projections. The runtime owns mounting, focus, scroll and event delivery.

// Views are values. Events carry actions; loading and clipboard access live in adapters.
function taskRow(task, sapi, model=state) {
  const tone=task.state==='Completed'?'complete':['Failed','Interrupted','Unresolved','WaitingForAdmin'].includes(task.state)?'attention':['Running','Queued'].includes(task.state)?'active':'neutral';
  const name=id=>findAgent(model,id).name,owner=name(task.owner),key=sapi+':'+task.id;
  const route=task.sender===task.owner?owner:`${name(task.sender)} → ${owner}`;
  const routine=task.editRoutine,paused=task.routineAction==='resume';
  const control=(action,label,extra='')=>`<button type="button" class="task-copy ${['pause','resume'].includes(action)?'task-routine-action':''}" data-${action}-routine="${esc(routine)}" ${extra}>${label}</button>`;
  return `<details class="task-row ${task.reference?'task-routine':''}" data-task-open="${esc(key)}" ${model.expanded['task:'+key]?'open':''}>
    <summary class="task-summary"><span class="task-mark ${tone}" aria-hidden="true">${task.state==='Completed'?'✓':tone==='attention'?'!':'·'}</span><span class="task-row-copy"><span class="task-title" title="${esc(task.title)}">${esc(task.title)}</span><span class="task-meta"><span class="task-state ${tone}">${esc(task.state==='WaitingForAdmin'?'Needs input':task.state)}</span><span class="task-assignee">${esc(task.meta||route)}</span></span></span>
    ${routine?control('run','Run','aria-label="Run routine"')+control('edit','Edit')+control(paused?'resume':'pause',`<svg width="14" height="14" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true">${paused?'<path d="M5 3l7 5-7 5z"/>':'<path d="M5 3v10M11 3v10"/>'}</svg>`,`aria-label="${paused?'Resume':'Pause'} routine" title="${paused?'Resume':'Pause'} routine"`):''}
    ${task.reference?`<span class="task-reference" title="Scheduled tasks queued in this allowance; pauses automatically at 1000."><code>${esc(task.reference)}</code><span>${task.runCount}/1000</span></span>`:''}<span class="task-chevron" aria-hidden="true">›</span></summary>
    <div class="task-content"><div class="task-body-heading"><span>${routine?'Execution prompt':'Task body'}</span><span class="task-format">${routine?'':'YAML'}</span><button type="button" class="task-copy" data-copy-task aria-label="Copy ${routine?'execution prompt':'task YAML'}">Copy</button></div><pre class="task-body-yaml" aria-label="${routine?'Execution prompt':'Task body YAML'}">${esc(task.body)}</pre>
    ${task.result?`<h3 class="task-result-heading">Result</h3><div class="task-result">${formatText(task.result,model)}</div>`:''}${task.error?`<p class="task-error">${esc(task.error)}</p>`:''}</div></details>`;
}
const emptyTasks=(title,detail)=>`<div class="task-empty"><p>${esc(title)}</p><small>${esc(detail)}</small></div>`;
function tasksView(model, document) {
  const past=model.period==='past',automated=model.view==='tasks-automated';
  const rows=(document?.value||[]).filter(t=>pastTaskStates.has(t.state)===past&&(!automated||t.taskType==='automated'));
  const content=document?.type==='Failed'?`<div class="task-empty"><p>Could not load tasks.</p><button type="button" class="task-copy" data-retry-document="tasks:${esc(model.selected)}">Try again</button></div>`:
    !document?.value?'<p class="task-empty">Loading tasks…</p>':rows.length?rows.map(t=>taskRow(t,model.selected,model)).join(''):
    emptyTasks(past?'No executed tasks':'No planned tasks',past?'Completed and stopped tasks will appear here.':'Queued, running and waiting tasks will appear here.');
  return `<section class="task-browser"><div id="task-list" class="task-list" aria-label="${past?'Executed':'Planned'} tasks" aria-busy="${document?.type==='Loading'}">${content}</div></section>`;
}

function turnActions(turn,model=state) {
  if (turn.status === 'running') return `<div class="actions"><button class="button" data-live-turn="cancel" data-id="${esc(turn.id)}" data-owner="${esc(turn.agent)}" ${!model.online || (model.snapshot.run_activity?.[turn.batch_id || turn.id] || model.snapshot.activity?.[turn.agent])?.stopping ? 'disabled' : ''}>Stop</button><small>Already completed actions are not undone.</small></div>`;
  if (attention.has(turn.status)) return `<div class="actions"><button class="button" data-live-turn="retry" data-id="${esc(turn.id)}" data-owner="${esc(turn.agent)}">Retry</button><button class="button" data-live-turn="cancel" data-id="${esc(turn.id)}" data-owner="${esc(turn.agent)}">Dismiss</button></div>`;
  if (turn.status === 'queued') return `<div class="actions"><button class="button" data-live-turn="cancel" data-id="${esc(turn.id)}" data-owner="${esc(turn.agent)}">Cancel queued turn</button></div>`;
  return '';
}

function turnProgress(turn, model=state) {
  const now=model.now;
  const current = model.snapshot.run_activity?.[turn.batch_id || turn.id] || model.snapshot.activity?.[turn.agent];
  const a = current?.turn === turn.id ? current : {};
  const elapsed = Math.max(0, Math.floor((now - (a.started || Date.parse(turn.created))) / 1000));
  const quiet = Math.max(0, Math.floor((now - (a.updated || a.started || now)) / 1000));
  const phase = !model.online ? 'Disconnected' : a.stopping ? 'Stopping…' : turn.status === 'output_pending' ? 'Awaiting output pulse' : turn.status === 'queued' ? 'Queued' : a.phase || 'Starting model';
  const detail = a.tool ? `Current tool: ${a.tool}` : a.last_action ? `Last completed action: ${a.last_action}` : '';
  return `<strong>${esc(phase)} · ${elapsed}s</strong><p>${esc(detail)}</p>${quiet >= 60 ? `<small>No recent update · ${quiet}s since last activity</small>` : ''}`;
}


function requestStatus(turn) {
  if (!attention.has(turn.status) && turn.status !== 'cancelled') return null;
  const error = turn.error || '';
  const reason = /TimeoutError|time limit|exceeded \d+(?:\.\d+)?s/i.test(error) ? 'Timed out' :
    /tool-step limit|tool limit/i.test(error) ? 'Tool limit reached' : null;
  return {label: reason ? reason + (turn.status === 'cancelled' ? ' · Dismissed' : '') : statusNames[turn.status],
    detail: error.split('\n')[0] || (turn.status === 'cancelled' ? 'This request was dismissed.' : 'This request needs attention.')};
}


function conversationView(model) {
  const a=findAgent(model),group=a.kind==='group',messages=model.messages[a.id]||[];
  const warning=(key,label,body,id=key)=>{
    const open=model.expanded['warning:'+key];
    return {badge:`<button type="button" class="warning-badge" data-warning-toggle="${esc(key)}" aria-expanded="${!!open}" aria-controls="${esc(id)}">${esc(label)}</button>`,
      detail:`<div class="warning-details" id="${esc(id)}" ${open?'':'hidden'}>${body}</div>`};
  };
  const rows=messages.map(m=>{
    const request=m.requestTurn,status=request&&requestStatus(request),warnings=[];
    if(status)warnings.push(warning('request-'+request.id,status.label,`<p>${esc(status.detail)}</p><p>No final reply was saved for this request.</p>${turnActions(request,model)}`));
    if(m.warning)warnings.push(warning(m.turnId,'Warning',esc(m.warning),'warning-'+m.turnId));
    const user=m.role==='user',author=m.author?(group?mention(m.author,model):esc(findAgent(model,m.author).name)):user?'Admin':mention(a.id,model);
    const attachments=(m.attachments||[]).length?`<div class="message-attachments">${m.attachments.map(attachmentLabel).join('')}</div>`:'';
    return `<div data-chat-key="${esc(m.chatKey||(m.delegation?'delegation:'+m.delegation.id:m.role+':'+(request?.id||m.turnId)))}" class="message ${user?'user':''} ${m.warning?'warning-message':''}"><div class="message-meta">${user?'<span>↗</span>':avatar(group?findAgent(model,m.author):a,'mini')}<strong>${author}</strong><time>${esc(m.created?displayTime(m.created):'')}</time>${warnings.map(w=>w.badge).join('')}</div><div class="message-bubble">${warnings.map(w=>w.detail).join('')}${formatText(m.text,model).split('\n\n').map(p=>`<p>${p.replace(/\n/g,'<br>')}</p>`).join('')}${attachments}${m.stale?'<small class="group-banner">Result from an earlier task revision · current work was preserved.</small>':''}${m.delegation&&request&&blocksChat(request)?turnActions(request,model):''}</div></div>`;
  }).join('');
  const progress=group?(a.requests||[]).filter(r=>['queued','running','failed','interrupted'].includes(r.status)).map(request=>{
    const turn=model.snapshot.turns.find(t=>t.id===request.id);
    return `<section data-chat-key="request:${esc(request.id)}" class="live-status"><strong>${esc(findAgent(model,request.target).name)} · ${esc(statusNames[request.status]||request.status)}</strong>${turn&&blocksChat(turn)?`<div data-turn-progress="${esc(turn.id)}">${turnProgress(turn,model)}</div>`:''}${request.error?`<p>${esc(request.error)}</p>`:''}${groupCallControls(a,request)}</section>`;
  }).join(''):model.snapshot.turns.filter(t=>t.agent===model.selected&&blocksChat(t)&&(!t.batch_id||t.batch_id===t.id))
    .map(t=>`<section data-chat-key="progress:${esc(t.id)}" class="live-status"><div data-turn-progress="${esc(t.id)}">${turnProgress(t,model)}</div>${turnActions(t,model)}</section>`).join('');
  return `${group&&a.archived?'<p class="group-banner">Archived · history is preserved. Restore this Group from settings to continue.</p>':''}<div class="day-divider">${group?'GROUP ':''}CONVERSATION</div>${rows}${messages.length?'':`<div class="empty">${group?`Message the Group to reach ${esc(findAgent(model,a.lead).name)}, or @mention a member.`:'Start a conversation.'}</div>`}${progress}`;
}
