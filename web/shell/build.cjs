/* Compile application sources; dependency manifests and caches live in libs4. */
const fs = require('node:fs');
const path = require('node:path');
const {execFileSync} = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const outputIndex = process.argv.indexOf('--output-dir');
const destinationRoot = outputIndex === -1 ? root : path.resolve(process.argv[outputIndex + 1]);
const deps = path.join(root, 'libs4/purescript');
const bin = path.join(root, 'libs4/node_modules/.bin');
const env = {...process.env, PATH: bin + path.delimiter + process.env.PATH};
const run = (name, args, options = {}) => {
  // Invoke pinned binaries directly; Windows cannot exec npm's .cmd shims.
  const command = name === 'spago' ? process.execPath : require('../../libs4/node_modules/purescript');
  const arguments_ = name === 'spago' ? [path.join(root, 'libs4/node_modules/spago/bin/bundle.js'), ...args] : args;
  return execFileSync(command, arguments_, {cwd: deps, env, stdio:'inherit', ...options});
};
run('spago', ['fetch']);
const sources = JSON.parse(run('spago', ['sources', '--json'], {stdio:['ignore','pipe','inherit'], encoding:'utf8'}));
fs.mkdirSync(path.join(deps, 'output'), {recursive:true});
const development = process.argv.includes('--development');
const compiled = development ? path.join(deps, 'output/development') : fs.mkdtempSync(path.join(deps, 'output/build-'));
const entries = {
  'Sapiens.Relays':'web/features/relay-servers.js',
  'Sapiens.ConnectionsApp':'web/features/corpora.js',
  'Sapiens.Transport':'web/features/remote-transport.js',
  'Sapiens.Onboarding':'web/features/remote-onboarding.js',
  'Sapiens.Application':'web/shell/application.js',
  'Sapiens.Components':'web/shell/components.js',
  'Sapiens.Text':'web/shell/text-format.js',
  'Sapiens.Tasks':'web/features/task-ui.js',
  'Sapiens.Panes':'web/shell/panel-layout.js',
  'Sapiens.Theme':'web/theme/sapi-theme.js',
  'Sapiens.ServiceWorker':'web/shell/sw.js',
  'Sapiens.RemoteCode':'web/features/remote-code.js',
  'Sapiens.RemoteInstall':'web/features/remote-install.js',
  'Sapiens.RemoteSession':'web/features/remote-session.js',
};
try {
  // A fresh output directory prevents deleted modules from surviving in a release.
  run('purs', ['compile', ...sources.filter(source => !source.startsWith('test/') && !source.startsWith('src/')),
    path.join(root, 'web/**/*.purs'), '--output', compiled]);
  const bundles = [];
  for (const [module, destination] of Object.entries(entries)) {
    const result = require('../../libs4/node_modules/esbuild').buildSync({
      stdin:{contents:`import {main} from ${JSON.stringify(path.join(compiled, module, 'index.js'))}; main();`,resolveDir:root},
      bundle:true, platform:'browser', format:'iife', target:['safari16','chrome109'],
      define:{__SAPIENS_BRAND_SVG__:JSON.stringify(fs.readFileSync(path.join(root,'web/shell/favicon.svg'),'utf8').trim())},
      banner:{js:'// Generated from PureScript by web/shell/build.cjs. Do not edit.'},
      outfile:path.join(destinationRoot,destination), write:false, legalComments:'eof', minify:true,
    });
    bundles.push(...result.outputFiles);
  }
  // No checked-in asset changes until every entrypoint has compiled and bundled.
  for (const bundle of bundles) {
    fs.mkdirSync(path.dirname(bundle.path), {recursive:true});
    fs.writeFileSync(bundle.path, bundle.contents);
  }
} finally {
  if (!development) fs.rmSync(compiled, {recursive:true, force:true});
}
