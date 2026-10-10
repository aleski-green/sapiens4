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
  $('pair-form').addEventListener('submit', async event => {
    event.preventDefault();
    const button = event.submitter; button.disabled = true;
    try {
      const data = await api('/pair', {relay:$('relay').value.trim(),token:$('token').value});
      $('token').value = '';
      await RemoteVendor.QRCode.toCanvas($('qr'), JSON.stringify(data.qr), {width:480, margin:3,errorCorrectionLevel:'M'});
      $('download').href = $('qr').toDataURL('image/png');
      $('remote-link').href = data.qr.relay + '/'; $('remote-link').textContent = data.qr.relay;
      $('qr-panel').hidden = false;
      await refresh();
    } catch (error) { status(error.message); }
    finally { button.disabled = false; }
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
