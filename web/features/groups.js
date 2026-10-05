// Group identity, shared activity, and revisioned work use the host's durable records.
const groupColor = value => /^#[a-f0-9]{6}$/i.test(value) ? value : '#74b9ed';
function groupAvatar(group, size='') {
  const colors=(group.stripes?.length?group.stripes:[group.color]).map(groupColor);
  const bands=colors.map((color,i)=>`${color} ${i*100/colors.length}% ${(i+1)*100/colors.length}%`).join(',');
  return `<span class="avatar group-avatar ${size}" style="background:linear-gradient(90deg,${bands})" aria-hidden="true"><span>(${esc(group.face)})</span></span>`;
}
function groupChip(group, member, compact=false) {
  const title=group.name+(group.lead===member?' · Lead':'');
  return `<button type="button" class="group-chip" style="--group-color:${groupColor(group.color)}" data-agent="${esc(group.id)}" title="${esc(title)}" aria-label="${esc(title)}"><span>${esc(compact?Array.from(group.name)[0]:group.name)}${group.lead===member?'★':''}</span></button>`;
}
function groupLabels(sapi, compact=false) {
  const groups=state.agents.filter(g=>g.kind==='group'&&!g.archived&&g.members.includes(sapi.id));
  return groups.length?`<span class="group-labels ${compact?'compact':''}" style="--label-count:${groups.length};--label-min:${22+3*(groups.length-1)}px">${groups.map(g=>groupChip(g,sapi.id,compact)).join('')}</span>`:'';
}
// Resize each stack to its available space; preserve every colour when initials no longer fit.
const groupLabelObserver = new ResizeObserver(entries=>{
  for(const {target} of entries) {
    const chips=[...target.children], count=chips.length, width=target.clientWidth;
    target.parentElement.style.setProperty('--name-reserve',`${22+3*(count-1)+(target.nextElementSibling?.offsetWidth||0)+8}px`);
    const step=Math.min(25,Math.max(3,(width-22)/Math.max(1,count-1)));
    target.style.setProperty('--label-step',`${step}px`);
    target.classList.toggle('colour-only',count>1&&step<18);
  }
});
function observeGroupLabels() {
  groupLabelObserver.disconnect();
  document.querySelectorAll('.group-labels.compact').forEach(el=>groupLabelObserver.observe(el));
}
function groupDialog(group) {
  const sapis=state.agents.filter(a=>a.kind!=='group'&&!a.retired);
  modal(`${group.name} settings`,`<form id="group-form" class="form-stack" data-revision="${group.revision}">
    <label>Name<input name="name" maxlength="60" value="${esc(group.name)}" required></label>
    <label>Purpose<textarea name="description" rows="2" maxlength="2000">${esc(group.description)}</textarea></label>
    <label>Lead<select name="lead">${sapis.map(a=>`<option value="${esc(a.id)}" ${a.id===group.lead?'selected':''}>${esc(a.name)}</option>`).join('')}</select></label>
    <fieldset class="group-members"><legend>Members · at least two, including the Lead</legend>${sapis.map(a=>`<label><input type="checkbox" name="member" value="${esc(a.id)}" ${group.members.includes(a.id)?'checked':''}>${avatar(a,'mini')}<span>${esc(a.name)}</span></label>`).join('')}</fieldset>
    <p class="form-hint">Each Sapi can belong to up to 11 active Groups.</p>
    <button type="submit" class="button primary">Save Group</button>
    <button type="button" class="button" data-group-archive="${esc(group.id)}">${group.archived?'Restore Group':'Archive Group'}</button></form>`,'GROUP');
  const form=$('#group-form');
  form.elements.lead.addEventListener('change',()=>{form.querySelector(`input[value="${CSS.escape(form.elements.lead.value)}"]`).checked=true;});
  form.addEventListener('submit',async e=>{
    e.preventDefault();const button=form.querySelector('[type=submit]');button.disabled=true;
    try {
      const data=new FormData(form);
      await api(`/api/groups/${group.id}`,'PUT',{name:data.get('name'),description:data.get('description'),lead:data.get('lead'),members:data.getAll('member'),revision:Number(form.dataset.revision)});
      await refresh();closeModal();openChat(group.id);toast('Group saved.');
    } catch(error){toast(error.message);} finally{button.disabled=false;}
  });
}
function groupCallControls(group, request) {
  if(!['queued','running','failed','interrupted'].includes(request.status))return '';
  return `<div class="actions">${['failed','interrupted'].includes(request.status)&&!request.task&&!group.archived?`<button class="button" data-group-call="retry" data-group="${esc(group.id)}" data-call="${esc(request.id)}">Retry</button>`:''}<button class="button" data-group-call="cancel" data-group="${esc(group.id)}" data-call="${esc(request.id)}">${request.status==='running'?'Stop':request.status==='queued'?'Cancel':'Dismiss'}</button></div>`;
}
function renderGroupPanel(host) {
  const group=selected();
  host.classList.remove('notes-view');
  $('#composer-area').hidden=state.panel!=='chat'||group.archived;
  if(state.panel==='updates'){renderUpdates(host,group);return;}
  if(state.panel!=='chat') {renderGroupWork(host,group);return;}
  host.innerHTML=`${group.archived?'<p class="group-banner">Archived · history is preserved. Restore this Group from settings to continue.</p>':''}<div class="day-divider">GROUP CONVERSATION</div>`;
  for(const message of group.messages) {
    const author=message.author==='admin'?null:agent(message.author);
    host.insertAdjacentHTML('beforeend',`<div class="message ${author?'':'user'}"><div class="message-meta">${author?avatar(author,'mini'):'<span>↗</span>'}<strong>${author?mention(author.id):'Admin'}</strong><time>${esc(displayTime(message.created))}</time></div><div class="message-bubble">${formatText(message.text).split('\n\n').map(p=>`<p>${p.replace(/\n/g,'<br>')}</p>`).join('')}${message.attachments?.length?`<div class="message-attachments">${message.attachments.map(attachmentLabel).join('')}</div>`:''}${message.stale?'<small class="group-banner">Result from an earlier task revision · current work was preserved.</small>':''}</div></div>`);
  }
  if(!group.messages.length)host.insertAdjacentHTML('beforeend',`<div class="empty">Message the Group to reach ${esc(agent(group.lead).name)}, or @mention a member.</div>`);
  for(const request of group.requests.filter(r=>['queued','running','failed','interrupted'].includes(r.status))) {
    const turn=live.turns.find(t=>t.id===request.id);
    host.insertAdjacentHTML('beforeend',`<section class="live-status"><strong>${esc(agent(request.target).name)} · ${esc(statusNames[request.status]||request.status)}</strong>${turn&&blocksChat(turn)?`<div data-turn-progress="${esc(turn.id)}">${turnProgress(turn)}</div>`:''}${request.error?`<p>${esc(request.error)}</p>`:''}${groupCallControls(group,request)}</section>`);
  }
  renderAttachment();
}
let groupTaskFilter='active', workView='tasks', chatView='conversation', updatesView='runtime';
const openGroupTasks=new Set();
const activityLabels={tasks:'Tasks',automation:'Automation',workflows:'Workflows',memo:'Memo',conversation:'Conversation',pins:'Pins',threads:'Threads',comments:'Comments',runtime:'Runtime',events:'Events',archived:'Archived'};
const activityChevron = sideways => `<svg class="activity-chevron${sideways?' sideways':''}" viewBox="0 0 16 16" width="12" height="12" fill="none" aria-hidden="true" focusable="false"><path d="m4.5 6.25 3.5 3.5 3.5-3.5" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round"/></svg>`;
function closeActivityMenus() {
  document.querySelectorAll('.activity-menu').forEach(menu=>menu.hidden=true);
  document.querySelectorAll('[data-activity-menu]').forEach(button=>button.setAttribute('aria-expanded','false'));
}
function renderActivityNavigation() {
  const nav=$('.conversation-tabs'), group=selected().kind==='group';
  const view=state.panel==='work'?workView:state.panel==='updates'?updatesView:chatView;
  const item=(name,panel)=>`<button data-activity-view="${name}" data-activity-panel="${panel}" class="${view===name?'selected':''}" aria-pressed="${view===name}">${activityLabels[name]}</button>`;
  const menus={chat:['pins','threads','comments'].map(v=>item(v,'chat')).join('')+'<hr><button data-activity-feedback>＋ Add feedback</button>',
    work:item('tasks','work')+`<div class="activity-submenu-row">${item('automation','work')}<button data-activity-menu="activity-automation-menu" aria-label="Automation menu" aria-expanded="false" aria-controls="activity-automation-menu">${activityChevron(true)}</button><div class="activity-menu activity-submenu" id="activity-automation-menu" hidden>${item('workflows','work')}</div></div>`+item('memo','work'),
    updates:['runtime','events','archived'].map(v=>item(v,'updates')).join('')};
  const html=['chat','work','updates'].map(panel=>`<div class="activity-tab ${state.panel===panel?'active':''}"><button data-panel="${panel}" aria-pressed="${state.panel===panel}">${panel[0].toUpperCase()+panel.slice(1)}</button><button class="activity-toggle" data-activity-menu="activity-${panel}-menu" aria-label="${panel[0].toUpperCase()+panel.slice(1)} menu" aria-expanded="false" aria-controls="activity-${panel}-menu">${activityChevron(false)}</button><div class="activity-menu" id="activity-${panel}-menu" hidden>${menus[panel]}</div></div>`).join('');
  // Keep open menus and keyboard focus intact across polling snapshots.
  if(nav.dataset.view!==html){nav.innerHTML=html;nav.dataset.view=html;}
  let bar=$('#activity-viewbar');
  if(!bar){bar=document.createElement('div');bar.id='activity-viewbar';nav.after(bar);}
  bar.hidden=state.panel==='chat'&&chatView==='conversation';
  let detail=`<span class="activity-view-title">${activityLabels[view]||''}</span>`;
  if(state.panel==='work'&&['automation','workflows'].includes(view))detail=`<div class="activity-view-menu"><button data-activity-menu="activity-workflows-menu" aria-expanded="false" aria-controls="activity-workflows-menu" aria-label="Automation views">Automation ${activityChevron(false)}</button><div class="activity-menu" id="activity-workflows-menu" hidden>${item('workflows','work')}</div></div>${view==='workflows'?'<span class="activity-view-title"> / Workflows</span>':''}`;
  if(state.panel==='work'&&workView==='tasks') {
    const options=group?[['active','Active'],['done','Done'],['deleted','Deleted']]:[['upcoming','Upcoming'],['past','Past']];
    detail+=`<div class="work-nav-tools"><select data-work-filter aria-label="${group?'Task status':'Task history'}">${options.map(([value,label])=>`<option value="${value}" ${(group?groupTaskFilter:taskPeriod)===value?'selected':''}>${label}</option>`).join('')}</select>${group&&!selected().archived?`<button data-new-group-task="${esc(state.selected)}">+ Task</button>`:''}</div>`;
  }
  if(bar.dataset.view!==detail){bar.innerHTML=detail;bar.dataset.view=detail;}
}
function renderChatCollection(host) {
  if(state.panel!=='chat'||chatView==='conversation')return false;
  host.classList.remove('notes-view');
  $('#composer-area').hidden=true;
  host.innerHTML=`<p class="empty">${activityLabels[chatView]} are not available yet.</p>`;
  return true;
}
function prepareActivityFeedback() {
  state.panel='chat';chatView='conversation';closeActivityMenus();renderConversation();
  const input=$('#message-input');
  // Preserve an unfinished request; feedback is a draft and is never auto-sent.
  input.value=input.value?input.value+'\n\nFeedback: ':'Feedback: ';
  state.drafts ??= {};state.drafts[state.selected]=input.value;
  input.focus();input.setSelectionRange(input.value.length,input.value.length);save();
}
document.addEventListener('click',e=>{
  const button=e.target.closest('button'),d=button?.dataset;
  if(d?.activityMenu) {
    const menu=document.getElementById(d.activityMenu),opening=menu.hidden;
    if(!menu.classList.contains('activity-submenu'))closeActivityMenus();
    menu.hidden=!opening;button.setAttribute('aria-expanded',String(opening));return;
  }
  if(d?.activityView) {
    closeActivityMenus();state.panel=d.activityPanel;
    if(state.panel==='work')workView=d.activityView;
    else if(state.panel==='chat')chatView=d.activityView;
    else updatesView=d.activityView;
    renderConversation();save();return;
  }
  if(d&&'activityFeedback' in d){prepareActivityFeedback();return;}
  if(!e.target.closest('.activity-menu'))closeActivityMenus();
});
document.addEventListener('keydown',e=>{
  const trigger=e.target.closest('[data-activity-menu]'),menu=e.target.closest('.activity-menu');
  if(e.key==='Escape') {
    const open=[...document.querySelectorAll('[data-activity-menu][aria-expanded="true"]')].pop();
    if(open){e.preventDefault();closeActivityMenus();open.focus();}
  } else if(trigger&&['ArrowDown','ArrowRight'].includes(e.key)) {
    e.preventDefault();if(trigger.getAttribute('aria-expanded')!=='true')trigger.click();
    document.getElementById(trigger.dataset.activityMenu).querySelector('button')?.focus();
  } else if(menu&&['ArrowDown','ArrowUp','Home','End'].includes(e.key)) {
    e.preventDefault();const buttons=[...menu.querySelectorAll('button')].filter(b=>b.closest('.activity-menu')===menu),i=buttons.indexOf(e.target);
    buttons[e.key==='Home'?0:e.key==='End'?buttons.length-1:(i+(e.key==='ArrowDown'?1:buttons.length-1))%buttons.length]?.focus();
  }
});
const taskStateLabel={backlog:'Backlog',in_progress:'In progress',done:'Done'};
function groupTaskCard(group, task) {
  const running=group.requests.some(r=>r.task===task.id&&['queued','running'].includes(r.status));
  const results=task.results.map(r=>`<div class="group-task-result"><strong>${esc(agent(r.author).name)}${r.stale?' · Earlier revision':''}</strong><div>${formatText(r.text||r.error||'No reply saved.')}</div></div>`).join('');
  return `<details class="task-row group-task" data-open-group-task="${esc(task.id)}" ${openGroupTasks.has(task.id)?'open':''}><summary class="task-summary"><span class="task-row-copy"><span class="task-title">${esc(task.title)}</span><span class="task-meta">${esc(agent(task.assignee).name)} · ${task.deleted?'Deleted':taskStateLabel[task.state]}</span></span><span class="task-chevron" aria-hidden="true">›</span></summary><div class="task-content">${task.body?`<div class="group-task-body">${formatText(task.body)}</div>`:''}
    <div class="actions">${!group.archived?`<button class="button" data-group-task="${esc(task.id)}" data-group="${esc(group.id)}">${task.deleted?'Restore / edit':'Edit'}</button>${!task.deleted?`<button class="button" data-task-run="${esc(task.id)}" data-group="${esc(group.id)}" ${running?'disabled':''}>${running?'Running / queued':task.state==='done'?'Run again':'Run task'}</button>`:''}`:''}</div>
    ${results?`<details><summary>Results · ${task.results.length}</summary>${results}</details>`:''}${task.history.length?`<details><summary>Change history · ${task.history.length}</summary>${task.history.slice().reverse().map(h=>`<div class="group-task-result"><strong>${esc(h.title)}</strong><p>${esc(agent(h.assignee).name)} · ${taskStateLabel[h.state]}${h.deleted?' · Deleted':''}</p><p>${esc(h.body)}</p></div>`).join('')}</details>`:''}</div></details>`;
}
function renderGroupWork(host, group) {
  const key=group.id+':'+workView;
  if(host.dataset.groupWork!==key||!host.querySelector('#group-work-content')) {
    host.dataset.groupWork=key;
    host.innerHTML='<div id="group-work-content"></div>';
  }
  const content=host.querySelector('#group-work-content');
  host.classList.toggle('notes-view',workView==='memo');
  if(workView==='memo') {
    if(group.notes?.revision==='missing')content.innerHTML='<p class="empty">No shared Memo yet.</p>';
    else renderNotes(content);
  } else if(workView==='tasks')renderGroupTasks(content,group);
  else content.innerHTML=`<p class="empty">${activityLabels[workView]} is not available yet.</p>`;
}
function renderGroupTasks(host, group) {
  host.querySelectorAll('[data-open-group-task]').forEach(row=>row.open?openGroupTasks.add(row.dataset.openGroupTask):openGroupTasks.delete(row.dataset.openGroupTask));
  host.innerHTML=`<section class="group-work"><div class="group-task-list">${group.tasks.filter(t=>groupTaskFilter==='deleted'?t.deleted:!t.deleted&&(groupTaskFilter==='done'?t.state==='done':t.state!=='done')).map(t=>groupTaskCard(group,t)).join('')||'<p class="empty">No tasks here yet.</p>'}</div></section>`;
}
function taskDialog(group, task=null) {
  modal(task?'Edit Group task':'Create Group task',`<form id="group-task-form" class="form-stack"><label>Title<input name="title" required maxlength="500" value="${esc(task?.title||'')}"></label><label>Work to do<textarea name="body" rows="5" maxlength="16000">${esc(task?.body||'')}</textarea></label><label>Assignee<select name="assignee">${group.members.map(id=>`<option value="${esc(id)}" ${id===(task?.assignee||group.lead)?'selected':''}>${esc(agent(id).name)}</option>`).join('')}</select></label>${task?`<label>Status<select name="state">${Object.entries(taskStateLabel).map(([v,label])=>`<option value="${v}" ${v===task.state?'selected':''}>${label}</option>`).join('')}</select></label>`:''}<button type="submit" class="button primary">${task?.deleted?'Restore task':'Save task'}</button>${task&&!task.deleted?'<button type="button" class="button" id="delete-group-task">Delete task</button>':''}<p class="form-hint">Saving keeps this as shared work. Use Run task to call the assignee. Deletions can be restored.</p></form>`,'GROUP WORK');
  const form=$('#group-task-form');
  const saveTask=async deleted=>{
    const button=form.querySelector('[type=submit]');button.disabled=true;
    try{
      const data=Object.fromEntries(new FormData(form));
      if(task){data.revision=task.revision;data.deleted=deleted;if(task.deleted)data.state='backlog';}
      await api(`/api/groups/${group.id}/tasks${task?'/'+task.id:''}`,task?'PUT':'POST',data);
      await refresh();closeModal();toast(deleted?'Task deleted.':'Task saved.');
    }catch(error){toast(error.message);}finally{button.disabled=false;}
  };
  form.addEventListener('submit',e=>{e.preventDefault();saveTask(false);});
  $('#delete-group-task')?.addEventListener('click',()=>saveTask(true));
}
function renderUpdates(host, group=null) {
  $('#composer-area').hidden=true;
  const groups=group?[group]:state.agents.filter(g=>g.kind==='group'&&g.members.includes(state.selected));
  const events=groups.flatMap(g=>g.events.map(e=>({...e,group:g}))).sort((a,b)=>b.created.localeCompare(a.created));
  host.innerHTML='<div class="group-updates"></div>';
  const list=host.firstElementChild;
  if(updatesView==='archived'){list.innerHTML='<p class="empty">Archived updates are not available yet.</p>';return;}
  if(updatesView==='runtime') {
    for(const turn of live.turns.filter(t=>group?t.group===group.id:t.agent===state.selected&&!t.group).slice().reverse())list.insertAdjacentHTML('beforeend',`<article class="group-event"><strong>${esc(statusNames[turn.status]||turn.status)}</strong><time>${esc(displayTime(turn.created))}</time><p>${esc(turn.input.slice(0,180))}</p></article>`);
  }
  for(const event of updatesView==='events'?events:[]) {
    const author=event.actor==='admin'?'Admin':agent(event.actor).name;
    const task=event.group.tasks.find(t=>t.id===event.detail);
    list.insertAdjacentHTML('beforeend',`<article class="group-event"><strong>${esc(author)} · ${esc(event.action)}</strong><time>${esc(new Date(event.created).toLocaleString())}</time><p>${esc(event.group.name)}${task?' · '+esc(task.title):''}</p></article>`);
  }
  if(!list.children.length)list.innerHTML='<p class="empty">No updates yet.</p>';
}
function renderPersonalWork(host) {
  $('#composer-area').hidden=true;
  if(state.panel==='updates'){renderUpdates(host);return;}
  // Preserve loaded task/Memo DOM between polling snapshots.
  const key=state.selected+':'+workView;
  if(host.dataset.personalWork!==key||!host.querySelector('#personal-work-content')) {
    host.dataset.personalWork=key;
    host.innerHTML='<div id="personal-group-tasks"></div><div id="personal-work-content"></div>';
  }
  const content=host.querySelector('#personal-work-content'), shared=host.querySelector('#personal-group-tasks');
  host.classList.toggle('notes-view',workView==='memo');
  if(workView==='memo'){shared.innerHTML='';renderNotes(content);return;}
  if(['automation','workflows'].includes(workView)){shared.innerHTML='';content.innerHTML=`<p class="empty">${activityLabels[workView]} is not available yet.</p>`;return;}
  const groups=state.agents.filter(g=>g.kind==='group');
  shared.innerHTML=groups.flatMap(g=>g.tasks.filter(t=>t.assignee===state.selected&&!t.deleted&&((t.state==='done')===(taskPeriod==='past'))).map(t=>groupTaskCard(g,t))).join('');
  renderTasks(content);
}
document.addEventListener('click',async e=>{
  const b=e.target.closest('button');if(!b)return;const d=b.dataset;
  if(d.newGroupTask){taskDialog(agent(d.newGroupTask));return;}
  if(d.groupTask){const group=agent(d.group);taskDialog(group,group.tasks.find(t=>t.id===d.groupTask));return;}
  if(!d.groupArchive&&!d.taskRun&&!d.groupCall)return;
  b.disabled=true;
  try{
    if(d.groupArchive){const group=agent(d.groupArchive);await api(`/api/groups/${group.id}`,'PUT',{revision:group.revision,archived:!group.archived});closeModal();}
    if(d.taskRun){const group=agent(d.group),task=group.tasks.find(t=>t.id===d.taskRun);await api(`/api/groups/${group.id}/tasks/${task.id}/run`,'POST',{revision:task.revision});}
    if(d.groupCall)await api(`/api/groups/${d.group}/calls/${d.call}/${d.groupCall}`,'POST',{});
    await refresh();render();
  }catch(error){toast(error.message);}finally{b.disabled=false;}
});

document.addEventListener('change',e=>{
  if(!e.target.matches('[data-work-filter]'))return;
  if(selected().kind==='group')groupTaskFilter=e.target.value;else taskPeriod=e.target.value;
  renderConversation();
});
document.addEventListener('toggle',e=>{
  const id=e.target.dataset?.openGroupTask;
  if(id&&e.target.isConnected)e.target.open?openGroupTasks.add(id):openGroupTasks.delete(id);
},true);
