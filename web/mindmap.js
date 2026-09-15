// Memory data is fetched only for the selected Sapi; the sandbox hosts CORPORA's JSON tree.
let memoryViewerTemplate;
const memoryRequests = new Set();
const memoryCache = new Map();
const consolidationPending = new Set();
function sendMemory(frame) {
  const cached = memoryCache.get(frame.dataset.owner);
  if (cached) frame.contentWindow?.postMessage({type:'sapiens-memory',memx:cached.memx,
    dark:document.documentElement.dataset.theme === 'dark'}, '*');
}
window.addEventListener('message', e => {
  const frame = $('#memory-viewer');
  if (frame && e.source === frame.contentWindow && e.data?.type === 'sapiens-memory-ready') sendMemory(frame);
});
new MutationObserver(() => {const frame=$('#memory-viewer'); if (frame) sendMemory(frame);})
  .observe(document.documentElement, {attributes:true,attributeFilter:['data-theme']});
function renderMindMap(host) {
  const owner = state.selected, info = live.orchestration[owner], memory = info.memory;
  if (host.querySelector('#mindmap-panel')?.dataset.owner !== owner) {
    host.innerHTML = `<section id="mindmap-panel" data-owner="${esc(owner)}"><div class="list-heading"><h3>MindMap</h3><button type="button" class="button" id="consolidate-memory">Start consolidation</button></div><div id="memory-status" role="status"></div><p id="memory-empty" hidden>No consolidated memory yet.</p><div id="memory-loading" role="status">Loading memory…</div><iframe id="memory-viewer" data-owner="${esc(owner)}" title="Consolidated memory JSON" sandbox="allow-scripts" hidden></iframe></section>`;
  }
  const waiting = consolidationPending.has(owner) || ['waiting','queued','running'].includes(memory.status);
  const stopped = attention.has(memory.status);
  const button = $('#consolidate-memory');
  button.disabled = waiting || stopped || !online;
  button.textContent = waiting ? 'Waiting…' : memory.status === 'done' ? 'Done' : 'Start consolidation';
  button.setAttribute('aria-label', memory.status === 'done' ? 'Done. Start consolidation again' : button.textContent);
  const issue = memory.blocker || (stopped ? memory.run : null);
  $('#memory-status').innerHTML = issue ? `<p>${memory.blocker ? 'Waiting for this run to be resolved.' : esc(statusNames[memory.status])}</p>${issue.error ? `<p>${esc(issue.error)}</p>` : ''}${jobActions(issue)}` : memory.status === 'running' ? '<p>Consolidating memory…</p>' : waiting ? '<p>Waiting for the local runner…</p>' : '';
  $('#memory-empty').hidden = info.memory_entries > 0;
  loadMindMap(owner, memory.revision);
}
async function loadMindMap(owner, revision) {
  const frame = $('#memory-viewer');
  if (!frame || frame.dataset.owner !== owner) return;
  if (frame.dataset.revision === revision) {sendMemory(frame);return;}
  const key = `${owner}:${revision}`;
  if (memoryRequests.has(key)) return;
  memoryRequests.add(key);
  try {
    memoryViewerTemplate ||= fetch('/mindmap.html').then(r => {if (!r.ok) throw new Error('Could not load memory viewer'); return r.text();}).catch(error => {memoryViewerTemplate=null;throw error;});
    const [template, data] = await Promise.all([memoryViewerTemplate, api(`/api/agents/${owner}/memory`)]);
    if (!frame.isConnected || state.selected !== owner || live.orchestration[owner].memory.revision !== revision) return;
    memoryCache.set(owner, data);
    frame.dataset.revision = revision;
    frame.hidden = false;
    $('#memory-loading').hidden = true;
    if (!frame.srcdoc) frame.srcdoc = template;
    else sendMemory(frame);
  } catch (error) {
    if (frame.isConnected) $('#memory-loading').innerHTML = `<p>${esc(error.message)}</p><button type="button" class="button" data-memory-reload>Retry</button>`;
  } finally {
    memoryRequests.delete(key);
    const currentFrame = $('#memory-viewer');
    if (currentFrame && currentFrame !== frame && currentFrame.dataset.owner === owner)
      loadMindMap(owner, live.orchestration[owner].memory.revision);
  }
}
document.addEventListener('click', async e => {
  const button = e.target.closest('#consolidate-memory, [data-memory-reload]');
  if (!button) return;
  e.preventDefault();
  if (button.hasAttribute('data-memory-reload')) {renderConversation();return;}
  const owner = state.selected;
  if (button.disabled || consolidationPending.has(owner)) return;
  consolidationPending.add(owner); renderConversation();
  try {
    await api(`/api/agents/${owner}/control`, 'POST', {op:'consolidate'});
    await refresh();
  } catch (error) {toast(error.message);}
  finally {consolidationPending.delete(owner); if (state.selected === owner && state.panel === 'mindmap') renderConversation();}
}, true);
