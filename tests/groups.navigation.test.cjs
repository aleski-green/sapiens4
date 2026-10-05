const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {JSDOM}=require('jsdom');
const {window}=new JSDOM(fs.readFileSync('web/shell/index.html','utf8'),{url:'http://localhost'});
const sapi=(id,name)=>({id,name,kind:'sapi',face:'^_^',role:'Test',color:'#48c99c',lastActivity:1});
const group={id:'g',name:'Researchers',kind:'group',lead:'a',members:['a','b'],stripes:['#48c99c'],face:'^_^',color:'#48c99c'};
const initial={agents:[sapi('chief','Chief'),sapi('a','Lead'),sapi('b','Member'),sapi('out','Outside'),group],mainSapiId:'chief',selected:'chief',scope:'all',panel:'chat',panes:{},drafts:{},workspaces:{}};
const ctx=vm.createContext({document:window.document,console,ResizeObserver:class{observe(){} disconnect(){}},setTimeout,clearTimeout,
 bootstrap:{creation_template:'create: sapi or group of sapis\nto work on: WORKFLOW'},makeInitialState:()=>initial,
 openNewTab:()=>{},setBrowserMenu:()=>{},renderTabs:()=>{},renderWorkspace:()=>{}});
vm.runInContext(fs.readFileSync('web/shell/app.js','utf8'),ctx);
vm.runInContext(fs.readFileSync('web/features/groups.js','utf8'),ctx);
vm.runInContext(`save=()=>{};closeModal=()=>{};render=()=>{renderSidebar();};`,ctx);
const bridge=fs.readFileSync('web/shell/bridge.js','utf8');
vm.runInContext(bridge.slice(bridge.indexOf('addAgent = function()'),bridge.indexOf('agentSettings = function()')),ctx);
const click=s=>{const e=window.document.querySelector(s);assert.ok(e,s);e.click();};
ctx.openChat('g');assert.equal(initial.scope,'groups');assert.equal(initial.groupView,'g');
assert.ok(window.document.querySelector('[data-scope=groups].group-open'));
assert.deepEqual([...window.document.querySelectorAll('.agent-row')].map(e=>e.dataset.agent),['a','b']);
assert.equal(window.document.querySelectorAll('.group-roster').length,0);
click('.agent-name[data-agent=b]');assert.equal(initial.selected,'g');assert.equal(initial.groupView,'g');
const draft=window.document.querySelector('#message-input');
assert.equal(draft.value,'@Member ');
assert.equal(window.document.querySelector('.agent-row-copy p').textContent,'Lead · Test');
draft.value='@Member Review this';
click('.agent-name[data-agent=a]');assert.equal(draft.value,'@Lead Review this');
click('.agent-name[data-agent=a]');assert.equal(draft.value,'@Lead Review this');
assert.equal(initial.drafts.g,'@Lead Review this');
assert.equal(window.document.querySelector('.group-chip').textContent,'R★');
click('[data-scope=groups]');assert.equal(initial.selected,'chief');assert.equal(initial.groupView,null);assert.equal(initial.scope,'groups');
assert.deepEqual([...window.document.querySelectorAll('.agent-row')].map(e=>e.dataset.agent),['g']);
assert.equal(window.document.querySelector('.group-row .group-chip').textContent,'2');
assert.equal(window.document.querySelector('.group-row small'),null);
assert.equal(window.document.querySelector('[data-action=archived-groups]'),null);
for(const scope of ['all','sapis']){ctx.openChat('g');click(`[data-scope=${scope}]`);assert.equal(initial.selected,'chief');assert.equal(initial.scope,scope);assert.equal(initial.groupView,null);}
ctx.openChat('b');click('.group-chip');assert.equal(initial.selected,'g');assert.equal(initial.groupView,'g');
click('#add-agent');const input=window.document.querySelector('#message-input');
assert.equal(initial.selected,'chief');assert.equal(initial.scope,'all');assert.equal(input.value,ctx.bootstrap.creation_template);
assert.equal(input.value.slice(input.selectionStart,input.selectionEnd),'WORKFLOW');
input.value='My unfinished request';ctx.openChat('g');click('#add-agent');assert.equal(input.value,'My unfinished request');
assert.equal(window.document.querySelector('#live-agent-form'),null);
group.archived=true;initial.scope='groups';ctx.renderSidebar();
assert.equal(initial.scope,'all');assert.equal(window.document.querySelector('[data-scope=groups]').disabled,true);
click('[data-scope=groups]');assert.equal(initial.scope,'all');
group.archived=false;ctx.renderSidebar();assert.equal(window.document.querySelector('[data-scope=groups]').disabled,false);
// Split tabs remain available for both Groups and Sapis.
ctx.taskPeriod='upcoming';ctx.renderNotes=host=>host.textContent='Memo';ctx.renderTasks=host=>host.textContent='Tasks';
ctx.live={turns:[]};ctx.renderAttachment=()=>{};
group.tasks=[];group.requests=[];group.messages=[];group.events=[];group.notes={revision:'missing'};
vm.runInContext(`renderConversation=()=>{const host=$('#conversation-body');if(!renderChatCollection(host)&&state.panel==='work'){if(selected().kind==='group')renderGroupWork(host,selected());else renderPersonalWork(host);}renderActivityNavigation();};`,ctx);
for(const id of ['g','b']) {
  ctx.openChat(id);ctx.renderActivityNavigation();click('[data-panel=work]');
  assert.equal(initial.panel,'work');assert.equal(window.document.querySelector('[data-activity-view=tasks]').getAttribute('aria-pressed'),'true');
  assert.equal(window.document.querySelectorAll('[data-panel]').length,3);
  click('[aria-label="Work menu"]');const menu=window.document.querySelector('#activity-work-menu');assert.equal(menu.hidden,false);
  ctx.renderActivityNavigation();assert.equal(window.document.querySelector('#activity-work-menu'),menu);assert.equal(menu.hidden,false);
  click('[aria-label="Automation menu"]');assert.equal(window.document.querySelector('#activity-automation-menu').hidden,false);
  click('[data-activity-view=workflows]');assert.match(window.document.querySelector('#conversation-body').textContent,/Workflows is not available/);
  assert.equal(window.document.querySelector('#activity-work-menu').hidden,true);
  click('[aria-label="Work menu"]');click('[data-activity-view=memo]');assert.equal(window.document.querySelector('[data-activity-view=memo]').getAttribute('aria-pressed'),'true');
  click('[data-panel=chat]');assert.equal(initial.panel,'chat');
  click('[aria-label="Chat menu"]');click('[data-activity-view=pins]');assert.match(window.document.querySelector('#conversation-body').textContent,/Pins are not available/);
  click('[aria-label="Chat menu"]');window.document.querySelector('[aria-label="Chat menu"]').dispatchEvent(new window.KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true}));
  assert.equal(window.document.activeElement.dataset.activityView,'pins');
  window.document.activeElement.dispatchEvent(new window.KeyboardEvent('keydown',{key:'Escape',bubbles:true}));assert.equal(window.document.querySelector('#activity-chat-menu').hidden,true);
  click('[aria-label="Chat menu"]');input.value='Keep this draft';click('[data-activity-feedback]');assert.equal(input.value,'Keep this draft\n\nFeedback: ');assert.equal(initial.drafts[id],input.value);
  click('[data-panel=work]');assert.equal(window.document.querySelector('[data-activity-view=tasks]').getAttribute('aria-pressed'),'true');
}
console.log('Groups: sidebar, drafts, persistent activity tabs, menus, keyboard controls and polling passed');
