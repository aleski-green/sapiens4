// Browser actions and observations; expectations are defined by RSpec.
const {observe,observeText,observeIdentity,attempt}=require('./observations.cjs');
const fs=require('node:fs'),vm=require('node:vm');
const {JSDOM}=require('../../libs4/node_modules/jsdom');
const {window}=new JSDOM('<body><nav class="conversation-tabs"></nav><div id="conversation-body"></div><div id="composer-area"></div><div id="dialog"></div></body>',{url:'http://localhost'});
const sapi=(id,name)=>({id,name,kind:'sapi',color:'#48c99c',face:'◠‿◠'});
const members=[sapi('a','Lead'),sapi('b','Researcher')];
const group={id:'group_1',name:'Research <script>',kind:'group',lead:'a',members:['a','b'],color:'#74b9ed',pattern:1,
  stripes:['#48c99c','#74b9ed'],face:'◠‿◠',revision:4,messages:[],requests:[],tasks:[],events:[]};
const state={selected:group.id,agents:[...members,group],mainSapiId:'a',panel:'chat'};
const calls=[];let refreshed=0;
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const ctx=vm.createContext({document:window.document,FormData:window.FormData,CSS:{escape:v=>v},ResizeObserver:class{observe(){} disconnect(){}},console,Date,Number,Set,Map,JSON,
  state,taskPeriod:'upcoming',save:()=>{},live:{turns:[]},esc,actions:{},agent:id=>state.agents.find(a=>a.id===id),selected:()=>state.agents.find(a=>a.id===state.selected),
  $:s=>window.document.querySelector(s),avatar:a=>`<span>${esc(a.name)}</span>`,mention:id=>esc(id),formatText:esc,
  displayTime:v=>v,statusNames:{},blocksChat:()=>false,renderAttachment:()=>{},attachmentLabel:a=>esc(a.name),
  modal:(title,content)=>{window.document.querySelector('#dialog').innerHTML=content;},closeModal:()=>{},toast:()=>{},openChat:()=>{},
  api:async(path,method,data)=>{calls.push({path,method,data});return group;},refresh:async()=>{refreshed++;},render:()=>{},renderConversation:()=>{},
  renderNotes:host=>host.textContent='Memo',renderTasks:host=>host.textContent='Personal tasks'});
require('./components.cjs').load(ctx,['activity','groups','work','mountActivity','mountWork','mountGroups']);
const host=window.document.querySelector('#conversation-body');
const tick=()=>new Promise(resolve=>setImmediate(resolve));
(async()=>{
  host.innerHTML=ctx.groupLabels(members[0]);
  observe("groups.dom.test.cjs:23:1", host.querySelector('script'));
  observe("groups.dom.test.cjs:24:2", host.querySelector('button').textContent);
  observe("groups.dom.test.cjs:25:3", host.querySelector('button').dataset.agent);
  observeText("groups.dom.test.cjs:26:4", ctx.groupAvatar(group));
  for(let i=2;i<=11;i++)state.agents.push({...group,id:'group_'+i,name:'Other '+i});
  host.innerHTML=ctx.groupLabels(members[0]);
  observe("groups.dom.test.cjs:29:5", host.querySelectorAll('.group-chip').length);
  host.innerHTML=ctx.groupLabels(members[0],true);
  observe("groups.dom.test.cjs:31:6", host.querySelector('button').textContent);
  observe("groups.dom.test.cjs:32:7", host.querySelector('i'));
  observe("groups.dom.test.cjs:33:8", host.querySelector('button').getAttribute('aria-label'));
  observe("groups.dom.test.cjs:34:9", ctx.actions['create-group']);
  ctx.groupDialog(group);
  const form=window.document.querySelector('#group-form');
  form.elements.name.value='New Group';form.elements.description.value='Shared';
  form.querySelector('input[value="b"]').checked=true;
  form.dispatchEvent(new window.Event('submit',{bubbles:true,cancelable:true}));await tick();
  observe("groups.dom.test.cjs:40:10", calls.at(-1).path);observe("groups.dom.test.cjs:40:11", calls.at(-1).method);observe("groups.dom.test.cjs:40:12", [...calls.at(-1).data.members]);
  group.messages=[{id:'m1',author:'admin',text:'Hello <script>',created:'2026-10-05T00:00:00Z'},
    {id:'m2',author:'b',text:'Member answer',created:'2026-10-05T00:00:01Z',stale:true}];
  ctx.renderGroupPanel(host);
  observe("groups.dom.test.cjs:44:13", host.querySelector('.group-roster'));observe("groups.dom.test.cjs:44:14", host.querySelectorAll('.message').length);observe("groups.dom.test.cjs:44:15", host.querySelector('script'));
  observeText("groups.dom.test.cjs:45:16", host.textContent);observeText("groups.dom.test.cjs:45:17", host.textContent);
  const task={id:'gtask_1',title:'Shared task',body:'Original',assignee:'b',state:'backlog',deleted:false,revision:7,history:[],results:[]};
  group.tasks=[task];ctx.taskDialog(group,task);
  const edit=window.document.querySelector('#group-task-form');edit.elements.title.value='Edited';
  edit.dispatchEvent(new window.Event('submit',{bubbles:true,cancelable:true}));await tick();
  observe("groups.dom.test.cjs:50:18", calls.at(-1).method);observe("groups.dom.test.cjs:50:19", calls.at(-1).data.revision);observe("groups.dom.test.cjs:50:20", calls.at(-1).data.title);
  state.panel='work';ctx.renderGroupPanel(host);ctx.renderActivityNavigation();
  const nav=window.document.querySelector('.conversation-tabs');
  observe("groups.dom.test.cjs:53:21", [...nav.querySelectorAll('[data-activity-panel=work]')].map(b=>b.textContent));
  observe("groups.dom.test.cjs:54:22", Boolean(nav.querySelector('[data-panel=work]')));
  observe("groups.dom.test.cjs:55:23", host.querySelector('.personal-work-tabs'));
  observe("groups.dom.test.cjs:56:24", host.querySelector('.task-row').open);
  host.querySelector('.task-row').open=true;await tick();ctx.renderGroupPanel(host);
  observe("groups.dom.test.cjs:58:25", host.querySelector('.task-row').open);
  window.document.querySelector('[data-work-filter=done]').click();ctx.renderGroupPanel(host);
  observeText("groups.dom.test.cjs:60:26", host.textContent);
  window.document.querySelector('[data-work-filter=active]').click();
  nav.querySelector('[data-activity-view=memo]').click();ctx.renderGroupPanel(host);observe("groups.dom.test.cjs:62:27", host.querySelector('#work-content').textContent);
  nav.querySelector('[data-activity-view=automation]').click();ctx.renderGroupPanel(host);ctx.renderActivityNavigation();
  observeText("groups.dom.test.cjs:64:28", host.textContent);observe("groups.dom.test.cjs:64:29", window.document.querySelector('[data-new-group-task]'));
  nav.querySelector('[data-activity-view=tasks]').click();ctx.renderGroupPanel(host);observeText("groups.dom.test.cjs:65:30", host.textContent);observeText("groups.dom.test.cjs:65:31", host.textContent);
  state.selected='b';ctx.renderWork(host);observeText("groups.dom.test.cjs:66:32", host.textContent);observeText("groups.dom.test.cjs:66:33", host.textContent);
  group.archived=true;state.selected=group.id;state.panel='chat';ctx.renderGroupPanel(host);
  observe("groups.dom.test.cjs:68:34", window.document.querySelector('#composer-area').hidden);observeText("groups.dom.test.cjs:68:35", host.textContent);
  observe("groups.dom.test.cjs:69:36", refreshed);

})().catch(error=>{console.error(error);process.exitCode=1;});
