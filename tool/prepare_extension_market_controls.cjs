// Export controls used inline in the approved React prototype, without tracing.
// Run: node tool/prepare_extension_market_controls.cjs <prototype directory>
const fs = require('node:fs');
const path = require('node:path');
const {createRequire} = require('node:module');
const source = path.resolve(process.argv[2] || 'docs/design/extension-market-v2/prototype');
const load = createRequire(path.join(source, 'package.json'));
const React = load('react');
const {renderToStaticMarkup} = load('react-dom/server');
async function main() {
const packageRoot = path.dirname(load.resolve('@phosphor-icons/react/package.json'));
const controls = {
  close: ['X', 'regular'], upload: ['UploadSimple', 'regular'],
  download: ['DownloadSimple', 'regular'], 'file-plus': ['FilePlus', 'regular'],
  'folder-plus': ['FolderPlus', 'regular'], paperclip: ['Paperclip', 'regular'],
  pencil: ['PencilSimple', 'regular'], info: ['Info', 'regular'],
  'caret-down': ['CaretDown', 'regular'], 'search-light': ['MagnifyingGlass', 'light'],
  'plus-light': ['Plus', 'light'], 'gear-light': ['GearSix', 'light'],
};
const target = path.resolve(__dirname, '../assets/icons/extension_market/detail');
fs.mkdirSync(target, {recursive:true});
for (const [name, [component, weight]] of Object.entries(controls)) {
  const icons = await import(require('node:url').pathToFileURL(path.join(packageRoot, 'dist/ssr', `${component}.es.js`)).href);
  const svg = renderToStaticMarkup(React.createElement(icons[component], {size:64, weight, color:'#191919'}));
  fs.writeFileSync(path.join(target, `${name}.svg`), `${svg}\n`);
}
console.log(`Exported ${Object.keys(controls).length} prototype control SVGs.`);
}
main().catch(error => { console.error(error.message); process.exitCode = 1; });
