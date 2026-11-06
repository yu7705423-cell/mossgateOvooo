#!/usr/bin/env node
// 在 Node 的 vm 里按 JavaScriptCore 的条件跑一遍 Resources/weblogic（docs/jscore-pilot.md）。
//
//   node scripts/check-weblogic.mjs            两个包都查（回复解析一定要有；提示词拼装有就查）
//   node scripts/check-weblogic.mjs reply      只查回复解析：跑样本、核对几项、打印耗时
//   node scripts/check-weblogic.mjs prompt     只查提示词拼装：拿 Tests/Fixtures/data.json 拼一次，核对几项、打印耗时
//   node scripts/check-weblogic.mjs --dump     另外把每条样本的结果、拼出来的提示词打印出来
//   node scripts/check-weblogic.mjs prompt --raw <目录>   另拿那个目录里原样（没去注释）的 prompt.bundle.js 跑同一批样本，结果要逐字相同
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
const which = process.argv.slice(2).find((a, i, all) => !a.startsWith('--') && all[i - 1] !== '--raw') || 'all';
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

  // 去过注释的包与原样的包（sync-weblogic 交来的 --raw 目录）：每条样本结果逐字相同
  const rawAt0 = process.argv.indexOf('--raw');
  if (rawAt0 > 0) {
    const rctx = vm.createContext({});
    vm.runInContext('delete globalThis.console', rctx);
    vm.runInContext(fs.readFileSync(path.join(dir, 'shims.js'), 'utf8'), rctx, { filename: 'shims.js' });
    vm.runInContext(fs.readFileSync(path.join(process.argv[rawAt0 + 1], 'reply.bundle.js'), 'utf8'), rctx, { filename: 'reply.bundle.js' });
    const rawParse = vm.runInContext('weblogic.parseReply', rctx);
    let same = 0;
    for (const c of cases) {
      const o = c.settings ? JSON.stringify({ settings: c.settings }) : '';
      const x = vm.runInContext('weblogic.parseReply', ctx)(c.raw, o), y = rawParse(c.raw, o);
      if (x === y) same += 1; else check(false, `${JSON.stringify(c.raw)}：去过注释的包与原样的包结果不同`);
    }
    console.log(`去注释对照：${same} / ${cases.length} 条样本逐字相同`);
  }

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

/** 一个新的上下文里加载三份脚本，boot 好。bundleDir 给了就从那里取 prompt.bundle.js（--raw 对照用） */
async function openPrompt(bundleDir = dir) {
  const pctx = vm.createContext({});
  vm.runInContext('delete globalThis.console', pctx);
  for (const g of ['window', 'document', 'console', 'setTimeout', 'fetch', 'localStorage', 'indexedDB', 'TextEncoder', 'structuredClone']) {
    if (vm.runInContext(`typeof ${g}`, pctx) !== 'undefined') throw new Error(`vm 里多了 ${g}`);
  }
  const t0 = process.hrtime.bigint();
  for (const [f, d] of [['shims.js', dir], ['prompt-host.js', dir], ['prompt.bundle.js', bundleDir]]) {
    vm.runInContext(fs.readFileSync(path.join(d, f), 'utf8'), pctx, { filename: f });
  }
  const P = vm.runInContext('weblogic.prompt', pctx);
  await P.boot();
  const loadMs = Number(process.hrtime.bigint() - t0) / 1e6;
  if (!P.isReady()) throw new Error('boot 没有完成');
  return { P, ctx: pctx, loadMs };
}
const fixture = name => JSON.parse(fs.readFileSync(path.join(root, 'Tests/Fixtures', name), 'utf8'));
const KVS = ['settings', 'persona', 'layout'];
/** 整表灌一份备份（原生第一次灌表、导入之后的做法） */
const fullFeed = (P, data) => {
  P.begin(null);
  P.clearAll();
  for (const [k, v] of Object.entries(data)) if (Array.isArray(v)) P.replace(k, JSON.stringify(v));
  for (const k of KVS) if (data[k]) P.kv(k, JSON.stringify(data[k]));
};
const build = async (P, req, now) => { P.begin(now); return JSON.parse(await P.buildChat(JSON.stringify(req))); };
// 对照时不比耗时
const comparable = r => JSON.stringify({ ...r, ms: undefined });

const SCENARIOS = [
  ['data.json', { chatId: 'chat_a' }, 1760000100000],
  ['webprompt-rich.json', { chatId: 'chat_r' }, 1760000000000 + 45 * 60000],
  ['webprompt-rich.json', { chatId: 'chat_r', excludeTurn: 'turn_r9' }, 1760000000000 + 45 * 60000],
  ['webprompt-avatar.json', { chatId: 'chat_v' }, 1760000000000 + 20 * 60000],
];

if ((which === 'all' || which === 'prompt') && fs.existsSync(promptBundle)) {
  const { P, loadMs } = await openPrompt();
  const data = fixture('data.json');
  const now = 1760000100000;
  fullFeed(P, data);
  const first = await build(P, { chatId: 'chat_a' }, now);
  check(first.ok, `拼装出错：${first.error}\n${first.stack || ''}`);
  if (first.ok) {
    check(first.system.includes('[你是谁]\nPERSONA_TEXT'), '设定区里有人设');
    check(first.system.includes('LORE_ALWAYS') && !first.system.includes('LORE_OFF') && !first.system.includes('LORE_MISS'), '世界书按开关与关键词');
    check(first.system.includes('2 to 4'), '每轮条数取设置里的 msgMin / msgMax');
    check(first.messages.some(m => m.role === 'user' && m.content.endsWith('你好')), '历史里有用户的那一句');
    check(first.messages.some(m => m.role === 'assistant' && m.content.includes('[图片：一只猫]')), '历史里有角色发的图');
    check(first.failed.length === 0, `有区块构建失败：${first.failed.join('、')}`);
    check(first.stubHits.length === 0, `拼装路径上调到了存根：${first.stubHits.join('、')}`);
    check(first.timers === 0, `拼装途中排了 ${first.timers} 个定时器`);
    // 写：头像看过了（我没有头像，记成 '-'），只交改了的字段
    const w = first.changes.find(c => c.store === 'chats' && c.id === 'chat_a');
    check(first.changes.length === 1 && w && w.op === 'patch' && w.set.seenAvatar === '-' && w.unset.length === 0
      && Object.keys(w.set).sort().join() === 'seenAvatar,updatedAt', `拼装途中的写：${JSON.stringify(first.changes)}`);
  }
  // 常驻表：写回原生之前，表里已经是写过的那一份；宿主照原生库重灌那一行之后，下一轮照旧
  const again0 = await build(P, { chatId: 'chat_a' }, now);
  check(again0.ok && again0.changes.length === 0, `同一行第二次不再写：${JSON.stringify(again0.changes)}`);

  // 增量：改一条、删一条、加一条，结果与一个新上下文整表灌的相同
  const changed = JSON.parse(JSON.stringify(data));
  changed.messages = changed.messages.map(m => m.id === 'msg_1' ? { ...m, content: '换过的一句' } : m);
  P.upsert('messages', JSON.stringify(changed.messages.filter(m => m.id === 'msg_1')));
  const inc1 = await build(P, { chatId: 'chat_a' }, now);
  check(inc1.ok && inc1.messages.some(m => m.content.endsWith('换过的一句')) && !inc1.messages.some(m => m.content.endsWith('你好')),
    '只交改过的那一行之后读到的是新的（条数相同、内容不同）');
  const extra = { id: 'msg_4', createdAt: data.messages[2].createdAt + 1000, updatedAt: data.messages[2].createdAt + 1000, chatId: 'chat_a',
    role: 'user', authorId: 'me', kind: 'text', content: '新来的一句', status: 'done' };
  changed.messages.push(extra);
  P.upsert('messages', JSON.stringify([extra]));
  const gone = JSON.parse(P.remove('messages', JSON.stringify(['msg_2'])));
  check(gone.join() === 'chat_a', `删掉的消息报出所在会话：${gone}`);
  changed.messages = changed.messages.filter(m => m.id !== 'msg_2');
  changed.settings = { ...changed.settings, msgMin: 1, msgMax: 3 };
  P.kv('settings', JSON.stringify(changed.settings));
  changed.chats = changed.chats.map(c => ({ ...c, seenAvatar: '-' }));
  P.upsert('chats', JSON.stringify(changed.chats));
  const inc = await build(P, { chatId: 'chat_a' }, now);
  const fresh = await openPrompt();
  fullFeed(fresh.P, changed);
  const full = await build(fresh.P, { chatId: 'chat_a' }, now);
  { const x = comparable(inc), y = comparable(full); let k = 0; while (k < x.length && x[k] === y[k]) k += 1;
    check(inc.ok && full.ok && x === y, `增量灌表与整表灌的结果不同（第 ${k} 字起）\n增量：${x.slice(k - 200, k + 300)}\n整表：${y.slice(k - 200, k + 300)}`); }
  check(inc.system.includes('1 to 3'), 'kv 换了之后读到新的设置');
  check(P.trimChat('chat_a', 2) === 1 && P.chatCount('chat_a') === 2, 'trimChat 只留最近几条');
  check(P.dropChat('chat_a') === 2 && P.chatCount('chat_a') === 0, 'dropChat 拿掉整段会话');

  const missing = await build(P, { chatId: 'chat_none' }, now);
  check(!missing.ok && /没有这段会话/.test(missing.error), '会话不存在时报错，不抛到宿主');

  // 换头像：第一轮说一次并记下，宿主把写交回去之后第二轮不再说
  const av = await openPrompt();
  fullFeed(av.P, fixture('webprompt-avatar.json'));
  const a1 = await build(av.P, { chatId: 'chat_v' }, SCENARIOS[3][2]);
  const said = r => r.ok && (r.system + r.messages.map(x => x.content).join('\n')).includes('[对方的头像]');
  check(said(a1) && JSON.stringify(a1.messages).includes('几乎全黑'), `换了头像的那一轮说一次：${a1.error || ''}`);
  const aw = a1.changes.find(c => c.store === 'chats');
  check(aw && aw.set.seenAvatar === 'img_new' && !('unknownChatField' in aw.set), `只写 seenAvatar 与 updatedAt：${JSON.stringify(a1.changes)}`);
  const a2 = await build(av.P, { chatId: 'chat_v' }, SCENARIOS[3][2]);
  check(a2.ok && !said(a2), '第二轮不再说');

  // 各份备份都拼得出、没有失败的区块
  for (const [name, req, at] of SCENARIOS) {
    const s = await openPrompt();
    fullFeed(s.P, fixture(name));
    const r = await build(s.P, req, at);
    check(r.ok && r.failed.length === 0 && r.stubHits.length === 0, `${name} ${JSON.stringify(req)}：${r.error || r.failed.join('、') || r.stubHits.join('、')}`);
    if (dump) console.log(name, JSON.stringify(r, null, 1));
  }

  // 去过注释的包与原样的包（sync-weblogic 交来的 --raw 目录）：同一批样本结果逐字相同
  const rawAt = process.argv.indexOf('--raw');
  if (rawAt > 0) {
    const rawDir = process.argv[rawAt + 1];
    for (const [name, req, at] of SCENARIOS) {
      const a = await openPrompt(), b = await openPrompt(rawDir);
      fullFeed(a.P, fixture(name)); fullFeed(b.P, fixture(name));
      const x = await build(a.P, req, at), y = await build(b.P, req, at);
      check(comparable(x) === comparable(y), `${name} ${JSON.stringify(req)}：去过注释的包与原样的包结果不同`);
    }
    const a = await openPrompt(), b = await openPrompt(rawDir);
    console.log(`去注释对照：${SCENARIOS.length} 份样本逐字相同；加载 ${a.loadMs.toFixed(0)} ms（原样 ${b.loadMs.toFixed(0)} ms）`);
  }

  // 耗时：data.json 常驻之后每拼一次（不灌表）与每次整表重灌
  const n = 50;
  let t1 = process.hrtime.bigint();
  for (let i = 0; i < n; i += 1) await build(P, { chatId: 'chat_a' }, now);
  const per = Number(process.hrtime.bigint() - t1) / 1e6 / n;
  fullFeed(P, data);
  t1 = process.hrtime.bigint();
  for (let i = 0; i < n; i += 1) { fullFeed(P, data); await build(P, { chatId: 'chat_a' }, now); }
  const perFull = Number(process.hrtime.bigint() - t1) / 1e6 / n;
  const kb = (fs.statSync(promptBundle).size / 1024).toFixed(0);
  console.log(`提示词拼装：包 ${kb} KB，加载 ${loadMs.toFixed(0)} ms；data.json 拼 ${n} 次，常驻 ${per.toFixed(2)} ms/次，整表重灌 ${perFull.toFixed(2)} ms/次；网页版提交 ${vm.runInContext('__wl.commit', fresh.ctx)}`);
}
if (bad) { console.error(`${bad} 项不通过`); process.exit(1); }
console.log('全部通过');
