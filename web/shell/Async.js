export const create = executor => () => new Promise((resolve, reject) => executor(value => () => resolve(value))(error => () => reject(error))());
export const subscribe = promise => resolve => reject => () => { promise.then(value => resolve(value)(), error => reject(error)()); };
