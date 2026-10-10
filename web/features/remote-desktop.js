/* Local-only pairing controls; never embed credentials in URLs or persistent browser storage. */
'use strict';
(() => {
  const $ = id => document.getElementById(id);
  let pending = null;
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
      $('setup').hidden = data.enabled;
      $('local-setup').hidden = !data.local_relay;
      $('active').hidden = !data.enabled;
      $('approval').hidden = !data.pending;
      pending = data.pending;
      if (pending) $('fingerprint').textContent = pending.fingerprint;
      $('device').textContent = data.paired ? 'Approved phone · ' + data.fingerprint : 'Waiting for pairing and approval.';
      if (data.paired || !data.enabled || data.expires < Date.now()/1000) $('qr-panel').hidden = true;
      status(!data.available ? 'Install the optional remote Python dependencies, then restart Sapiens4.' :
        data.error || (data.paired ? 'Your phone can now connect.' : data.enabled ?
          (data.expires < Date.now()/1000 ? 'Invitation expired. Revoke and create a new QR.' : 'Invitation ready. Upload the QR image on your phone.') : 'Remote access is off.'));
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
      await RemoteVendor.QRCode.toCanvas($('qr'), JSON.stringify(data.qr), {width:480, margin:3,errorCorrectionLevel:'M'});
      $('download').href = $('qr').toDataURL('image/png');
      $('remote-link').href = data.qr.relay + '/'; $('remote-link').textContent = data.qr.relay;
      $('qr-panel').hidden = false;
      $('setup-feedback').textContent = '';
      await refresh();
    } catch (error) { $('setup-feedback').textContent = error.message; }
    finally { button.disabled = button.id === 'create-pair' && !$('token').value; }
  }
  $('local-pair').addEventListener('click', () => createPairing({local:true}, $('local-pair')));
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
      $('setup-feedback').textContent = 'Ready to connect to ' + url.origin + '. Select Create pairing QR.';
    } catch (error) {
      $('setup-feedback').textContent = 'Could not import connection file. ' + error.message;
    } finally { $('connection-file').value = ''; }
  });
  $('approve').addEventListener('click', async () => {
    if (!pending) return;
    $('approve').disabled = true;
    try { await api('/approve', {peer:pending.peer}); await refresh(); }
    catch (error) { status(error.message); }
    finally { $('approve').disabled = false; }
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
