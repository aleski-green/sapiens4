// ECMAScript regular expressions and URL/Unicode primitives.
export const matches = pattern => flags => value => Array.from(value.matchAll(new RegExp(pattern, flags.includes('g') ? flags : flags + 'g')), m => ({index:m.index,value:m[0],groups:Array.from(m).slice(1)}));
export const test = pattern => flags => value => new RegExp(pattern, flags).test(value);
export const replace = pattern => flags => replacement => value => value.replace(new RegExp(pattern, flags), replacement);
export const url = value => base => { try { return base ? new URL(value, base) : new URL(value); } catch { return null; } };
export const decode = value => { try { return decodeURIComponent(value); } catch { return value; } };
export const encode = value => encodeURIComponent(value);
