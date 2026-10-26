const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const esc = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const sandbox = {esc}; vm.createContext(sandbox);
vm.runInContext(fs.readFileSync('web/features/notes.js', 'utf8'), sandbox);
const render = sandbox.highlightNotes;
const decode = text => text.replace(/<\/?span[^>]*>/g, '').replace(/&(amp|lt|gt|quot|#39);/g, (_, key) => ({amp:'&',lt:'<',gt:'>',quot:'"','#39':"'"}[key]));
const cases = {
  yaml: 'facts:\n  enabled: true\n  count: 42\n  text: "Admin"\n  details: |\n    # not a comment\n    inner: still text\nnext: null\n',
  python: 'def check(page):\n    # inspect\n    return page is not None\n',
  haskell: 'data Outcome = Done | Failed\nrecipe :: Call -> Outcome\n-- descriptive only\n',
  html: '<div class="preview"><svg viewBox="0 0 10 10"></svg></div>'
};
for (const [language, text] of Object.entries(cases)) {
  const html = render(text, language);
  assert.equal(decode(html), text);
  assert.match(html, /class="syntax-(key|keyword)"/);
  assert.doesNotMatch(html, /<svg|<div/);
}
assert.match(render(cases.yaml), /class="syntax-string">    # not a comment<\/span>/);
assert.match(render(cases.yaml), /class="syntax-key">next<\/span>/);
for (const language of ['yaml','python','haskell','html','svg','text']) {
  for (const text of ['<script>alert(1)</script>', '<img src=x onerror=alert(1)>', '"😎"\r\n', 'x'.repeat(70000)]) {
    assert.equal(decode(render(text,language)), text);
    assert.doesNotMatch(render(text,language), /<script|<img/);
  }
}
console.log('Five snippet languages: highlighting, escaping and exact content preservation passed');
