// Exercise the same encrypted transport through both user-facing entry points.
const {execFileSync} = require('node:child_process');
const path = require('node:path');
for (const mode of ['--link', '--code']) {
  execFileSync(process.execPath, [path.join(__dirname, 'remote.test.cjs'), mode], {stdio: 'inherit'});
}
