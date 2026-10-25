'use strict';
const $ = (s, root = document) => root.querySelector(s);
const $$ = (s, root = document) => [...root.querySelectorAll(s)];
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

let state = makeInitialState(bootstrap);
let toastTimer;
const agent = id => state.agents.find(a=>a.id===id) || state.agents[0];
const selected = () => agent(state.selected);
const isMainSapi = a => a.id===state.mainSapiId;

const avatar = (a, size='', presence=false) => a.kind==='group' ? groupAvatar(a,size) : `<span class="avatar ${size}" style="--avatar-color:${/^#[a-f0-9]{6}$/i.test(a.color)?a.color:'#fdd997'}" aria-hidden="true">(${esc(a.face)})${presence?`<i class="presence ${a.status==='busy'?'busy':a.status==='idle'?'idle':''}"></i>`:''}</span>`;
function mention(id,model=state){
  const a=model.agents.find(a=>a.id===id);
  return a?`<button type="button" class="entity-mention" data-mention="${esc(a.id)}" aria-label="Open chat with ${esc(a.name)}">@${esc(a.name)}</button>`:esc(id==='you'?'You':id);
}

// The only writer of workspace state. Effects may dispatch replies, never mutate it.
function dispatchUI(action) {
  const [next,commands]=updateUI(state,action);state=next;
  for(const command of commands)performUI(command);
}
function performUI(command) {
  switch(command.type) {
    case 'Selection':
      closeActivityMenus();showPane('chat');
      $('#agent-search').value='';syncComposer();closeModal();setBrowserMenu();render();
      $('#conversation-body').scrollTop=$('#conversation-body').scrollHeight;return;
    case 'Activity': closeActivityMenus();renderConversation();save();return;
    case 'Roster': if(paneLimit()<3){showPane('sidebar');renderPanes();}renderSidebar();save();return;
    case 'Persist': save();return;
    case 'Notify': toast(command.message);return;
    case 'Sent': closeMentions();save();refresh();return;
    case 'Render':
      for(const region of command.regions)({conversation:renderConversation,sidebar:renderSidebar,header:renderAgentHeader,composer:syncComposer,attachments:renderAttachment})[region]();
      return;
    case 'LoadDocument': {
      const {request}=command;
      api(request.path).then(data=>({type:'Ready',value:decodeDocument(request.kind,data)}))
        .catch(error=>({type:'Failed',error:error.message}))
        .then(result=>dispatchUI({type:'DocumentReceived',request,result}));return;
    }
    case 'SendMessage': {
      const {request,path}=command;
      api(path,'POST',{text:request.text,attachments:request.attachments.map(a=>a.id),...(request.workload?{workload:request.workload}:{})})
        .then(()=>dispatchUI({type:'MessageSent',request}),error=>dispatchUI({type:'MessageFailed',request,error:error.message}));return;
    }
    default: throw new Error('Unknown UI command: '+command.type);
  }
}
function syncComposer() {
  const input=$('#message-input'),value=state.drafts[state.selected]||'';
  if(input.value!==value)input.value=value;
  resizeComposer();
}
function saveDraft(value=$('#message-input').value) {dispatchUI({type:'Draft',value});}
function openChat(id){dispatchUI({type:'Select',id,draft:$('#message-input').value});}

function toast(message){$('#toast').textContent=message;$('#toast').classList.add('visible');clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('#toast').classList.remove('visible'),3200);}

function modal(title,content,eyebrow='SAPI WORKSPACE'){$('#modal').classList.remove('app-menu-sheet');$('#modal-eyebrow').textContent=eyebrow;$('#modal-content').innerHTML=`<h2 id="modal-title">${esc(title)}</h2>${content}`;if(!$('#modal').open)$('#modal').showModal();}
function closeModal(){$('#modal').close();}
function render(){if($('#modal').open&&$('#modal-title')?.textContent==='Shared computer')computerDialog();renderPanes();renderSidebar();renderAgentHeader();renderConversation();renderTabs();renderWorkspace();renderGlobal();save();}
function paneLimit(){
  const touch=window.matchMedia?.('(pointer: coarse)').matches;
  if(!touch && window.innerWidth>600)return 3;
  // The software keyboard changes viewport height, but not the phone's orientation.
  const orientation=touch && window.screen.orientation?.type;
  const portrait=orientation ? orientation.startsWith('portrait') : window.innerHeight>=window.innerWidth;
  return portrait ? 1 : 2;
}
function showPane(pane, toggle=false){
  dispatchUI({type:'Pane',pane,toggle,limit:paneLimit()});
}
function renderPanes(){
  const limit=paneLimit();
  const p=paneState(state.panes,state.paneOrder,limit,!!state.activeTab).panes;
  p.workspace &&= !!state.activeTab;
  document.body.dataset.paneLimit=limit;
  document.body.toggleAttribute('data-mobile-ui',limit<3);
  syncMobileViewport();
  const input=$('#message-input');
  if(input.placeholder.startsWith('Message'))input.placeholder=limit<3?'Message…':`Message ${selected().name}…`;
  const names={sidebar:'chat list',chat:'chat',workspace:'workspace'};
  const ids={sidebar:'#chat-list-panel',chat:'#chat-panel',workspace:'#workspace-panel'};
  for(const pane of Object.keys(ids)){
    $(ids[pane]).hidden=!p[pane];
    const button=$(`[data-toggle-pane="${pane}"]`);
    button.setAttribute('aria-pressed',String(p[pane]));
    button.setAttribute('aria-expanded',String(p[pane]));
    const label=`${limit===1?'Show':p[pane]?'Hide':'Show'} ${names[pane]}`;
    button.setAttribute('aria-label',label);button.title=label;
  }
  const count=Object.values(p).filter(Boolean).length;
  $('.main-grid').dataset.visiblePanes=count;
  $('.main-grid').style.gridTemplateColumns=[p.sidebar?(count===1?'minmax(0,1fr)':'clamp(205px,18vw,250px)'):'0px',p.chat?'minmax(300px,1fr)':'0px',p.workspace?'minmax(350px,1.2fr)':'0px'].join(' ');
  resizeComposer();
}
function viewportChanged(){dispatchUI({type:'Viewport',limit:paneLimit()});renderPanes();}
window.addEventListener('resize',viewportChanged);
window.screen.orientation?.addEventListener('change',viewportChanged);
function syncMobileViewport(){
  const viewport=window.visualViewport;
  if(viewport && Math.abs(viewport.scale-1)<0.01)
    document.documentElement.style.setProperty('--mobile-viewport-height',`${viewport.height}px`);
}
window.visualViewport?.addEventListener('resize',syncMobileViewport);
function resizeComposer(){
  const input=$('#message-input');
  if(paneLimit()===3){input.style.height='';return;}
  if(!input.getClientRects().length)return;
  input.style.height='44px';
  input.style.height=Math.min(140,Math.max(44,input.scrollHeight))+'px';
}
$('#message-input').addEventListener('input',resizeComposer);
function setSearchOpen(open){
  $('#search-toggle').setAttribute('aria-expanded',String(open));
  $('#corpora-search').classList.toggle('search-open',open);
  if(open)$('#agent-search').focus();
  else{$('#agent-search').value='';dispatchUI({type:'Search',value:''});}
}
$('#search-toggle').addEventListener('click',()=>setSearchOpen($('#search-toggle').getAttribute('aria-expanded')!=='true'));
$('#agent-search').addEventListener('keydown',e=>{
  if(e.key==='Escape' && paneLimit()<3){e.preventDefault();setSearchOpen(false);$('#search-toggle').focus();}
});
function appMenu(){
  const identity=$('#corpora-identity')?.textContent || 'CORPORA';
  const row=(label,target,detail='')=>`<button class="app-menu-row" data-menu-target="${target}"><span>${label}</span><span>${esc(detail)}</span></button>`;
  modal(identity,`<nav aria-label="Corpora menu">${row('Workspace & settings','workspace-settings')}${row('Shared computer','resource-button',$('#resource-owner').textContent)}</nav>`,'MENU');
  $('#modal').classList.add('app-menu-sheet');
}


function leaveGroup(scope) {dispatchUI({type:'Scope',scope,draft:$('#message-input').value});}
function renderSidebar(){
  const {group,pinned,rows}=roster(state);
  const hasGroups=state.agents.some(a=>a.kind==='group'&&!a.archived);
  $('#agent-count').textContent=String(state.agents.filter(a=>a.kind!=='group'&&!a.retired&&!a.archived).length).padStart(2,'0');
  $$('[data-scope]').forEach(b=>{
    const active=b.dataset.scope===state.scope;
    b.classList.toggle('active',active);b.classList.toggle('group-open',active&&!!group);
    b.setAttribute('aria-pressed',String(active));
    b.disabled=b.dataset.scope==='groups'&&!hasGroups;
  });
  $('#agent-list').innerHTML=rows.map(a=>`<div class="agent-entry"><div class="agent-row ${a.id===state.selected?'active':''} ${pinned(a.id)?'main-sapi-row':''} ${a.kind==='group'?'group-row':''}" data-agent="${esc(a.id)}">${avatar(a,pinned(a.id)?'main-sapi-avatar':'',true)}<div class="agent-row-copy"><div class="agent-row-name"><button class="agent-name" data-agent="${esc(a.id)}" aria-label="Open ${esc(a.name)}${group&&pinned(a.id)?' · Lead':''}" ${a.id===state.selected?'aria-current="true"':''}>${esc(a.name)}</button>${a.kind==='group'?`<span class="group-labels compact" style="--label-count:1"><span class="group-chip" style="--group-color:${groupColor(a.color)}" title="${a.members.length} members" aria-label="${a.members.length} members"><span>${a.members.length}</span></span></span>`:groupLabels(a,true)+`<small>${esc(new Date(a.lastActivity).toLocaleTimeString([],{hour:'2-digit',minute:'2-digit',hour12:false}))}</small>`}</div><p>${group&&pinned(a.id)?'Lead · ':''}${esc(group?a.role:(a.preview||a.description||'Shared workspace'))}</p></div></div></div>`).join('');
  observeGroupLabels();
}

// Text is always literal; rich HTML must pass through the existing sanitizer explicitly.
function element(tag, className='', text, attributes={}) {
  const node=document.createElement(tag);node.className=className;
  if(Array.isArray(text))node.append(...text);
  else if(text!==undefined)node.textContent=text;
  for(const [key,value] of Object.entries(attributes)) {
    if(key.startsWith('on'))node.addEventListener(key.slice(2),value);
    else if(value!=null)node.setAttribute(key,String(value));
  }
  return node;
}

const actions = {'new-tab':openNewTab};

document.addEventListener('click',e=>{
  const b=e.target.closest('button,[data-agent]');if(!b)return;const d=b.dataset;

  if(d.menuTarget){
    closeModal();
    if(d.menuTarget==='workspace-settings')autonomyDialog();
    else document.getElementById(d.menuTarget)?.click();
    return;
  }
  if(d.togglePane){
    if(d.togglePane==='workspace'&&!state.activeTab){openNewTab();return;}
    showPane(d.togglePane,true);
    renderPanes();save();return;
  }
  if(d.action){actions[d.action]?.();return;}
  if(d.mention){openChat(d.mention);return;}
  if(d.agent){
    const group=state.agents.find(g=>g.id===state.groupView&&!g.archived);
    if(!b.matches('.agent-name')&&b.closest('#agent-list')&&group?.members.includes(d.agent)) {
      openChat(group.id);
      const input=$('#message-input');
      const previous=group.members.map(id=>'@'+agent(id).name+' ').find(prefix=>input.value.startsWith(prefix));
      input.value='@'+agent(d.agent).name+' '+(previous?input.value.slice(previous.length):input.value);
      saveDraft();input.focus();
    } else openChat(d.agent);
    return;
  }
  if(d.scope&&!b.disabled){leaveGroup(d.scope);return;}
  if(d.panel && !b.disabled){dispatchUI({type:'Navigate',panel:d.panel,...(d.panel==='work'?defaultWorkActivity():{})});return;}
  if(d.tab){browserAction('focus',{id:d.tab});return;}
  if(d.closeTab){browserAction('close',{id:d.closeTab});return;}


});

document.addEventListener('submit',e=>{if(e.target.id==='chat-form'){e.preventDefault();sendChat($('#message-input').value);}});

$('#close-modal').addEventListener('click',closeModal);
$('#modal').addEventListener('click',e=>{if(e.target===$('#modal')){const r=$('#modal').getBoundingClientRect();if(e.clientX<r.left||e.clientX>r.right||e.clientY<r.top||e.clientY>r.bottom)closeModal();}});

$('#add-agent').addEventListener('click',()=>addAgent());
$('#resource-button').addEventListener('click',()=>computerDialog());


$('#agent-search').addEventListener('input',e=>{dispatchUI({type:'Search',value:e.target.value});});

$('#message-input').addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.shiftKey&&!e.isComposing){e.preventDefault();sendChat(e.target.value);}});
$('.wordmark').addEventListener('click',e=>{e.preventDefault();dispatchUI({type:'Home'});showPane('chat');renderPanes();save();});

document.addEventListener('keydown',e=>{if(e.key==='/'&&!['INPUT','TEXTAREA','SELECT'].includes(document.activeElement.tagName)&&!$('#modal').open){e.preventDefault();showPane('sidebar');renderPanes();save();setSearchOpen(true);}});

// Stable mounts preserve focus, selection and native disclosure state on polling.
function mountHTML(host,html,key=html) {
  if(host.viewKey!==key){host.innerHTML=html;host.viewKey=key;}
}
