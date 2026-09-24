// One entity catalog powers text links and composer suggestions.
function mentionEntities() {
  const entities = state.agents.map(a => ({type:a.kind === 'group' ? 'group' : 'sapi',id:a.id,name:a.name,owner:a.id}));
  for (const [owner, info] of Object.entries(live.orchestration || {})) {
    for (const task of [...info.tasks, ...info.past_tasks]) {
      if (task.name) entities.push({type:'task',id:task.id,name:task.name,tag:task.tag,slug:task.slug,aliases:task.aliases || [],owner,past:info.past_tasks.includes(task),title:task.title});
    }
  }
  entities.push(...(live.artifacts || []));
  return entities;
}
function entityLink(entity, label=entity.name) {
  if (entity.type === 'artifact') return `<button type="button" class="entity-mention" data-artifact-link="${esc(entity.tag)}" data-artifact-owner="${esc(entity.owner)}" aria-label="Open artifact ${esc(entity.name)}">@${esc(label)}</button>`;
  return entity.type === 'task' ? `<button type="button" class="entity-mention" data-task-link="${esc(entity.id)}" data-task-owner="${esc(entity.owner)}" aria-label="Open task ${esc(entity.name)}">@${esc(label)}</button>` : mention(entity.id);
}
function formatMentions(value) {
  const text = String(value ?? '');
  const entities = mentionEntities().flatMap(e => [...new Set([e.name,e.tag,...(e.aliases || [])].filter(Boolean))].map(handle => ({...e,handle}))).sort((a,b) => b.handle.length-a.handle.length);
  if (!entities.length) return esc(text);
  const names = [...new Set(entities.map(e => e.handle))].map(n => n.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
  const pattern = new RegExp(`(?<![\\p{L}\\p{N}_@.-])@?(?:${names.join('|')})(?![\\p{L}\\p{N}_@:-])`, 'gu');
  let result='', cursor=0;
  for (const match of text.matchAll(pattern)) {
    const candidates = entities.filter(e => e.handle === match[0].replace(/^@/,''));
    result += esc(text.slice(cursor,match.index)) + (candidates.length === 1 ? entityLink(candidates[0],match[0].replace(/^@/,'')) : esc(match[0]));
    cursor=match.index+match[0].length;
  }
  return result + esc(text.slice(cursor));
};
// Parse link tokens before mentions so names inside URLs never become buttons.
function chatLink(destination, label) {
  const artifact = (live.artifacts || []).find(a => destination === a.path || destination === a.url);
  if (artifact) return entityLink(artifact);
  let url;
  try { url = new URL(destination); } catch { return esc(label || destination); }
  if (!['http:','https:'].includes(url.protocol)) return esc(label || destination);
  if (!label) {
    let tail = url.pathname.split('/').filter(Boolean).pop() || '';
    try { tail = decodeURIComponent(tail); } catch {}
    if (tail.length > 48) tail = tail.slice(0,45) + '…';
    label = url.hostname + (tail ? ' · ' + tail : '');
  }
  return `<a class="chat-link" href="${esc(url.href)}" title="${esc(destination)}" target="_blank" rel="noopener noreferrer">${esc(label)} ↗</a>`;
}
formatText = function(value) {
  const text = String(value ?? '');
  const tokens = /\[([^\]\n]+)\]\((?:<([^>\n]+)>|((?:[^()\s]|\([^()\s]*\))+))\)|https?:\/\/[^\s<>]+|`([^`\n]+)`|\*\*([^*\n]+)\*\*/g;
  let output = '', cursor = 0;
  for (const match of text.matchAll(tokens)) {
    output += formatMentions(text.slice(cursor,match.index));
    if (match[1] !== undefined) output += chatLink(match[2] || match[3], match[1]);
    else if (match[4] !== undefined) output += `<code>${esc(match[4])}</code>`;
    else if (match[5] !== undefined) output += `<strong>${formatMentions(match[5])}</strong>`;
    else {
      let url = match[0].replace(/[.,;:!?]+$/, '');
      while (url.endsWith(')') && (url.match(/\)/g)||[]).length > (url.match(/\(/g)||[]).length) url = url.slice(0,-1);
      output += chatLink(url) + esc(match[0].slice(url.length));
    }
    cursor = match.index + match[0].length;
  }
  return output + formatMentions(text.slice(cursor));
};
let mentionRange = null, mentionChoices = [], mentionIndex = 0;
function closeMentions() {
  $('#mention-suggestions')?.remove();
  $('#message-input').setAttribute('aria-expanded','false');
  $('#message-input').removeAttribute('aria-activedescendant');
  mentionRange=null; mentionChoices=[];
}
function updateMentions() {
  const input=$('#message-input'), before=input.value.slice(0,input.selectionStart);
  const match=before.match(/(?:^|\s)@([A-Za-z0-9_.:#+|()&$^\-]*)$/);
  if (!match || input.selectionStart !== input.selectionEnd) { closeMentions(); return; }
  mentionRange={start:input.selectionStart-match[1].length-1,end:input.selectionStart};
  mentionChoices=mentionEntities().filter(e => !(e.type === 'sapi' && agent(e.id).retired) && [e.name,e.tag,e.slug,e.filename,e.title,...(e.aliases || [])].filter(Boolean).some(n => n.toLowerCase().startsWith(match[1].toLowerCase()))).slice(0,12);
  mentionIndex=0;
  drawMentions();
}
function drawMentions() {
  let menu=$('#mention-suggestions');
  if (!menu) { menu=document.createElement('div');menu.id='mention-suggestions';menu.className='mention-suggestions';menu.setAttribute('role','listbox');menu.setAttribute('aria-label','Sapis, groups, tasks and artifacts');$('#chat-form').append(menu); }
  menu.innerHTML=mentionChoices.length ? mentionChoices.map((e,i) => `<button type="button" role="option" id="mention-option-${i}" aria-selected="${i===mentionIndex}" data-mention-choice="${i}"><strong>@${esc(e.name)}</strong><small>${esc(e.type === 'task' ? `Task · ${agent(e.owner).name}${e.past ? ' · Past' : ''}` : e.type === 'artifact' ? `Artifact · ${agent(e.owner).name}` : e.type === 'group' ? 'Group' : 'Sapi')}</small></button>`).join('') : '<div class="empty">No matching Sapis, groups, tasks or artifacts.</div>';
  const input=$('#message-input');input.setAttribute('aria-controls',menu.id);input.setAttribute('aria-expanded','true');
  if (mentionChoices.length) input.setAttribute('aria-activedescendant',`mention-option-${mentionIndex}`);
}
function chooseMention(index) {
  const entity=mentionChoices[index], range=mentionRange, input=$('#message-input');
  if (!entity || !range) return;
  input.setRangeText(`@${entity.name} `,range.start,range.end,'end');
  state.drafts[state.selected]=input.value;save();closeMentions();input.focus();
}
document.addEventListener('input',e => { if(e.target.id==='message-input') updateMentions(); });
document.addEventListener('click',async e => {
  const choice=e.target.closest('[data-mention-choice]');
  if (choice) { e.preventDefault();e.stopImmediatePropagation();chooseMention(Number(choice.dataset.mentionChoice));return; }
  const artifactLink=e.target.closest('[data-artifact-link]');
  if (artifactLink) {
    e.preventDefault();e.stopImmediatePropagation();closeMentions();
    const entity=mentionEntities().find(a=>a.type==='artifact' && a.tag===artifactLink.dataset.artifactLink && a.owner===artifactLink.dataset.artifactOwner);
    if (!entity) return;
    try {
      await api(`/api/agents/${entity.owner}/control`, 'POST', {op:'workspace_open',artifact:entity.tag});
      await refresh();openChat(entity.owner);state.panes.workspace=true;render();
    } catch (error) {toast(error.message);}
    return;
  }
  const link=e.target.closest('[data-task-link]');
  if (link) {
    e.preventDefault();e.stopImmediatePropagation();closeMentions();
    const entity=mentionEntities().find(t=>t.type==='task' && t.id===link.dataset.taskLink && t.owner===link.dataset.taskOwner);
    if (!entity) return;
    openChat(entity.owner);state.panel='tasks';workViews.tasks=entity.past?'past':'ongoing';renderConversation();save();
    taskDialog(entity.owner,entity.id);
    return;
  }
  if (e.target.id==='message-input') updateMentions(); else closeMentions();
},true);
document.addEventListener('keydown',e => {
  if (e.target.id!=='message-input' || !mentionRange || e.isComposing) return;
  if (!['ArrowDown','ArrowUp','Enter','Tab','Escape'].includes(e.key)) return;
  e.preventDefault();e.stopImmediatePropagation();
  if (e.key==='Escape') {closeMentions();return;}
  if (!mentionChoices.length) return;
  if (e.key==='Enter' || e.key==='Tab') {chooseMention(mentionIndex);return;}
  mentionIndex=(mentionIndex+(e.key==='ArrowDown'?1:-1)+mentionChoices.length)%mentionChoices.length;drawMentions();
},true);
