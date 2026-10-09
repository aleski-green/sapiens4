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
vm.runInContext(fs.readFileSync('web/features/tasks.js','utf8'),ctx);
vm.runInContext(fs.readFileSync('web/features/groups.js','utf8'),ctx);
vm.runInContext(`save=()=>{};closeModal=()=>{};formatText=esc;render=()=>{renderSidebar();};`,ctx);
const bridge=fs.readFileSync('web/shell/bridge.js','utf8');
vm.runInContext(bridge.slice(bridge.indexOf('addAgent = function()'),bridge.indexOf('agentSettings = function()')),ctx);
const click=s=>{const e=window.document.querySelector(s);assert.ok(e,s);e.click();};
ctx.openChat('g');assert.equal(initial.scope,'groups');assert.equal(initial.groupView,'g');
assert.ok(window.document.querySelector('[data-scope=groups].group-open'));
assert.deepEqual([...window.document.querySelectorAll('.agent-row')].map(e=>e.dataset.agent),['a','b']);
assert.equal(window.document.querySelectorAll('.group-roster').length,0);
click('.agent-row[data-agent=b]');assert.equal(initial.selected,'g');assert.equal(initial.groupView,'g');
const draft=window.document.querySelector('#message-input');
assert.equal(draft.value,'@Member ');
assert.equal(window.document.querySelector('.agent-row-copy p').textContent,'Lead · Test');
draft.value='@Member Review this';
click('.agent-row[data-agent=a]');assert.equal(draft.value,'@Lead Review this');
click('.agent-row[data-agent=a]');assert.equal(draft.value,'@Lead Review this');
assert.equal(initial.drafts.g,'@Lead Review this');
// Names and mentions leave Group context; each conversation retains its draft.
click('.agent-name[data-agent=b]');
assert.equal(initial.selected,'b');assert.equal(initial.groupView,null);assert.equal(initial.scope,'all');assert.equal(initial.panel,'chat');
assert.equal(initial.drafts.g,'@Lead Review this');assert.equal(draft.value,'');
ctx.openChat('g');window.document.querySelector('#conversation-body').innerHTML=ctx.mention('a');
click('[data-mention=a]');assert.equal(initial.selected,'a');assert.equal(initial.groupView,null);assert.equal(initial.scope,'all');
ctx.openChat('g');

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
ctx.live={turns:[],workloads:[{participants:['b'],state:'Running'}]};ctx.renderAttachment=()=>{};
group.tasks=[{id:'shared',title:'Shared work',state:'in_progress',assignee:'b',results:[],history:[]}];group.requests=[];group.messages=[];group.events=[];group.notes={revision:'missing'};
vm.runInContext(`renderConversation=()=>{const host=$('#conversation-body');if(!renderChatCollection(host)&&state.panel==='work'){renderWork(host);}renderActivityNavigation();};`,ctx);
for(const id of ['g','b']) {
  ctx.openChat(id);ctx.renderActivityNavigation();click('[data-panel=work]');
  assert.equal(initial.panel,'work');assert.equal(window.document.querySelector('[data-activity-view=tasks]').getAttribute('aria-pressed'),'true');
  input.value='';click('[data-new-task]');assert.equal(initial.panel,'chat');assert.equal(input.value,'Add New Task: TODO');assert.equal(input.value.slice(input.selectionStart,input.selectionEnd),'TODO');assert.equal(initial.drafts[id],input.value);
  click('[data-panel=work]');input.value='Keep this';click('[data-new-task]');assert.equal(input.value,'Keep this\n\nAdd New Task: TODO');click('[data-panel=work]');
  assert.equal(window.document.querySelector('select[data-work-filter]'),null);

  assert.equal(window.document.querySelectorAll('[data-panel]').length,3);
  click('[aria-label="Work menu"]');const menu=window.document.querySelector('#activity-work-menu');assert.equal(menu.hidden,false);
  ctx.renderActivityNavigation();assert.equal(window.document.querySelector('#activity-work-menu'),menu);assert.equal(menu.hidden,false);
  click('[aria-label="Automation menu"]');assert.equal(window.document.querySelector('#activity-automation-menu').hidden,false);
  assert.equal(menu.querySelector('.activity-submenu .activity-submenu'),null);
  click('[data-activity-view=workflows]');assert.match(window.document.querySelector('#conversation-body').textContent,/Agentic is not available/);
  assert.equal(window.document.querySelector('#activity-work-menu').hidden,true);
  for(const [category,views] of [['routine',['routine-scheduled','routine-callback','routine-job']],['workflows',['workflow-agentic','workflow-pipeline','workflow-composer']],['composer',['composer-workflow','composer-routine','composer-call']]]) {
    click(`[data-activity-view="${category}"]`);
    for(const view of views) {
      click('[data-activity-menu="activity-category-menu"]');
      const dropdown=window.document.querySelector('#activity-category-menu');assert.equal(dropdown.hidden,false);
      ctx.renderActivityNavigation();assert.equal(window.document.querySelector('#activity-category-menu'),dropdown);assert.equal(dropdown.hidden,false);
      click(`#activity-category-menu [data-activity-view="${view}"]`);
      assert.match(window.document.querySelector('#conversation-body').textContent,view==='routine-scheduled'?/No (planned|paused) routines/:/not available yet/);
      assert.equal(window.document.querySelector('#activity-category-menu').hidden,true);
      assert.equal(window.document.querySelectorAll('[id]').length,new Set([...window.document.querySelectorAll('[id]')].map(e=>e.id)).size);
    }
  }
  click('[data-activity-view=routine]');
  assert.match(window.document.querySelector('#activity-viewbar').textContent,/Automation \/ Routines \/Scheduled/);
  assert.equal(window.document.querySelector('#activity-viewbar').querySelectorAll('button[data-activity-menu]').length,2);
  click('[data-activity-menu=activity-task-filter]');click('[data-work-filter=upcoming]');
  assert.match(window.document.querySelector('#conversation-body').textContent,/No planned routines/);
  click('[data-activity-menu=activity-task-filter]');click('[data-work-filter=paused]');
  assert.match(window.document.querySelector('#conversation-body').textContent,/No paused routines/);
  input.value='';click('[data-new-task]');assert.equal(initial.panel,'chat');assert.equal(input.value,'Add New Scheduled Routine:\nFrequency: every XXX minutes\nExecute: PROMPT');assert.equal(input.value.slice(input.selectionStart,input.selectionEnd),'XXX');
  click('[data-panel=work]');assert.equal(window.document.querySelector('[data-activity-menu=activity-task-filter]').textContent.trim(),'Planned');

  for(const view of ['tasks-call','tasks-backlog']) {
    click(`[data-activity-view="${view}"]`);assert.match(window.document.querySelector('#conversation-body').textContent,/not available yet/);
  }
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
// Scheduled rows reuse Tasks, preserve expansion on polling, and edit through chat.
ctx.live.routines=[{id:'routine_sch_00013',owner:'b',title:'Compare <products>',minutes:2,prompt:'Compare A and B.\nKeep details.',nextDue:'2026-10-09T10:00:00Z'}];
ctx.openChat('b');click('[data-panel=work]');click('[data-activity-view=routine]');
click('[data-work-filter=upcoming]');
let row=window.document.querySelector('.task-row');assert.ok(row);
assert.equal(row.querySelector('.task-title').textContent,'Compare <products>');
assert.equal(row.querySelector('code').textContent,'@routine_sch_00013');
row.open=true;ctx.renderWork(window.document.querySelector('#conversation-body'));
assert.equal(window.document.querySelector('.task-row'),row);assert.equal(row.open,true);
input.value='';click('[data-edit-routine]');
assert.equal(initial.panel,'chat');
assert.equal(input.value,'Edit @routine_sch_00013 ( Compare <products> )\nEdit Frequency (prev every 2 minutes): new every XXX minutes\nEdit Execution Prompt as: Compare A and B.\nKeep details.');
assert.equal(input.value.slice(input.selectionStart,input.selectionEnd),'XXX');
assert.equal(row.querySelector('.task-reference').textContent,'@routine_sch_000130/1000');
click('[data-panel=work]');click('[data-activity-view=routine]');
input.value='';click('[data-pause-routine]');
assert.equal(initial.panel,'chat');
assert.equal(input.value,'Pause Schedule Riutine\n@routine_sch_00013');
assert.equal(ctx.live.routines[0].paused,undefined); // A draft does not mutate the routine.
ctx.live.routines[0].paused=true;ctx.live.routines[0].runCount=1000;
click('[data-panel=work]');click('[data-activity-view=routine]');
assert.equal(window.document.querySelector('.task-row'),null);
click('[data-work-filter=paused]');
row=window.document.querySelector('.task-row');
assert.equal(row.querySelector('.task-state').textContent,'Paused');
assert.equal(row.querySelector('.task-reference').textContent,'@routine_sch_000131000/1000');
assert.equal(row.querySelector('[data-pause-routine]'),null);
assert.ok(row.querySelector('[data-edit-routine]'));
input.value='';click('[data-resume-routine]');
assert.equal(input.value,'Resume Scheduled Routine\n@routine_sch_00013');
console.log('Scheduled routines: Planned/Paused, count, Edit, Pause and Resume drafts passed');

// Work chooses the first non-empty view for the selected Sapi or Group.
const sharedTask=(state,assignee='b',deleted=false)=>({id:'shared',title:'Shared work',state,assignee,deleted,results:[],history:[]});
const workDefault=(view,filter)=>{
  click('[data-panel=work]');
  assert.equal(vm.runInContext('workView',ctx),view);
  if(filter)assert.equal(window.document.querySelector('[data-activity-menu=activity-task-filter]').textContent.trim(),filter);
};
for(const id of ['b','g']) {
  ctx.openChat(id);group.tasks=[];
  ctx.live.workloads=[];
  ctx.live.routines=[{id:'routine_sch_00013',owner:id,title:'Recurring work',minutes:2,prompt:'Compare.',nextDue:'2026-10-09T10:00:00Z',paused:false}];
  for(const status of ['Queued','Running','WaitingForAdmin','WaitingForDependency']) {
    if(id==='g')group.tasks=[sharedTask('in_progress')];
    else ctx.live.workloads=[{participants:['b'],state:status}];
    workDefault('tasks','Planned');
  }
  if(id==='g')group.tasks=[sharedTask('done')];
  else ctx.live.workloads=[{participants:['b'],state:'Completed'}];
  workDefault('routine-scheduled','Planned'); // Routines outrank executed tasks.
  ctx.live.routines[0].paused=true;
  workDefault('tasks','Executed');
  ctx.live.workloads=[{participants:['out'],state:'Running'}];
  group.tasks=[sharedTask('done','b',true)];
  workDefault('memo'); // Paused routines, deleted tasks, and other Sapis do not qualify.
  ctx.live.routines[0].paused=false;
  workDefault('routine-scheduled','Planned'); // Reevaluate on every Work click.
  click('[data-activity-view=memo]');
  ctx.renderConversation();
  assert.equal(vm.runInContext('workView',ctx),'memo'); // Polling preserves manual navigation.
}
ctx.openChat('b');ctx.live.routines=[];ctx.live.workloads=[];
group.tasks=[sharedTask('backlog')];workDefault('memo');
group.tasks=[sharedTask('done')];workDefault('memo');
group.tasks=[sharedTask('in_progress','out')];workDefault('memo');
// Existing Group calls are visible without creating or replaying tasks.
group.tasks=[];
group.messages=[{id:'request',author:'admin',text:'Compare <choices>'},{id:'reply',author:'b',text:'Member result',turn:'call'}];
group.requests=[{id:'call',message:'request',target:'b',status:'running'}];
ctx.openChat('g');workDefault('tasks','Planned');
assert.equal(window.document.querySelector('.task-title').textContent,'Compare <choices>');
assert.equal(window.document.querySelector('.task-state').textContent,'Running');
assert.equal(window.document.querySelector('choices'),null);
row=window.document.querySelector('.task-row');row.open=true;row.dispatchEvent(new window.Event('toggle'));
ctx.renderWork(window.document.querySelector('#conversation-body'));assert.equal(window.document.querySelector('.task-row').open,true);
group.requests[0].status='done';workDefault('tasks','Executed');
assert.match(window.document.querySelector('.task-result').textContent,/Member result/);
group.requests[0].status='failed';group.requests[0].error='Provider failed';workDefault('tasks','Executed');
assert.match(window.document.querySelector('.task-error').textContent,/Provider failed/);
group.requests.push({id:'linked',message:'request',target:'b',status:'done',task:'shared'});
assert.equal(ctx.groupCallTasks(group).length,1); // A persisted task already owns its execution.
ctx.openChat('b');workDefault('memo');
assert.doesNotMatch(window.document.querySelector('#conversation-body').textContent,/Compare <choices>|Member result/);
console.log('Work defaults: active tasks, planned routines, executed tasks, Memo; Sapi/Group scope and manual navigation passed');

ctx.renderActivityNavigation();click('[aria-label="Updates menu"]');
const updatesMenu=window.document.querySelector('#activity-updates-menu');
assert.match(updatesMenu.textContent,/Events/);assert.match(updatesMenu.textContent,/Records/);
assert.equal(updatesMenu.querySelector('button[disabled]').textContent,'Records');
assert.equal(updatesMenu.querySelector('[data-activity-view=pulses]'),null);

click('[data-panel=updates]');
assert.equal(window.document.querySelector('#activity-viewbar').hidden,true);
assert.doesNotMatch(window.document.querySelector('#activity-viewbar').textContent,/Latest 100/);
