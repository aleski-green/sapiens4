// Pure workspace model. No DOM, clocks, storage, network or native handles.
const pastTaskStates = new Set(['Completed', 'Unresolved', 'Failed', 'Interrupted', 'Cancelled']);
const attention = new Set(['failed','interrupted','conflict']);
const blocksChat = turn => ['queued','running','output_pending'].includes(turn.status);
const statusNames = {output_pending:'Awaiting output pulse',queued:'Queued',running:'Running',done:'Completed',warning:'Warning',failed:'Failed',
  interrupted:'Interrupted',conflict:'Needs review',cancelled:'Dismissed'};
const findAgent = (model,id=model.selected) => model.agents.find(a=>a.id===id) || model.agents[0];
const ownerPath = (model,id=model.selected) => `/api/${findAgent(model,id).kind==='group'?'groups':'agents'}/${encodeURIComponent(id)}`;
const renderCommand = (...regions) => ({type:'Render',regions});
const draftState = (model,id,value) => ({...model,drafts:{...model.drafts,[id]:value}});

function makeInitialState(snapshot, epoch=0) {
  const p=snapshot.preferences,selected=snapshot.groups?.find(g=>g.id===p.selected);
  return projectSnapshot({snapshot,epoch,sequence:0,online:false,now:0,agents:[],selected:p.selected,mainSapiId:snapshot.main_agent_id,
    scope:selected?'groups':p.scope||'all',groupView:p.groupView||(selected?selected.id:null),search:'',...activityState(p.panel,p.view,p.period,true),
    drafts:p.drafts||{},panes:{sidebar:true,chat:true,workspace:true,...p.panes},paneOrder:['chat','sidebar','workspace'],limit:3,
    workspaces:p.workspaces||{},workspaceRevision:p.workspace_revision||0,documents:{},expanded:{},
    composer:{sending:{},attachments:snapshot.attachment_drafts||{},uploading:0,clarification:null}},snapshot);
}
function workspaceState(model, prefs={}) {
  if((prefs.workspace_revision||0)>model.workspaceRevision)
    model={...model,workspaces:prefs.workspaces||{},workspaceRevision:prefs.workspace_revision};
  const ws=model.workspaces[model.selected]||{tabs:[]};
  const tabs=ws.tabs.filter(t=>t.url!=='about:blank'||t.path||!/^(blank-|id-)/.test(t.id));
  return {...model,tabs,activeTab:tabs.some(t=>t.id===ws.activeTab)?ws.activeTab:tabs[0]?.id||null};
}
function chatResult(turn) {
  const text=turn.output||'';
  if(turn.status!=='warning')return {text};
  const notice=/^Warning — partial result\.\n\n(Saved: [\s\S]+?)\n\n(The (?:tool|time) limit was reached after [\s\S]+)$/.exec(text);
  return {text:notice?notice[1]:text,warning:notice?notice[2]:turn.error||'Partial result; review before relying on it.'};
}
function projectSnapshot(model, snapshot) {
  const agents=snapshot.agents.map(a=>({...a,kind:'sapi',scope:'personal',autonomy:'assist',status:'online',
    lastActivity:Date.parse(a.created),preview:'Ready for your message.'}));
  const messages={};
  for(const turn of snapshot.turns) {
    if(turn.group)continue;
    const rows=messages[turn.agent]||=[],timestamp=Date.parse(turn.created);
    const chat=['chat','computer'].includes(turn.flow),done=['done','warning'].includes(turn.status)&&turn.output!==null;
    if(chat)rows.push({role:'user',author:turn.origin?.caller,text:turn.input,created:turn.created,timestamp,attachments:turn.attachments,requestTurn:turn});
    if(chat&&done)rows.push({role:'assistant',...chatResult(turn),created:turn.output_at||turn.created,
      timestamp:Date.parse(turn.output_at||turn.created),outputOrder:turn.output_order,turnId:turn.id});
    const a=agents.find(a=>a.id===turn.agent);
    if(a&&chat){a.lastActivity=timestamp;a.preview=(done?chatResult(turn).text:turn.input).replace(/\s+/g,' ').slice(0,150);}
    if(a&&turn.status==='running')a.status='busy';
  }
  for(const group of snapshot.groups||[]) {
    agents.push({...group,status:group.requests.some(r=>r.status==='running')?'busy':'online',
      lastActivity:Date.parse(group.updated),preview:group.messages.at(-1)?.text||group.description||'Shared workspace'});
    messages[group.id]=group.messages.map(m=>({role:m.author==='admin'?'user':'assistant',author:m.author==='admin'?null:m.author,
      text:m.text,created:m.created,timestamp:Date.parse(m.created),chatKey:m.id,attachments:m.attachments,stale:m.stale}));
  }
  for(const work of snapshot.workloads||[]) {
    if(work.callId===work.origin.call)continue;
    const call=snapshot.turns.find(t=>t.id===work.callId);
    (messages[work.origin.agent]||=[]).push({role:'assistant',author:work.owner,
      text:work.output||work.error||`Delegated to ${agents.find(a=>a.id===work.owner)?.name||work.owner} · ${work.state}`,
      created:call?.created,timestamp:call?Date.parse(call.created):0,delegation:work,requestTurn:call&&!['done','warning'].includes(call.status)?call:null});
  }
  for(const rows of Object.values(messages))rows.sort((a,b)=>a.timestamp-b.timestamp||(a.outputOrder||0)-(b.outputOrder||0));
  const selected=agents.find(a=>a.id===model.selected);
  const id=!selected||(selected.retired&&!model.agents.find(a=>a.id===selected.id)?.retired)?snapshot.main_agent_id:model.selected;
  const groupView=agents.some(a=>a.id===model.groupView&&!a.archived)?model.groupView:null;
  const scope=model.scope==='groups'&&!agents.some(a=>a.kind==='group'&&!a.archived)?'all':model.scope;
  return workspaceState({...model,snapshot,agents,messages,selected:id,groupView,scope,
    ...activityState(model.panel,model.view,model.period,agents.find(a=>a.id===id)?.kind==='group')},snapshot.preferences);
}
function roster(model) {
  const group=model.agents.find(a=>a.id===model.groupView),pinned=id=>id===(group?group.lead:model.mainSapiId);
  const rows=model.agents.filter(a=>!a.retired&&!a.archived&&(group?group.members.includes(a.id):
    model.scope==='all'||(model.scope==='groups')===(a.kind==='group'))&&`${a.name} ${a.role}`.toLowerCase().includes(model.search.toLowerCase()))
    .sort((a,b)=>Number(pinned(b.id))-Number(pinned(a.id))||(b.lastActivity||0)-(a.lastActivity||0));
  return {group,pinned,rows};
}

// RemoteData a = Loading request (Maybe a) | Ready request a | Failed request error.
// Request identity is data; the model never holds an element or a Promise.
function currentDocument(model) {
  if(model.panel!=='work')return null;
  const a=findAgent(model),kind=model.view==='memo'?'memo':['tasks','tasks-automated'].includes(model.view)&&a.kind!=='group'?'tasks':null;
  if(!kind)return null;
  const info=a.kind==='group'?a.notes:model.snapshot.orchestration[a.id]?.notes;
  if(kind==='memo'&&info?.revision==='missing')return null;
  const revision=kind==='tasks'?JSON.stringify((model.snapshot.workloads||[]).filter(w=>w.participants.includes(a.id))):info?.revision;
  return {kind,id:a.id,key:kind+':'+a.id,revision,path:ownerPath(model)+(kind==='memo'?'/notes':'/tasks?format=json')};
}
function loadDocument([model,commands]) {
  const wanted=currentDocument(model),cached=wanted&&model.documents[wanted.key];
  if(!wanted||(cached&&cached.request.revision===wanted.revision))return [model,commands];
  const request={...wanted,epoch:model.epoch,sequence:model.sequence+1};
  return [{...model,sequence:request.sequence,documents:{...model.documents,[request.key]:{type:'Loading',request,value:cached?.value}}},
    [...commands,{type:'LoadDocument',request}]];
}
function decodeDocument(kind, data) {
  if(kind==='tasks') {
    if(!Array.isArray(data.tasks)||data.tasks.some(t=>!t||!['id','title','body','state','owner','sender'].every(k=>typeof t[k]==='string')))
      throw new Error('Invalid tasks response');
    return data.tasks;
  }
  if(typeof data.content!=='string'||typeof data.path!=='string')throw new Error('Invalid Memo response');
  return data;
}
function updateWorkspace(model, action) {
  const a=findAgent(model);
  switch(action.type) {
    case 'Connection': return [{...model,online:action.online},[]];
    case 'Clock': return [{...model,now:action.now},[]];
    case 'Snapshot': return [projectSnapshot(model,action.snapshot),[]];
    case 'Reset': return [{...makeInitialState(action.snapshot,model.epoch+1),now:model.now},[]];
    case 'Workspaces': return [workspaceState(model,action.preferences),[]];
    case 'Draft': return [draftState(model,action.id||model.selected,action.value),[{type:'Persist'}]];
    case 'Expand': return [{...model,expanded:{...model.expanded,[action.key]:action.open}},[]];
    case 'Pane': case 'Viewport': {
      const limit=action.limit||model.limit;
      return [{...model,limit,...paneState(model.panes,model.paneOrder,limit,!!model.activeTab,action)},[]];
    }
    case 'Home': return [{...model,panes:{sidebar:true,chat:true,workspace:true},paneOrder:['chat','sidebar','workspace']},[]];
    case 'RetryDocument': {
      const documents={...model.documents};delete documents[action.key];
      return [{...model,documents},[renderCommand('conversation')]];
    }
    case 'DocumentReceived': {
      const {request,result}=action,current=model.documents[request.key];
      if(request.epoch!==model.epoch||current?.request.sequence!==request.sequence)return [model,[]];
      return [{...model,documents:{...model.documents,[request.key]:{...result,request}}},
        currentDocument(model)?.key===request.key?[renderCommand('conversation')]:[]];
    }
    case 'Send': {
      const text=action.value.trim(),c=model.composer,id=model.selected,attachments=c.attachments[id]||[];
      if((!text&&!attachments.length)||c.sending[id]||c.uploading||!model.online||a.retired||a.archived||['paused','archived'].includes(model.snapshot.corpora?.status))return [model,[]];
      const request={epoch:model.epoch,id,text,attachments,workload:c.clarification?.owner===id?c.clarification.id:undefined};
      return [{...model,composer:{...c,sending:{...c.sending,[id]:true}}},[renderCommand('header'),{type:'SendMessage',request,path:ownerPath(model)+'/messages'}]];
    }
    case 'MessageSent': case 'MessageFailed': {
      const {request}=action;if(request.epoch!==model.epoch)return [model,[]];
      const c=model.composer,sent=action.type==='MessageSent';
      const next={...model,composer:{...c,sending:{...c.sending,[request.id]:false},
        clarification:sent&&c.clarification?.id===request.workload?null:c.clarification,attachments:sent?{...c.attachments,[request.id]:(c.attachments[request.id]||[]).filter(a=>!request.attachments.some(s=>s.id===a.id))}:c.attachments}};
      return [sent&&model.drafts[request.id]?.trim()===request.text?draftState(next,request.id,''):next,
        [renderCommand('composer','header','attachments'),sent?{type:'Sent'}:{type:'Notify',message:action.error}]];
    }
    case 'Clarify': return [{...model,composer:{...model.composer,clarification:action.work}},[]];
    case 'Uploading': return [{...model,composer:{...model.composer,uploading:model.composer.uploading+action.delta}},[renderCommand('header')]];
    case 'Attachment': {
      if(action.epoch!==undefined&&action.epoch!==model.epoch)return [model,[]];
      const c=model.composer,items=c.attachments[action.id]||[];
      return [{...model,composer:{...c,attachments:{...c.attachments,[action.id]:action.item?[...items,action.item]:items.filter(a=>a.id!==action.remove)}}},
        [renderCommand('attachments'),{type:'Persist'}]];
    }
    default: return updateNavigation(model,action);
  }
}
function updateUI(model, action) {
  const [next,commands]=updateWorkspace(model,action);
  return loadDocument([workspaceState(next),commands]);
}
