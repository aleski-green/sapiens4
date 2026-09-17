// Reconcile host-created tabs with browser edits without replacing unrelated tabs.
function mergeWorkspaces(base, local, remote) {
  const result = {};
  const same = (a,b) => JSON.stringify(a) === JSON.stringify(b);
  for (const owner of new Set([...Object.keys(base), ...Object.keys(local), ...Object.keys(remote)])) {
    const before = base[owner] || {tabs:[]};
    const ours = local[owner] || {tabs:[]};
    const theirs = remote[owner] || {tabs:[]};
    const bm = new Map(before.tabs.map(t=>[t.id,t]));
    const lm = new Map(ours.tabs.map(t=>[t.id,t]));
    const rm = new Map(theirs.tabs.map(t=>[t.id,t]));
    const tabs = [];
    for (const id of new Set([...ours.tabs.map(t=>t.id), ...theirs.tabs.map(t=>t.id)])) {
      // A remote edit wins a conflict on that tab; independent local edits survive.
      const tab = !same(bm.get(id),rm.get(id)) ? rm.get(id) : lm.get(id);
      if (tab) tabs.push(tab);
    }
    let activeTab = theirs.activeTab !== before.activeTab ? theirs.activeTab : ours.activeTab;
    if (!tabs.some(t=>t.id===activeTab)) activeTab = tabs[0]?.id || null;
    result[owner] = {tabs,activeTab};
  }
  return result;
}
let workspaceBase = structuredClone(bootstrap.preferences.workspaces || {});
let workspacePending = null;
let workspaceRevision = bootstrap.preferences.workspace_revision || 0;
function receiveWorkspaces(prefs, acknowledged) {
  const revision = prefs.workspace_revision || 0;
  if (revision <= workspaceRevision) return;
  storeWorkspace();
  // Polling may observe our PUT before its response arrives. Treat that echo as
  // an acknowledgement too, preserving edits made while the request was in flight.
  if (!acknowledged && workspacePending && JSON.stringify(prefs.workspaces) === JSON.stringify(workspacePending)) acknowledged = workspacePending;
  state.workspaces = mergeWorkspaces(acknowledged || workspaceBase, state.workspaces, prefs.workspaces || {});
  workspaceBase = structuredClone(prefs.workspaces || {});
  workspaceRevision = revision;
  const ws = state.workspaces[workspaceOwner];
  if (ws) {state.tabs=ws.tabs;state.activeTab=ws.activeTab;}
}
