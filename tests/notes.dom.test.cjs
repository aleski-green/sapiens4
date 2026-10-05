// Install DOM test support with: npm install --prefix tests
const fs = require('node:fs'), vm = require('node:vm'), assert = require('node:assert/strict');
const {JSDOM} = require('jsdom');
const {window} = new JSDOM('<!doctype html><body></body>', {url:'http://localhost/'});
const sandbox = {document:window.document, XMLSerializer:window.XMLSerializer, URL, console,
  esc: value => String(value).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))};
vm.createContext(sandbox); vm.runInContext(fs.readFileSync('web/features/notes.js','utf8'),sandbox);
const profile = {id:'sapi_test',name:'Test Sapi',face:'¬o¬',color:'#dbd0f7',role:'Designer'};
const metadata = {modified_at:'2026-10-01T20:30:00+00:00',workspace:'/workspace/sapi_test'};
const render = source => sandbox.notesWiki(source,'/workspace/sapi_test/Notes.html',profile.id,profile,metadata,6);
const wrap = (content,about='<p>A saved lead.</p>',map='<a href="#topic">Topic</a>') => `<section id="about">${about}</section><section id="map"><nav>${map}</nav></section><section id="content">${content}</section>`;
let root = render(wrap('<article id="topic"><h2>Topic</h2><p>Fact <sup><a href="#source">[1]</a></sup>.</p><blockquote id="source">Recorded evidence.</blockquote><img src="image.png" alt="Asset"><script>alert(1)</script><p onclick="alert(1)">Safe text</p><a href="javascript:alert(1)">Unsafe URL</a></article>'));
assert.equal(root.querySelector('h1').textContent,'Memo');
assert.equal(root.querySelector('h2').textContent,'Topic');
assert.equal(root.querySelector('blockquote').textContent,'Recorded evidence.');
assert.equal(root.querySelector('.memo-avatar').textContent,'(¬o¬)');
assert.equal(root.querySelector('.memo-avatar').style.backgroundColor,'rgb(219, 208, 247)');
for (const value of ['sapi_test','6 recorded turns','/workspace/sapi_test']) assert.ok(root.querySelector('.memo-infobox').textContent.includes(value));
assert.equal(root.querySelector('time').dateTime,metadata.modified_at);
assert.match(root.querySelector('.memo-meta').textContent,/Created at not recorded/);
assert.equal(root.querySelector('[data-note-anchor]').dataset.noteAnchor,'note-source');
assert.equal(root.querySelector('img').getAttribute('src'),'/api/agents/sapi_test/notes?image=image.png');
assert.equal(root.querySelector('script,[onclick],[href^="javascript:"]'),null);
root = render(wrap('<article id="topic"><details><summary>Facts</summary><div id="fact"><pre><code class="language-yaml">observed:\n  - Admin requested a white background.\nuncertainty: "Exact font is unknown."\ntext: |-\n  A literal line.\n  Another line.</code></pre></div></details></article>'));
assert.equal(root.querySelector('details'),null);
assert.equal(root.querySelector('pre'),null);
assert.match(root.textContent,/Admin requested a white background/);
assert.match(root.textContent,/Exact font is unknown/);
assert.match(root.textContent,/A literal line.\nAnother line./);
assert.ok(root.querySelector('#note-fact'));
root = render(wrap('<article id="topic"><pre><code class="language-yaml">facts: {}</code></pre></article><details id="empty"><summary>Unrecorded</summary><pre><code class="language-yaml">Events: "***"</code></pre></details>'));
assert.ok(root.querySelector('.memo-stub'));
assert.equal(root.querySelector('.memo-toc'),null);
assert.doesNotMatch(root.textContent,/\*\*\*/);
assert.ok(root.querySelector('#note-topic'));
assert.throws(()=>render(wrap('<p id="about">Duplicate</p>')),/unique/);
assert.throws(()=>render('<section id="content"></section>'),/three sections/);
// No knowledge silently disappears: unfamiliar YAML syntax stays as source code.
root = render(wrap('<article id="topic"><pre><code class="language-yaml">&amp;anchor [one, two]</code></pre></article>'));
assert.equal(root.querySelector('pre code').textContent,'&anchor [one, two]');
// Authoring example is accepted by the actual renderer and keeps all references.
root = render(fs.readFileSync('prompts/examples/jarvis-notes.html','utf8'));
for(const a of root.querySelectorAll('[data-note-anchor]')) assert.ok(root.querySelector('#'+a.dataset.noteAnchor));
const groupProfile={...profile,id:'group_test',kind:'group'};
const groupMemo=sandbox.notesWiki(wrap('<p>Shared finding</p><img src="chart.png">'),'/workspace/group_test/Notes.html',groupProfile.id,groupProfile,metadata);
assert.equal(groupMemo.querySelector('img').getAttribute('src'),'/api/groups/group_test/notes?image=chart.png');
assert.match(groupMemo.textContent,/Group ID/);
console.log('Memo DOM: article layout, legacy facts, stub, links, metadata and inert content passed');

root = render(wrap('<article id="topic"><h2>Working with Admin<a class="permalink" href="#topic">¶</a></h2><p>Address the user as <strong>Admin</strong>.</p><a class="citation" href="#reference">[1]</a></article><article id="reference"><h2>References</h2><ol class="references"><li>Saved source.</li></ol></article>').replace('id="about"','id="about" data-memo-name="Chief" data-memo-assists="Admin" data-memo-role="1st director"'));
assert.match(root.querySelector('.memo-infobox').textContent,/ChiefFull nameTest SapiRole1st directorAssistsAdmin/);
assert.equal(root.querySelector('.memo-toc a').textContent,'Working with Admin');
assert.ok(root.querySelector('.citation'));
assert.ok(root.querySelector('.references'));

// Memo remains reachable after moving it beneath Work; async responses still render.
sandbox.state={selected:profile.id,panel:'work'};
sandbox.live={orchestration:{[profile.id]:{notes:{revision:'v1'}}},turns:[]};
sandbox.agent=()=>profile;
sandbox.api=async()=>({content:wrap('<p>Shared navigation preserves personal Memo.</p>'),path:'/workspace/sapi_test/Notes.html'});
const workMemo=window.document.createElement('div');window.document.body.append(workMemo);
sandbox.renderNotes(workMemo);
setImmediate(()=>{
  try {assert.match(workMemo.textContent,/Shared navigation preserves personal Memo/);console.log('Memo async rendering under Work passed');}
  catch(error){console.error(error);process.exitCode=1;}
});
