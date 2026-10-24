// Regenerate the checked-in Windows icon from the same SVG used by the web/macOS app.
// Requires Node.js and sharp (npm ci --prefix libs4 --ignore-scripts).
const fs = require('node:fs');
const path = require('node:path');
const sharp = require('../libs4/node_modules/sharp');

(async () => {
  const svg = fs.readFileSync(path.join(__dirname, '../web/shell/favicon.svg'), 'utf8');
  const sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256];
  for (const [name, artwork] of [['AppIcon.ico', svg], ['AppIconDark.ico', svg.replace('fill="#fff"', 'fill="#171717"')]]) {
    const frames = await Promise.all(sizes.map(size => sharp(Buffer.from(artwork), { density: 768 }).resize(size, size).png().toBuffer()));
    const header = Buffer.alloc(6 + 16 * sizes.length);
    header.writeUInt16LE(1, 2);
    header.writeUInt16LE(sizes.length, 4);
    let offset = header.length;
    frames.forEach((frame, index) => {
      const entry = 6 + index * 16;
      header[entry] = header[entry + 1] = sizes[index] % 256;
      header.writeUInt16LE(1, entry + 4);
      header.writeUInt16LE(32, entry + 6);
      header.writeUInt32LE(frame.length, entry + 8);
      header.writeUInt32LE(offset, entry + 12);
      offset += frame.length;
    });
    fs.writeFileSync(path.join(__dirname, name), Buffer.concat([header, ...frames]));
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
