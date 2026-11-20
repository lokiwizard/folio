const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
function copy(source, destination) {
  const target = path.join(root, 'assets', destination);
  fs.mkdirSync(path.dirname(target), {recursive: true});
  fs.cpSync(path.resolve(root, source), target, {recursive: true});
}
const pdf = 'node_modules/pdfjs-dist/';
for (const name of ['cmaps', 'iccs', 'standard_fonts', 'wasm', 'web/images', 'web/pdf_viewer.css', 'web/pdf_viewer.mjs', 'LICENSE']) copy(pdf + name, 'pdf/' + name);
for (const name of ['pdf', 'pdf.worker', 'pdf.renderer']) copy(pdf + 'build/' + name + '.min.mjs', 'pdf/build/' + name + '.mjs');
for (const name of ['qpdf.js', 'qpdf.wasm', 'LICENSE']) copy('node_modules/@jspawn/qpdf-wasm/' + name, 'qpdf/' + name);
copy('node_modules/fabric/dist/index.min.mjs', 'fabric.mjs');
copy('node_modules/fabric/LICENSE', 'fabric-LICENSE');
copy('../Resources/Math', 'math');
// Reuse the Mac reader's Markdown/KaTeX parser without its WebKit sizing bridge.
const mathFile=path.join(root,'assets/math/answer.js');
const mathSource=fs.readFileSync(mathFile,'utf8');
const parser=mathSource.slice(mathSource.indexOf('let previousFormulas'),mathSource.indexOf('function renderAnswer'));
if(!parser.includes('function appendMarkdown'))throw Error('Math answer renderer changed');
fs.writeFileSync(path.join(root,'assets/math/render.mjs'),parser+'\nexport function renderMath(text,node){const part=document.createDocumentFragment();const formulas=new Map();appendMarkdown(text,part,formulas,true);node.replaceChildren(part);previousFormulas=formulas;}\n');
