// Browser actions and observations; expectations are defined by RSpec.
const {observe,observeText,observeIdentity,attempt}=require('./observations.cjs');
const fs = require('node:fs'), vm = require('node:vm');
const esc = value => String(value).replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const sandbox = {esc}; require('./components.cjs').load(sandbox,['notes']);
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
  observe("notes.test.cjs:15:1", decode(html));
  observeText("notes.test.cjs:16:2", html);
  observeText("notes.test.cjs:17:3", html);
}
observeText("notes.test.cjs:19:4", render(cases.yaml));
observeText("notes.test.cjs:20:5", render(cases.yaml));
for (const language of ['yaml','python','haskell','html','svg','text']) {
  for (const text of ['<script>alert(1)</script>', '<img src=x onerror=alert(1)>', '"😎"\r\n', 'x'.repeat(70000)]) {
    observe("notes.test.cjs:23:6", decode(render(text,language)));
    observeText("notes.test.cjs:24:7", render(text,language));
  }
}
