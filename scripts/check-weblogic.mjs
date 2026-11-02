#!/usr/bin/env node
// 在 Node 的 vm 里按 JavaScriptCore 的条件跑一遍 Resources/weblogic（docs/jscore-pilot.md）。
//
//   node scripts/check-weblogic.mjs            跑样本、核对几项、打印耗时
//   node scripts/check-weblogic.mjs --dump     另外把每条样本的结果打印出来
//
// vm.createContext({}) 给的是一套全新的 ES 内建对象，没有 window、document、console、setTimeout、fetch，
// 和 app 里的 JSContext 一样。样本与 WebLogicTests 共用 Tests/Fixtures/weblogic-cases.json。

import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const dir = path.join(root, 'Resources/weblogic');
const dump = process.argv.includes('--dump');

const ctx = vm.createContext({});
// V8 的新上下文自带 console，JSContext 没有
vm.runInContext('delete globalThis.console', ctx);
for (const f of ['shims.js', 'reply.bundle.js']) {
  vm.runInContext(fs.readFileSync(path.join(dir, f), 'utf8'), ctx, { filename: f });
}
// JSContext 里没有的东西，这里也不许有
for (const g of ['window', 'document', 'console', 'setTimeout', 'fetch', 'localStorage', 'indexedDB']) {
  if (vm.runInContext(`typeof ${g}`, ctx) !== 'undefined') throw new Error(`vm 里多了 ${g}`);
}

const parse = (raw, opts) => JSON.parse(vm.runInContext('weblogic.parseReply', ctx)(raw, opts ? JSON.stringify(opts) : ''));

let bad = 0;
const check = (cond, msg) => { if (!cond) { bad += 1; console.error(`不通过：${msg}`); } };

const { cases } = JSON.parse(fs.readFileSync(path.join(root, 'Tests/Fixtures/weblogic-cases.json'), 'utf8'));
for (const c of cases) {
  const r = parse(c.raw, c.settings ? { settings: c.settings } : null);
  check(r.ok, `${JSON.stringify(c.raw)} 抛错：${r.error}`);
  if (dump) console.log(JSON.stringify(c.raw), '=>', JSON.stringify(r.ok ? r.parts : r.error));
}

// 几项抽查（与 ReplyParserTests 同一条规则）
const p = raw => parse(raw).parts;
check(JSON.stringify(p('你好\n\n今天怎么样\n嗯').map(x => x.text)) === '["你好","今天怎么样","嗯"]', '每行一条');
check(p('好啊[图片：一只猫]真可爱').map(x => x.type).join() === 'text,image,text', '行中间的图片');
check(p('[语音：你好（译文：hello）]')[0]?.translation === 'hello', '语音里的译文');
check(p('说错了\n[撤回]\n重说')[0]?.recall === true, '撤回挂到上一条');
check(parse('<think>先想想</think>嗯').think === '先想想', '思考段');
check(p('[时间：2026-10-13 12:00]\n在呢')[0]?.stamp, '时间戳挂在第一条');
check(p('[转账：52 奶茶]')[0]?.amount === 52, '转账金额');
check(parse('今天天气很好。'.repeat(12), { settings: { autoSplitAt: 0 } }).parts.length === 1, 'autoSplitAt 为 0 不切');
check(p('今天天气很好。'.repeat(12)).length > 1, '默认按 40 字切');

const hits = vm.runInContext('__wl.stubHits.slice()', ctx);
check(hits.length === 0, `解析路径上调到了存根：${hits.join('、')}`);

// 耗时：2000 行的回复解析 200 次（Node 有 JIT，app 里的 JSContext 没有，真机会慢得多）
const lines = [];
for (let i = 0; i < 2000; i += 1) {
  lines.push(i % 10 === 3 ? `[图片：第${i}张]` : i % 10 === 7 ? `[语音：第${i}句（译文：line ${i}）]` : `这是第${i}行，随便说点什么。`);
}
const big = lines.join('\n');
const fn = vm.runInContext('weblogic.parseReply', ctx);
const t0 = process.hrtime.bigint();
let n = 0;
for (let i = 0; i < 200; i += 1) n += JSON.parse(fn(big, '')).parts.length;
const ms = Number(process.hrtime.bigint() - t0) / 1e6;
console.log(`${cases.length} 条样本；2000 行 x 200 次：${ms.toFixed(0)} ms（每次 ${(ms / 200).toFixed(2)} ms，共 ${n} 条）`);
console.log(`网页版提交：${vm.runInContext('weblogic.commit()', ctx)}`);

if (bad) { console.error(`${bad} 项不通过`); process.exit(1); }
console.log('全部通过');
