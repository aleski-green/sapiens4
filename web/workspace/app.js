'use strict';
const $ = (s, root = document) => root.querySelector(s);
const $$ = (s, root = document) => [...root.querySelectorAll(s)];
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const uid = () => 'id-' + Math.random().toString(36).slice(2, 10);

let state = makeInitialState(bootstrap);
let workspaceOwner = state.selected;
function syncWorkspace(){
  workspaceOwner=state.selected;
  const ws=state.workspaces[workspaceOwner] || {tabs:[]};
  state.tabs=ws.tabs;state.activeTab=ws.activeTab || null;
}

let search = '', toastTimer, pending = new Set();
const agent = id => state.agents.find(a=>a.id===id) || state.agents[0];
const selected = () => agent(state.selected);
const isGroup = a => a.kind==='group';
const isMainSapi = a => a.id===state.mainSapiId;

const groupAvatarCache = new Map();
function groupAvatar(a){
  const key=JSON.stringify([a.id,a.name,a.face,a.color,a.groupAvatar]);
  if(!groupAvatarCache.has(key)){
    const safeColor=/^#[a-f0-9]{6}$/i.test(a.color)?a.color:'#dbd0f7';
    const group=a.groupAvatar || {id:a.id,name:a.name,lead:{id:a.id+'-lead',expression:a.face,colour:safeColor},peers:[{id:a.id+'-peer-1',expression:'◕‿◕',colour:'#c9f3f1'},{id:a.id+'-peer-2',expression:'◠‿◠',colour:'#f7d6d1'}],groups:[]};
    const svg=SapiGroupAvatar.render(group,{tight:true});
    groupAvatarCache.set(key,'data:image/svg+xml;charset=utf-8,'+encodeURIComponent(svg));
  }
  return groupAvatarCache.get(key);
}
const avatar = (a, size='', presence=false) => `<span class="avatar ${size} ${isGroup(a)?'group-avatar':''}" style="--avatar-color:${/^#[a-f0-9]{6}$/i.test(a.color)?a.color:'#fdd997'}" aria-hidden="true">${isGroup(a)?`<img src="${esc(groupAvatar(a))}" alt="">`:`(${esc(a.face)})`}${presence?`<i class="presence ${a.status==='busy'?'busy':a.status==='idle'?'idle':''}"></i>`:''}</span>`;
function mention(id){
  const a=state.agents.find(a=>a.id===id);
  return a?`<button type="button" class="entity-mention" data-mention="${esc(a.id)}" aria-label="Open chat with ${esc(a.name)}">@${esc(a.name)}</button>`:esc(id==='you'?'You':id);
}

function openChat(id){
  const a=state.agents.find(a=>a.id===id);if(!a)return;
  state.drafts ??= {};state.drafts[state.selected]=$('#message-input').value;
  state.selected=id;state.panel='chat';state.panes.chat=true;a.unread=false;
  if(state.scope!=='all')state.scope=isGroup(a)?'groups':'sapis';
  search='';$('#agent-search').value='';$('#message-input').value=state.drafts[id]||'';
  closeModal();render();$('#conversation-body').scrollTop=$('#conversation-body').scrollHeight;
}

function toast(message){$('#toast').textContent=message;$('#toast').classList.add('visible');clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('#toast').classList.remove('visible'),3200);}

function modal(title,content,eyebrow='SAPI WORKSPACE'){$('#modal-eyebrow').textContent=eyebrow;$('#modal-content').innerHTML=`<h2 id="modal-title">${esc(title)}</h2>${content}`;if(!$('#modal').open)$('#modal').showModal();}
function closeModal(){$('#modal').close();}
function render(){if($('#modal').open&&$('#modal-title')?.textContent==='Shared computer')computerDialog();renderPanes();renderSidebar();renderAgentHeader();renderConversation();renderTabs();renderWorkspace();renderGlobal();save();}
function renderPanes(){
  state.panes ??= {sidebar:true,chat:true,workspace:true};
  const names={sidebar:'chat list',chat:'chat',workspace:'workspace'};
  const ids={sidebar:'#chat-list-panel',chat:'#chat-panel',workspace:'#workspace-panel'};
  for(const pane of Object.keys(ids)){
    $(ids[pane]).hidden=!state.panes[pane];
    const button=$(`[data-toggle-pane="${pane}"]`);
    button.setAttribute('aria-pressed',String(state.panes[pane]));
    button.setAttribute('aria-expanded',String(state.panes[pane]));
    const label=`${state.panes[pane]?'Hide':'Show'} ${names[pane]}`;
    button.setAttribute('aria-label',label);button.title=label;
  }
  const p=state.panes;
  const count=Object.values(p).filter(Boolean).length;
  $('.main-grid').dataset.visiblePanes=count;
  $('.main-grid').style.gridTemplateColumns=[p.sidebar?(count===1?'minmax(0,1fr)':'clamp(205px,18vw,250px)'):'0px',p.chat?'minmax(300px,1fr)':'0px',p.workspace?'minmax(350px,1.2fr)':'0px'].join(' ');
}

function renderSidebar(){
  $('#agent-count').textContent=String(state.agents.length).padStart(2,'0');
  $$('[data-scope]').forEach(b=>{b.classList.toggle('active',b.dataset.scope===state.scope);b.setAttribute('aria-pressed',b.dataset.scope===state.scope);});
  const list=state.agents.filter(a=>isMainSapi(a)||((state.scope==='all'||(state.scope==='groups'?isGroup(a):!isGroup(a)))&&`${a.name} ${a.role}`.toLowerCase().includes(search.toLowerCase())))
    .sort((a,b)=>Number(isMainSapi(b))-Number(isMainSapi(a))||(b.lastActivity||0)-(a.lastActivity||0));
  $('#agent-list').innerHTML=list.map(a=>`<button class="agent-row ${a.id===state.selected?'active':''} ${isMainSapi(a)?'main-sapi-row':''}" data-agent="${esc(a.id)}" aria-pressed="${a.id===state.selected}">${avatar(a,isMainSapi(a)?'main-sapi-avatar':'',true)}<span class="agent-row-copy"><span class="agent-row-name">${esc(a.name)}<small>${esc(new Date(a.lastActivity).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit',hour12:false}))}</small></span><p>${esc(a.preview)}</p></span>${a.unread&&!isMainSapi(a)?'<span class="unread-dot"></span>':''}</button>`).join('');
}

// Live modules assign these before the first render.
let save, getMessages, formatText, renderGlobal, renderAgentHeader, sendChat;
let addAgent, agentSettings, computerDialog, autonomyDialog, renderAttachment;
function renderConversation() {
  const host = $('#conversation-body'), a = selected();
  $('#composer-area').hidden = state.panel !== 'chat';
  host.innerHTML = '<div class="day-divider">CONVERSATION</div>' + getMessages(a.id).map(m =>
    `<div class="message ${m.role==='user'?'user':''}"><div class="message-meta">${m.role==='assistant'?avatar(a,'mini'):'<span>↗</span>'}<strong>${m.role==='user'?'You':mention(a.id)}</strong><time>${esc(m.time)}</time></div><div class="message-bubble">${m.text.split('\n\n').map(p=>`<p>${formatText(p).replace(/\n/g,'<br>')}</p>`).join('')}</div></div>`).join('');
  renderAttachment();
}

const actions = {'new-tab':addTabDialog};

document.addEventListener('click',e=>{
  const b=e.target.closest('button');if(!b)return;const d=b.dataset;

  if(d.togglePane){state.panes[d.togglePane]=!state.panes[d.togglePane];renderPanes();save();return;}
  if(d.action){actions[d.action]?.();return;}
  if(d.mention){openChat(d.mention);return;}
  if(d.agent){openChat(d.agent);return;}
  if(d.scope){state.scope=d.scope;renderSidebar();save();return;}
  if(d.panel && !b.disabled && ['chat','notes','log'].includes(d.panel)){state.panel=d.panel;renderConversation();save();return;}
  if(d.tab){browserAction('focus',{id:d.tab});return;}
  if(d.closeTab){browserAction('close',{id:d.closeTab});return;}


});

document.addEventListener('submit',e=>{if(e.target.id==='chat-form'){e.preventDefault();sendChat($('#message-input').value);}});

$('#close-modal').addEventListener('click',closeModal);
$('#modal').addEventListener('click',e=>{if(e.target===$('#modal')){const r=$('#modal').getBoundingClientRect();if(e.clientX<r.left||e.clientX>r.right||e.clientY<r.top||e.clientY>r.bottom)closeModal();}});

$('#add-agent').addEventListener('click',()=>addAgent());
$('#autonomy-button').addEventListener('click',()=>autonomyDialog());
$('#resource-button').addEventListener('click',()=>computerDialog());


$('#agent-search').addEventListener('input',e=>{search=e.target.value;renderSidebar();});

$('#message-input').addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.shiftKey&&!e.isComposing){e.preventDefault();sendChat(e.target.value);}});
$('.wordmark').addEventListener('click',e=>{e.preventDefault();state.panes={sidebar:true,chat:true,workspace:true};renderPanes();save();});
$('#workspace-menu').addEventListener('click',showBookmarks);

document.addEventListener('keydown',e=>{if(e.key==='/'&&!['INPUT','TEXTAREA','SELECT'].includes(document.activeElement.tagName)&&!$('#modal').open){e.preventDefault();state.panes.sidebar=true;renderPanes();save();$('#agent-search').focus();}});
