function taskStatus(task, run) {
  if (task.past || task.status === 'done') return 'Completed';
  if (run) return run.status === 'done' ? 'Ready for review' : run.status === 'running' ? 'In progress' : statusNames[run.status];
  if (task.due && new Date(task.due) <= new Date()) return 'Due · waiting for runner';
  return 'Planned';
}
async function taskDialog(owner, id) {
  modal('Task', `<div id="task-details-body" data-owner="${esc(owner)}" data-id="${esc(id)}">Loading…</div><section class="task-comments"><h3>Comments</h3><div id="task-comments-list"></div><form id="task-comment-form" data-owner="${esc(owner)}" data-id="${esc(id)}" class="form-stack"><label>Add a comment<textarea name="text" required maxlength="4000" rows="3"></textarea></label><button type="submit" class="button primary">Post comment</button></form></section>`, 'TASK');
  await refreshTaskDialog();
}
let taskDialogLoading = false;
async function refreshTaskDialog() {
  const host=$('#task-details-body');
  if (!host || !$('#modal').open || taskDialogLoading) return;
  taskDialogLoading=true;
  try {
    const {owner,id}=host.dataset;
    const data=await api(`/api/agents/${owner}/tasks/${id}`);
    if ($('#task-details-body')!==host) return;
    const t=data.task, run=data.run;
    $('#modal-title').textContent=`@${t.name}`;
    const actions=t.past ? '' : `<div class="actions">${!t.job ? workButton('run_task',t.id,'Start') : ''}${!run || !['queued','running'].includes(run.status) ? workButton('finish_task',t.id,'Mark complete') : ''}</div>`;
    const expanded=host.querySelector('details')?.open;
    host.innerHTML=`<span class="tag">${esc(taskStatus(t,run))}</span><p class="task-description">${esc(t.title)}</p><dl class="sapi-details"><dt>Assigned to</dt><dd>${esc(agent(owner).name)}</dd><dt>Due</dt><dd>${t.due ? esc(new Date(t.due).toLocaleString()) : 'Unscheduled'}</dd></dl>${run?.error ? `<p class="task-error">${esc(run.error)}</p>`:''}${run?.output ? `<section class="task-result"><h3>Result</h3><p>${esc(run.output)}</p></section>`:''}${run ? jobActions(run):''}${actions}<section class="task-history"><h3>Activity</h3><div class="log-row"><time>${esc(new Date(t.created || t.completed).toLocaleString())}</time><p>Assignment recorded for ${esc(agent(owner).name)}.</p></div>${data.activity.filter(r=>r.kind!=='comment').map(r=>`<div class="log-row"><time>${esc(new Date(r.time).toLocaleString())}</time><p>${esc(r.kind==='done' ? 'Result ready for review.' : r.text)}</p></div>`).join('')}<details><summary>Execution log (${data.events.length})</summary>${data.events.map(e=>`<div class="log-row"><time>${esc(displayTime(e.time))}</time><strong>${esc(e.kind)}</strong><p>${esc(e.detail)}</p></div>`).join('') || '<p>No execution yet.</p>'}</details></section>`;
    if(expanded && host.querySelector('details'))host.querySelector('details').open=true;
    $('#task-comments-list').innerHTML=data.activity.filter(r=>r.kind==='comment').map(r=>`<article class="task-comment"><strong>${esc(r.author==='Human'?'Human':agent(r.author).name)}</strong> <time>${esc(new Date(r.time).toLocaleString())}</time><p>${esc(r.text)}</p></article>`).join('') || '<p class="form-hint">No comments yet.</p>';
  } catch(error) { if ($('#task-details-body')===host) toast(error.message); }
  finally {taskDialogLoading=false;if($('#task-details-body') && $('#task-details-body')!==host && $('#modal').open) refreshTaskDialog();}
}
document.addEventListener('submit',async e=>{
  const form=e.target;
  if(form.id!=='task-comment-form') return;
  e.preventDefault();e.stopImmediatePropagation();
  const button=form.querySelector('button');if(button.disabled)return;button.disabled=true;
  const text=form.elements.text.value;
  try {
    await api(`/api/agents/${form.dataset.owner}/tasks/${form.dataset.id}/comments`,'POST',{text});
    if(form.elements.text.value===text)form.elements.text.value='';
    await refreshTaskDialog();await refresh();
  } catch(error){toast(error.message);}finally{button.disabled=false;}
},true);
