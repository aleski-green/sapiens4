// Platform access only; installation choices and update lifecycle are PureScript.
export const environment = () => ({userAgent:navigator.userAgent, platform:navigator.platform || '', maxTouchPoints:navigator.maxTouchPoints || 0});
export const installed = () => navigator.standalone === true || window.matchMedia?.('(display-mode: standalone)').matches === true;
export const registration = () => Promise.resolve(navigator.serviceWorker?.getRegistration());
export const update = registration => () => registration.update();
export const workers = registration => () => ({installing:registration.installing, waiting:registration.waiting, active:registration.active});
export const workerState = worker => () => worker.state;
export const onWorkerState = worker => changed => () => { const listener = () => changed(); worker.addEventListener('statechange', listener); return () => worker.removeEventListener('statechange', listener); };
export const prompt = event => () => event.prompt();
export const saveWorkspace = () => { window.sapiensWorkspace?.save(); };
export const reload = () => { location.reload(); };
