#!/usr/bin/env node
// 把网页版的纯逻辑 JS 打成脚本，交给 JavaScriptCore 跑（docs/jscore-pilot.md、docs/jscore-prompt.md）。
//
//   node scripts/sync-weblogic.mjs <网页版仓库目录>            两个都打
//   node scripts/sync-weblogic.mjs <网页版仓库目录> reply      只打回复解析
//   node scripts/sync-weblogic.mjs <网页版仓库目录> prompt     只打提示词拼装
//   --no-strip   不去注释与缩进（查问题时看原样的代码）
//
// 默认去掉注释与缩进（scripts/jsstrip.mjs，省一半以上的体积与加载时间）。去之前后各做一次语法检查，
// 再由 check-weblogic 拿同一批样本对照去过的与原样的两份包，结果逐字相同才用去过的那一份，否则用原样的并报警告。
//
// 网页版是原生 ES Modules、没有打包器（网页版 CLAUDE.md 第 9 条），JSContext 却只认普通脚本。
// 这里手写一个最小的 ESM -> 函数作用域转换：每个模块包进一个函数，import / export 改成模块表上的读写。
// 只支持网页版实际用到的写法；遇到不认得的（解构导出、一条 export 声明多个）直接报错退出，不猜着转。
//
// 两个产物（都不许手改，重跑本脚本；都不进本仓库，见 .gitignore）：
//
// - reply.bundle.js：回复解析。白名单：只打 REAL 里的 22 个模块，其余一律是存根。
// - prompt.bundle.js：提示词拼装。黑名单：从入口走到的模块全部原样打进来，只有 PROMPT_STUB 里的是存根
//   （界面、网络、媒体这些拼提示词用不到、在 JSContext 里也跑不起来的），存储那一层（db/idb.js）换成
//   Resources/weblogic/prompt-host.js 里手写的内存表。网页版加了新的区块、新的能力，下一次打包自动带进来。
//
// 存根：读到的每一项都是一个函数，一调就抛错，错误里写明是哪个模块的哪一项。
//
// 不需要 npm install（无依赖）。

import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import vm from 'node:vm';
import { strip } from './jsstrip.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const native = path.resolve(here, '..');
const web = process.argv[2];
const only = process.argv.slice(3).find(a => !a.startsWith('--')) || 'all';
const stripOn = !process.argv.includes('--no-strip');
if (!web || !fs.existsSync(path.join(web, 'src/system/ai/reply.js'))) {
  console.error('用法：node scripts/sync-weblogic.mjs <网页版仓库目录> [reply|prompt]（目录里要有 src/system/ai/reply.js）');
  process.exit(1);
}

// ---- 回复解析（docs/jscore-pilot.md）

const REPLY = {
  name: 'reply',
  file: 'reply.bundle.js',
  entries: ['src/system/ai/reply.js'],
  // 真的打进包的模块：splitReply 一路调到的那几个。它们自己再 import 的东西，不在这张表里就是存根。
  // 加一个之前先确认它被调到的那几个函数不碰 db / window / fetch（docs/jscore-pilot.md 的表）。
  real: [
    'src/system/ai/reply.js',
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
  ],
  // 换成 shims.js 里手写版本的模块（键是模块路径，shims.js 里 __wlShims 用同一个键）。
  shimmed: ['src/system/db/index.js', 'src/system/ai/templates.js'],
  // shims.js 自己要 require 的真模块（入口走不到它们，单独排进队列）
  shimDeps: ['src/system/db/defaults.js'],
  // reply.js 的 materialize 里有四处动态 import（一起听两处、来电、一起看）。那一段不在解析路径上，
  // 换成一个调用即失败的 Promise；其余位置出现动态 import 一律报错。
  dynamicOk: new Set(['src/system/call.js', 'src/system/watch.js', 'src/system/listen.js']),
};

// ---- 提示词拼装（docs/jscore-prompt.md）

const PROMPT = {
  name: 'prompt',
  file: 'prompt.bundle.js',
  // engine.js 里的 buildChatSystem / buildHistory / historyWindow，context/lorebook.js 的 activate，
  // context/memory.js 的 recall，presets.js 的 within。宿主入口在 prompt-host.js 的 weblogic.buildChat
  entries: ['src/system/ai/engine.js', 'src/system/presets.js', 'src/system/db/schema.js'],
  real: null,   // 黑名单模式：走到的全打进来
  // 存储那一层：IndexedDB 换成宿主灌进来的内存表（prompt-host.js）。db/index.js、collection.js 都是网页版原样的
  shimmed: ['src/system/db/idb.js'],
  shimDeps: [],
  // 存根：拼提示词用不到、在 JSContext 里也跑不起来的。加一个之前先确认拼装路径上不调它（check-weblogic 会报调到的存根）
  stub: [
    'vendor/preact-htm.mjs',        // 界面
    'src/lib.js',
    'vendor/qrcode-generator.mjs',
    'src/icons/paths.js',
    'src/icons/solar.js',
    'src/system/ai/providers/index.js',   // 网络：请求次数与记账留在原生的 AIService（原生规约第 10、15 条）
    'src/system/ai/queue.js',
    'src/system/ai/sse.js',
  ],
  // 动态 import 一律不展开：包里有那个模块就给它，没有就是被拒的 Promise。拼装路径上不该有（tasks/day.js 这类在 streamReply 里，不在这里）
  dynamicOk: 'lazy',
  // engine.js 里没导出、streamReply 拼上下文时调的两个小函数：扫描窗口的正文、各块的注入预算
  expose: { 'src/system/ai/engine.js': ['scanTextOf', 'budgets'] },
};

const fail = msg => { console.error(`sync-weblogic: ${msg}`); process.exit(1); };
const rel = f => path.relative(web, f).split(path.sep).join('/');
const read = id => fs.readFileSync(path.join(web, id), 'utf8');
const resolve = (from, spec) => {
  if (!spec.startsWith('.')) fail(`${from}: 只认相对路径的 import，遇到 '${spec}'`);
  return rel(path.resolve(path.dirname(path.join(web, from)), spec));
};

let uid = 0;
const tmp = () => `__m${uid++}`;

/**
 * 一个 import 子句 `a, { b as c }, * as d` 拆成若干条声明。
 *
 * 具名 import 不是加载时取一次值就完：循环依赖里对方可能还没执行到那一行（const 还在暂时性死区），
 * ES 模块里这没关系（绑定是活的，用的时候才读），这里照样读会抛 ReferenceError。所以写成
 * `let b = __wl.live(mod, 'b', v => { b = v; })`：读得到就是它；读不到（对方还没执行完）先是 undefined，
 * 对方执行完时补上。网页版从不给 import 进来的名字赋值（ES 模块里那是语法错误），改成 let 不影响别的。
 */
function bindings(clause, mod, id) {
  const out = [];
  const one = (local, key) => `let ${local} = __wl.live(${mod}, ${JSON.stringify(key)}, v => { ${local} = v; });`;
  let c = clause.trim();
  const ns = c.match(/^(?:([A-Za-z_$][\w$]*)\s*,\s*)?\*\s+as\s+([A-Za-z_$][\w$]*)$/);
  if (ns) {
    if (ns[1]) out.push(one(ns[1], 'default'));
    out.push(`const ${ns[2]} = ${mod};`);
    return out;
  }
  const m = c.match(/^(?:([A-Za-z_$][\w$]*)\s*,?\s*)?(?:\{([\s\S]*)\})?$/);
  if (!m) fail(`${id}: 认不出的 import 子句：${c}`);
  if (m[1]) out.push(one(m[1], 'default'));
  if (m[2] != null) {
    for (const part of m[2].split(',').map(s => s.trim()).filter(Boolean)) {
      const p = part.match(/^([A-Za-z_$][\w$]*)(?:\s+as\s+([A-Za-z_$][\w$]*))?$/);
      if (!p) fail(`${id}: 认不出的 import 项：${part}`);
      out.push(one(p[2] || p[1], p[1]));
    }
  }
  return out;
}

/** 一个模块的源码改成函数体。返回 { body, deps } */
function transform(id, src, target) {
  const deps = new Set();
  const getters = [];      // [导出名, 表达式]
  const star = [];         // export * from 的模块变量
  const lazy = target.dynamicOk === 'lazy';
  if (/\bimport\.meta\b/.test(src)) {
    if (!lazy) fail(`${id}: 不支持 import.meta`);
    src = src.replace(/\bimport\.meta\b/g, `__wl.meta(${JSON.stringify(id)})`);
  }

  // 动态 import：回复解析只放行允许表里的；提示词拼装一律换成「包里有就给，没有就拒」
  src = src.replace(/\bimport\(\s*(['"])([^'"]+)\1\s*\)/g, (_, q, spec) => {
    const t = resolve(id, spec);
    if (!lazy && !target.dynamicOk.has(t)) fail(`${id}: 动态 import('${spec}') 不在 dynamicOk 里`);
    return `__wl.dynamicImport(${JSON.stringify(t)})`;
  });
  const bare = src.replace(/\/\/.*$/gm, '').replace(/\/\*[\s\S]*?\*\//g, '');
  // 提示词拼装那一包里剩下的 import(（多半在字符串里）不动：普通脚本里 import() 也是合法写法，真走到了是被拒的 Promise
  if (!lazy && /(^|[^.\w$])import\s*\(/.test(bare)) fail(`${id}: 还有没转换的动态 import（写法不是字面量路径）`);

  const req = spec => {
    const t = resolve(id, spec);
    deps.add(t);
    return `__wl.require(${JSON.stringify(t)})`;
  };

  // import 子句 from '...'（可跨行）
  src = src.replace(/^import\s+([^'";]+?)\s+from\s+(['"])([^'"]+)\2\s*;?/gm, (_, clause, q, spec) => {
    const mod = tmp();
    return [`const ${mod} = ${req(spec)};`, ...bindings(clause, mod, id)].join(' ');
  });
  // import '...'（只为副作用）
  src = src.replace(/^import\s+(['"])([^'"]+)\1\s*;?/gm, (_, q, spec) => `${req(spec)};`);

  // export * as 名字 from '...'
  src = src.replace(/^export\s+\*\s+as\s+([A-Za-z_$][\w$]*)\s+from\s+(['"])([^'"]+)\2\s*;?/gm, (_, name, q, spec) => {
    const mod = tmp();
    getters.push([name, mod]);
    return `const ${mod} = ${req(spec)};`;
  });
  // export * from '...'
  src = src.replace(/^export\s+\*\s+from\s+(['"])([^'"]+)\1\s*;?/gm, (_, q, spec) => {
    const mod = tmp(); star.push(mod);
    return `const ${mod} = ${req(spec)};`;
  });
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
  // export const / let / var（解构不支持）
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

  // 模块里没导出、宿主入口要调的几个（target.expose）：只是多挂一个 getter，代码本身不动
  for (const n of target.expose?.[id] || []) {
    if (!new RegExp(`^(?:async\\s+)?(?:function\\s*\\*?\\s*|const\\s+|let\\s+)${n}\\b`, 'm').test(src)) fail(`${id}: expose 里的 ${n} 在模块顶层找不到`);
    if (getters.some(([g]) => g === n)) fail(`${id}: ${n} 已经导出了，从 expose 里删掉`);
    getters.push([n, n]);
  }

  // 导出用 getter，放在函数体最前面：函数声明会提升，循环依赖时对方先拿到的也是真函数
  const head = getters.map(([n, e]) => `__wl.bind(__exports, ${JSON.stringify(n)}, () => ${e});`).join('\n');
  const tail = star.map(m => `__wl.star(__exports, ${m});`).join('\n');
  return { body: `${head}\n${src}\n${tail}`, deps };
}

function bundle(target) {
  const isReal = target.real ? new Set(target.real) : null;
  const isShim = new Set(target.shimmed);
  const isStub = new Set(target.stub || []);
  const modules = new Map();
  const stubs = new Set();
  const queue = [...target.entries, ...target.shimDeps];
  while (queue.length) {
    const id = queue.shift();
    if (modules.has(id) || stubs.has(id)) continue;
    if (isShim.has(id) || isStub.has(id) || (isReal && !isReal.has(id))) { stubs.add(id); continue; }
    if (!fs.existsSync(path.join(web, id))) fail(`${id} 不存在`);
    const t = transform(id, read(id), target);
    modules.set(id, t);
    for (const d of t.deps) queue.push(d);
  }
  if (isReal) for (const id of isReal) if (!modules.has(id)) fail(`${target.name}：real 里的 ${id} 从入口走不到，删掉它`);
  for (const id of isStub) if (!stubs.has(id)) console.warn(`sync-weblogic: ${target.name}：stub 里的 ${id} 从入口走不到，可以删掉`);

  let commit = 'unknown';
  try { commit = execFileSync('git', ['-C', web, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(); } catch {}

  const autoStubs = [...stubs].filter(s => !isShim.has(s)).sort();
  const out = [];
  out.push(`// 由 scripts/sync-weblogic.mjs 生成，不许手改；网页版改了重跑：node scripts/sync-weblogic.mjs <网页版仓库目录>
// 网页版提交：${commit}
// 入口：${target.entries.join('、')}
// 打进来的模块（${modules.size}）：
${[...modules.keys()].map(m => `//   ${m}`).join('\n')}
// 换成手写版本的（${target.shimmed.length}）：${target.shimmed.join('、')}
// 存根（${autoStubs.length}，一调就抛错）：
${autoStubs.map(m => `//   ${m}`).join('\n')}
'use strict';
(function () {
  const __wl = globalThis.__wl;
  if (!__wl) throw new Error('weblogic: 先加载 shims.js');
  __wl.commit = ${JSON.stringify(commit)};
  __wl.stubbed(${JSON.stringify(autoStubs)});
`);
  const raw = [...out];
  const syntax = (id, body) => {
    try { new vm.Script(`(function (__exports) {\n'use strict';\n${body}\n})`, { filename: id }); return null; }
    catch (e) { return e.message; }
  };
  for (const [id, t] of modules) {
    const wrap = body => `__wl.define(${JSON.stringify(id)}, function (__exports) {\n'use strict';\n${body}\n});\n`;
    raw.push(wrap(t.body));
    let body = t.body;
    if (stripOn) {
      const before = syntax(id, t.body);
      if (before) fail(`${id}: 转换之后语法不对：${before}`);
      try { body = strip(t.body); } catch (e) { fail(`${id}: 去注释失败：${e.message}`); }
      const after = syntax(id, body);
      if (after) fail(`${id}: 去注释之后语法不对：${after}（jsstrip 认错了这个模块里的某种写法，修 scripts/jsstrip.mjs，或者先用 --no-strip）`);
    }
    out.push(wrap(body));
  }
  out.push(`})();\n`);
  raw.push(`})();\n`);

  const dir = path.join(native, 'Resources/weblogic');
  fs.mkdirSync(dir, { recursive: true });
  const file = path.join(dir, target.file);
  const rawText = raw.join('\n');
  fs.writeFileSync(file, stripOn ? out.join('\n') : rawText);
  const size = fs.statSync(file).size;
  if (stripOn) {
    // 原样的那一份放在临时目录（不进 Resources，不随 app 打包），交给 check-weblogic 对照
    const rawDir = fs.mkdtempSync(path.join(os.tmpdir(), 'weblogic-raw-'));
    fs.writeFileSync(path.join(rawDir, target.file), rawText);
    try {
      execFileSync(process.execPath, [path.join(here, 'check-weblogic.mjs'), target.name, '--raw', rawDir], { stdio: 'inherit' });
      console.log(`去注释：${rawText.length} 字符 -> ${out.join('\n').length} 字符（${Buffer.byteLength(rawText)} -> ${size} 字节）`);
    } catch {
      console.warn(`::warning::sync-weblogic：${target.name} 去过注释的包没有通过对照，改用原样的那一份`);
      fs.writeFileSync(file, rawText);
    }
    fs.rmSync(rawDir, { recursive: true, force: true });
  }
  console.log(`已生成 ${path.relative(native, file)}：${modules.size} 个模块，${autoStubs.length} 个存根，${fs.statSync(file).size} 字节，网页版 ${commit.slice(0, 10)}`);
}

for (const t of [REPLY, PROMPT]) if (only === 'all' || only === t.name) bundle(t);
