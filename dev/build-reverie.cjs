// Run with NODE_PATH pointing at esbuild, and the LibreChat checkout as argument.
const fs = require('node:fs');
const path = require('node:path');
const esbuild = require('esbuild');
const repo = path.resolve(__dirname, '..');
const source = path.resolve(process.argv[2], 'client/public/assets/reverie/stage.mjs');
const target = path.join(repo, 'Sources/Reverie/ReverieStage.html');
const html = fs.readFileSync(target, 'utf8');
const start = html.indexOf('var ReverieBundled=');
const end = html.indexOf('let stage=null,failed=false;');
if (start < 0 || end < start) throw new Error('Native renderer wrapper changed');
const result = esbuild.buildSync({ entryPoints: [source], bundle: true, format: 'iife', globalName: 'ReverieBundled', minify: true, supported: { 'template-literal': false }, write: false });
fs.writeFileSync(target, html.slice(0, start) + result.outputFiles[0].text + '\n' + html.slice(end));
console.log('Bundled the shared Reverie renderer for offline native use.');
