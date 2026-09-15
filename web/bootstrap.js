// Executed in the same closure as the pinned CORPORA app. No demo state is loaded.
async function api(path, method = 'GET', data) {
  const response = await fetch(path, {
    method,
    headers: {'Content-Type': 'application/json', 'X-Sapiens-Local': '1'},
    ...(data === undefined ? {} : {body: JSON.stringify(data)}),
    signal: AbortSignal.timeout(15000)
  });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || `Request failed (${response.status})`);
  return result;
}
const bootstrap = await api('/api/state');
function makeInitialState(data) {
  const prefs = data.preferences;
  const agents = data.agents.map(a => ({...a, kind:'sapi', scope:'personal', status:'online',
    autonomy:'assist', preview:'Ready for your message.', lastActivity:Date.parse(a.created), unread:false}));
  const selected = agents.some(a => a.id === prefs.selected) ? prefs.selected : agents[0].id;
  const workspaces = prefs.workspaces || {};
  const ws = workspaces[selected] || {tabs:[{id:`blank-${selected}`,type:'blank',title:'New tab'}]};
  return {agents, mainSapiId:agents[0].id, selected, scope:prefs.scope || 'all',
    panel:prefs.panel || 'chat', mode:'assist', panes:{sidebar:true,chat:true,workspace:true,...prefs.panes},
    tabs:ws.tabs, activeTab:ws.activeTab || ws.tabs[0]?.id || null, workspaces,
    drafts:prefs.drafts || {}, messages:{}, tasks:[], logs:[], schedules:[],
    computer:{owner:null,lastUsed:null,paused:false,queue:[],completed:0},
    document:{}, connections:{}, posts:[], attachment:false};
}
