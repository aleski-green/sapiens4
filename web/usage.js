const number = value => Number(value || 0).toLocaleString();
function usageSettings(info, section) {
  const s = info.execution;
  if (section === 'usage') return `<section class="usage-section" aria-label="Token consumption"><div class="list-heading"><h3>Token consumption</h3><button type="button" class="button" data-refresh-usage>Refresh</button></div>
    <div id="sapi-usage" aria-live="polite">Loading usage…</div></section>`;
  return `<section class="execution-settings form-stack"><h3>Budget & execution limits</h3>
      <p>Budget units = uncached input + output + 10% of cached input. This is a local allowance, not a price or your Codex subscription limit.</p>
      <label>Weekly budget units<input name="weekly_limit" type="number" min="1000" max="100000000" required value="${s.weekly_limit}"></label>
      <label>Allowance per model call<input name="call_allowance" type="number" min="1000" max="1000000" required value="${s.call_allowance}"></label>
      <label>Tool-step stop threshold<input name="max_tools" type="number" min="1" max="100" required value="${s.max_tools}"></label>
      <small>Current effective timeout: ${info.effective_timeout_seconds ?? s.timeout_seconds} seconds.</small>
      <label>Call timeout (seconds)<input name="timeout_seconds" type="number" min="15" max="600" required value="${s.timeout_seconds}"></label>
      <label>Tool result limit (tokens)<input name="output_tokens" type="number" min="200" max="8000" required value="${s.output_tokens}"></label>
      <small>Usage arrives at the end of a model call, so its allowance can be exceeded. Tool and time limits stop long runs; interrupted actions need review.</small>
    </section>`;
}
async function loadUsage(owner) {
  const host = $('#sapi-usage');
  if (!host) return;
  try {
    const report = await api(`/api/agents/${owner}/usage`);
    if (!host.isConnected || $('#live-settings-form')?.dataset.id !== owner) return;
    host.innerHTML = `<div class="usage-table-wrap"><table class="usage-table"><caption>Rolling usage, as of ${esc(new Date(report.as_of).toLocaleTimeString())}</caption><thead><tr><th>Period</th><th>Total</th><th>Uncached input</th><th>Cached input</th><th>Output</th></tr></thead><tbody>${Object.entries(report.windows).map(([key,row]) => `<tr><th>${{hour:'Last hour',day:'Last 24h',week:'Last 7d'}[key]}</th><td>${number(row.total)}</td><td>${number(row.uncached)}</td><td>${number(row.cached)}</td><td>${number(row.output)}</td></tr>`).join('')}</tbody></table></div>
      <p class="usage-budget">${number(report.budget.remaining)} / ${number(report.budget.limit)} budget units available · resets ${esc(new Date(report.budget.resets_at).toLocaleString())}</p>
      <small>Totals include cached input. Reasoning is part of output, not counted twice. Calls are counted when usage is reported.</small>
      ${report.windows.week.unknown ? `<p class="usage-warning">${report.windows.week.unknown} call(s) have unavailable usage, including active or interrupted calls. Totals are incomplete.</p>` : ''}
      ${report.windows.week.historical ? '<small>Earlier usage was recovered from saved runs; older retries may be missing and call times use run completion.</small>' : ''}
      <details><summary>Recent calls</summary><div class="usage-calls">${report.recent.slice(0,10).map(r => `<article><strong>${esc(r.flow)} · ${r.tokens ? number(r.tokens.total)+' tokens' : 'Usage unavailable'}</strong><small>${esc(new Date(r.time).toLocaleString())} · ${esc(r.status)}${r.tools == null ? '' : ` · ${r.tools} tool steps · ${number(r.output_chars)} tool-output characters`}${r.repeated_tools ? ` · ${r.repeated_tools} repeated commands` : ''}</small></article>`).join('') || '<p>No calls in the last seven days.</p>'}</div></details>`;
  } catch (error) {
    if (host.isConnected) host.textContent = error.message;
  }
}
document.addEventListener('click', e => {
  if (e.target.closest('[data-refresh-usage]')) loadUsage($('#live-settings-form')?.dataset.id);
});
