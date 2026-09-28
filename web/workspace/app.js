'use strict';
const $ = (s, root = document) => root.querySelector(s);
const $$ = (s, root = document) => [...root.querySelectorAll(s)];
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const uid = () => 'id-' + Math.random().toString(36).slice(2, 10);

const tabTypes = {custom:['↗','Website'],blank:['','New tab'],html:['◇','HTML']};
let state = makeInitialState(bootstrap);
let workspaceOwner = state.selected;
const browserFrames = new Map();

function storeWorkspace(){state.workspaces[workspaceOwner]={tabs:state.tabs,activeTab:state.activeTab};}
function syncWorkspace(){
  if(workspaceOwner===state.selected)return;
  storeWorkspace();workspaceOwner=state.selected;
  const ws=state.workspaces[workspaceOwner] || {tabs:[{id:uid(),type:'blank',title:'New tab'}]};
  state.tabs=ws.tabs;state.activeTab=ws.activeTab??ws.tabs[0]?.id??null;
}


let search = '', toastTimer, dragId, pending = new Set();
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

function renderTabs(){syncWorkspace();const host=$('#browser-tabs');host.innerHTML=state.tabs.map(t=>`<div class="workspace-tab ${t.id===state.activeTab?'active':''}" draggable="true" data-drag-tab="${esc(t.id)}"><button class="tab-select" data-tab="${esc(t.id)}" aria-pressed="${t.id===state.activeTab}"><span class="tab-icon">${tabTypes[t.type]?.[0]??'↗'}</span>${esc(t.title)}</button><button class="tab-close" data-close-tab="${esc(t.id)}" aria-label="Close ${esc(t.title)}">×</button></div>`).join('');
  $$('[data-drag-tab]').forEach(el=>{el.addEventListener('dragstart',e=>{dragId=el.dataset.dragTab;e.dataTransfer.setData('text/plain',dragId);e.dataTransfer.effectAllowed='move';});el.addEventListener('dragover',e=>e.preventDefault());el.addEventListener('drop',e=>{e.preventDefault();const target=el.dataset.dragTab;const from=state.tabs.findIndex(t=>t.id===dragId),to=state.tabs.findIndex(t=>t.id===target);if(from<0||to<0)return;state.tabs.splice(to,0,state.tabs.splice(from,1)[0]);renderTabs();save();});el.addEventListener('dblclick',e=>{if(!e.target.closest('[data-close-tab]'))tabSettings(el.dataset.dragTab);});});
}
function openTab(type='blank',title,extra={}){
  syncWorkspace();
  const t={id:uid(),type,title:title||tabTypes[type]?.[1]||'New tab',...extra};
  state.tabs.push(t);state.activeTab=t.id;state.panes.workspace=true;
  renderPanes();renderTabs();renderWorkspace();save();
}
function renderWorkspace(){
  syncWorkspace();
  $('#workspace-owner').innerHTML=`${mention(workspaceOwner)}<span>’s workspace</span>`;
  const t=state.tabs.find(t=>t.id===state.activeTab),host=$('#workspace-content');
  $('#browser-address-form').hidden=!t;
  $('#browser-address').value=t?.type==='custom'?t.url:t?.type==='html'?'HTML document':'';
  $('#open-page').hidden=t?.type!=='custom';
  if(t?.type==='custom')$('#open-page').href=t.url;else $('#open-page').removeAttribute('href');
  storeWorkspace();
  const liveIds=new Set(Object.values(state.workspaces).flatMap(ws=>ws.tabs.map(t=>t.id)).concat(state.tabs.map(t=>t.id)));
  for(const [id,entry] of browserFrames)if(!liveIds.has(id)){entry.frame.remove();browserFrames.delete(id);}
  for(const entry of browserFrames.values())entry.frame.hidden=true;
  if(!t)return;
  const signature=JSON.stringify([t.type,t.url,t.html]);
  let entry=browserFrames.get(t.id);
  if(!entry||entry.signature!==signature){
    entry?.frame.remove();
    const frame=document.createElement('iframe');
    frame.className='workspace-browser';
    // Guest scripts run in an opaque origin, separated from app data and controls.
    frame.setAttribute('sandbox','allow-scripts allow-forms allow-popups allow-popups-to-escape-sandbox allow-downloads');
    frame.referrerPolicy='no-referrer';
    if(t.type==='custom'&&safeUrl(t.url))frame.src=safeUrl(t.url);
    else if(t.type==='html')frame.srcdoc=t.html||'';
    else frame.srcdoc='<!doctype html><html><head><meta name="color-scheme" content="light dark"></head><body></body></html>';
    entry={frame,signature};browserFrames.set(t.id,entry);host.append(frame);
  }
  entry.frame.title=t.title;entry.frame.hidden=false;
}
function safeUrl(value){try{const u=new URL(value);return /^https?:$/.test(u.protocol)?u.href:null;}catch{return null;}}
function addTabDialog(){modal('Add tab',`<form id="custom-tab-form" class="form-stack"><label>Tab name<input name="title" placeholder="New tab" maxlength="48"></label><label>Website URL<input name="url" type="url" placeholder="https://…"></label><label>Or paste HTML<textarea name="html" aria-label="HTML source" placeholder="<!doctype html>" rows="5"></textarea></label><button type="submit" class="button primary">Add tab</button></form>`);}
function tabSettings(id){const t=state.tabs.find(t=>t.id===id);if(!t)return;modal('Tab settings',`<form class="form-stack" id="tab-settings-form" data-id="${esc(id)}"><label>Tab name<input name="title" value="${esc(t.title)}" maxlength="48" required></label><label>Website URL<input name="url" type="url" value="${esc(t.url||'')}" placeholder="https://…"></label><label>HTML source<textarea name="html" rows="5">${esc(t.html||'')}</textarea></label><button class="button primary" type="submit">Save tab</button></form><div class="modal-actions"><button class="button" data-move-tab="left" data-id="${esc(id)}">← Move left</button><button class="button" data-move-tab="right" data-id="${esc(id)}">Move right →</button><button class="button danger" data-close-tab="${esc(id)}">Close tab</button></div>`);}

const actions = {'new-tab':addTabDialog};

document.addEventListener('click',e=>{
  const b=e.target.closest('button');if(!b)return;const d=b.dataset;

  if(d.togglePane){state.panes[d.togglePane]=!state.panes[d.togglePane];renderPanes();save();return;}
  if(d.action){actions[d.action]?.();return;}
  if(d.mention){openChat(d.mention);return;}
  if(d.agent){openChat(d.agent);return;}
  if(d.scope){state.scope=d.scope;renderSidebar();save();return;}
  if(d.panel && !b.disabled && ['chat','notes','log'].includes(d.panel)){state.panel=d.panel;renderConversation();save();return;}
  if(d.tab){state.activeTab=d.tab;renderTabs();renderWorkspace();save();return;}
  if(d.closeTab){const i=state.tabs.findIndex(t=>t.id===d.closeTab);if(i<0)return;state.tabs.splice(i,1);if(state.activeTab===d.closeTab)state.activeTab=state.tabs[Math.max(0,i-1)]?.id||null;closeModal();renderTabs();renderWorkspace();save();return;}
  if(d.newTabType){openTab(d.newTabType);closeModal();return;}
  if(d.editTab){tabSettings(d.editTab);return;}
  if(d.moveTab){const i=state.tabs.findIndex(t=>t.id===d.id),j=i+(d.moveTab==='left'?-1:1);if(j<0||j>=state.tabs.length){toast('That tab is already at the edge.');return;}[state.tabs[i],state.tabs[j]]=[state.tabs[j],state.tabs[i]];renderTabs();save();return;}

});

document.addEventListener('submit',e=>{const f=e.target;if(f.id==='chat-form'){e.preventDefault();sendChat($('#message-input').value);return;}if(!['custom-tab-form','tab-settings-form'].includes(f.id))return;e.preventDefault();const data=Object.fromEntries(new FormData(f));

  if(f.id==='custom-tab-form'||f.id==='tab-settings-form'){
    if(data.url.trim()&&data.html.trim()){toast('Use a website URL or HTML, one source per tab.');return;}
    const url=data.url.trim()?safeUrl(data.url.trim()):null;
    if(data.url.trim()&&!url){toast('Use an http:// or https:// website address.');return;}
    const type=url?'custom':data.html.trim()?'html':'blank';
    const title=data.title.trim()||(url?new URL(url).hostname:tabTypes[type][1]);
    if(f.id==='custom-tab-form')openTab(type,title,{url,html:data.html});
    else Object.assign(state.tabs.find(t=>t.id===f.dataset.id),{type,title,url,html:data.html});
  }

  closeModal();render();
});

$('#close-modal').addEventListener('click',closeModal);
$('#modal').addEventListener('click',e=>{if(e.target===$('#modal')){const r=$('#modal').getBoundingClientRect();if(e.clientX<r.left||e.clientX>r.right||e.clientY<r.top||e.clientY>r.bottom)closeModal();}});

$('#browser-address-form').addEventListener('submit',e=>{
  e.preventDefault();const value=$('#browser-address').value.trim();
  const url=safeUrl(value);if(!url){toast('Use an http:// or https:// website address.');return;}
  const t=state.tabs.find(t=>t.id===state.activeTab);if(!t)return;
  Object.assign(t,{type:'custom',url,html:'',title:new URL(url).hostname});renderTabs();renderWorkspace();save();
});
$('#reload-page').addEventListener('click',()=>{const entry=browserFrames.get(state.activeTab);if(entry){entry.frame.remove();browserFrames.delete(state.activeTab);}renderWorkspace();});
$('#add-tab').addEventListener('click',addTabDialog);
$('#add-agent').addEventListener('click',()=>addAgent());
$('#autonomy-button').addEventListener('click',()=>autonomyDialog());
$('#resource-button').addEventListener('click',()=>computerDialog());


$('#agent-search').addEventListener('input',e=>{search=e.target.value;renderSidebar();});

$('#message-input').addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.shiftKey&&!e.isComposing){e.preventDefault();sendChat(e.target.value);}});
$('.wordmark').addEventListener('click',e=>{e.preventDefault();state.panes={sidebar:true,chat:true,workspace:true};renderPanes();save();});
$('#workspace-menu').addEventListener('click',()=>{if(state.activeTab)tabSettings(state.activeTab);else addTabDialog();});

document.addEventListener('keydown',e=>{if(e.key==='/'&&!['INPUT','TEXTAREA','SELECT'].includes(document.activeElement.tagName)&&!$('#modal').open){e.preventDefault();state.panes.sidebar=true;renderPanes();save();$('#agent-search').focus();}});
