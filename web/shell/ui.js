const activityLabels={conversation:'Conversation',pins:'Pins',threads:'Threads',comments:'Comments',events:'Events',records:'Records'};
// Stable view IDs distinguish Composer workflows from goal-specific composers.
const workNavigation=[
  {id:'memo',label:'Memo'},
  {id:'tasks',label:'Tasks',children:[
    {id:'tasks-call',label:'Call'},{id:'tasks-backlog',label:'Backlog'},{id:'tasks-automated',label:'Automated'}]},
  {id:'automation',label:'Automation',children:[
    {id:'routine',label:'Routines',children:[
      {id:'routine-scheduled',label:'Scheduled'},{id:'routine-callback',label:'Callbacks'},{id:'routine-job',label:'Jobs'}]},
    {id:'workflows',label:'Workflows',children:[
      {id:'workflow-agentic',label:'Agentic'},{id:'workflow-pipeline',label:'Pipelines'},{id:'workflow-composer',label:'Composers'}]},
    {id:'composer',label:'Composers',children:[
      {id:'composer-workflow',label:'Workflow'},{id:'composer-routine',label:'Routine'},{id:'composer-call',label:'Call'}]}
  ]}
];
const workPaths={};
function indexWorkNavigation(nodes,path=[]) {
  for(const node of nodes) {
    activityLabels[node.id]=node.label;
    workPaths[node.id]=[...path,node];
    if(node.children)indexWorkNavigation(node.children,workPaths[node.id]);
  }
}
indexWorkNavigation(workNavigation);

// A navigation value is a tagged state: each panel admits only its own views.
function activityState(panel='chat', view, period='upcoming', group=false) {
  if(panel==='notes'){panel='work';view='memo';}
  if(panel==='tasks'){panel='work';view='tasks';}
  const views={chat:['conversation','pins','threads','comments'],work:Object.keys(workPaths),updates:['events']};
  if(!Object.hasOwn(views,panel))panel='chat';
  if(!views[panel].includes(view))view=views[panel][0];
  const node=workPaths[view]?.at(-1);
  if(panel==='work'&&workPaths[view].length===2&&node.children)view=node.children[0].id;
  const periods=view==='routine-scheduled'?['upcoming','paused']:
    ['tasks','tasks-automated'].includes(view)?['upcoming','past',...(group?['deleted']:[])]:['upcoming'];
  return {panel,view,period:periods.includes(period)?period:'upcoming'};
}
// Pure transitions return the next model and explicit commands for the shell.
function updateNavigation(model, action) {
  const group=model.agents.find(a=>a.id===model.selected)?.kind==='group';
  switch(action.type) {
    case 'Navigate': return [{...model,...activityState(action.panel,action.view,action.period,group)},[{type:'Activity'}]];
    case 'Filter': return [{...model,...activityState(model.panel,model.view,action.period,group)},[{type:'Activity'}]];
    case 'Select': {
      const target=model.agents.find(a=>a.id===action.id);
      if(!target)return [model,[]];
      const group=target.kind==='group';
      return [{...model,...activityState(),selected:target.id,search:'',
        drafts:{...model.drafts,[model.selected]:action.draft},groupView:group?target.id:null,
        scope:group?'groups':model.groupView||model.scope==='groups'?'all':model.scope},[{type:'Selection'}]];
    }
    case 'Scope': {
      if(!['all','sapis','groups'].includes(action.scope))return [model,[]];
      const [next]=updateNavigation(model,{type:'Select',id:model.mainSapiId,draft:action.draft});
      return [{...next,scope:action.scope,groupView:null},[{type:'Selection'},{type:'Roster'}]];
    }
    case 'Search': return [{...model,search:action.value},[renderCommand('sidebar')]];
    default: throw new Error('Unknown UI action: '+action.type);
  }
}
function paneState(panes, order, limit, workspace, action={}) {
  let next=action.pane?paneState(panes,order,limit,workspace).panes:
    {...panes,workspace:!!panes.workspace&&(limit===3||workspace)};
  if(action.pane) {
    const count=Object.values(next).filter(Boolean).length;
    const hide=action.toggle&&next[action.pane]&&(limit===3||limit===2&&count>1);
    next[action.pane]=!hide;
    if(!hide)order=[action.pane,...order.filter(p=>p!==action.pane)];
  }
  if(limit<3) {
    const visible=order.filter(p=>next[p]).slice(0,limit);
    if(!visible.length)visible.push('chat');
    next=Object.fromEntries(order.map(p=>[p,visible.includes(p)]));
  }
  return {panes:next,paneOrder:order};
}
