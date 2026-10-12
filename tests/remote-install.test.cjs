const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {JSDOM} = require('jsdom');
const root = path.join(__dirname, '..');
function client(standalone = false) {
  const dom = new JSDOM(fs.readFileSync(path.join(root, 'web/shell/remote.html'), 'utf8'),
    {url:'https://relay.example', runScripts:'outside-only'});
  const w = dom.window;
  Object.defineProperty(w.navigator, 'standalone', {value:standalone});
  w.HTMLDialogElement.prototype.showModal = function() { this.open = true; };
  w.HTMLDialogElement.prototype.close = function() { this.open = false; this.dispatchEvent(new w.Event('close')); };
  w.HTMLElement.prototype.scrollTo = function({left}) { this.scrollLeft = left; };
  // Installation guidance must not move the device key into cookies, links, or HTTP.
  w.fetch = () => { throw new Error('Install guide must not make API requests'); };
  Object.defineProperty(w.document, 'cookie', {set() { throw new Error('Install guide must not export credentials'); }});
  w.eval(fs.readFileSync(path.join(root, 'web/features/remote-install.js'), 'utf8'));
  return dom;
}
const dom = client(), w = dom.window, d = w.document;
d.querySelector('#install-entry button').click();
assert.ok(d.querySelector('#install-guide').open);
d.querySelector('.install-next').click();
assert.equal(d.querySelector('.install-counter').textContent, '2 / 3');
d.querySelector('#install-guide').dispatchEvent(new w.KeyboardEvent('keydown', {key:'ArrowRight'}));
assert.equal(d.querySelector('.install-counter').textContent, '3 / 3');
d.querySelector('.install-next').click();
assert.equal(d.querySelector('#install-guide'), null);
// The entry and guide remain available after the encrypted workspace replaces the body.
d.body.innerHTML = '<div class="sidebar-bottom"></div>';
w.RemoteInstall.mount(true);
d.querySelector('#install-entry button').click();
assert.match(d.querySelector('#install-guide').textContent, /Home Screen app needs its own one-time approval/);
assert.equal(d.querySelectorAll('#install-entry').length, 1);
dom.window.close();
const app = client(true);
assert.equal(app.window.document.querySelector('#install-entry'), null);
assert.ok(app.window.document.body.classList.contains('remote-standalone'));
app.window.document.body.className = 'sapi-workspace';
app.window.RemoteInstall.mount(true);
assert.ok(app.window.document.body.classList.contains('remote-standalone'), 'Safe-area layout survives workspace mounting');
assert.equal(app.window.document.querySelector('#install-entry'), null);
app.window.close();
console.log('Remote Home Screen onboarding passed');
