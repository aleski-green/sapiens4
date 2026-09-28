const notesCache = new Map();
function renderNotes(host) {
  const id = state.selected, info = live.orchestration[id].notes;
  const cached = notesCache.get(id);
  host.innerHTML = `<div class="list-heading"><h3>Notes</h3></div><p class="notes-help">Managed by ${esc(agent(id).name)}. Ask in chat to add or change a note.</p><small class="notes-path">${esc(info.path)}</small><pre class="notes-content">${esc(cached?.content ?? 'Loading…')}</pre><p class="notes-notice"></p>`;
  const show = row => {
    if (state.selected !== id || state.panel !== 'notes' || live.orchestration[id].notes.revision !== info.revision) return;
    host.querySelector('.notes-content').textContent = row.error ? '' : row.content || 'No notes yet.';
    host.querySelector('.notes-notice').textContent = row.error || (row.truncated ? 'Showing the first 64,000 characters. The complete notes are in the local file.' : '');
  };
  if (cached?.revision === info.revision) {show(cached); return;}
  api(`/api/agents/${id}/notes`).then(row => {
    if (live.orchestration[id].notes.revision === info.revision) notesCache.set(id, {...row, revision:info.revision});
    show(row);
  }).catch(error => show({error:error.message}));
}
function activityLog(turns) {
  const body = turns.slice().reverse().map(turn => `<article class="live-turn"><span class="tag">${esc(statusNames[turn.status] || turn.status)}</span><h3>${esc(turn.input)}</h3><small>${esc(new Date(turn.created).toLocaleString())}</small>${turn.error ? `<p>${esc(turn.error)}</p>` : ''}${turn.output ? `<details><summary>Reply</summary><p>${esc(turn.output)}</p></details>` : ''}${turnActions(turn)}</article>`).join('');
  return '<div class="list-heading"><h3>Activity log</h3></div>' + (body || '<div class="empty">No activity yet.</div>') + `<details class="event-history"><summary>Activity events</summary>${eventRows.filter(e=>e.agent===state.selected).slice(-100).reverse().map(e=>`<div class="log-row"><time>${esc(displayTime(e.time))}</time><strong>${esc(e.kind)}</strong><p>${esc(e.detail)}</p></div>`).join('')}</details>`;
}
