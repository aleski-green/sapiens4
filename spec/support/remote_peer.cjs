const readline = require('node:readline');
const nacl = require('../../libs4/node_modules/tweetnacl');
const WebSocket = require('../../libs4/node_modules/ws');
const bytes = value => new Uint8Array(Buffer.from(value, 'base64'));
const b64 = value => Buffer.from(value).toString('base64');
const peers = new Map();
let serial = 0;
async function wait(check, timeout = 5000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    const value = check();
    if (value !== undefined && value !== null) return value;
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  return null;
}
async function run(data) {
  if (data.op === 'keys') {
    const pair = nacl.box.keyPair();
    return {private: b64(pair.secretKey), public: b64(pair.publicKey)};
  }
  if (data.op === 'pack') {
    const key = nacl.box.keyPair.fromSecretKey(bytes(data.private)), nonce = nacl.randomBytes(24);
    const body = {v: 'sapiens-remote-box-v1', room: data.room, direction: 'phone-to-desktop', ...data.body};
    return {sender: b64(key.publicKey), nonce: b64(nonce), ciphertext:
      b64(nacl.box(Buffer.from(JSON.stringify(body)), nonce, bytes(data.public), key.secretKey))};
  }
  if (data.op === 'unpack') {
    const raw = nacl.box.open(bytes(data.frame.ciphertext), bytes(data.frame.nonce), bytes(data.public), bytes(data.private));
    if (!raw) throw Error('Authentication failed');
    return JSON.parse(Buffer.from(raw).toString());
  }
  if (data.op === 'connect') {
    const peer = {queue: [], closed: null};
    peers.set(data.name, peer);
    peer.ws = new WebSocket(data.url.replace(/^http/, 'ws') + '/api/socket', {origin: data.origin || data.url});
    peer.ws.on('message', raw => peer.queue.push(JSON.parse(raw.toString())));
    peer.ws.on('close', code => {peer.closed = code;});
    peer.ws.on('error', error => {peer.error = error.message;});
    peer.ws.on('open', () => peer.ws.send(JSON.stringify({type: 'auth', room: data.room, token: data.token})));
    return await wait(() => peer.queue.shift() || (peer.closed && {closed: peer.closed, error: peer.error}));
  }
  const peer = peers.get(data.name);
  if (data.op === 'status') return {closed: peer.closed, error: peer.error};
  if (data.op === 'close') {peer.ws.close(); return true;}
  if (data.op === 'read') return await wait(() => peer.queue.shift() || (peer.closed && {closed: peer.closed}), data.timeout);
  if (data.op === 'call') {
    const id = String(++serial);
    peer.ws.send(JSON.stringify({id, ...data.body}));
    return await wait(() => {
      const index = peer.queue.findIndex(item => item.type === 'result' && item.id === id);
      return index >= 0 ? peer.queue.splice(index, 1)[0] : (peer.closed ? {closed: peer.closed} : undefined);
    });
  }
  throw Error('Unknown peer operation');
}
const lines = readline.createInterface({input: process.stdin});
let pending = Promise.resolve();
lines.on('line', line => {
  pending = pending.then(async () => {
    try {process.stdout.write(JSON.stringify({value: await run(JSON.parse(line))}) + '\n');}
    catch (error) {process.stdout.write(JSON.stringify({error: error.message}) + '\n');}
  });
});
lines.on('close', () => {for (const peer of peers.values()) peer.ws.terminate();});
