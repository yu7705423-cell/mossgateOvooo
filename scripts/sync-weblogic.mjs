#!/usr/bin/env node
// 把网页版的纯逻辑 JS 打成一个脚本，交给 JavaScriptCore 跑（docs/jscore-pilot.md）。
//
//   node scripts/sync-weblogic.mjs <网页版仓库目录>
//
// 网页版是原生 ES Modules、没有打包器（网页版 CLAUDE.md 第 9 条），JSContext 却只认普通脚本。
// 这里手写一个最小的 ESM -> 函数作用域转换：每个模块包进一个函数，import / export 改成模块表上的读写。
// 只支持网页版实际用到的写法；遇到不认得的（import.meta、解构导出、动态 import 不在允许表里）直接报错退出，
// 不猜着转。
//
// 产物：Resources/weblogic/reply.bundle.js（不许手改，重跑本脚本）。
// 不进包的模块一律换成「存根」：读到的是一个函数，一调就抛错，错误里写明是哪个模块的哪一项。
// 少数确实要用到的不纯模块（数据库的设置读取）换成 Resources/weblogic/shims.js 里手写的那一份。
//
// 不需要 npm install（无依赖）。

import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const native = path.resolve(here, '..');
const web = process.argv[2];
if (!web || !fs.existsSync(path.join(web, 'src/system/ai/reply.js'))) {
  console.error('用法：node scripts/sync-weblogic.mjs <网页版仓库目录>（目录里要有 src/system/ai/reply.js）');
  process.exit(1);
}

const ENTRY = 'src/system/ai/reply.js';

// 真的打进包的模块：splitReply 一路调到的那几个。它们自己再 import 的东西，不在这张表里就是存根。
// 加一个之前先确认它被调到的那几个函数不碰 db / window / fetch（docs/jscore-pilot.md 的表）。
const REAL = [
  ENTRY,
  'src/system/markfold.js',
  'src/system/ai/think.js',
  'src/system/ai/translate.js',   // compiled / splitInline / transLine：只读 settings.translateFormats
  'src/system/db/defaults.js',    // DEFAULT_SETTINGS，shims.js 的 settings.get() 从这里取默认值
  'src/system/place.js',          // parse
  'src/system/gift.js',           // parse
  'src/system/day.js',            // DONE / DROP 两个常量
  'src/system/reaction.js',       // isEmoji / emojisIn
  'src/system/takeout.js',        // parse
  'src/system/ban.js',
  'src/system/trip.js',           // parse
  'src/system/request.js',        // JOINT / SPEND / CARD / DEPOSIT 常量
  'src/system/pass.js',           // kindByMark
  'src/system/gacha.js',          // rarityByLabel
  'src/system/funcard.js',
  'src/system/closet.js',         // parseOutfit
  'src/system/collect.js',        // parseAcquire
  'src/system/htmlcard.js',       // hasHtml / htmlSegments
  'src/system/statusbar.js',      // lift
  'src/system/innercard.js',      // lift
  'src/system/currency.js',
];

// 换成 shims.js 里手写版本的模块（键是模块路径，shims.js 里 __wlShims 用同一个键）。
const SHIMMED = [
  'src/system/db/index.js',
  'src/system/ai/templates.js',
];

// reply.js 的 materialize 里有四处动态 import（一起听两处、来电、一起看）。那一段不在解析路径上，
// 换成一个调用即失败的 Promise；其余位置出现动态 import 一律报错。
// shims.js 自己要 require 的真模块（入口走不到它们，单独排进队列）
const SHIM_DEPS = ['src/system/db/defaults.js'];

const DYNAMIC_OK = new Set(['src/system/call.js', 'src/system/watch.js', 'src/system/listen.js']);

const fail = msg => { console.error(`sync-weblogic: ${msg}`); process.exit(1); };
const rel = f => path.relative(web, f).split(path.sep).join('/');
const read = id => fs.readFileSync(path.join(web, id), 'utf8');
const resolve = (from, spec) => {
  if (!spec.startsWith('.')) fail(`${from}: 只认相对路径的 import，遇到 '${spec}'`);
  return rel(path.resolve(path.dirname(path.join(web, from)), spec));
};

const isReal = new Set(REAL);
const isShim = new Set(SHIMMED);

let uid = 0;
const tmp = () => `__m${uid++}`;

/** 一个 import 子句 `a, { b as c }, * as d` 拆成若干条 `const` */
function bindings(clause, mod, id) {
  const out = [];
  let c = clause.trim();
  const ns = c.match(/^(?:([A-Za-z_$][\w$]*)\s*,\s*)?\*\s+as\s+([A-Za-z_$][\w$]*)$/);
  if (ns) {
    if (ns[1]) out.push(`const ${ns[1]} = ${mod}.default;`);
    out.push(`const ${ns[2]} = ${mod};`);
    return out;
  }
  const m = c.match(/^(?:([A-Za-z_$][\w$]*)\s*,?\s*)?(?:\{([\s\S]*)\})?$/);
  if (!m) fail(`${id}: 认不出的 import 子句：${c}`);
  if (m[1]) out.push(`const ${m[1]} = ${mod}.default;`);
  if (m[2] != null) {
    for (const part of m[2].split(',').map(s => s.trim()).filter(Boolean)) {
      const p = part.match(/^([A-Za-z_$][\w$]*)(?:\s+as\s+([A-Za-z_$][\w$]*))?$/);
      if (!p) fail(`${id}: 认不出的 import 项：${part}`);
      out.push(`const ${p[2] || p[1]} = ${mod}.${p[1]};`);
    }
  }
  return out;
}

/** 一个模块的源码改成函数体。返回 { body, deps } */
function transform(id, src) {
  const deps = new Set();
  const getters = [];      // [导出名, 表达式]
  const star = [];         // export * from 的模块变量
  if (/\bimport\.meta\b/.test(src)) fail(`${id}: 不支持 import.meta`);

  // 动态 import：只放行允许表里的
  src = src.replace(/\bimport\(\s*(['"])([^'"]+)\1\s*\)/g, (_, q, spec) => {
    const target = resolve(id, spec);
    if (!DYNAMIC_OK.has(target)) fail(`${id}: 动态 import('${spec}') 不在 DYNAMIC_OK 里`);
    return `__wl.dynamicImport(${JSON.stringify(target)})`;
  });
  if (/\bimport\s*\(/.test(src.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, ''))) {
    fail(`${id}: 还有没转换的动态 import（写法不是字面量路径）`);
  }

  const req = spec => {
    const target = resolve(id, spec);
    deps.add(target);
    return `__wl.require(${JSON.stringify(target)})`;
  };

  // import 子句 from '...'（可跨行）
  src = src.replace(/^import\s+([^'";]+?)\s+from\s+(['"])([^'"]+)\2\s*;?/gm, (_, clause, q, spec) => {
    const mod = tmp();
    return [`const ${mod} = ${req(spec)};`, ...bindings(clause, mod, id)].join(' ');
  });
  // import '...'（只为副作用）
  src = src.replace(/^import\s+(['"])([^'"]+)\1\s*;?/gm, (_, q, spec) => `${req(spec)};`);

  // export * from '...'
  src = src.replace(/^export\s+\*\s+from\s+(['"])([^'"]+)\1\s*;?/gm, (_, q, spec) => {
    const mod = tmp(); star.push(mod);
    return `const ${mod} = ${req(spec)};`;
  });
  if (/^export\s+\*\s+as\b/m.test(src)) fail(`${id}: 不支持 export * as`);
  // export { a, b as c } from '...'
  src = src.replace(/^export\s*\{([^}]*)\}\s*from\s+(['"])([^'"]+)\2\s*;?/gm, (_, list, q, spec) => {
    const mod = tmp();
    for (const part of list.split(',').map(s => s.trim()).filter(Boolean)) {
      const p = part.match(/^([A-Za-z_$][\w$]*)(?:\s+as\s+([A-Za-z_$][\w$]*))?$/);
      if (!p) fail(`${id}: 认不出的 export from 项：${part}`);
      getters.push([p[2] || p[1], `${mod}.${p[1]}`]);
    }
    return `const ${mod} = ${req(spec)};`;
  });
  // export { a, b as c }
  src = src.replace(/^export\s*\{([^}]*)\}\s*;?/gm, (_, list) => {
    for (const part of list.split(',').map(s => s.trim()).filter(Boolean)) {
      const p = part.match(/^([A-Za-z_$][\w$]*)(?:\s+as\s+([A-Za-z_$][\w$]*))?$/);
      if (!p) fail(`${id}: 认不出的 export 项：${part}`);
      getters.push([p[2] || p[1], p[1]]);
    }
    return '';
  });
  // export default function / class 名字
  src = src.replace(/^export\s+default\s+((?:async\s+)?function\s*\*?\s*|class\s+)([A-Za-z_$][\w$]*)/gm, (_, kw, name) => {
    getters.push(['default', name]);
    return `${kw}${name}`;
  });
  // export default 表达式
  src = src.replace(/^export\s+default\s+/gm, () => {
    getters.push(['default', '__default']);
    return 'const __default = ';
  });
  // export function / async function / function* / class
  src = src.replace(/^export\s+((?:async\s+)?function\s*\*?\s*|class\s+)([A-Za-z_$][\w$]*)/gm, (_, kw, name) => {
    getters.push([name, name]);
    return `${kw}${name}`;
  });
  // export const / let / var（一行可以声明多个，逐个取名字；解构不支持）
  src = src.replace(/^export\s+(const|let|var)\s+/gm, (all, kw, offset) => {
    const rest = src.slice(offset + all.length);
    if (/^[{[]/.test(rest)) fail(`${id}: 不支持解构导出（export ${kw} { … } = …）`);
    const name = rest.match(/^[A-Za-z_$][\w$]*/)?.[0];
    if (!name) fail(`${id}: 认不出的 export ${kw}`);
    getters.push([name, name]);
    // 同一条声明里逗号后面的名字（`export const a = 1, b = 2`）在网页版里没出现过，碰到就报错
    const stmt = rest.split(/;\s*$|\n(?=\S)/m)[0];
    if (/^[A-Za-z_$][\w$]*\s*=\s*[^,()[\]{}`'"]+,\s*[A-Za-z_$][\w$]*\s*=/.test(stmt)) fail(`${id}: 不支持一条 export ${kw} 里声明多个：${stmt.slice(0, 80)}`);
    return `${kw} `;
  });

  if (/^\s*(import|export)\s/m.test(src)) {
    const line = src.split('\n').find(l => /^\s*(import|export)\s/.test(l));
    fail(`${id}: 还有没转换的 import / export：${line.trim().slice(0, 120)}`);
  }

  // 导出用 getter，放在函数体最前面：函数声明会提升，循环依赖时对方先拿到的也是真函数
  const head = getters.map(([n, e]) => `__wl.bind(__exports, ${JSON.stringify(n)}, () => ${e});`).join('\n');
  const tail = star.map(m => `__wl.star(__exports, ${m});`).join('\n');
  return { body: `${head}\n${src}\n${tail}`, deps };
}

// ---- 从入口走一遍，只展开 REAL 里的
const modules = new Map();
const stubs = new Set();
const queue = [ENTRY, ...SHIM_DEPS];
while (queue.length) {
  const id = queue.shift();
  if (modules.has(id) || stubs.has(id)) continue;
  if (isShim.has(id)) { stubs.add(id); continue; }
  if (!isReal.has(id)) { stubs.add(id); continue; }
  if (!fs.existsSync(path.join(web, id))) fail(`${id} 不存在`);
  const t = transform(id, read(id));
  modules.set(id, t);
  for (const d of t.deps) queue.push(d);
}
for (const id of REAL) if (!modules.has(id)) fail(`REAL 里的 ${id} 从入口走不到，删掉它`);

let commit = 'unknown';
try { commit = execFileSync('git', ['-C', web, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(); } catch {}

const autoStubs = [...stubs].filter(s => !isShim.has(s)).sort();
const out = [];
out.push(`// 由 scripts/sync-weblogic.mjs 生成，不许手改；网页版改了重跑：node scripts/sync-weblogic.mjs <网页版仓库目录>
// 网页版提交：${commit}
// 入口：${ENTRY}
// 打进来的模块（${modules.size}）：
${[...modules.keys()].map(m => `//   ${m}`).join('\n')}
// 换成 shims.js 手写版本的（${SHIMMED.length}）：${SHIMMED.join('、')}
// 存根（${autoStubs.length}，一调就抛错）：
${autoStubs.map(m => `//   ${m}`).join('\n')}
'use strict';
(function () {
  const __wl = globalThis.__wl;
  if (!__wl) throw new Error('weblogic: 先加载 shims.js');
  __wl.commit = ${JSON.stringify(commit)};
  __wl.stubbed(${JSON.stringify(autoStubs)});
`);
for (const [id, t] of modules) {
  out.push(`__wl.define(${JSON.stringify(id)}, function (__exports) {\n'use strict';\n${t.body}\n});\n`);
}
out.push(`})();\n`);

const dir = path.join(native, 'Resources/weblogic');
fs.mkdirSync(dir, { recursive: true });
const file = path.join(dir, 'reply.bundle.js');
fs.writeFileSync(file, out.join('\n'));
console.log(`已生成 ${path.relative(native, file)}：${modules.size} 个模块，${autoStubs.length} 个存根，${fs.statSync(file).size} 字节，网页版 ${commit.slice(0, 10)}`);
