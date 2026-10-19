/* Installation guidance is presentation only: no keys or invitations are exported. */
'use strict';
window.RemoteInstall = (() => {
  const display = window.matchMedia?.('(display-mode: standalone)');
  const installed = () => navigator.standalone === true || display?.matches === true;
  const appleMobile = /iPad|iPhone|iPod/.test(navigator.userAgent) ||
    (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
  const route = location.pathname.replace(/^\/+|\/+$/g, '');
  const platform = ['ios', 'android', 'mac', 'windows'].includes(route) ? route :
    appleMobile ? 'ios' : /Android/.test(navigator.userAgent) ? 'android' :
    /Mac/.test(navigator.platform) ? 'mac' : /Win/.test(navigator.platform) ? 'windows' : 'desktop';
  const ios = platform === 'ios';
  const mobile = ios || platform === 'android';
  const label = {ios: 'iPhone & iPad', android: 'Android', mac: 'Mac', windows: 'Windows', desktop: 'your computer'}[platform];
  const action = mobile ? 'Add to Home Screen' : 'Install Sapiens4';
  const steps = {
    ios: '<li>In Safari, tap <strong>Share</strong>. It may be inside the <strong>•••</strong> menu.</li><li>Choose <strong>Add to Home Screen</strong>, keep <strong>Open as Web App</strong> on, then tap <strong>Add</strong>.</li>',
    android: '<li>In Chrome, open the <strong>⋮</strong> menu and choose <strong>Install and create shortcut</strong> or <strong>Add to Home screen</strong>.</li><li>Choose <strong>Install</strong>, confirm, then open Sapiens4 from its icon.</li>',
    mac: '<li>In Safari, choose <strong>File → Add to Dock</strong>, then <strong>Add</strong>.</li><li>In Chrome, use the <strong>Install</strong> icon in the address bar. Open Sapiens4 from its app icon.</li>',
    windows: '<li>In Chrome or Edge, use the <strong>Install</strong> icon in the address bar and confirm installation.</li><li>Open Sapiens4 from the <strong>Start menu</strong>.</li>',
    desktop: '<li>In Chrome or Edge, use the <strong>Install</strong> icon in the address bar and confirm installation.</li><li>You can also keep using Sapiens4 in this browser.</li>',
  }[platform];
  const share = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 15V3m-4 4 4-4 4 4M7 10H5v11h14V10h-2"/></svg>';
  const plus = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" aria-hidden="true"><rect x="3" y="3" width="18" height="18" rx="4"/><path d="M12 7v10M7 12h10"/></svg>';
  const icon = '<img src="/app-icon-180.png" alt="" width="72" height="72">';

  let installPrompt=null;
  window.addEventListener('beforeinstallprompt',event=>{event.preventDefault();installPrompt=event;});
  function show(paired) {
    if(installPrompt){const pending=installPrompt;installPrompt=null;pending.prompt();return;}
    if (installed() || document.getElementById('install-guide')) return;
    const dialog = document.createElement('dialog');
    dialog.id = 'install-guide';
    dialog.className = 's4-install';
    dialog.setAttribute('aria-labelledby', 'install-title');
    dialog.innerHTML = `
      <div class="install-top"><span id="install-title">SAPIENS4 FOR ${label.toUpperCase()}</span><button type="button" class="install-close" aria-label="Close installation guide">×</button></div>
      <div class="install-track" aria-roledescription="carousel" aria-label="Install Sapiens4" tabindex="0">
        <article class="install-slide" role="group" aria-roledescription="slide" aria-label="1 of 3">
          <div class="install-art install-home" aria-hidden="true"><div class="install-orbit"></div><div class="install-phone"><div class="install-island"></div><div class="install-grid"><i></i><i></i><i></i><i></i><i></i><i></i><div class="install-app">${icon}<span>Sapiens4</span></div><i></i><i></i><i></i><i></i><i></i></div><div class="install-dock"><i></i><i></i><i></i></div></div><span class="install-sticker">One tap. Your CORPORA.</span></div>
          <div class="install-copy"><span class="install-kicker">01 / MAKE IT YOURS</span><h2>Your Sapis.<br>Right at home.</h2><p>Install Sapiens4 on ${label}. Open your CORPORA in its own app window, whenever you need it.</p></div>
        </article>
        <article class="install-slide" role="group" aria-roledescription="slide" aria-label="2 of 3">
          <div class="install-art install-share" aria-hidden="true"><div class="install-share-sheet"><div class="install-share-heading">${icon}<div><strong>Sapiens4</strong><span>Your CORPORA, on ${label}</span></div></div><div class="install-share-row">${plus}<strong>${action}</strong><span>›</span></div>${ios ? '<div class="install-toggle-row">Open as Web App <i></i></div>' : ''}</div><div class="install-safari-bar"><span>‹</span><span class="install-address">Sapiens4</span><span class="install-share-highlight">${ios ? share : plus}</span><span>•••</span></div></div>
          <div class="install-copy"><span class="install-kicker">02 / ${action.toUpperCase()}</span><h2>A little shortcut.<br>A lot closer.</h2><ol>${steps}</ol><p class="install-hint">${ios ? 'Can’t see the option? Scroll down the Share menu, or enable it in Edit Actions.' : mobile ? 'Open Sapiens4 from its Home Screen icon before connecting.' : 'Installation is optional on desktop.'}</p></div>
        </article>
        <article class="install-slide" role="group" aria-roledescription="slide" aria-label="3 of 3">
          <div class="install-art install-connect" aria-hidden="true"><div class="install-app-large">${icon}<span>Sapiens4</span></div><div class="install-connection"><i></i><i></i><i></i></div><div class="install-desktop"><div><span>CORPORA</span><strong>Your Sapis, together.</strong><span class="install-trust">✓ Trusted device</span></div></div></div>
          <div class="install-copy"><span class="install-kicker">03 / CONNECT ONCE</span><h2>Open. Approve.<br>You’re home.</h2><p>Open Sapiens4 from its app icon. Scan or upload the QR from the host computer’s corpora menu → <strong>New Pairing</strong>. Approve the matching code there.</p><p class="install-hint">${paired ? (ios ? 'Already connected in Safari? The Home Screen app needs its own one-time approval. ' : 'If the installed app asks to connect again, approve it on your host computer. ') : ''}After approval, the app remembers your CORPORA until you revoke it. Your host computer needs to be online. Only one remote device can be connected at a time.</p></div>
        </article>
      </div>
      <div class="install-bottom"><div class="install-progress"><div class="install-dots" aria-label="Guide pages"><button type="button" aria-label="Page 1" aria-current="step"></button><button type="button" aria-label="Page 2"></button><button type="button" aria-label="Page 3"></button></div><span class="install-counter" aria-live="polite">1 / 3</span></div><div class="install-actions"><button type="button" class="install-back" hidden>Back</button><button type="button" class="install-next">Show me how <span aria-hidden="true">→</span></button></div><p class="install-platform">${mobile ? 'Swipe through · No app store download needed' : 'Connect from your browser or install the web app'}</p></div>`;
    document.body.append(dialog);
    const track = dialog.querySelector('.install-track');
    const slides = [...dialog.querySelectorAll('.install-slide')];
    const dots = [...dialog.querySelectorAll('.install-dots button')];
    const next = dialog.querySelector('.install-next'), back = dialog.querySelector('.install-back');
    let page = 0;
    function select(index, scroll = true) {
      page = Math.max(0, Math.min(2, index));
      dots.forEach((dot, i) => i === page ? dot.setAttribute('aria-current', 'step') : dot.removeAttribute('aria-current'));
      slides.forEach((slide, i) => slide.setAttribute('aria-hidden', String(i !== page)));
      dialog.querySelector('.install-counter').textContent = `${page + 1} / 3`;
      back.hidden = page === 0;
      next.textContent = ['Show me how →', 'Next →', 'Got it'][page];
      if (scroll) track.scrollTo({left: page * track.clientWidth, behavior: window.matchMedia?.('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth'});
    }
    next.addEventListener('click', () => page === 2 ? dialog.close() : select(page + 1));
    back.addEventListener('click', () => select(page - 1));
    dots.forEach((dot, i) => dot.addEventListener('click', () => select(i)));
    track.addEventListener('scroll', () => {
      if (track.clientWidth) select(Math.round(track.scrollLeft / track.clientWidth), false);
    }, {passive: true});
    dialog.addEventListener('keydown', event => {
      if (event.key === 'ArrowRight' || event.key === 'ArrowLeft') {
        event.preventDefault(); select(page + (event.key === 'ArrowRight' ? 1 : -1));
      }
    });
    dialog.querySelector('.install-close').addEventListener('click', () => dialog.close());
    dialog.addEventListener('close', () => dialog.remove(), {once: true});
    select(0, false);
    dialog.showModal();
  }

  function mount(paired = false) {
    document.getElementById('install-entry')?.remove();
    if (installed()) {
      document.getElementById('install-guide')?.close();
      return;
    }
    const entry = document.createElement('div');
    entry.id = 'install-entry';
    if (paired) entry.className = 'install-workspace';
    entry.innerHTML = `<button type="button">${paired ? plus : ''}<span>${action}</span></button>`;
    entry.querySelector('button').addEventListener('click', () => show(paired));
    if (paired) document.querySelector('.sidebar-bottom')?.prepend(entry);
    else document.querySelector('main')?.append(entry);
  }
  display?.addEventListener('change', () => mount(!!window.sapiensRemote));
  return {mount, show, installed, mobile:appleMobile || /Android/.test(navigator.userAgent)};
})();
if(document.body.classList.contains('pairing-page'))RemoteInstall.mount();
