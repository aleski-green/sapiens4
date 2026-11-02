const {chromium, firefox} = require('../../submodules/libs4/node_modules/playwright');
const {randomBytes} = require('node:crypto');
const keys = {enter: 'Enter', return: 'Enter', tab: 'Tab', escape: 'Escape', backspace: 'Backspace', delete: 'Delete',
  arrowleft: 'ArrowLeft', arrowright: 'ArrowRight', arrowup: 'ArrowUp', arrowdown: 'ArrowDown'};

function fail(message, exit = 77) { throw Object.assign(new Error(message), {exit}); }
function number(value, fallback, minimum, maximum) {
  const result = value === undefined ? fallback : Number(value);
  if (!Number.isInteger(result) || result < minimum || result > maximum) fail('Invalid numeric argument', 64);
  return result;
}

class Browser {
  constructor() {
    this.references = new Map();
    this.snapshots = new Map();
    this.sequence = 0;
    this.epoch = 0;
  }
  async close() {
    const browser = await this.starting?.catch(() => null);
    await browser?.close();
    this.browser = this.page = this.starting = null;
    this.references.clear();
    this.snapshots.clear();
    this.epoch++;
  }
  async launch(name) {
    const engine = ['Browser', 'Chromium', 'Chrome'].includes(name) ? 'chromium' : name === 'Firefox' ? 'firefox' : null;
    if (!engine) fail('Headless launch supports Browser, Chromium, Chrome or Firefox', 64);
    if (this.browser && engine !== this.engine) fail('A browser is already running in this session');
    if (!this.browser) {
      this.starting = ({chromium, firefox})[engine].launch({headless: true, chromiumSandbox: true,
        args: engine === 'chromium' ? ['--disable-gpu'] : [],
        env: {...process.env, LIBGL_ALWAYS_SOFTWARE: '1', DBUS_SESSION_BUS_ADDRESS: 'unix:path=/dev/null'}});
      this.browser = await this.starting;
      this.engine = engine;
      this.page = await this.browser.newPage({viewport: {width: 1440, height: 960}});
      this.page.setDefaultTimeout(5000);
      this.page.setDefaultNavigationTimeout(15000);
      this.page.on('framenavigated', frame => { if (frame === this.page.mainFrame()) this.epoch++; });
    }
    return {launched: true, app: name, pid: process.pid, backend: 'playwright', error: null};
  }
  requirePage(pid) {
    if (!this.page || this.page.isClosed()) fail('Launch Browser before using this session');
    if (pid !== undefined && number(pid, 0, 1, 2147483647) !== process.pid) fail('PID does not identify this owned browser session');
  }
  async details(element, path) {
    const row = await element.evaluate(el => {
      const type = el.getAttribute('type')?.toLowerCase();
      const secure = type === 'password';
      const tag = el.tagName.toLowerCase();
      const role = secure ? 'AXSecureTextField' : tag === 'textarea' ? 'AXTextArea' :
        tag === 'select' ? 'AXComboBox' : type === 'checkbox' ? 'AXCheckBox' : type === 'radio' ? 'AXRadioButton' :
        tag === 'button' || ['submit', 'button', 'reset'].includes(type) || el.getAttribute('role') === 'button' ? 'AXButton' :
        tag === 'a' ? 'AXLink' : tag === 'input' || el.isContentEditable ? 'AXTextField' : 'AXGroup';
      const labelled = (el.getAttribute('aria-labelledby') || '').split(/\s+/).map(id => el.ownerDocument.getElementById(id)?.textContent || '').join(' ').trim();
      const labels = Array.from(el.labels || []).map(label => {
        const copy = label.cloneNode(true);
        copy.querySelectorAll('input, textarea, select').forEach(control => control.remove());
        return copy.textContent;
      }).join(' ').trim();
      const title = el.getAttribute('aria-label') || labelled || labels || el.getAttribute('title') ||
        (['AXButton', 'AXLink'].includes(role) ? (tag === 'input' ? el.value : el.textContent) : '') || '';
      const value = secure ? null : 'value' in el ? el.value : el.isContentEditable ? el.textContent : null;
      const options = tag === 'select' ? Array.from({length: Math.min(el.options.length, 16)}, (_, index) => {
        const option = el.options[index];
        return {value: option.value, label: option.label.slice(0, 256), label_truncated: option.label.length > 256,
          enabled: !option.disabled && !option.parentElement.disabled, selected: option.selected};
      }).filter(option => option.value.length <= 256) : null;
      return {role, title: title.slice(0, 1000), value: value?.slice(0, 2000), text_truncated: value?.length > 2000 || title.length > 1000,
        ...(options ? {options, options_truncated: options.length < el.options.length} : {}),
        enabled: !el.disabled && el.getAttribute('aria-disabled') !== 'true', focused: el.ownerDocument.activeElement === el,
        selected: Boolean(el.checked), writable: !secure && !el.disabled && !el.readOnly &&
          (['AXTextField', 'AXTextArea'].includes(role)) && el.getAttribute('aria-readonly') !== 'true'};
    });
    return {...row, pid: process.pid, path, actions: ['AXButton', 'AXLink', 'AXCheckBox', 'AXRadioButton'].includes(row.role) ? ['AXPress'] : []};
  }
  async target(path, writable = false) {
    const reference = this.references.get(path);
    if (!reference || reference.epoch !== this.epoch || Date.now() - reference.time > 90000) fail('Stale path; read the page again');
    const element = reference.element;
    if (!await element.evaluate(el => el.isConnected) || !await element.isVisible()) fail('Target is detached or hidden; rediscover it');
    const row = await this.details(element, path);
    if (writable && !row.writable) fail('Target is not an enabled writable control');
    return {element, row};
  }
  async exact(path, expected) {
    const target = await this.target(path, true);
    const value = await target.element.evaluate(el => 'value' in el ? el.value : el.textContent);
    if (value !== expected) fail('Draft does not exactly match --require-value');
    return target;
  }
  async observe(limit) {
    const text = await this.page.locator('body').innerText();
    const rows = [{pid: process.pid, path: '', role: 'AXWebArea', title: (await this.page.title()).slice(0, 1000), value: text.slice(0, 4000), text_truncated: text.length > 4000}];
    const controls = this.page.locator('input, textarea, select, button, a[href], [contenteditable]:not([contenteditable="false"]), [role="button"]');
    const count = await controls.count();
    try {
      for (let index = 0; index < Math.min(count, limit); index++) {
        const element = await controls.nth(index).elementHandle();
        if (!element) continue;
        if (!await element.isVisible()) { await element.dispose(); continue; }
        const path = `${this.epoch}.${++this.sequence}`;
        this.references.set(path, {element, epoch: this.epoch, time: Date.now()});
        rows.push(await this.details(element, path));
      }
    } finally {
      while (this.references.size > 1000) {
        const [path, reference] = this.references.entries().next().value;
        this.references.delete(path);
        await reference.element.dispose();
      }
    }
    return {nodes: rows, truncated: count > limit};
  }
  async run(command, options) {
    if (command === 'launch') return this.launch(options.name);
    if (command === 'request-permission') return {trusted: true, platform: 'linux', backend: 'playwright', nativeDesktopAccess: false};
    if (command === 'apps') return {apps: this.page && !this.page.isClosed() ? [{pid: process.pid, name: this.engine, frontmost: true, backend: 'playwright'}] : []};
    this.requirePage(options.pid);
    if (command === 'activate') return {pid: process.pid, ok: true};
    if (command === 'open') {
      let url;
      try { url = new URL(options.url); } catch { fail('Invalid URL', 64); }
      if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) fail('Only HTTP(S) URLs without credentials are supported', 64);
      await this.page.goto(url.href, {waitUntil: 'domcontentloaded'});
      return {url: this.page.url(), ok: true};
    }
    if (['read', 'tree', 'find'].includes(command)) {
      if (options.path) {
        const {row} = await this.target(options.path);
        return {nodes: [row], pid: process.pid, truncated: false};
      }
      let snapshot = options.snapshot && this.snapshots.get(options.snapshot);
      if (options.snapshot && (!snapshot || Date.now() / 1000 - snapshot.observed_at > 90)) fail('Snapshot expired; read the page again');
      if (!snapshot) {
        const observed = await this.observe(number(options['max-nodes'], 250, 1, 500));
        snapshot = {...observed, pid: process.pid, url: this.page.url(), snapshot: randomBytes(16).toString('hex'), observed_at: Date.now() / 1000,
          coverage: 'Main-frame visible controls only; frames, native dialogs and browser chrome are not included.'};
      }
      if (command === 'find') {
        const filters = ['title', 'role', 'value'].filter(key => options[key] !== undefined)
          .map(key => [key, options[key].toLowerCase()]);
        if (!filters.length) fail('find requires a property filter', 64);
        const limit = number(options.limit, 25, 1, 500);
        const matches = [];
        for (const row of snapshot.nodes) {
          if (!filters.every(([key, value]) => String(row[key] ?? '').toLowerCase().includes(value))) continue;
          if (matches.length === limit) return {matches, truncated: true};
          matches.push(row);
        }
        return {matches, truncated: snapshot.truncated};
      }
      if (command === 'tree') return {tree: {...snapshot.nodes[0], children: snapshot.nodes.slice(1)}, truncated: snapshot.truncated};
      this.snapshots.set(snapshot.snapshot, snapshot);
      while (this.snapshots.size > 5) this.snapshots.delete(this.snapshots.keys().next().value);
      const offset = number(options.offset, 0, 0, snapshot.nodes.length);
      let size = 1000;
      const nodes = [];
      for (let index = offset; index < snapshot.nodes.length; index++) {
        const row = snapshot.nodes[index];
        const length = Buffer.byteLength(JSON.stringify(row));
        if (nodes.length && size + length > 45000) break;
        nodes.push(row); size += length;
      }
      const end = offset + nodes.length;
      return {...snapshot, nodes, offset, total: snapshot.nodes.length, next_offset: end < snapshot.nodes.length ? end : null};
    }
    const path = options['target-path'] || options.path;
    const {element, row} = await this.target(path, ['paste', 'set-value', 'key'].includes(command));
    if (command === 'inspect') return row;
    if (command === 'actions') return {path, actions: row.actions};
    if (!row.enabled) fail('Target is disabled');
    if (command === 'focus') await element.focus();
    else if (command === 'scroll-to') await element.scrollIntoViewIfNeeded();
    else if (command === 'select') {
      const selectable = await element.evaluate((el, value) => el.tagName === 'SELECT' && !el.multiple &&
        Array.prototype.some.call(el.options, option => option.value === value && !option.disabled && !option.parentElement.disabled), options.value);
      if (!selectable) fail('Select requires an enabled option in a single-selection control', 64);
      await element.selectOption({value: options.value});
      if (await element.inputValue() !== options.value) fail('Selected value could not be verified; inspect before retrying');
      return {path, ok: true, value: options.value};
    }
    else if (command === 'paste' || command === 'set-value') {
      const text = command === 'paste' ? options.text : options.value;
      await element.fill(text);
      await this.exact(path, text);
      return {path, ok: true, verified: true, characters: Array.from(text).length};
    } else if (command === 'press') {
      if (!row.actions.includes('AXPress')) fail('Target does not support press');
      if (options['require-value-path']) await this.exact(options['require-value-path'], options['require-value']);
      await element.click();
    } else if (command === 'key') {
      await this.exact(path, options['require-value']);
      if (!row.focused) fail('Target must already be focused');
      await element.press(keys[options.key.toLowerCase()]);
    }
    return {path, ok: true};
  }
}

module.exports = {Browser, fail, keys};
