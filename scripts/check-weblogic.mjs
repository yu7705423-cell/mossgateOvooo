#!/usr/bin/env node
// 在 Node 的 vm 里按 JavaScriptCore 的条件跑一遍 Resources/weblogic（docs/jscore-pilot.md）。
//
//   node scripts/check-weblogic.mjs            两个包都查（回复解析一定要有；提示词拼装有就查）
//   node scripts/check-weblogic.mjs reply      只查回复解析：跑样本、核对几项、打印耗时
//   node scripts/check-weblogic.mjs prompt     只查提示词拼装：拿 Tests/Fixtures/data.json 拼一次，核对几项、打印耗时
//   node scripts/check-weblogic.mjs --dump     另外把每条样本的结果、拼出来的提示词打印出来
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
const which = process.argv.slice(2).find(a => !a.startsWith('--')) || 'all';
let bad = 0;
const check = (cond, msg) => { if (!cond) { bad += 1; console.error(`不通过：${msg}`); } };

if (which === 'all' || which === 'reply') {
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
}

// ---- 提示词拼装（docs/jscore-prompt.md）：shims.js + prompt-host.js + prompt.bundle.js，另一个上下文
const promptBundle = path.join(dir, 'prompt.bundle.js');
if (which === 'prompt' && !fs.existsSync(promptBundle)) { console.error('没有 prompt.bundle.js，先跑 sync-weblogic'); process.exit(1); }
if ((which === 'all' || which === 'prompt') && fs.existsSync(promptBundle)) {
  const pctx = vm.createContext({});
  vm.runInContext('delete globalThis.console', pctx);
  for (const g of ['window', 'document', 'console', 'setTimeout', 'fetch', 'localStorage', 'indexedDB', 'TextEncoder', 'structuredClone']) {
    if (vm.runInContext(`typeof ${g}`, pctx) !== 'undefined') throw new Error(`vm 里多了 ${g}`);
  }
  const t0 = process.hrtime.bigint();
  for (const f of ['shims.js', 'prompt-host.js', 'prompt.bundle.js']) {
    vm.runInContext(fs.readFileSync(path.join(dir, f), 'utf8'), pctx, { filename: f });
  }
  const loadMs = Number(process.hrtime.bigint() - t0) / 1e6;
  const P = vm.runInContext('weblogic.prompt', pctx);
  const data = JSON.parse(fs.readFileSync(path.join(root, 'Tests/Fixtures/data.json'), 'utf8'));
  const feed = () => {
    P.reset(1760000100000);
    for (const [k, v] of Object.entries(data)) if (Array.isArray(v)) P.table(k, JSON.stringify(v));
    for (const k of ['settings', 'persona', 'layout']) if (data[k]) P.kv(k, JSON.stringify(data[k]));
  };
  const build = async req => { feed(); return JSON.parse(await P.buildChat(JSON.stringify(req))); };
  const first = await build({ chatId: 'chat_a' });
  check(first.ok, `拼装出错：${first.error}\n${first.stack || ''}`);
  if (first.ok) {
    check(first.system.includes('[你是谁]\nPERSONA_TEXT'), '设定区里有人设');
    check(first.system.includes('LORE_ALWAYS') && !first.system.includes('LORE_OFF') && !first.system.includes('LORE_MISS'), '世界书按开关与关键词');
    check(first.system.includes('2 to 4'), '每轮条数取设置里的 msgMin / msgMax');
    check(first.messages.some(m => m.role === 'user' && m.content.endsWith('你好')), '历史里有用户的那一句');
    check(first.messages.some(m => m.role === 'assistant' && m.content.includes('[图片：一只猫]')), '历史里有角色发的图');
    check(first.failed.length === 0, `有区块构建失败：${first.failed.join('、')}`);
    check(first.stubHits.length === 0, `拼装路径上调到了存根：${first.stubHits.join('、')}`);
    check(first.writes.every(w => w.store === 'chats'), `拼装途中想写别的数据域：${JSON.stringify(first.writes)}`);
    check(first.timers === 0, `拼装途中排了 ${first.timers} 个定时器`);
  }
  // 换一份数据再拼：上一次的表不能留下来（第二次灌的是一段新消息）
  const second = JSON.parse(JSON.stringify(data));
  second.messages = second.messages.map(m => m.id === 'msg_1' ? { ...m, content: '换过的一句' } : m);
  P.reset(1760000100000);
  for (const [k, v] of Object.entries(second)) if (Array.isArray(v)) P.table(k, JSON.stringify(v));
  for (const k of ['settings', 'persona', 'layout']) if (second[k]) P.kv(k, JSON.stringify(second[k]));
  const again = JSON.parse(await P.buildChat(JSON.stringify({ chatId: 'chat_a' })));
  check(again.ok && again.messages.some(m => m.content.endsWith('换过的一句')) && !again.messages.some(m => m.content.endsWith('你好')),
    '重新灌表之后读到的是新的消息（条数相同、内容不同）');
  const missing = await build({ chatId: 'chat_none' });
  check(!missing.ok && /没有这段会话/.test(missing.error), '会话不存在时报错，不抛到宿主');
  if (dump) console.log(JSON.stringify(first, null, 1));
  const n = 50;
  const t1 = process.hrtime.bigint();
  for (let i = 0; i < n; i += 1) await build({ chatId: 'chat_a' });
  const per = Number(process.hrtime.bigint() - t1) / 1e6 / n;
  const kb = (fs.statSync(promptBundle).size / 1024).toFixed(0);
  console.log(`提示词拼装：包 ${kb} KB，加载 ${loadMs.toFixed(0)} ms；data.json 拼 ${n} 次，每次 ${per.toFixed(2)} ms（含灌表）；网页版提交 ${vm.runInContext('__wl.commit', pctx)}`);
}
if (bad) { console.error(`${bad} 项不通过`); process.exit(1); }
console.log('全部通过');
