'use strict';
/*
 * iOS 上的 nodejs-mobile 编译时没有 ICU（--with-intl=none），因此：
 *   1. 正则里的 Unicode 属性转义（\p{P}、\p{ID_Start} 等）一出现就是语法错误，整个模块加载失败；
 *   2. 运行期的 TextDecoder 不支持 fatal 选项（由 nodejs/main.js 处理）。
 *
 * 本脚本处理第 1 点：在服务端会加载的 JS 里找出含 \p{…} / \P{…} 的正则字面量，
 * 用 regexpu-core（Babel 同款）展开成等价的显式码点区间，并逐个码点核对展开前后匹配结果一致。
 *
 * 用法：node scripts/tools/patch-no-icu.js <nodejs-project 目录>
 */
const fs = require('fs');
const path = require('path');
const rewritePattern = require('regexpu-core');

const root = path.resolve(process.argv[2] || 'ios/nodejs-project');

// 只在服务端用不到的开发期 / Edge 运行时文件里出现，且是字符串形式（不会在加载时编译）的，跳过
const SKIP = [
  `${path.sep}.next${path.sep}static${path.sep}`,
  `${path.sep}next-devtools${path.sep}`,
  `${path.sep}edge-runtime${path.sep}`,
  `${path.sep}@edge-runtime${path.sep}`,
  `${path.sep}css-loader${path.sep}`,
];

// 正则字面量：/body/flags，body 内允许转义与字符类；要求 body 含 \p{ 或 \P{
const LITERAL = /\/((?:[^\/\\\n\[]|\\.|\[(?:[^\]\\\n]|\\.)*\])+)\/([dgimsuyv]*)/g;

function* walk(dir) {
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    const p = path.join(dir, ent.name);
    if (ent.isDirectory()) yield* walk(p);
    else if (ent.isFile() && (p.endsWith('.js') || p.endsWith('.cjs') || p.endsWith('.mjs'))) yield p;
  }
}

// regexpu-core 自带的 Unicode 数据版本与运行这个脚本的 Node 可能不同：只在一边已分配的码点（另一边是“未分配”Cn），
// 这类差异不是展开错误，允许存在
const UNASSIGNED_IN_REGEXPU = new RegExp(rewritePattern('^\\p{Cn}$', 'u', { unicodePropertyEscapes: 'transform' }), 'u');

const UNASSIGNED_IN_NODE = /^\p{Cn}$/u;

function verify(origSrc, flags, newSrc) {
  const a = new RegExp(origSrc, flags.replace(/[gy]/g, ''));
  const b = new RegExp(newSrc, flags.replace(/[gy]/g, ''));
  // 单字符级别逐码点比较（属性转义只影响单个字符的归类）
  const single = (re) => new RegExp(`^(?:${re.source})$`, re.flags);
  const sa = single(a);
  const sb = single(b);
  for (let cp = 0; cp <= 0x10ffff; cp++) {
    if (cp >= 0xd800 && cp <= 0xdfff) continue;
    const ch = String.fromCodePoint(cp);
    if (sa.test(ch) !== sb.test(ch) || a.test(ch) !== b.test(ch)) {
      if (UNASSIGNED_IN_REGEXPU.test(ch) || UNASSIGNED_IN_NODE.test(ch)) continue;
      throw new Error(`展开后的正则在 U+${cp.toString(16)} 上与原式不一致：/${origSrc}/${flags}`);
    }
  }
}

let filesChanged = 0;
let literalsChanged = 0;
const leftovers = [];

for (const file of walk(root)) {
  if (SKIP.some((s) => file.includes(s))) continue;
  const text = fs.readFileSync(file, 'utf8');
  if (!/\\[pP]\{/.test(text)) continue;

  // 压缩后的代码是一整行，从行首扫描 /…/ 容易和除号、字符串里的斜杠错位配对；
  // 改为从每个 \p{ 出发，向前找最近的、能从那里完整解析成合法正则字面量并覆盖该位置的 /
  const STICKY = new RegExp(LITERAL.source, 'y');
  let out = '';
  let cursor = 0;
  let changed = 0;
  const PROP = /\\[pP]\{/g;
  let m;
  while ((m = PROP.exec(text))) {
    if (m.index < cursor) continue;
    let found = null;
    for (let start = m.index - 1; start >= Math.max(cursor, m.index - 4000); start--) {
      if (text[start] !== '/') continue;
      STICKY.lastIndex = start;
      const lm = STICKY.exec(text);
      if (!lm || start + lm[0].length <= m.index) continue;
      const [whole, body, flags] = lm;
      if (!flags.includes('u') && !flags.includes('v')) continue;
      try { new RegExp(body, flags); } catch { continue; }
      found = { start, whole, body, flags };
      break;
    }
    if (!found) continue;
    const { start, whole, body, flags } = found;
    const expanded = rewritePattern(body, flags, { unicodePropertyEscapes: 'transform' });
    if (/\\[pP]\{/.test(expanded)) throw new Error(`${file}: 未能展开 /${body}/${flags}`);
    verify(body, flags, expanded);
    out += text.slice(cursor, start) + `/${expanded}/${flags}`;
    cursor = start + whole.length;
    PROP.lastIndex = cursor;
    changed++;
  }
  out += text.slice(cursor);

  if (changed) {
    fs.writeFileSync(file, out);
    filesChanged++;
    literalsChanged += changed;
    console.log(`  展开 ${changed} 个属性正则：${path.relative(root, file)}`);
  }
  if (/\/(?:[^\/\n]|\\\/)*\\[pP]\{[^\n]*\/[dgimsuyv]*u/.test(out) && /\\[pP]\{/.test(out)) {
    // 粗查：还残留疑似属性正则字面量
    const m = out.match(/.{0,40}\\[pP]\{[A-Za-z_=]+\}.{0,40}/);
    leftovers.push(`${path.relative(root, file)}: ${m ? m[0] : ''}`);
  }
}

console.log(`patch-no-icu：${filesChanged} 个文件，展开 ${literalsChanged} 个正则`);
if (leftovers.length) {
  console.error('仍有疑似 Unicode 属性正则未处理：\n' + leftovers.join('\n'));
  process.exit(1);
}
