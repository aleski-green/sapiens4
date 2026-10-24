// Serialization and DOM lookup bindings only. All task behavior is PureScript.
export const stringify = value => JSON.stringify(value);
export const dateParse = value => Date.parse(value);
export const nullTurn = null;
export const nullableTurn = value => value;
export const requireElement = selector => parent => () => {
  const node = parent.querySelector(selector);
  if (!node) throw new Error(`Missing element: ${selector}`);
  return node;
};
