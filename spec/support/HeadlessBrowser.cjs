const {chromium, firefox} = require('../../submodules/libs4/node_modules/playwright');

(async () => {
  const [engine, url, message, scale] = process.argv.slice(2);
  const browser = await ({chromium, firefox})[engine].launch({
    headless: process.env.SAPIENS_TEST_HEADED !== '1',
    chromiumSandbox: true,
    args: engine === 'chromium' ? ['--disable-gpu'] : [],
    env: {...process.env, LIBGL_ALWAYS_SOFTWARE: '1',
      ...(process.env.SAPIENS_TEST_HEADED === '1' ? {} : {DBUS_SESSION_BUS_ADDRESS: 'unix:path=/dev/null'})},
  });
  try {
    const page = await browser.newPage({viewport: {width: 1440, height: 960}, deviceScaleFactor: Number(scale)});
    await page.goto(url);
    const draft = page.getByRole('textbox', {name: /^Message /});
    await draft.fill(message);
    await page.getByRole('button', {name: 'Send message', exact: true}).click();
    const reply = page.getByRole('region', {name: 'Agent conversation'}).getByText('Contract test reply', {exact: true});
    await reply.waitFor({state: 'visible'});
    const result = {version: browser.version(), reply: await reply.innerText(), draft: await draft.inputValue()};
    await page.reload();
    await reply.waitFor({state: 'visible'});
    console.log(JSON.stringify({...result, restored: await reply.innerText()}));
  } finally {
    await browser.close();
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
