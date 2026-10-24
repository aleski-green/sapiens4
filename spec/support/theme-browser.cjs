// Browser actions and observations only. Theme expectations live in RSpec.
const fs = require('node:fs');
const {JSDOM} = require('../../libs4/node_modules/jsdom');
const mode = process.argv[2];
const dom = new JSDOM('<button data-theme-toggle></button><button data-theme-toggle></button>', {url:'https://sapiens.example', runScripts:'outside-only'});
const w = dom.window, d = w.document;
const system = new w.EventTarget(); system.matches = mode === 'system-dark';
w.matchMedia = () => system;
if (mode === 'stored-dark') w.localStorage.setItem('sapi-color-theme', 'dark');
if (mode === 'unavailable-storage') Object.defineProperty(w, 'localStorage', {get(){throw new Error('Unavailable');}});
const source = fs.readFileSync('web/theme/sapi-theme.js', 'utf8');
const snapshot = () => ({theme:d.documentElement.dataset.theme, colorScheme:d.documentElement.style.colorScheme,
  buttons:Array.from(d.querySelectorAll('button'), b => ({text:b.textContent, label:b.getAttribute('aria-label'), title:b.title, pressed:b.getAttribute('aria-pressed')}))});
w.eval(source);
const initial = snapshot();
d.querySelector('button').click();
const clicked = snapshot();
system.matches = !system.matches; system.dispatchEvent(new w.Event('change'));
const systemWithPreference = snapshot();
w.dispatchEvent(new w.StorageEvent('storage', {key:'sapi-color-theme',newValue:null}));
const cleared = snapshot();
system.matches = !system.matches; system.dispatchEvent(new w.Event('change'));
const systemAfterClear = snapshot();
w.eval(source);d.querySelector('button').click();
const reloaded = snapshot();
console.log(JSON.stringify({initial,clicked,systemWithPreference,cleared,systemAfterClear,reloaded,
  stored:mode === 'unavailable-storage' ? null : w.localStorage.getItem('sapi-color-theme')}));
w.close();
