// One suggestion from each naming pool keeps every batch balanced.
const namePools = [
  ['Armin','Howl','Seneca','Socrates','Aesop','Nikola','Walt','Akira','Milo'],
  ['Kiki','Chihiro','Sophie','Alice','Hypatia','Simone','Ada','Oprah','Arianna'],
  ['Sage','River','Rowan','Sky','Nova','Phoenix','Ash','Robin','Aster']
];
function suggestedNames() {
  const used = new Set(state.agents.map(a => a.name.toLowerCase()));
  return namePools.map(pool => {
    const available = pool.filter(name => !used.has(name.toLowerCase()));
    const names = available.length ? available : pool.map(name => `${name}-${Math.floor(Math.random()*90)+10}`);
    return names[Math.floor(Math.random()*names.length)];
  });
}
function nameSuggestions() {
  return `<div class="name-suggestions" id="name-help" aria-label="Suggested names">${suggestedNames().map(name => `<button type="button" class="button" data-use-name="${esc(name)}">${esc(name)}</button>`).join('')}<button type="button" class="icon-button" data-more-names="true" aria-label="More name suggestions">↻</button></div>`;
}
function managerOptions(a) {
  if (a.id === live.main_agent_id) return '<div class="settings-row"><span>Main orchestrator</span></div>';
  const info = live.orchestration[a.id];
  const allowed = state.agents.filter(candidate => {
    if (candidate.retired) return false;
    let id = candidate.id;
    while (id) {
      if (id === a.id) return false;
      id = live.orchestration[id]?.manager;
    }
    return true;
  });
  return `<label>Manager<select name="manager">${allowed.map(s => `<option value="${esc(s.id)}" ${s.id === info.manager ? 'selected' : ''}>${esc(s.name)}${s.id === live.main_agent_id ? ' · Main orchestrator' : ''}</option>`).join('')}</select></label>`;
}
document.addEventListener('click', e => {
  const b = e.target.closest('button');
  if (!b || (!b.dataset.useName && !b.dataset.moreNames)) return;
  e.preventDefault(); e.stopImmediatePropagation();
  if (b.dataset.useName) {
    const input = b.closest('form').elements.name;
    input.value = b.dataset.useName; input.focus();
  } else $('#name-help').outerHTML = nameSuggestions();
}, true);
