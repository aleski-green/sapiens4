const fs = require('node:fs');
const path = require('node:path');
const {JSDOM} = require('../../tests/node_modules/jsdom');
const root = path.join(__dirname, '../..');
const [entry, mode = 'browser'] = process.argv.slice(2);
const dom = new JSDOM(fs.readFileSync(path.join(root, 'web/shell/remote.html'), 'utf8'),
  {url: `https://relay.example${entry}`, runScripts: 'outside-only'});
const w = dom.window;
w.matchMedia = query => ({matches: mode === 'standalone' && query === '(display-mode: standalone)', addEventListener() {}});
w.HTMLDialogElement.prototype.showModal = function() { this.open = true; };
w.HTMLDialogElement.prototype.close = function() { this.open = false; };
w.HTMLElement.prototype.scrollTo = function() {};
w.eval(fs.readFileSync(path.join(root, 'web/features/remote-install.js'), 'utf8'));
const button = w.document.querySelector('#install-entry button');
button?.click();
console.log(JSON.stringify({entry: button?.textContent ?? null,
  title: w.document.querySelector('#install-title')?.textContent ?? null,
  instructions: w.document.querySelector('#install-guide ol')?.textContent ?? null}));
dom.window.close();
