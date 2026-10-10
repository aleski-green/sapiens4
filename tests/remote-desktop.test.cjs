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
  let fail = false;
  w.setInterval = fn => intervals.push(fn);
  w.RemoteVendor = {QRCode: {toCanvas: async () => {}}};
  $('qr').toDataURL = () => 'data:image/png;base64,test';
  w.fetch = async (url, opts) => {
    calls.push({url, body: opts.body && JSON.parse(opts.body)});
    if (url.endsWith('/pair')) return {ok: !fail, json: async () => fail ?
      {error: 'Relay unavailable'} : {qr: {relay: 'http://127.0.0.1:4180'}}};
    return {ok: true, json: async () => ({available: true, enabled: false, local_relay: true})};
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
  dom.window.close();
  console.log('Remote desktop setup: import, invalid origins, local pairing, and persistent errors passed');
})().catch(error => {console.error(error); process.exitCode = 1;});
