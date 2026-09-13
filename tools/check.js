// Repository checks — what CI runs on every pull request, and what you can run locally:
//
//   npm test
//
//   * every .js file parses (node --check)
//   * package.json parses and its scripts point at files that exist
//   * the panel's inline script parses
//   * both i18n dictionaries carry exactly the same keys
//   * every key the panel asks for exists in both languages
//
// No dependencies, no network: it must work on a clean checkout.
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { execFileSync } = require('child_process');

const root = path.join(__dirname, '..');
const problems = [];
const fail = (what, detail) => problems.push(what + (detail ? ': ' + detail : ''));

// ---------- javascript ----------
const SKIP = new Set(['node_modules', '.git', 'build', 'out', 'assets']);
function jsFiles(dir) {
  const out = [];
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (SKIP.has(e.name)) continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) out.push(...jsFiles(p));
    else if (e.name.endsWith('.js')) out.push(p);
  }
  return out;
}
const files = jsFiles(root);
for (const f of files) {
  try { execFileSync(process.execPath, ['--check', f], { stdio: 'pipe' }); }
  catch (e) { fail('syntax ' + path.relative(root, f), String(e.stderr || e.message).split('\n').slice(0, 3).join(' ')); }
}

// ---------- package.json ----------
let pkg = null;
try { pkg = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8')); }
catch (e) { fail('package.json', e.message); }
if (pkg) {
  for (const [name, cmd] of Object.entries(pkg.scripts || {})) {
    const m = /^node\s+([\w./-]+)/.exec(cmd);
    if (m && !fs.existsSync(path.join(root, m[1]))) fail('script "' + name + '" runs a missing file', m[1]);
  }
  if (pkg.main && !fs.existsSync(path.join(root, pkg.main))) fail('package.json main is missing', pkg.main);
}

// ---------- panel.html ----------
const html = fs.readFileSync(path.join(root, 'panel.html'), 'utf8');
const script = /<script>([\s\S]*?)<\/script>\s*<\/body>/.exec(html) || /<script>([\s\S]*)<\/script>/.exec(html);
if (!script) fail('panel.html', 'no inline <script> found');
else {
  try { new vm.Script(script[1], { filename: 'panel.html' }); }
  catch (e) { fail('panel.html script', e.message); }
}

// ---------- i18n ----------
const ctx = { window: {}, navigator: { language: 'en' } };
vm.createContext(ctx);
try { vm.runInContext(fs.readFileSync(path.join(root, 'i18n.js'), 'utf8'), ctx); }
catch (e) { fail('i18n.js', e.message); }
const i18n = ctx.window.i18n;
if (!i18n) fail('i18n.js', 'does not expose window.i18n');
else {
  const ru = new Set(i18n.keys('ru'));
  const en = new Set(i18n.keys('en'));
  for (const k of ru) if (!en.has(k)) fail('key missing in English', k);
  for (const k of en) if (!ru.has(k)) fail('key missing in Russian', k);

  const used = new Set();
  for (const m of html.matchAll(/data-i18n(?:-title)?="([^"]+)"/g)) used.add(m[1]);
  for (const m of html.matchAll(/\bt\('([^']+)'/g)) if (!m[1].endsWith('.')) used.add(m[1]);
  // keys the host sends as identifiers rather than literals in the markup
  for (const m of fs.readFileSync(path.join(root, 'main.js'), 'utf8').matchAll(/sessionHint\('([^']+)'\)/g)) used.add('a.' + m[1]);
  for (const k of used) {
    for (const lang of ['ru', 'en']) {
      i18n.setLang(lang);
      if (i18n.t(k) === k) fail('panel uses an unknown key (' + lang + ')', k);
    }
  }
  console.log('i18n: ' + ru.size + ' keys × 2 languages, ' + used.size + ' used by the panel');
}

console.log('checked ' + files.length + ' js files');
if (problems.length) {
  console.error('\n' + problems.length + ' problem(s):');
  for (const p of problems) console.error('  - ' + p);
  process.exit(1);
}
console.log('all good');
