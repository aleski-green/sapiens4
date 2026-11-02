const net = require('node:net');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const {spawn} = require('node:child_process');
const {Browser, fail, keys} = require('./Browser.cjs');

const commands = {
  schema: [], 'request-permission': [], apps: [], activate: ['pid!'], open: ['url!'],
  read: ['pid', 'path', 'depth', 'snapshot', 'offset'], tree: ['pid', 'depth', 'max-nodes'],
  find: ['pid', 'title', 'role', 'value', 'depth', 'limit'], inspect: ['pid', 'path!'], actions: ['pid', 'path!'],
  focus: ['pid', 'path!'], 'scroll-to': ['pid', 'path!'], 'set-value': ['pid', 'path!', 'value!'],
  select: ['pid', 'path!', 'value!'],
  paste: ['pid', 'target-path!', 'text!'], press: ['pid', 'path!', 'require-value-path', 'require-value'],
  key: ['pid', 'target-path!', 'require-value!', 'key!'],
};

function parse(args) {
  if (!Array.isArray(args) || args.some(value => typeof value !== 'string')) fail('Arguments must be strings', 64);
  if (args[0] === 'blindly') args = args.slice(1);
  const [command, ...rest] = args;
  if (command === 'launch' && rest.length === 1) return {command, options: {name: rest[0]}};
  if (!Object.hasOwn(commands, command)) fail('Unsupported headless command; use schema', 64);
  const options = Object.create(null);
  const allowed = commands[command].map(key => key.replace('!', ''));
  for (let index = 0; index < rest.length; index++) {
    const match = /^--([a-z-]+)(?:=(.*))?$/s.exec(rest[index]);
    if (!match || !allowed.includes(match[1]) || Object.hasOwn(options, match[1])) fail('Unknown or duplicate option', 64);
    const value = match[2] === undefined ? rest[++index] : match[2];
    if (value === undefined) fail('Missing option argument', 64);
    options[match[1]] = value;
  }
  if (commands[command].some(key => key.endsWith('!') && options[key.slice(0, -1)] === undefined)) fail('Missing required option', 64);
  if ((options['require-value-path'] !== undefined) !== (options['require-value'] !== undefined) && command === 'press') fail('Draft path and exact value must be supplied together', 64);
  if (command === 'read' && options.pid === undefined && options.snapshot === undefined) fail('read requires --pid or --snapshot', 64);
  if (command === 'key' && !Object.hasOwn(keys, options.key.toLowerCase())) fail('Unsupported headless key', 64);
  if (options.depth !== undefined && (!/^\d+$/.test(options.depth) || Number(options.depth) < 1 || Number(options.depth) > 64)) fail('Depth must be 1–64', 64);
  return {command, options};
}

function bounded(value) {
  const rows = value.matches || value.tree?.children;
  if (!rows) return value;
  const kept = [];
  let size = value.tree ? Buffer.byteLength(JSON.stringify({...value.tree, children: []})) : 1000;
  for (const row of rows) {
    size += Buffer.byteLength(JSON.stringify(row)) + 1;
    if (size > 45000) break;
    kept.push(row);
  }
  return {...value, truncated: value.truncated || kept.length < rows.length,
    ...(value.matches ? {matches: kept} : {tree: {...value.tree, children: kept}})};
}

async function serve(socket) {
  const directory = fs.lstatSync(path.dirname(socket));
  if (!directory.isDirectory() || directory.uid !== process.getuid() || directory.mode & 0o077) fail('Browser socket requires a private directory owned by this user');
  const browser = new Browser();
  let queue = Promise.resolve(), pending = 0, stopping = false;
  const clients = new Set();
  const server = net.createServer(client => {
    if (stopping) { client.destroy(); return; }
    clients.add(client);
    client.once('close', () => clients.delete(client));
    let input = '', received = false;
    client.setEncoding('utf8');
    client.setTimeout(30000, () => client.destroy());
    client.on('error', () => {});
    client.on('data', data => {
      if (received) return;
      input += data;
      if (Buffer.byteLength(input) > 65536) { received = true; client.destroy(); return; }
      if (!input.includes('\n')) return;
      received = true;
      if (pending >= 16) { client.end(JSON.stringify({exit: 77, value: {error: 'Browser session is busy'}}) + '\n'); return; }
      pending++;
      queue = queue.then(async () => {
        let closing;
        // Abort pending browser input and drain cleanup before the next command.
        const cancel = () => { closing = browser.close().catch(error => { stopping = true; console.error(error.message); }); };
        try {
          if (stopping || client.destroyed) return;
          const {command, options} = parse(JSON.parse(input));
          client.once('close', cancel);
          const value = bounded(await browser.run(command, options));
          client.end(JSON.stringify({exit: 0, value}) + '\n');
        } catch (error) {
          client.end(JSON.stringify({exit: error.exit || 77, value: {code: 'linux_browser_error', error: error.message}}) + '\n');
        } finally {
          client.removeListener('close', cancel);
          await closing;
          pending--;
        }
      });
    });
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(socket, resolve); });
  fs.chmodSync(socket, 0o600);
  return async () => {
    stopping = true;
    server.close();
    for (const client of clients) client.destroy();
    await queue;
    await browser.close();
    fs.rmSync(socket, {force: true});
  };
}

async function host(args) {
  const root = path.resolve(__dirname, '../..');
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'sapiens-browser-'));
  fs.chmodSync(directory, 0o700);
  let close;
  try {
    const socket = path.join(directory, 'browser.sock');
    close = await serve(socket);
    const child = spawn(path.join(root, '.build/bin/sapiens4'), args, {stdio: 'inherit', env: {...process.env,
      SAPIENS_LINUX_BACKEND: 'headless', SAPIENS_LINUX_BROWSER_SOCKET: socket,
      SAPIENS_BLINDLY_BINARY: path.join(__dirname, 'headless.sh')}});
    const term = () => child.kill('SIGTERM'), interrupt = () => child.kill('SIGINT');
    process.once('SIGTERM', term);
    process.once('SIGINT', interrupt);
    try {
      process.exitCode = await new Promise((resolve, reject) => {
        child.once('error', reject);
        child.once('exit', (code, signal) => resolve(code ?? (signal === 'SIGINT' ? 130 : 143)));
      });
    } finally {
      process.removeListener('SIGTERM', term);
      process.removeListener('SIGINT', interrupt);
    }
  } finally {
    if (close) await close();
    fs.rmSync(directory, {recursive: true, force: true});
  }
}

function request(socket, args) {
  return new Promise((resolve, reject) => {
    const client = net.createConnection(socket);
    let response = '';
    client.setEncoding('utf8');
    client.setTimeout(25000, () => client.destroy(new Error('Browser command timed out; inspect effects before retrying')));
    client.on('connect', () => client.write(JSON.stringify(args) + '\n'));
    client.on('error', reject);
    client.on('data', data => {
      response += data;
      if (Buffer.byteLength(response) > 65536) client.destroy(new Error('Browser response exceeds its limit'));
    });
    client.on('end', () => { try { resolve(JSON.parse(response)); } catch (error) { reject(error); } });
  });
}

(async () => {
  const args = process.argv.slice(2);
  const socket = process.env.SAPIENS_LINUX_BROWSER_SOCKET;
  if (args[0] === 'host') return host(args.slice(1));
  if (args.length === 1 && args[0] === 'serve') {
    if (!socket) fail('SAPIENS_LINUX_BROWSER_SOCKET is required', 64);
    const close = await serve(socket);
    const stop = async () => { await close(); process.exit(0); };
    process.once('SIGTERM', stop);
    process.once('SIGINT', stop);
    console.log('READY');
    return;
  }
  const {command} = parse(args);
  if (command === 'schema') {
    console.log(JSON.stringify({schemaVersion: 1, platform: 'linux', backend: 'playwright',
      scope: 'Owned headless browser only; pid is the session identity, not desktop foreground verification.',
      commands: [{name: 'launch', usage: 'launch Browser|Chromium|Chrome|Firefox', risk: 'ui-mutation'},
        ...Object.entries(commands).map(([name, options]) =>
          ({name, usage: [name, ...options.map(key => key.endsWith('!') ? `--${key.slice(0, -1)} VALUE` : `[--${key} VALUE]`)].join(' '),
            risk: ['press', 'key'].includes(name) ? 'external-commit' :
              ['read', 'tree', 'find', 'inspect', 'actions', 'apps', 'schema'].includes(name) ? 'read-only' : 'ui-mutation'}))]}));
    return;
  }
  if (!socket) fail('Start the Linux host launcher to create an owned browser session');
  const result = await request(socket, args);
  console.log(JSON.stringify(result.value));
  process.exitCode = result.exit;
})().catch(error => { console.log(JSON.stringify({code: 'linux_browser_error', error: error.message})); process.exitCode = error.exit || 77; });
