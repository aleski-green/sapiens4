document.title = 'Sapi4: Corpora';
const favicon = document.createElement('link');
favicon.rel = 'icon';
favicon.type = 'image/svg+xml';
favicon.href = 'data:image/svg+xml,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 32 32"><defs><linearGradient id="brand" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#ed3995"/><stop offset=".35" stop-color="#df2eea"/><stop offset=".65" stop-color="#783cf0"/><stop offset="1" stop-color="#35c5e8"/></linearGradient></defs><rect width="32" height="32" rx="7" fill="#fff"/><path transform="translate(4 4)" fill="none" stroke="url(#brand)" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" d="M18 8a3 3 0 1 0-3-3v14a3 3 0 1 0 3-3H5a3 3 0 1 0 3 3V5a3 3 0 1 0-3 3Z"/></svg>');
document.head.append(favicon);
const lightBrandIcon = favicon.href;
function syncBrandIcon() {
  const dark = document.documentElement.dataset.theme === 'dark';
  favicon.href = dark ? lightBrandIcon.replace(encodeURIComponent('fill="#fff"'), encodeURIComponent('fill="#171717"')) : lightBrandIcon;
}
syncBrandIcon();
new MutationObserver(syncBrandIcon).observe(document.documentElement, {attributes:true, attributeFilter:['data-theme']});

function apiFetch(path, options) {
  return window.SapiensConnections ? window.SapiensConnections.fetch(path, options) : fetch(path, options);
}
async function api(path, method = 'GET', data) {
  const generation=window.SapiensConnections?.generation;
  const response = await apiFetch(path, {
    method,
    headers: {'Content-Type': 'application/json', 'X-Sapiens-Local': '1'},
    ...(data === undefined ? {} : {body: JSON.stringify(data)}),
    signal: AbortSignal.timeout(15000)
  });
  if(generation!==window.SapiensConnections?.generation)throw new Error('Workspace changed');
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || `Request failed (${response.status})`);
  return result;
}
const bootstrap = window.SapiensConnections ? await SapiensConnections.initial : await api('/api/state');
