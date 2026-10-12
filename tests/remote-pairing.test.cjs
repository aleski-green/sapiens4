// Exercise the same encrypted transport through code entry, fresh links, and links opened in an existing tab.
const {execFileSync} = require('node:child_process');
const path = require('node:path');
for (const mode of ['--link', '--code', '--hash']) {
  execFileSync(process.execPath, [path.join(__dirname, 'remote.test.cjs'), mode], {stdio: 'inherit'});
}
