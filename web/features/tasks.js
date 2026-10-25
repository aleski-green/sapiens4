function renderTasks(host) {
  const document=state.documents['tasks:'+state.selected];
  mountHTML(host,tasksView(state,document),JSON.stringify([state.selected,state.period,state.view,document]));
}
document.addEventListener('toggle',event=>{
  const key=event.target.dataset?.taskOpen;
  if(key&&event.target.isConnected)dispatchUI({type:'Expand',key:'task:'+key,open:event.target.open});
},true);
document.addEventListener('click',async event=>{
  const button=event.target.closest('button');if(!button)return;
  if(button.closest('.task-summary'))event.preventDefault();
  if(button.dataset.retryDocument)dispatchUI({type:'RetryDocument',key:button.dataset.retryDocument});
  if(button.hasAttribute('data-copy-task')) {
    try {await navigator.clipboard.writeText(button.closest('.task-content').querySelector('pre').textContent);toast(button.getAttribute('aria-label').includes('execution')?'Execution prompt copied.':'Task YAML copied.');}
    catch {toast('Could not copy. You can select the task body to copy it.');}
  }
});
function taskCallControls(host) {
  for(const work of state.snapshot.workloads||[]) {
    if(work.state!=='WaitingForAdmin'||![work.owner,work.origin.agent].includes(state.selected))continue;
    host.append(element('button','button','Answer Chief',{type:'button','data-chat-key':'clarify:'+work.id+':'+work.owner+':'+work.taskId,onclick:()=>{
      openChat(work.owner);dispatchUI({type:'Clarify',work});
      $('#message-input').placeholder=`Clarify ${work.taskId} for Chief…`;$('#message-input').focus();
    }}));
  }
}
async function editDecisionPrompts() {
  try {
    const {prompts} = await api('/api/decision-prompts');
    modal('Decision prompts', '<form id="decision-prompt-form" class="form-stack"><label>Node<select name="node"></select></label><small class="prompt-path"></small><label>Prompt<textarea name="content" rows="16" maxlength="20000" required></textarea></label><p>Changes apply to subsequent decisions. Saved decision records keep their original prompt.</p><button class="button" type="submit">Save prompt</button></form>', 'CORPORA');
    const form = $('#decision-prompt-form');
    for (const row of prompts) {
      const option = document.createElement('option'); option.value = row.node; option.textContent = row.node;
      form.elements.node.append(option);
    }
    const show = () => {
      const row = prompts.find(p => p.node === form.elements.node.value);
      form.elements.content.value = row.content;
      form.querySelector('.prompt-path').textContent = row.path;
    };
    form.elements.node.addEventListener('change', show); show();
    form.addEventListener('submit', async e => {
      e.preventDefault();
      const button = form.querySelector('button'); button.disabled = true;
      try {
        const content = form.elements.content.value, node = form.elements.node.value;
        const saved = await api(`/api/decision-prompts/${encodeURIComponent(node)}`, 'PUT', {content});
        const row = prompts.find(p => p.node === node); row.content = content; row.path = saved.path;
        show(); toast('Prompt saved for subsequent decisions.');
      } catch (error) { toast(error.message); }
      finally { button.disabled = false; }
    });
  } catch (error) { toast(error.message); }
}
