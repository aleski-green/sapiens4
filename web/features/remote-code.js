/* Compact invitation encoding, not encryption. Device keys and approval secure pairing. */
'use strict';
window.RemoteCode = (() => {
  const protocol = 'sapiens-remote-box-v1';
  const url64 = value => value.replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
  const base64 = value => value.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4-value.length%4)%4);
  function encode(data) {
    return ['s4', url64(btoa(data.relay)), data.room, data.token, data.secret,
      url64(data.desktop), Math.floor(data.expires).toString(36), ...(data.public_id ? [data.public_id] : [])].join('.');
  }
  function decode(text) {
    if (typeof text !== 'string' || text.length > 4096) throw new Error('Use the QR from desktop Connect phone.');
    if (text.trim().startsWith('{')) return JSON.parse(text);
    if (/^https?:\/\//.test(text.trim())) {
      const link = new URL(text.trim());
      const invitation = decode(link.hash.slice(1));
      if (link.origin !== invitation.relay || link.pathname !== '/' || link.search || link.username || link.password)
        throw new Error('Invalid pairing link.');
      return invitation;
    }
    const parts = text.replace(/\s/g, '').split('.');
    if (![7,8].includes(parts.length) || parts[0] !== 's4' ||
        // Accept the original mixed-character suffix in existing QR invitations.
        (parts.length===8 && !/^sapi4_[a-z0-9]{9}$/.test(parts[7])) ||
        !parts.slice(1,6).every(value => /^[A-Za-z0-9_-]+$/.test(value)) ||
        !/^[0-9a-z]{1,10}$/.test(parts[6])) throw new Error('Use the QR from desktop Connect phone.');
    try {
      return {v:protocol, relay:atob(base64(parts[1])), room:parts[2], token:parts[3],
        secret:parts[4], desktop:base64(parts[5]), expires:parseInt(parts[6],36), ...(parts[7] ? {public_id:parts[7]} : {})};
    } catch { throw new Error('Use the QR from desktop Connect phone.'); }
  }
  async function confirmation(desktop, phone, room) {
    const alphabet = 'ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz';
    const context = new TextEncoder().encode('sapiens-confirm-v1\0' + room + '\0');
    const keys = [desktop, phone].map(key => Uint8Array.from(atob(key), c => c.charCodeAt(0)));
    if (keys.some(key => key.length !== 32)) throw new Error('Invalid device key.');
    const input = new Uint8Array(context.length + 64);
    input.set(context); input.set(keys[0], context.length); input.set(keys[1], context.length + 32);
    const hash = new Uint8Array(await crypto.subtle.digest('SHA-256', input));
    let value = Array.from(hash.slice(0, 6)).reduce((n, byte) => n * 256 + byte, 0) % alphabet.length ** 8;
    let code = '';
    for (let i = 0; i < 8; i++) {
      code = alphabet[value % alphabet.length] + code;
      value = Math.floor(value / alphabet.length);
    }
    return code.slice(0, 4) + ' · ' + code.slice(4);
  }
  const link = data => data.relay + '/#' + encode(data);
  return {encode, decode, link, confirmation};
})();
