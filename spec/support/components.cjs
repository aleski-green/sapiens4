// Loads compiled PureScript components into a deterministic browser host.
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm');
const {JSDOM}=require('../../libs4/node_modules/jsdom');
const root=path.resolve(__dirname,'../..');
function load(context={},modules=[]){
  const window=context.window||context.document?.defaultView||new JSDOM(fs.readFileSync(path.join(root,'web/shell/index.html'),'utf8'),{url:'http://localhost/'}).window;
  Object.assign(context,{window,document:context.document||window.document});
  for(const name of ['Node','Element','HTMLElement','XMLSerializer','Event','CustomEvent','FormData','MutationObserver','URL','URLSearchParams'])context[name]??=window[name];
  Object.assign(context,{setTimeout:context.setTimeout||setTimeout,clearTimeout:context.clearTimeout||clearTimeout,console:context.console||console});
  context.requestAnimationFrame??=fn=>setTimeout(fn,0);
  context.getComputedStyle??=window.getComputedStyle.bind(window);
  context.ResizeObserver??=class{observe(){}disconnect(){}};
  context.SapiensUI=context;
  if(!vm.isContext(context))vm.createContext(context);
  vm.runInContext(fs.readFileSync(path.join(root,'web/shell/components.js'),'utf8'),context);
  for(const module of modules)context.SapiensComponents[module]();
  return context;
}
module.exports={load};
