const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {JSDOM} = require('jsdom');
const root = path.join(__dirname, '..');
const settle = () => new Promise(resolve => setTimeout(resolve, 0));
(async () => {
  const dom = new JSDOM(fs.readFileSync(path.join(root, 'web/shell/remote-desktop.html'), 'utf8'),
    {url: 'http://127.0.0.1:4174/remote/', runScripts: 'outside-only'});
  const w = dom.window, $ = id => w.document.getElementById(id), calls = [], intervals = [];
  let fail = false, enabled = false, copied = '', qrText = '';
  let configured = null, pending = null;
  Object.defineProperty(w.navigator, 'clipboard', {value:{writeText: async text => {copied = text;}}});
  const invitation = {v:'sapiens-remote-box-v1',relay:'http://127.0.0.1:4180',room:'r'.repeat(43),
    token:'t'.repeat(43),secret:'s'.repeat(43),desktop:Buffer.alloc(32,7).toString('base64'),expires:Math.floor(Date.now()/1000)+259200,public_id:'sapi4_abc123qwe'};
  w.eval(fs.readFileSync(path.join(root, 'web/features/remote-code.js'), 'utf8'));
  w.setInterval = fn => intervals.push(fn);
  w.RemoteVendor = {QRCode: {toCanvas: async (_, text) => {qrText = text;}}};
  $('qr').toDataURL = () => 'data:image/png;base64,test';
  w.fetch = async (url, opts) => {
    calls.push({url, body: opts.body && JSON.parse(opts.body)});
    if (url.endsWith('/pair')) { enabled = !fail; return {ok: !fail, json: async () => fail ?
      {error: 'Relay unavailable'} : {qr: invitation}}; }
    return {ok: true, json: async () => ({available: true, enabled, pending, local_relay: true, configured_relay: configured, public_id:invitation.public_id, invitation:enabled?invitation:null, expires: invitation.expires})};
  };
  w.eval(fs.readFileSync(path.join(root, 'web/features/remote-desktop.js'), 'utf8'));
  await settle();
  assert.equal($('local-setup').hidden, false);
  async function upload(value) {
    Object.defineProperty($('connection-file'), 'files', {configurable: true,
      value: [{size: 200, text: async () => JSON.stringify(value)}]});
    $('connection-file').dispatchEvent(new w.Event('change'));
    await settle();
  }
  const connection = {format: 'sapiens-relay-connection-v1', relay: 'https://relay.example', token: 's'.repeat(43)};
  await upload(connection);
  assert.equal($('relay').value, connection.relay);
  assert.equal($('create-pair').disabled, false);
  assert.match($('setup-feedback').textContent, /Ready to connect to https:\/\/relay.example/);
  assert.equal(calls.filter(c => c.body).length, 0, 'Import must not send a credential before user submits');
  await upload({...connection, relay: 'http://public.example'});
  assert.equal($('token').value, '');
  assert.equal($('create-pair').disabled, true);
  await upload(connection);
  fail = true;
  $('pair-form').dispatchEvent(new w.Event('submit', {cancelable: true}));
  await settle();
  await intervals[0]();
  assert.equal($('setup-feedback').textContent, 'Relay unavailable', 'Polling must not erase setup errors');
  fail = false;
  $('local-pair').click();
  await settle();
  assert.deepEqual(calls.at(-2).body, {local: true});
  assert.equal($('token').value, '');
  assert.equal(w.localStorage.length, 0);
  const code = w.RemoteCode.encode(invitation);
  assert.ok(code.length < JSON.stringify(invitation).length);
  assert.deepEqual(JSON.parse(JSON.stringify(w.RemoteCode.decode(code))), invitation);
  $('copy-address').click(); await settle();
  assert.equal(copied, invitation.public_id);
  assert.equal(qrText,w.RemoteCode.link(invitation));
  assert.deepEqual(JSON.parse(JSON.stringify(w.RemoteCode.decode(qrText))),invitation);
  configured = 'https://relay.example'; enabled = false; await intervals[0]();
  assert.equal($('saved-setup').hidden,false);
  assert.equal($('relay-settings').open,false);
  $('saved-pair').click(); await settle();
  assert.deepEqual(calls.at(-2).body,{saved:true});
  enabled = false; await intervals[0]();
  assert.equal($('qr-panel').hidden, true, 'Disabled invitation must not remain visible');
  pending = {peer:'full-public-key',fingerprint:'old-long-fingerprint',confirmation_code:'CwnX · eCGC'};
  await intervals[0]();
  assert.equal($('confirmation-code').textContent,'CwnX · eCGC');
  assert.equal($('qr-panel').hidden,true,'Focus the approval step once the QR was scanned');
  assert.equal($('approve').textContent,'Confirm');
  assert.equal($('approve').disabled,false);
  $('approve').click();await settle();
  assert.deepEqual(calls.find(c=>c.url.endsWith('/approve')).body,{peer:'full-public-key'});
  delete pending.confirmation_code;await intervals[0]();
  assert.equal($('approve').disabled,true,'Never approve without a displayed comparison code');
  dom.window.close();
  console.log('Remote desktop setup: import, invalid origins, local pairing, and persistent errors passed');
})().catch(error => {console.error(error); process.exitCode = 1;});
