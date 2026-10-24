// Browser actions and observations; expectations are defined by RSpec.
const {observe,observeText,observeIdentity,attempt}=require('./observations.cjs');
// Install DOM test support with: npm ci --prefix libs4 --ignore-scripts
const fs = require('node:fs'), vm = require('node:vm');
const {JSDOM} = require('../../libs4/node_modules/jsdom');
const {window} = new JSDOM('<!doctype html><body></body>', {url:'http://localhost/'});
const sandbox = {document:window.document, XMLSerializer:window.XMLSerializer, URL, console,
  esc: value => String(value).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]))};
require('./components.cjs').load(sandbox,['notes']);
const profile = {id:'sapi_test',name:'Test Sapi',face:'¬o¬',color:'#dbd0f7',role:'Designer'};
const metadata = {modified_at:'2026-10-01T20:30:00+00:00',workspace:'/workspace/sapi_test'};
const render = source => sandbox.notesWiki(source,'/workspace/sapi_test/Notes.html',profile.id,profile,metadata,6);
const wrap = (content,about='<p>A saved lead.</p>',map='<a href="#topic">Topic</a>') => `<section id="about">${about}</section><section id="map"><nav>${map}</nav></section><section id="content">${content}</section>`;
let root = render(wrap('<article id="topic"><h2>Topic</h2><p>Fact <sup><a href="#source">[1]</a></sup>.</p><blockquote id="source">Recorded evidence.</blockquote><img src="image.png" alt="Asset"><script>alert(1)</script><p onclick="alert(1)">Safe text</p><a href="javascript:alert(1)">Unsafe URL</a></article>'));
observe("notes.dom.test.cjs:13:1", root.querySelector('.memo-header h1'));
observe("notes.dom.test.cjs:14:2", root.querySelector('h2').textContent);
observe("notes.dom.test.cjs:15:3", root.querySelector('blockquote').textContent);
observe("notes.dom.test.cjs:16:4", root.querySelector('.memo-avatar').textContent);
observe("notes.dom.test.cjs:17:5", root.querySelector('.memo-avatar').style.backgroundColor);
for (const value of ['sapi_test','6 recorded turns','/workspace/sapi_test']) observe("notes.dom.test.cjs:18:6", Boolean(root.querySelector('.memo-infobox').textContent.includes(value)));
observe("notes.dom.test.cjs:19:7", root.querySelector('time').dateTime);
observeText("notes.dom.test.cjs:20:8", root.querySelector('.memo-meta').textContent);
observe("notes.dom.test.cjs:21:9", root.querySelector('[data-note-anchor]').dataset.noteAnchor);
observe("notes.dom.test.cjs:22:10", root.querySelector('img').getAttribute('src'));
observe("notes.dom.test.cjs:23:11", root.querySelector('script,[onclick],[href^="javascript:"]'));
root = render(wrap('<article id="topic"><details><summary>Facts</summary><div id="fact"><pre><code class="language-yaml">observed:\n  - Admin requested a white background.\nuncertainty: "Exact font is unknown."\ntext: |-\n  A literal line.\n  Another line.</code></pre></div></details></article>'));
observe("notes.dom.test.cjs:25:12", root.querySelector('details'));
observe("notes.dom.test.cjs:26:13", root.querySelector('pre'));
observeText("notes.dom.test.cjs:27:14", root.textContent);
observeText("notes.dom.test.cjs:28:15", root.textContent);
observeText("notes.dom.test.cjs:29:16", root.textContent);
observe("notes.dom.test.cjs:30:17", Boolean(root.querySelector('#note-fact')));
root = render(wrap('<article id="topic"><pre><code class="language-yaml">facts: {}</code></pre></article><details id="empty"><summary>Unrecorded</summary><pre><code class="language-yaml">Events: "***"</code></pre></details>'));
observe("notes.dom.test.cjs:32:18", Boolean(root.querySelector('.memo-stub')));
observe("notes.dom.test.cjs:33:19", root.querySelector('.memo-toc'));
observeText("notes.dom.test.cjs:34:20", root.textContent);
observe("notes.dom.test.cjs:35:21", Boolean(root.querySelector('#note-topic')));
observeText("notes.dom.test.cjs:36:22", attempt(()=>render(wrap('<p id="about">Duplicate</p>'))));
observeText("notes.dom.test.cjs:37:23", attempt(()=>render('<section id="content"></section>')));
// No knowledge silently disappears: unfamiliar YAML syntax stays as source code.
root = render(wrap('<article id="topic"><pre><code class="language-yaml">&amp;anchor [one, two]</code></pre></article>'));
observe("notes.dom.test.cjs:40:24", root.querySelector('pre code').textContent);
// Authoring example is accepted by the actual renderer and keeps all references.
root = render(fs.readFileSync('prompts/examples/jarvis-notes.html','utf8'));
for(const a of root.querySelectorAll('[data-note-anchor]')) observe("notes.dom.test.cjs:43:25", Boolean(root.querySelector('#'+a.dataset.noteAnchor)));
const groupProfile={...profile,id:'group_test',kind:'group'};
const groupMemo=sandbox.notesWiki(wrap('<p>Shared finding</p><img src="chart.png">'),'/workspace/group_test/Notes.html',groupProfile.id,groupProfile,metadata);
observe("notes.dom.test.cjs:46:26", groupMemo.querySelector('img').getAttribute('src'));
observeText("notes.dom.test.cjs:47:27", groupMemo.textContent);


root = render(wrap('<article id="topic"><h2>Working with Admin<a class="permalink" href="#topic">¶</a></h2><p>Address the user as <strong>Admin</strong>.</p><a class="citation" href="#reference">[1]</a></article><article id="reference"><h2>References</h2><ol class="references"><li>Saved source.</li></ol></article>').replace('id="about"','id="about" data-memo-name="Chief" data-memo-assists="Admin" data-memo-role="1st director"'));
observeText("notes.dom.test.cjs:51:28", root.querySelector('.memo-infobox').textContent);
observe("notes.dom.test.cjs:52:29", root.querySelector('.memo-toc a').textContent);
observe("notes.dom.test.cjs:53:30", Boolean(root.querySelector('.citation')));
observe("notes.dom.test.cjs:54:31", Boolean(root.querySelector('.references')));

// Memo remains reachable after moving it beneath Work; async responses still render.
sandbox.state={selected:profile.id,panel:'work'};
sandbox.live={orchestration:{[profile.id]:{notes:{revision:'v1'}}},turns:[]};
sandbox.agent=()=>profile;
sandbox.api=async()=>({content:wrap('<p>Shared navigation preserves personal Memo.</p>'),path:'/workspace/sapi_test/Notes.html'});
const workMemo=window.document.createElement('div');window.document.body.append(workMemo);
sandbox.renderNotes(workMemo);
setImmediate(()=>{
  try {observeText("notes.dom.test.cjs:64:32", workMemo.textContent);}
  catch(error){console.error(error);process.exitCode=1;}
});
