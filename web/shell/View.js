// DOM lifecycle interop. Component state and rendering stay in PureScript.
const cancellations = new WeakMap();
const roots = new WeakMap();
export const remember = node => cancel => () => { cancellations.set(node, cancel); };
export const rememberRoot = node => cancel => () => { roots.set(node, cancel); };
const cancel = (map, node) => { const action = map.get(node); if (action) { map.delete(node); action(); } };
export const dispose = node => () => {
  for (const child of [node, ...node.querySelectorAll('*')].reverse()) { cancel(cancellations, child); cancel(roots, child); }
};
export const disposeContents = node => () => {
  for (const child of [...node.querySelectorAll('*')].reverse()) { cancel(cancellations, child); cancel(roots, child); }
  cancel(cancellations, node);
};
export const firstElement = node => () => node.firstElementChild;
