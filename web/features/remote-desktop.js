/* Local-only pairing controls; never embed credentials in URLs or persistent browser storage. */
'use strict';
(() => {
  const $ = id => document.getElementById(id);
  let pending = null, renderedInvitation = null;
  let configuredRelay;
  const status = text => { $('status').textContent = text; };
  async function api(path = '', body) {
    const response = await fetch('/api/remote' + path, {method: body ? 'POST' : 'GET',
      headers: {'Content-Type':'application/json','X-Sapiens-Local':'1'},
      body: body ? JSON.stringify(body) : undefined, cache:'no-store'});
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || 'Local request failed');
    return result;
  }
  async function refresh() {
    try {
      const data = await api();
      $('corpora-identity').textContent = data.corpora?.name || '';
      $('corpora-identity').title = data.corpora?.id || '';
      $('public-address').textContent=data.public_id || '';
      if(data.invitation) await showInvitation(data.invitation);
      $('setup').hidden = data.enabled;
      $('local-setup').hidden = !data.local_relay;
      $('saved-setup').hidden = !data.configured_relay;
      if(configuredRelay !== data.configured_relay) {
        $('relay-settings').open = !data.configured_relay;
        configuredRelay = data.configured_relay;
      }
      $('active').hidden = !data.enabled;
      $('approval').hidden = !data.pending;
      pending = data.pending;
      $('confirmation-code').textContent = pending?.confirmation_code || '';
      $('approve').disabled = !pending?.confirmation_code;
      if (pending) $('qr-panel').hidden = true;
      $('device').textContent = data.paired ? 'Device connected' : 'Waiting for device.';
      if (data.paired || !data.enabled || data.expires < Date.now()/1000) {
        $('qr-panel').hidden = true; renderedInvitation=null;
      }
      status(!data.available ? 'Install the optional remote Python dependencies, then restart Sapiens4.' :
        data.error || (data.paired ? '' : data.enabled ?
          (data.expires < Date.now()/1000 ? 'QR expired. Revoke this invitation and show a new QR.' : '') : ''));
    } catch (error) { status(error.message); }
  }
  async function createPairing(body, button) {
    button.disabled = true;
    $('setup-feedback').textContent = 'Creating pairing invitation…';
    try {
      const data = await api('/pair', body);
      $('token').value = '';
      $('connection-file').value = '';
      $('create-pair').disabled = true;
      await showInvitation(data.qr);
      $('setup-feedback').textContent = '';
      await refresh();
    } catch (error) { $('setup-feedback').textContent = error.message; }
    finally { button.disabled = button.id === 'create-pair' && !$('token').value; }
  }
  async function showInvitation(invitation) {
    const link=RemoteCode.link(invitation);
    if(renderedInvitation!==link) {
      await RemoteVendor.QRCode.toCanvas($('qr'),link,{width:480,margin:3,errorCorrectionLevel:'M'});
      $('download').href=$('qr').toDataURL('image/png');
      $('remote-link').href=invitation.relay+'/ios';
      $('qr-expiry').textContent='Expires '+new Date(invitation.expires*1000).toLocaleString();
      renderedInvitation=link;
    }
    $('qr-panel').hidden=false;
  }
  $('copy-address').addEventListener('click',async()=>{
    try {await navigator.clipboard.writeText($('public-address').textContent);$('address-feedback').textContent='ID copied';}
    catch {$('address-feedback').textContent='Select the ID above to copy it.';}
  });
  $('local-pair').addEventListener('click', () => createPairing({local:true}, $('local-pair')));
  $('saved-pair').addEventListener('click', () => createPairing({saved:true}, $('saved-pair')));
  $('pair-form').addEventListener('submit', event => {
    event.preventDefault();
    createPairing({relay:$('relay').value.trim(), token:$('token').value}, $('create-pair'));
  });
  for (const id of ['relay', 'token']) $(id).addEventListener('input', () => {
    $('create-pair').disabled = !($('relay').value.trim() && $('token').value.length >= 32);
  });
  $('connection-file').addEventListener('change', async () => {
    const file = $('connection-file').files[0];
    if (!file) return;
    $('relay').value = ''; $('token').value = ''; $('create-pair').disabled = true;
    try {
      if (file.size > 4096) throw new Error('Connection file is too large.');
      const data = JSON.parse(await file.text());
      const url = new URL(data.relay);
      if (data.format !== 'sapiens-relay-connection-v1' ||
          typeof data.token !== 'string' || !/^[\x21-\x7e]{32,256}$/.test(data.token) ||
          url.username || url.password || url.search || url.hash || url.pathname !== '/' ||
          !(url.protocol === 'https:' || (url.protocol === 'http:' && ['localhost','127.0.0.1','[::1]'].includes(url.hostname)))) {
        throw new Error('Choose a valid Sapiens relay connection file.');
      }
      $('relay').value = url.origin; $('token').value = data.token;
      $('create-pair').disabled = false;
      $('setup-feedback').textContent = 'Ready to connect to ' + url.origin + '. Select Show QR.';
    } catch (error) {
      $('setup-feedback').textContent = 'Could not import connection file. ' + error.message;
    } finally { $('connection-file').value = ''; }
  });
  $('approve').addEventListener('click', async () => {
    if (!pending?.confirmation_code) return;
    $('approve').disabled = true;
    try { await api('/approve', {peer:pending.peer}); await refresh(); }
    catch (error) { status(error.message); }
    finally { $('approve').disabled = !pending?.confirmation_code; }
  });
  $('revoke').addEventListener('click', async () => {
    try {
      const result = await api('/revoke', {}); await refresh();
      $('qr').getContext('2d').clearRect(0,0,$('qr').width,$('qr').height);
      $('download').removeAttribute('href');
      if (!result.relay_deleted) status('Revoked locally. Relay could not be reached; stored ciphertext expires automatically.');
    } catch (error) { status(error.message); }
  });
  refresh(); setInterval(refresh, 2500);
})();
