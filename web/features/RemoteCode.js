// Standard encoding, URL and crypto bindings; protocol and validation are PureScript.
export const encode64 = value => btoa(value);
export const decode64 = value => () => atob(value);
export const stringInput = value => typeof value === 'string' ? value : null;
export const field = name => value => value?.[name];
export const parseJSON = value => () => JSON.parse(value);
export const parseURL = value => () => { const url = new URL(value); return {origin:url.origin, pathname:url.pathname, search:url.search, username:url.username, password:url.password, hash:url.hash}; };
export const radix36 = value => value.toString(36);
export const parse36 = value => parseInt(value, 36);
export const decodeBytes = value => () => Array.from(atob(value), char => char.charCodeAt(0));
export const encodeBytes = value => Array.from(new TextEncoder().encode(value));
export const digest = bytes => () => crypto.subtle.digest('SHA-256', new Uint8Array(bytes)).then(buffer => Array.from(new Uint8Array(buffer)));
export const device = () => ({userAgent:navigator.userAgent, maxTouchPoints:navigator.maxTouchPoints || 0, installed:navigator.standalone === true || window.matchMedia?.('(display-mode: standalone)').matches === true});
