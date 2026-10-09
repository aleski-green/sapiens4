const fs=require('node:fs'),vm=require('node:vm'),assert=require('node:assert/strict');
const {JSDOM}=require('jsdom');
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
vm.runInContext(fs.readFileSync('web/features/groups.js','utf8'),ctx);
const host=window.document.querySelector('#conversation-body');
const tick=()=>new Promise(resolve=>setImmediate(resolve));
(async()=>{
  host.innerHTML=ctx.groupLabels(members[0]);
  assert.equal(host.querySelector('script'),null);
  assert.equal(host.querySelector('button').textContent,'Research <script>★');
  assert.equal(host.querySelector('button').dataset.agent,'group_1');
  assert.match(ctx.groupAvatar(group),/#48c99c 0% 50%,#74b9ed 50% 100%/);
  for(let i=2;i<=11;i++)state.agents.push({...group,id:'group_'+i,name:'Other '+i});
  host.innerHTML=ctx.groupLabels(members[0]);
  assert.equal(host.querySelectorAll('.group-chip').length,11);
  host.innerHTML=ctx.groupLabels(members[0],true);
  assert.equal(host.querySelector('button').textContent,'R★');
  assert.equal(host.querySelector('i'),null);
  assert.equal(host.querySelector('button').getAttribute('aria-label'),'Research <script> · Lead');
  assert.equal(ctx.actions['create-group'],undefined);
  ctx.groupDialog(group);
  const form=window.document.querySelector('#group-form');
  form.elements.name.value='New Group';form.elements.description.value='Shared';
  form.querySelector('input[value="b"]').checked=true;
  form.dispatchEvent(new window.Event('submit',{bubbles:true,cancelable:true}));await tick();
  assert.equal(calls.at(-1).path,'/api/groups/group_1');assert.equal(calls.at(-1).method,'PUT');assert.deepEqual([...calls.at(-1).data.members],['a','b']);
  group.messages=[{id:'m1',author:'admin',text:'Hello <script>',created:'2026-10-05T00:00:00Z'},
    {id:'m2',author:'b',text:'Member answer',created:'2026-10-05T00:00:01Z',stale:true}];
  ctx.renderGroupPanel(host);
  assert.equal(host.querySelector('.group-roster'),null);assert.equal(host.querySelectorAll('.message').length,2);assert.equal(host.querySelector('script'),null);
  assert.match(host.textContent,/earlier task revision/);assert.match(host.textContent,/Member answer/);
  const task={id:'gtask_1',title:'Shared task',body:'Original',assignee:'b',state:'backlog',deleted:false,revision:7,history:[],results:[]};
  group.tasks=[task];ctx.taskDialog(group,task);
  const edit=window.document.querySelector('#group-task-form');edit.elements.title.value='Edited';
  edit.dispatchEvent(new window.Event('submit',{bubbles:true,cancelable:true}));await tick();
  assert.equal(calls.at(-1).method,'PUT');assert.equal(calls.at(-1).data.revision,7);assert.equal(calls.at(-1).data.title,'Edited');
  state.panel='work';ctx.renderGroupPanel(host);ctx.renderActivityNavigation();
  const nav=window.document.querySelector('.conversation-tabs');
  assert.deepEqual([...nav.querySelectorAll('[data-activity-panel=work]')].map(b=>b.textContent),['Memo','Tasks','Call','Backlog','Automated','Automation','Routines','Workflows','Composers']);
  assert.ok(nav.querySelector('[data-panel=work]'));
  assert.equal(host.querySelector('.personal-work-tabs'),null);
  assert.equal(host.querySelector('.task-row').open,false);
  host.querySelector('.task-row').open=true;await tick();ctx.renderGroupPanel(host);
  assert.equal(host.querySelector('.task-row').open,true);
  window.document.querySelector('[data-work-filter=done]').click();ctx.renderGroupPanel(host);
  assert.doesNotMatch(host.textContent,/Shared task/);
  window.document.querySelector('[data-work-filter=active]').click();
  nav.querySelector('[data-activity-view=memo]').click();ctx.renderGroupPanel(host);assert.equal(host.querySelector('#work-content').textContent,'Memo');
  nav.querySelector('[data-activity-view=automation]').click();ctx.renderGroupPanel(host);ctx.renderActivityNavigation();
  assert.match(host.textContent,/not available yet/);assert.equal(window.document.querySelector('[data-new-group-task]'),null);
  nav.querySelector('[data-activity-view=tasks]').click();ctx.renderGroupPanel(host);assert.match(host.textContent,/Shared task/);assert.match(host.textContent,/Researcher/);
  state.selected='b';ctx.renderWork(host);assert.doesNotMatch(host.textContent,/Shared task/);assert.match(host.textContent,/Personal tasks/);
  group.archived=true;state.selected=group.id;state.panel='chat';ctx.renderGroupPanel(host);
  assert.equal(window.document.querySelector('#composer-area').hidden,true);assert.match(host.textContent,/history is preserved/);
  assert.equal(refreshed,2);
  console.log('Groups DOM: initial labels, all 11 memberships, avatar order, settings, attribution, shared tasks, revision edits and archives passed');
})().catch(error=>{console.error(error);process.exitCode=1;});
