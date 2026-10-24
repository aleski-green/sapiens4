// Browser actions and observations; expectations are defined by RSpec.
const {observe,observeText,observeIdentity,attempt}=require('./observations.cjs');
const fs=require('node:fs'),vm=require('node:vm');

const esc = v=>String(v).replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const sandbox={esc,URL,state:{agents:[{id:'sapi',name:'Nova'}]},mention:id=>`<button>${id}</button>`};
require('./components.cjs').load(sandbox,['mentions','conversation']);
const render=sandbox.formatText;
let value=render('https://github.com/aleski-green/lab-sapiens-rnd/blob/commit/human_specs/agentpy_spec_human.md');
observeText("chat_links.test.cjs:8:1", value);observeText("chat_links.test.cjs:8:2", value);
observeText("chat_links.test.cjs:9:3", value);
value=render('[Proposal](</Users/Admin/My files/proposal.md>)');
observeText("chat_links.test.cjs:11:4", value);observeText("chat_links.test.cjs:11:5", value);
observeText("chat_links.test.cjs:12:6", render('@art-md0016 and @art-md0016:old'));
observeText("chat_links.test.cjs:13:7", render('@art-md0016:wrong'));
observeText("chat_links.test.cjs:14:8", render('@task-x0012 and @create-or-find-one'));
observeText("chat_links.test.cjs:15:9", render('[Bad](javascript:alert(1))'));
observeText("chat_links.test.cjs:16:10", render('<img src=x onerror=alert(1)>'));
observe("chat_links.test.cjs:17:11", render('`https://example.com`'));
observeText("chat_links.test.cjs:18:12", render('[Reference](https://example.com/docs)'));
observeText("chat_links.test.cjs:19:13", render('https://example.com/Nova'));observeText("chat_links.test.cjs:19:14", render('https://example.com/Nova'));
observeText("chat_links.test.cjs:20:15", render('https://example.com/a_(b).'));
observeText("chat_links.test.cjs:21:16", render('**Admin**'));
const report='/Users/Admin/My files/sapi_team.pdf', citation=`:codex-file-citation{path="${report}" purpose="output"}`;
observeText("chat_links.test.cjs:23:17", render(citation));
for (const message of [`[PDF](<${report}>) ${citation}`, `${citation}\n\n[PDF](<${report}>)`, `${citation} ${citation}`]) {
  const html=render(message);
  observe("chat_links.test.cjs:26:18", (html.match(/data-file-link=/g)||[]).length);observeText("chat_links.test.cjs:26:19", html);
}
observe("chat_links.test.cjs:28:20", render('`'+citation+'`'));
observe("chat_links.test.cjs:29:21", render(':codex-file-citation{path="javascript:alert(1)"}'));
observe("chat_links.test.cjs:30:22", render(':codex-file-citation{purpose="output"}'));
observeText("chat_links.test.cjs:31:23", render(String.raw`:codex-file-citation{purpose="output" path="/tmp/sapi\_team.pdf"}`));
observeText("chat_links.test.cjs:32:24", render(':codex-file-citation{path="file:///tmp/report.pdf"}'));
observeText("chat_links.test.cjs:33:25", render(':codex-file-citation{path="/tmp/<img src=x onerror=alert(1)>.pdf"}'));
observeText("chat_links.test.cjs:34:26", render(String.raw`:codex-file-citation{path="/tmp/a\"b.pdf"}`));
sandbox.state.agents.push({id:'retired',name:'Old',retired:true});observe("chat_links.test.cjs:35:27", render('@Old'));
sandbox.state.agents.push({id:'other',name:'Nova'});observe("chat_links.test.cjs:36:28", render('@Nova'));sandbox.state.agents.pop();
const host=sandbox.document.querySelector('#conversation-body');
Object.assign(sandbox,{$:()=>host,selected:()=>({id:'sapi'}),getMessages:()=>[{role:'assistant',time:'now',text:`[PDF](<${report}>)\n\n${citation}`}],avatar:()=>'',renderAttachment:()=>{},taskCallControls:()=>{}});
sandbox.state.messages={sapi:sandbox.getMessages()};sandbox.renderMessages(host);
observe("chat_links.test.cjs:40:29", (host.innerHTML.match(/data-file-link=/g)||[]).length);observeText("chat_links.test.cjs:40:30", host.innerHTML);


sandbox.online=true;
sandbox.live={activity:{sapi:{turn:'current',started:1000,updated:2000,phase:'Waiting for model',last_action:'<completed>'}}};

const current={id:'current',agent:'sapi',status:'running',created:new Date(1000).toISOString()};
observeText("chat_links.test.cjs:47:31", sandbox.turnProgress(current,65000));
observeText("chat_links.test.cjs:48:32", sandbox.turnProgress(current,65000));
observeText("chat_links.test.cjs:49:33", sandbox.turnProgress(current,65000));
observeText("chat_links.test.cjs:50:34", sandbox.turnProgress({...current,id:'retry'},65000));
sandbox.live.activity.sapi.stopping=true;
observeText("chat_links.test.cjs:52:35", sandbox.turnProgress(current,65000));
sandbox.online=false;
observeText("chat_links.test.cjs:54:36", sandbox.turnProgress(current,65000));
