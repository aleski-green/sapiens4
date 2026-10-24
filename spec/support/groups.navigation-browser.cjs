// Browser actions and observations; expectations are defined by RSpec.
const {observe,observeText,observeIdentity,attempt}=require('./observations.cjs');
const fs=require('node:fs'),vm=require('node:vm');
const {JSDOM}=require('../../libs4/node_modules/jsdom');
const {window}=new JSDOM(fs.readFileSync('web/shell/index.html','utf8'),{url:'http://localhost'});
const sapi=(id,name)=>({id,name,kind:'sapi',face:'^_^',role:'Test',color:'#48c99c',lastActivity:1});
const group={id:'g',name:'Researchers',kind:'group',lead:'a',members:['a','b'],stripes:['#48c99c'],face:'^_^',color:'#48c99c'};
const initial={agents:[sapi('chief','Chief'),sapi('a','Lead'),sapi('b','Member'),sapi('out','Outside'),group],mainSapiId:'chief',selected:'chief',scope:'all',panel:'chat',panes:{},drafts:{},workspaces:{}};
const ctx=vm.createContext({window,document:window.document,console,ResizeObserver:class{observe(){} disconnect(){}},setTimeout,clearTimeout,
 bootstrap:{creation_template:'create: sapi or group of sapis\nto work on: WORKFLOW'},makeInitialState:()=>initial,
 openNewTab:()=>{},setBrowserMenu:()=>{},renderTabs:()=>{},renderWorkspace:()=>{}});
require('./components.cjs').load(ctx,['panes','shell','activity','groups','work','composer']);
ctx.makeInitialState=()=>initial;ctx.SapiensComponents.mountShell();
ctx.SapiensComponents.tasks();ctx.SapiensComponents.mountActivity();ctx.SapiensComponents.mountWork();ctx.SapiensComponents.mountGroups();
Object.assign(ctx,{$:s=>window.document.querySelector(s),save:()=>{},closeModal:()=>{},formatText:v=>String(v),render:()=>ctx.renderSidebar(),renderConversation:()=>{},resizeComposer:()=>{}});
const click=s=>{const e=window.document.querySelector(s);observe("groups.navigation.test.cjs:16:1", Boolean(e));e.click();};
ctx.openChat('g');observe("groups.navigation.test.cjs:17:2", initial.scope);observe("groups.navigation.test.cjs:17:3", initial.groupView);
observe("groups.navigation.test.cjs:18:4", Boolean(window.document.querySelector('[data-scope=groups].group-open')));
observe("groups.navigation.test.cjs:19:5", [...window.document.querySelectorAll('.agent-row')].map(e=>e.dataset.agent));
observe("groups.navigation.test.cjs:20:6", window.document.querySelectorAll('.group-roster').length);
click('.agent-row[data-agent=b]');observe("groups.navigation.test.cjs:21:7", initial.selected);observe("groups.navigation.test.cjs:21:8", initial.groupView);
const draft=window.document.querySelector('#message-input');
observe("groups.navigation.test.cjs:23:9", draft.value);
observe("groups.navigation.test.cjs:24:10", window.document.querySelector('.agent-row-copy p').textContent);
draft.value='@Member Review this';
click('.agent-row[data-agent=a]');observe("groups.navigation.test.cjs:26:11", draft.value);
click('.agent-row[data-agent=a]');observe("groups.navigation.test.cjs:27:12", draft.value);
observe("groups.navigation.test.cjs:28:13", initial.drafts.g);
// Names and mentions leave Group context; each conversation retains its draft.
click('.agent-name[data-agent=b]');
observe("groups.navigation.test.cjs:31:14", initial.selected);observe("groups.navigation.test.cjs:31:15", initial.groupView);observe("groups.navigation.test.cjs:31:16", initial.scope);observe("groups.navigation.test.cjs:31:17", initial.panel);
observe("groups.navigation.test.cjs:32:18", initial.drafts.g);observe("groups.navigation.test.cjs:32:19", draft.value);
ctx.openChat('g');window.document.querySelector('#conversation-body').innerHTML=ctx.mention('a');
click('[data-mention=a]');observe("groups.navigation.test.cjs:34:20", initial.selected);observe("groups.navigation.test.cjs:34:21", initial.groupView);observe("groups.navigation.test.cjs:34:22", initial.scope);
ctx.openChat('g');

observe("groups.navigation.test.cjs:37:23", window.document.querySelector('.group-chip').textContent);
click('[data-scope=groups]');observe("groups.navigation.test.cjs:38:24", initial.selected);observe("groups.navigation.test.cjs:38:25", initial.groupView);observe("groups.navigation.test.cjs:38:26", initial.scope);
observe("groups.navigation.test.cjs:39:27", [...window.document.querySelectorAll('.agent-row')].map(e=>e.dataset.agent));
observe("groups.navigation.test.cjs:40:28", window.document.querySelector('.group-row .group-chip').textContent);
observe("groups.navigation.test.cjs:41:29", window.document.querySelector('.group-row small'));
observe("groups.navigation.test.cjs:42:30", window.document.querySelector('[data-action=archived-groups]'));
for(const scope of ['all','sapis']){ctx.openChat('g');click(`[data-scope=${scope}]`);observe("groups.navigation.test.cjs:43:31", initial.selected);observe("groups.navigation.test.cjs:43:32", initial.scope);observe("groups.navigation.test.cjs:43:33", initial.groupView);}
ctx.openChat('b');click('.group-chip');observe("groups.navigation.test.cjs:44:34", initial.selected);observe("groups.navigation.test.cjs:44:35", initial.groupView);
click('#add-agent');const input=window.document.querySelector('#message-input');
observe("groups.navigation.test.cjs:46:36", initial.selected);observe("groups.navigation.test.cjs:46:37", initial.scope);observe("groups.navigation.test.cjs:46:38", input.value);
observe("groups.navigation.test.cjs:47:39", input.value.slice(input.selectionStart,input.selectionEnd));
input.value='My unfinished request';ctx.openChat('g');click('#add-agent');observe("groups.navigation.test.cjs:48:40", input.value);
observe("groups.navigation.test.cjs:49:41", window.document.querySelector('#live-agent-form'));
group.archived=true;initial.scope='groups';ctx.renderSidebar();
observe("groups.navigation.test.cjs:51:42", initial.scope);observe("groups.navigation.test.cjs:51:43", window.document.querySelector('[data-scope=groups]').disabled);
click('[data-scope=groups]');observe("groups.navigation.test.cjs:52:44", initial.scope);
group.archived=false;ctx.renderSidebar();observe("groups.navigation.test.cjs:53:45", window.document.querySelector('[data-scope=groups]').disabled);
// Split tabs remain available for both Groups and Sapis.
ctx.taskPeriod='upcoming';ctx.renderNotes=host=>host.textContent='Memo';ctx.renderTasks=host=>host.textContent='Tasks';
ctx.live={turns:[],workloads:[{participants:['b'],state:'Running'}]};ctx.renderAttachment=()=>{};
group.tasks=[{id:'shared',title:'Shared work',state:'in_progress',assignee:'b',results:[],history:[]}];group.requests=[];group.messages=[];group.events=[];group.notes={revision:'missing'};
vm.runInContext(`renderConversation=()=>{const host=$('#conversation-body');if(!renderChatCollection(host)&&state.panel==='work'){renderWork(host);}renderActivityNavigation();};`,ctx);
for(const id of ['g','b']) {
  ctx.openChat(id);ctx.renderActivityNavigation();click('[data-panel=work]');
  observe("groups.navigation.test.cjs:61:46", initial.panel);observe("groups.navigation.test.cjs:61:47", window.document.querySelector('[data-activity-view=tasks]').getAttribute('aria-pressed'));
  input.value='';click('[data-new-task]');observe("groups.navigation.test.cjs:62:48", initial.panel);observe("groups.navigation.test.cjs:62:49", input.value);observe("groups.navigation.test.cjs:62:50", input.value.slice(input.selectionStart,input.selectionEnd));observe("groups.navigation.test.cjs:62:51", initial.drafts[id]);
  click('[data-panel=work]');input.value='Keep this';click('[data-new-task]');observe("groups.navigation.test.cjs:63:52", input.value);click('[data-panel=work]');
  observe("groups.navigation.test.cjs:64:53", window.document.querySelector('select[data-work-filter]'));

  observe("groups.navigation.test.cjs:66:54", window.document.querySelectorAll('[data-panel]').length);
  click('[aria-label="Work menu"]');const menu=window.document.querySelector('#activity-work-menu');observe("groups.navigation.test.cjs:67:55", menu.hidden);
  ctx.renderActivityNavigation();observeIdentity("groups.navigation.test.cjs:68:56", window.document.querySelector('#activity-work-menu'), menu);observe("groups.navigation.test.cjs:68:57", menu.hidden);
  click('[aria-label="Automation menu"]');observe("groups.navigation.test.cjs:69:58", window.document.querySelector('#activity-automation-menu').hidden);
  observe("groups.navigation.test.cjs:70:59", menu.querySelector('.activity-submenu .activity-submenu'));
  click('[data-activity-view=workflows]');observeText("groups.navigation.test.cjs:71:60", window.document.querySelector('#conversation-body').textContent);
  observe("groups.navigation.test.cjs:72:61", window.document.querySelector('#activity-work-menu').hidden);
  for(const [category,views] of [['routine',['routine-scheduled','routine-callback','routine-job']],['workflows',['workflow-agentic','workflow-pipeline','workflow-composer']],['composer',['composer-workflow','composer-routine','composer-call']]]) {
    click(`[data-activity-view="${category}"]`);
    for(const view of views) {
      click('[data-activity-menu="activity-category-menu"]');
      const dropdown=window.document.querySelector('#activity-category-menu');observe("groups.navigation.test.cjs:77:62", dropdown.hidden);
      ctx.renderActivityNavigation();observeIdentity("groups.navigation.test.cjs:78:63", window.document.querySelector('#activity-category-menu'), dropdown);observe("groups.navigation.test.cjs:78:64", dropdown.hidden);
      click(`#activity-category-menu [data-activity-view="${view}"]`);
      observeText("groups.navigation.test.cjs:80:65", window.document.querySelector('#conversation-body').textContent);
      observe("groups.navigation.test.cjs:81:66", window.document.querySelector('#activity-category-menu').hidden);
      observe("groups.navigation.test.cjs:82:67", [...window.document.querySelectorAll('[id]')].map(node=>node.id));
    }
  }
  click('[data-activity-view=routine]');
  observeText("groups.navigation.test.cjs:86:68", window.document.querySelector('#activity-viewbar').textContent);
  observe("groups.navigation.test.cjs:87:69", window.document.querySelector('#activity-viewbar').querySelectorAll('button[data-activity-menu]').length);
  click('[data-activity-menu=activity-task-filter]');click('[data-work-filter=upcoming]');
  observeText("groups.navigation.test.cjs:89:70", window.document.querySelector('#conversation-body').textContent);
  click('[data-activity-menu=activity-task-filter]');click('[data-work-filter=paused]');
  observeText("groups.navigation.test.cjs:91:71", window.document.querySelector('#conversation-body').textContent);
  input.value='';click('[data-new-task]');observe("groups.navigation.test.cjs:92:72", initial.panel);observe("groups.navigation.test.cjs:92:73", input.value);observe("groups.navigation.test.cjs:92:74", input.value.slice(input.selectionStart,input.selectionEnd));
  click('[data-panel=work]');observe("groups.navigation.test.cjs:93:75", window.document.querySelector('[data-activity-menu=activity-task-filter]').textContent.trim());

  for(const view of ['tasks-call','tasks-backlog']) {
    click(`[data-activity-view="${view}"]`);observeText("groups.navigation.test.cjs:96:76", window.document.querySelector('#conversation-body').textContent);
  }
  click('[aria-label="Work menu"]');click('[data-activity-view=memo]');observe("groups.navigation.test.cjs:98:77", window.document.querySelector('[data-activity-view=memo]').getAttribute('aria-pressed'));
  click('[data-panel=chat]');observe("groups.navigation.test.cjs:99:78", initial.panel);
  click('[aria-label="Chat menu"]');click('[data-activity-view=pins]');observeText("groups.navigation.test.cjs:100:79", window.document.querySelector('#conversation-body').textContent);
  click('[aria-label="Chat menu"]');window.document.querySelector('[aria-label="Chat menu"]').dispatchEvent(new window.KeyboardEvent('keydown',{key:'ArrowDown',bubbles:true}));
  observe("groups.navigation.test.cjs:102:80", window.document.activeElement.dataset.activityView);
  window.document.activeElement.dispatchEvent(new window.KeyboardEvent('keydown',{key:'Escape',bubbles:true}));observe("groups.navigation.test.cjs:103:81", window.document.querySelector('#activity-chat-menu').hidden);
  click('[aria-label="Chat menu"]');input.value='Keep this draft';click('[data-activity-feedback]');observe("groups.navigation.test.cjs:104:82", input.value);observe("groups.navigation.test.cjs:104:83", initial.drafts[id]);
  click('[data-panel=work]');observe("groups.navigation.test.cjs:105:84", window.document.querySelector('[data-activity-view=tasks]').getAttribute('aria-pressed'));
}

// Scheduled rows reuse Tasks, preserve expansion on polling, and edit through chat.
ctx.live.routines=[{id:'routine_sch_00013',owner:'b',title:'Compare <products>',minutes:2,prompt:'Compare A and B.\nKeep details.',nextDue:'2026-10-09T10:00:00Z'}];
ctx.openChat('b');click('[data-panel=work]');click('[data-activity-view=routine]');
click('[data-work-filter=upcoming]');
let row=window.document.querySelector('.task-row');observe("groups.navigation.test.cjs:112:85", Boolean(row));
observe("groups.navigation.test.cjs:113:86", row.querySelector('.task-title').textContent);
observe("groups.navigation.test.cjs:114:87", row.querySelector('code').textContent);
row.open=true;ctx.renderWork(window.document.querySelector('#conversation-body'));
observeIdentity("groups.navigation.test.cjs:116:88", window.document.querySelector('.task-row'), row);observe("groups.navigation.test.cjs:116:89", row.open);
input.value='Existing draft';click('[data-run-routine]');
observe("groups.navigation.test.cjs:118:90", initial.panel);
observe("groups.navigation.test.cjs:119:91", initial.selected);
observe("groups.navigation.test.cjs:120:92", input.value);
observe("groups.navigation.test.cjs:121:93", initial.drafts.b);
observe("groups.navigation.test.cjs:122:94", ctx.live.routines[0].runCount);
click('[data-panel=work]');click('[data-activity-view=routine]');
input.value='';click('[data-edit-routine]');
observe("groups.navigation.test.cjs:125:95", initial.panel);
observe("groups.navigation.test.cjs:126:96", input.value);
observe("groups.navigation.test.cjs:127:97", input.value.slice(input.selectionStart,input.selectionEnd));
observe("groups.navigation.test.cjs:128:98", row.querySelector('.task-reference').textContent);
click('[data-panel=work]');click('[data-activity-view=routine]');
input.value='';click('[data-pause-routine]');
observe("groups.navigation.test.cjs:131:99", initial.panel);
observe("groups.navigation.test.cjs:132:100", input.value);
observe("groups.navigation.test.cjs:133:101", ctx.live.routines[0].paused); // A draft does not mutate the routine.
ctx.live.routines[0].paused=true;ctx.live.routines[0].runCount=1000;
click('[data-panel=work]');click('[data-activity-view=routine]');
observe("groups.navigation.test.cjs:136:102", window.document.querySelector('.task-row'));
click('[data-work-filter=paused]');
row=window.document.querySelector('.task-row');
observe("groups.navigation.test.cjs:139:103", row.querySelector('.task-state').textContent);
observe("groups.navigation.test.cjs:140:104", row.querySelector('.task-reference').textContent);
observe("groups.navigation.test.cjs:141:105", row.querySelector('[data-pause-routine]'));
observe("groups.navigation.test.cjs:142:106", Boolean(row.querySelector('[data-edit-routine]')));
input.value='';click('[data-resume-routine]');
observe("groups.navigation.test.cjs:144:107", input.value);


// Work chooses the first non-empty view for the selected Sapi or Group.
const sharedTask=(state,assignee='b',deleted=false)=>({id:'shared',title:'Shared work',state,assignee,deleted,results:[],history:[]});
const workDefault=(view,filter)=>{
  click('[data-panel=work]');
  observe("groups.navigation.test.cjs:151:108", vm.runInContext('workView',ctx));
  if(filter)observe("groups.navigation.test.cjs:152:109", window.document.querySelector('[data-activity-menu=activity-task-filter]').textContent.trim());
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
  observe("groups.navigation.test.cjs:175:110", vm.runInContext('workView',ctx)); // Polling preserves manual navigation.
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
observe("groups.navigation.test.cjs:186:111", window.document.querySelector('.task-title').textContent);
observe("groups.navigation.test.cjs:187:112", window.document.querySelector('.task-state').textContent);
observe("groups.navigation.test.cjs:188:113", window.document.querySelector('choices'));
row=window.document.querySelector('.task-row');row.open=true;row.dispatchEvent(new window.Event('toggle'));
ctx.renderWork(window.document.querySelector('#conversation-body'));observe("groups.navigation.test.cjs:190:114", window.document.querySelector('.task-row').open);
group.requests[0].status='done';workDefault('tasks','Executed');
observeText("groups.navigation.test.cjs:192:115", window.document.querySelector('.task-result').textContent);
group.requests[0].status='failed';group.requests[0].error='Provider failed';workDefault('tasks','Executed');
observeText("groups.navigation.test.cjs:194:116", window.document.querySelector('.task-error').textContent);
group.requests.push({id:'linked',message:'request',target:'b',status:'done',task:'shared'});
observe("groups.navigation.test.cjs:196:117", ctx.groupCallTasks(group).length); // A persisted task already owns its execution.
ctx.openChat('b');workDefault('memo');
observeText("groups.navigation.test.cjs:198:118", window.document.querySelector('#conversation-body').textContent);


ctx.renderActivityNavigation();click('[aria-label="Updates menu"]');
const updatesMenu=window.document.querySelector('#activity-updates-menu');
observeText("groups.navigation.test.cjs:203:119", updatesMenu.textContent);observeText("groups.navigation.test.cjs:203:120", updatesMenu.textContent);
observe("groups.navigation.test.cjs:204:121", updatesMenu.querySelector('button[disabled]').textContent);
observe("groups.navigation.test.cjs:205:122", updatesMenu.querySelector('[data-activity-view=pulses]'));

click('[data-panel=updates]');
observe("groups.navigation.test.cjs:208:123", window.document.querySelector('#activity-viewbar').hidden);
observeText("groups.navigation.test.cjs:209:124", window.document.querySelector('#activity-viewbar').textContent);
