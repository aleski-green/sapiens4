function formatMentions(value) {
  const text = String(value ?? '');
  const entities = [...state.agents].sort((a,b) => b.name.length-a.name.length);
  if (!entities.length) return esc(text);
  const names = [...new Set(entities.map(e => e.name))].map(n => n.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
  const pattern = new RegExp(`(?<![\\p{L}\\p{N}_@.-])@?(?:${names.join('|')})(?![\\p{L}\\p{N}_@:-])`, 'gu');
  let result='', cursor=0;
  for (const match of text.matchAll(pattern)) {
    const candidates = entities.filter(e => e.name === match[0].replace(/^@/,''));
    result += esc(text.slice(cursor,match.index)) + (candidates.length === 1 ? mention(candidates[0].id) : esc(match[0]));
    cursor=match.index+match[0].length;
  }
  return result + esc(text.slice(cursor));
};
// Parse link tokens before mentions so names inside URLs never become buttons.
function chatLink(destination, label) {
  if (destination.startsWith('/') || destination.startsWith('file://'))
    return `<button type="button" class="entity-mention" data-file-link="${esc(destination)}">${esc(label || destination)}</button>`;
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
  const tokens = /\[([^\]\n]+)\]\((?:<([^>\n]+)>|((?:[^()\s]|\([^()\s]*\))+))\)|https?:\/\/[^\s<>]+|`([^`\n]+)`|\*\*([^*\n]+)\*\*|:codex-file-citation\{((?:[^{}"\n]|"(?:\\.|[^"\\\n])*")*)\}/g;
  const matches = [...text.matchAll(tokens)];
  const files = new Set(matches.filter(m => m[1] !== undefined).map(m => m[2] || m[3]));
  let output = '', cursor = 0;
  for (const match of matches) {
    output += formatMentions(text.slice(cursor,match.index));
    if (match[1] !== undefined) output += chatLink(match[2] || match[3], match[1]);
    else if (match[4] !== undefined) output += `<code>${esc(match[4])}</code>`;
    else if (match[5] !== undefined) output += `<strong>${formatMentions(match[5])}</strong>`;
    else if (match[6] !== undefined) {
      const path = /(?:^|\s)path="((?:\\.|[^"\\])*)"/.exec(match[6])?.[1]?.replace(/\\([\\_"])/g, '$1');
      if (!path || !/^(\/|file:\/\/)/.test(path)) output += esc(match[0]);
      else if (!files.has(path)) {output += chatLink(path, path.split('/').pop());files.add(path);}
    }
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
  mentionChoices=state.agents.filter(a => a.kind!=='group' && !a.retired && (selected().kind!=='group'||selected().members.includes(a.id)) && a.name.toLowerCase().startsWith(match[1].toLowerCase())).slice(0,12);
  mentionIndex=0;
  drawMentions();
}
function drawMentions() {
  let menu=$('#mention-suggestions');
  if (!menu) { menu=document.createElement('div');menu.id='mention-suggestions';menu.className='mention-suggestions';menu.setAttribute('role','listbox');menu.setAttribute('aria-label','Sapis');$('#chat-form').append(menu); }
  menu.innerHTML=mentionChoices.length ? mentionChoices.map((e,i) => `<button type="button" role="option" id="mention-option-${i}" aria-selected="${i===mentionIndex}" data-mention-choice="${i}"><strong>@${esc(e.name)}</strong><small>Sapi</small></button>`).join('') : '<div class="empty">No matching Sapis.</div>';
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
  const pageLink=e.target.closest('a.chat-link');
  if(pageLink && window.webkit?.messageHandlers?.browser){
    e.preventDefault();e.stopImmediatePropagation();browserAction('open',{url:pageLink.href});return;
  }
  const fileLink=e.target.closest('[data-file-link]');
  if (fileLink) {
    e.preventDefault();closeMentions();
    browserAction('open',browserDestination(fileLink.dataset.fileLink));
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
