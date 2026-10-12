/* Compact invitation encoding, not encryption. Device keys and approval secure pairing. */
'use strict';
window.RemoteCode = (() => {
  const protocol = 'sapiens-remote-box-v1';
  const url64 = value => value.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const base64 = value => value.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4-value.length%4)%4);
  function encode(data) {
    return ['s4', url64(btoa(data.relay)), data.room, data.token, data.secret,
      url64(data.desktop), Math.floor(data.expires).toString(36)].join('.');
  }
  function decode(text) {
    if (typeof text !== 'string' || text.length > 4096) throw new Error('Paste a valid pairing code from desktop.');
    if (/^https?:\/\//.test(text.trim())) {
      const link = new URL(text.trim());
      const invitation = decode(link.hash.slice(1));
      if (link.origin !== invitation.relay || link.pathname !== '/' || link.search || link.username || link.password)
        throw new Error('Invalid pairing link.');
      return invitation;
    }
    const parts = text.replace(/\s/g, '').split('.');
    if (parts.length !== 7 || parts[0] !== 's4' ||
        !parts.slice(1,6).every(value => /^[A-Za-z0-9_-]+$/.test(value)) ||
        !/^[0-9a-z]{1,10}$/.test(parts[6])) throw new Error('Paste a valid pairing code from desktop.');
    try {
      return {v:protocol, relay:atob(base64(parts[1])), room:parts[2], token:parts[3],
        secret:parts[4], desktop:base64(parts[5]), expires:parseInt(parts[6],36)};
    } catch { throw new Error('Paste a valid pairing code from desktop.'); }
  }
  const link = data => data.relay + '/#' + encode(data);
  return {encode, decode, link};
})();
