// Vectrex palette backend, adapted from the Asteroids Sharp path.
// Raw RGBA input avoids source-profile conversion. build_art.py handles alpha,
// palette limits, validation and VART packaging.
const fs = require('node:fs');
const sharp = require('sharp');

async function main() {
  const [input, output, widthText, heightText, budgetText] = process.argv.slice(2);
  const width = Number(widthText), height = Number(heightText), budget = Number(budgetText);
  if (!input || !output || !Number.isInteger(width) || !Number.isInteger(height) ||
      width < 1 || height < 1 || !Number.isInteger(budget) || budget < 2 || budget > 256) {
    throw new Error('Usage: node quantize_art.cjs IN.rgba OUT.rgb WIDTH HEIGHT COLOURS');
  }
  if (!sharp.versions.imagequant) throw new Error('Sharp has no libimagequant backend');
  const material = fs.readFileSync(input);
  if (material.length !== width * height * 4) throw new Error('Raw input size mismatch');
  let hasClear = false;
  for (let p = 0; p < width * height; p++) {
    // Both optical materials receive full RGB weight. Only clear pixels carry
    // zero importance; their RGB is canonical black in the authored planes.
    const clear = material[p * 4 + 3] === 0;
    hasClear ||= clear;
    material[p * 4 + 3] = clear ? 0 : 255;
  }
  const rgb = Buffer.alloc(width * height * 3);
  const used = new Set();
  for (let quality = 100; quality >= 0; quality--) {
    const png = await sharp(material, {raw: {width, height, channels: 4}})
      .png({palette: true, colours: budget, quality, dither: 0, effort: 10})
      .toBuffer();
    const rgba = await sharp(png).ensureAlpha().raw().toBuffer();
    used.clear();
    // Clear pixels contribute canonical black, regardless of hidden source RGB.
    if (hasClear) used.add(0);
    for (let p = 0; p < width * height; p++) {
      if (material[p * 4 + 3] === 0) continue;
      used.add((rgba[p * 4] << 16) | (rgba[p * 4 + 1] << 8) | rgba[p * 4 + 2]);
      // Further pixels cannot reduce the number of distinct colors.
      if (used.size > budget) break;
    }
    // Some libvips/Sharp builds round the requested PNG palette capacity up.
    // Check decoded pixels, including clear black, rather than trusting options.
    if (used.size <= budget) {
      for (let p = 0; p < width * height; p++) {
        if (material[p * 4 + 3] === 0) continue;
        rgb[p * 3] = rgba[p * 4];
        rgb[p * 3 + 1] = rgba[p * 4 + 1];
        rgb[p * 3 + 2] = rgba[p * 4 + 2];
      }
      fs.writeFileSync(output, rgb);
      console.log(JSON.stringify({quality, rgbColours: used.size, dither: 0,
        sharp: sharp.versions.sharp, imagequant: sharp.versions.imagequant}));
      return;
    }
  }
  throw new Error(`libimagequant did not fit the ${budget}-colour RGB budget`);
}
main().catch(error => {console.error(error.message); process.exitCode = 1;});
