// Rasterize the original vector master. Run with Node and the sharp package.
// No raster source image is edited. The production avatar is already verified;
// regenerating this file does not update the public agent or native identity.
const path = require('path');
const sharp = require('sharp');
sharp(path.join(__dirname, 'angel-master.svg')).png()
  .toFile(path.join(__dirname, 'angel-avatar.png'))
  .then(result => console.log(JSON.stringify(result)))
  .catch(error => { console.error(error.message); process.exit(1); });
