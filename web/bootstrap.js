// Executed in the same closure as the pinned CORPORA app. No demo state is loaded.
// Set tab branding before loading state, including when the backend is unavailable.
document.title = 'Sapi4: Corpora';
const favicon = document.createElement('link');
favicon.rel = 'icon';
favicon.type = 'image/svg+xml';
favicon.href = 'data:image/svg+xml,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><defs><linearGradient id="brand" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#ed3995"/><stop offset=".35" stop-color="#df2eea"/><stop offset=".65" stop-color="#783cf0"/><stop offset="1" stop-color="#35c5e8"/></linearGradient></defs><rect width="32" height="32" rx="7" fill="#fff"/><path transform="translate(4 4)" fill="none" stroke="url(#brand)" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" d="M18 8a3 3 0 1 0-3-3v14a3 3 0 1 0 3-3H5a3 3 0 1 0 3 3V5a3 3 0 1 0-3 3Z"/></svg>');
document.head.append(favicon);

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
