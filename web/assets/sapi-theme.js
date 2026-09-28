/* Shared shell preference. Guest pages retain control over their own styles. */
(() => {
  const key='sapi-color-theme';
  let preference;
  try { preference=localStorage.getItem(key); } catch {}
  const system=matchMedia('(prefers-color-scheme: dark)');
  function apply(theme){
    document.documentElement.dataset.theme=theme;
    document.documentElement.style.colorScheme=theme;
    document.querySelectorAll('[data-theme-toggle]').forEach(button=>{
      const label=`Switch to ${theme==='dark'?'light':'dark'} theme`;
      button.textContent=theme==='dark'?'☀':'☾';
      button.setAttribute('aria-label',label);button.title=label;
      button.setAttribute('aria-pressed',String(theme==='dark'));
    });
  }
  apply(preference==='dark'||preference==='light'?preference:system.matches?'dark':'light');
  document.addEventListener('click',event=>{
    if(!event.target.closest('[data-theme-toggle]'))return;
    preference=document.documentElement.dataset.theme==='dark'?'light':'dark';
    apply(preference);try{localStorage.setItem(key,preference);}catch{}
  });
  addEventListener('storage',event=>{if(event.key===key){preference=event.newValue;apply(preference==='dark'||preference==='light'?preference:system.matches?'dark':'light');}});
  system.addEventListener('change',()=>{if(!preference)apply(system.matches?'dark':'light');});
})();
