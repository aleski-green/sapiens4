/* Installation and explicit reload of the public app shell; no credential access. */
'use strict';
window.RemoteInstall = (() => {
  const display = window.matchMedia?.('(display-mode: standalone)');
  const installed = () => navigator.standalone === true || display?.matches === true;
  const ios = /iPad|iPhone|iPod/.test(navigator.userAgent) ||
    (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  const mobile = ios || /Android/.test(navigator.userAgent);
  let installPrompt;
  let reloading = false;
  async function updateShell() {
    const registration = await navigator.serviceWorker?.getRegistration();
    if (!registration) return;
    await registration.update();
    const worker = registration.installing || registration.waiting || registration.active;
    if (!worker) return;
    await new Promise((resolve, reject) => {
      function changed() {
        if (!['activated', 'redundant'].includes(worker.state)) return;
        worker.removeEventListener('statechange', changed);
        if (worker.state === 'activated') resolve(); else reject(new Error('Update unavailable'));
      }
      worker.addEventListener('statechange', changed);changed();
    });
  }
  const reloadLogo = () => ios && installed() && document.body.hasAttribute('data-remote');
  if (reloadLogo()) {
    const logo = document.querySelector('.wordmark');
    logo?.setAttribute('aria-label', 'Reload Sapiens4 and check for updates');
    if (logo) logo.title = 'Reload and check for updates';
  }
  document.addEventListener('click', async event => {
    const logo = event.target.closest('.wordmark');
    if (!logo || !reloadLogo()) return;
    // Keep the normal logo handlers from changing the chat before it is saved.
    event.preventDefault();event.stopImmediatePropagation();
    if (reloading) return;
    reloading = true;logo.setAttribute('aria-busy', 'true');
    let timer;
    try {
      window.sapiensWorkspace?.save();
      await Promise.race([updateShell(), new Promise((_, reject) => {
        timer = setTimeout(() => reject(new Error('Update timed out')), 12000);
      })]);
    } catch { /* Offline or failed updates keep the last complete cached shell. */ }
    finally { clearTimeout(timer); }
    window.sapiensWorkspace?.save();
    location.reload();
  }, true);
  function mount() {
    const gate = document.getElementById('mobile-install-gate');
    gate.hidden = !mobile || installed();
    if (gate.hidden) return;
    gate.innerHTML = `<div class="install-card"><span class="install-brand">Sapiens4</span>
      <h1>Add to Home Screen</h1><p>Install to connect your corpora.</p>
      <ol>${ios
        ? '<li>In Safari, tap <strong>Share</strong> <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 15V3m-4 4 4-4 4 4M7 10H5v11h14V10h-2"/></svg></li><li><strong>Add to Home Screen</strong><small>Open as Web App on → Add</small></li>'
        : '<li>In Chrome, tap <strong>⋮</strong></li><li><strong>Install and create shortcut</strong><small>Then tap Install</small></li>'}
        <li>Open <strong>Sapiens4</strong> from Home Screen.</li></ol>
      <button id="install-app" type="button" hidden>Install Sapiens4</button>
      <a href="https://sapiens4.ai/help?q=add2homescreen" target="_blank" rel="noopener noreferrer">Need help? ↗</a></div>`;
    const button = document.getElementById('install-app');
    button.hidden = ios || !installPrompt;
    button.onclick = async () => {
      const prompt = installPrompt; installPrompt = null; button.hidden = true;
      try { await prompt.prompt(); } catch { /* The manual steps remain available. */ }
    };
  }
  window.addEventListener('beforeinstallprompt', event => {
    event.preventDefault(); installPrompt = event; mount();
  });
  return {mount, installed, mobile};
})();
