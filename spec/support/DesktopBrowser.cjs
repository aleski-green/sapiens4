const {chromium, firefox} = require('../../submodules/libs4/node_modules/playwright');

(async () => {
  const [engine, url] = process.argv.slice(2);
  const wayland = process.env.XDG_SESSION_TYPE === 'wayland';
  const server = await ({chromium, firefox})[engine].launchServer({
    headless: false, chromiumSandbox: true,
    executablePath: process.env[`SAPIENS_TEST_${engine.toUpperCase()}_EXECUTABLE`],
    channel: process.env[`SAPIENS_TEST_${engine.toUpperCase()}_CHANNEL`],
    args: engine === 'chromium' ? [`--ozone-platform=${wayland ? 'wayland' : 'x11'}`, '--force-renderer-accessibility', '--disable-gpu'] : [],
    firefoxUserPrefs: {'accessibility.force_disabled': -1},
    env: {...process.env, MOZ_ENABLE_WAYLAND: wayland ? '1' : '0', ACCESSIBILITY_ENABLED: '1', LIBGL_ALWAYS_SOFTWARE: '1'},
  });
  try {
    const browser = await ({chromium, firefox})[engine].connect(server.wsEndpoint());
    const page = await browser.newPage();
    await page.goto(url);
    console.log(`READY ${server.process().pid} ${browser.version()}`);
    process.stdin.resume();
    await new Promise(resolve => process.stdin.on('end', resolve));
  } finally {
    await server.close();
  }
})().catch(error => {console.error(error); process.exitCode = 1;});
