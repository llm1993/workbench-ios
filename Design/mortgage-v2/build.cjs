const fs = require('node:fs');
const path = require('node:path');
let html = fs.readFileSync(path.join(__dirname, 'page.template.html'), 'utf8');
for (const [key, file] of [
  ['STYLES', 'styles.css'], ['INTERACTION', 'preview.js'],
  ['CALC', '../../ClipStudio/Resources/Mortgage/calc.js'],
  ['RATES', '../../ClipStudio/Resources/Mortgage/rates.js'],
  ['BRIDGE', '../../ClipStudio/Resources/Mortgage/native-bridge.js'],
]) html = html.replace(`/* ${key} */`, () => fs.readFileSync(path.join(__dirname, file), 'utf8'));
fs.writeFileSync(path.join(__dirname, 'index.html'), html);
console.log('Built iOS mortgage design preview. This is not a simulator capture.');
