#!/usr/bin/env node
// 用网页版自己的代码记一本账，写成 Tests/Fixtures/ledger-web.json 与 ledger-web-expected.json（LedgerTests 读它们）。
//
//   node scripts/sync-weblogic.mjs <网页版仓库目录> prompt     先打提示词拼装的包（ledger.js 等都在里面）
//   TZ=UTC node scripts/make-ledger-fixture.mjs
//
// 数据（账本、账户、流水、固定入账、转账、外卖、申请、亲属卡、娱乐卡、门禁卡、票券、会员卡）全部由网页版的
// ledger.js、transfer.js、takeout.js、request.js、funcard.js、pass.js、ticket.js、member.js 在 Node 的 vm 里生成，
// 不在这里手写；之后再用网页版的代码算出余额、合计、收支、构成、亲属卡额度、注入的那一段与几种卡的状态，写进 ledger-web-expected.json。
// 测的是「原生版读网页版记下的账，算出来的和网页版一样」。时区一律 UTC（测试里同样钉成 UTC）。

import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

if (process.env.TZ !== 'UTC') { console.error('请用 TZ=UTC 运行'); process.exit(1); }
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const dir = path.join(root, 'Resources/weblogic');
if (!fs.existsSync(path.join(dir, 'prompt.bundle.js'))) { console.error('没有 prompt.bundle.js，先跑 sync-weblogic <网页版目录> prompt'); process.exit(1); }

const ctx = vm.createContext({});
vm.runInContext('delete globalThis.console', ctx);
for (const f of ['shims.js', 'prompt-host.js', 'prompt.bundle.js']) vm.runInContext(fs.readFileSync(path.join(dir, f), 'utf8'), ctx, { filename: f });
const P = vm.runInContext('weblogic.prompt', ctx);
await P.boot();
const req = id => vm.runInContext('__wl', ctx).require(id);
const at = s => Date.parse(s);

const t0 = at('2026-09-10T12:00:00Z');
P.begin(t0);
P.clearAll();
P.replace('personas', JSON.stringify([{ id: 'me_root', createdAt: t0 - 1e6, updatedAt: t0 - 1e6, name: '小于', parentId: null }]));
P.replace('characters', JSON.stringify([{ id: 'char_a', createdAt: t0 - 1e6, updatedAt: t0 - 1e6, name: '林', webOnlyField: { keep: true } }]));
P.replace('chats', JSON.stringify([{ id: 'chat_a', createdAt: t0 - 1e6, updatedAt: t0 - 1e6, characterIds: ['char_a'], personaId: 'me_root', lastMessageAt: t0 - 1e6 }]));
P.kv('settings', JSON.stringify({ activePersonaId: 'me_root', currency: 'CNY' }));

const L = req('src/system/ledger.js');
const T = req('src/system/transfer.js');
const K = req('src/system/takeout.js');
const R = req('src/system/request.js');
const F = req('src/system/funcard.js');
const S = req('src/system/pass.js');
const Tk = req('src/system/ticket.js');
const M = req('src/system/member.js');
const db = req('src/system/db/index.js');

// 一步一个时刻：消息按 createdAt 排，同一毫秒的两条顺序说不清
let clock = t0;
const step = (min = 1) => { clock += min * 60000; P.begin(clock); return clock; };

const book = L.create({ name: '和林一起记账', kind: 'play', chatId: 'chat_a', start: 1000 });
const mine = L.defaultFor(book.id, 'me');
const hers = L.defaultFor(book.id, 'char');
step(); L.seed(book.id, hers.id, 500);
step(); L.add({ bookId: book.id, accountId: mine.id, amount: -35.5, category: 'food', sub: 'lunch', note: '午饭' });
step(); L.add({ bookId: book.id, accountId: mine.id, amount: -120, category: 'shopping', sub: 'clothes', note: '外套' });
step(); L.add({ bookId: book.id, accountId: mine.id, amount: 3000, category: 'salary', sub: 'wage' });
step(); L.add({ bookId: book.id, accountId: mine.id, amount: -50, category: 'food', note: '对话里提取的', pending: true, src: 'chat' });
step(); const star = L.addCategory('追星');
step(); L.add({ bookId: book.id, accountId: mine.id, amount: -88, category: star.id, note: '专辑' });
step(); const night = L.addSub('food', '夜宵');
step(); L.add({ bookId: book.id, accountId: mine.id, amount: -25, category: 'food', sub: night.id, note: '烧烤' });
step(); L.addRule(book.id, { accountId: mine.id, day: 15, amount: 8000, category: 'salary', note: '工资' });
step(); L.addRule(book.id, { accountId: hers.id, day: 15, amount: -2000, category: 'home', note: '房租', by: 'ai' });

// 聊天里的钱：转账、外卖、申请
step(); const tr1 = T.send({ chatId: 'chat_a', role: 'user', authorId: 'me', amount: 200, note: '奶茶' });
step(); T.settle(tr1.id, true);
step(); T.send({ chatId: 'chat_a', role: 'char', authorId: 'char_a', amount: 52, note: '还没收' });
step(); const tr3 = T.send({ chatId: 'chat_a', role: 'char', authorId: 'char_a', amount: 88, note: '' });
step(); T.settle(tr3.id, true);
step(); const tr4 = T.send({ chatId: 'chat_a', role: 'user', authorId: 'me', amount: 20 });
step(); T.settle(tr4.id, false);
step(); K.order({ chatId: 'chat_a', role: 'char', authorId: 'char_a', kind: 'self', item: '咖啡', amount: 30 });
step(); const tk = K.order({ chatId: 'chat_a', role: 'user', authorId: 'me', kind: 'treat', item: '寿司', amount: 45 });
step(); K.settle(tk.id, true);
step(); const tkAsk = K.order({ chatId: 'chat_a', role: 'user', authorId: 'me', kind: 'ask', item: '炸鸡', amount: 33 });
step(); K.settle(tkAsk.id, true);
step(); const j = R.send({ chatId: 'chat_a', role: 'user', authorId: 'me', kind: 'joint' });
step(); R.settle(j.id, true);
step(); R.send({ chatId: 'chat_a', role: 'user', authorId: 'me', kind: 'deposit', amount: 300 });
step(); R.send({ chatId: 'chat_a', role: 'char', authorId: 'char_a', kind: 'deposit', amount: 100, note: '零花钱' });
step(); const sp = R.send({ chatId: 'chat_a', role: 'char', authorId: 'char_a', kind: 'spend', amount: 60, note: '买机票' });
step(); R.settle(sp.id, true);
step(); const sp2 = R.send({ chatId: 'chat_a', role: 'user', authorId: 'me', kind: 'spend', amount: 9, note: '被驳回的' });
step(); R.settle(sp2.id, false);
step(); const cd = R.send({ chatId: 'chat_a', role: 'char', authorId: 'char_a', kind: 'card', amount: 150 });
step(); R.settle(cd.id, true);
// 亲属卡：林发给我，额度 150。我请的寿司 45、自己点的 40 走卡；再点 200、100 都超过剩下的 65，照旧从我自己的钱出
step(); K.order({ chatId: 'chat_a', role: 'user', authorId: 'me', kind: 'self', item: '面包', amount: 40 });
step(); K.order({ chatId: 'chat_a', role: 'user', authorId: 'me', kind: 'self', item: '鞋', amount: 200 });
step(); K.order({ chatId: 'chat_a', role: 'user', authorId: 'me', kind: 'self', item: '电影', amount: 100 });

// 交通卡充值（不算收支）、私密账户（锁着不计入合计）
step(); const transit = L.addAccount(book.id, { name: '地铁卡', owner: 'me', kind: 'transit' });
step(); L.moveBetween(book.id, mine.id, transit.id, 50, '地铁卡充值');
step(); L.add({ bookId: book.id, accountId: transit.id, amount: -3, category: 'transit', sub: 'metro', note: '乘车' });
step(); const secret = L.addAccount(book.id, { name: '小金库', owner: 'char', secret: true, pass: '0520', hint: '一个日子' });
step(); L.add({ bookId: book.id, accountId: secret.id, amount: 999, category: 'other', note: '藏起来的' });
step(); L.update(book.id, { settle: true });

// 卡包：娱乐卡、门禁卡、票券、会员卡
step(); const fc1 = F.give({ chatId: 'chat_a', role: 'user', name: '和好卡', desc: '吵架之后先和好', uses: 2, until: at('2030-01-01T00:00:00Z'), confirm: true });
step(); const use1 = F.use(fc1.id, { role: 'char', authorId: 'char_a' });
step(); F.settle(use1.id, true);
step(); F.use(fc1.id, { role: 'char', authorId: 'char_a' });
step(); F.give({ chatId: 'chat_a', role: 'char', authorId: 'char_a', name: '抱抱卡', desc: '', uses: 0, days: 0, color: 'peach' });
step(); const ps = S.give({ chatId: 'chat_a', role: 'user', kind: 'door', name: '楼下门禁', place: '滨江花园 3 栋', note: '想来就来' });
step(); S.use(ps.id, { role: 'char', authorId: 'char_a' });
step(); S.revoke(ps.id, { role: 'user' });
step(); S.give({ chatId: 'chat_a', role: 'char', authorId: 'char_a', kind: 'key', name: '备用钥匙' });
step(); Tk.give({ chatId: 'chat_a', role: 'user', title: '《花样年华》重映', when: '2030-10-20 19:30', venue: '百老汇电影中心', seat: '7 排 12 座' });
step(); const t2 = Tk.give({ chatId: 'chat_a', role: 'char', authorId: 'char_a', title: '演唱会', when: '2030年3月2日 晚上8点', venue: '体育馆' });
step(); Tk.check(t2.id, { role: 'user' });
step(); const mb = M.open({ chatId: 'chat_a', role: 'user', shop: '街角咖啡', note: '每次都点拿铁' });
step(); M.visit(mb.id, { role: 'char', authorId: 'char_a', points: 3, note: '拿铁' });
step(); M.visit(mb.id, { role: 'user', points: 2 });

// 固定入账：十月中旬打开过一次记账，补上了 9 月 15 日与 10 月 15 日两笔
P.begin(at('2026-10-16T12:00:00Z'));
const ranMid = L.runRules(book.id);

// 存下来的就是备份
const names = ['books', 'entries', 'messages', 'chats', 'characters', 'personas'];
const backup = {
  _format: 'mini-phone-backup', _version: 2, _data: 12, _media: false, _keys: false,
  exportedAt: new Date(at('2026-10-16T12:00:00Z')).toISOString(),
  settings: db.settings.get(),
};
for (const n of names) backup[n] = db[n].all();
backup.settings = { activePersonaId: 'me_root', ...Object.fromEntries(Object.entries(backup.settings).filter(([k]) => ['currency', 'ledgerCats', 'billBook'].includes(k))) };
const snapshot = JSON.parse(JSON.stringify(backup));

// 十一月二十日再打开一次：补上 11 月 15 日那一笔，然后算
const nowE = at('2026-11-20T12:00:00Z');
P.begin(nowE);
const ranEnd = L.runRules(book.id);
const id = book.id;
const accs = L.accountsOf(id);
const months = ['2026-09', '2026-10', '2026-11'];
const expected = {
  now: nowE, bookId: id, ranMid, ranEnd,
  balances: Object.fromEntries(accs.map(a => [a.id, L.balanceOf(id, a.id)])),
  accounts: accs.map(a => ({ id: a.id, name: a.name, owner: a.owner, kind: a.kind || '', secret: !!a.secret })),
  total: { all: L.totalOf(id), me: L.totalOf(id, 'me'), char: L.totalOf(id, 'char'), joint: L.totalOf(id, 'joint') },
  months: L.months(id),
  stats: Object.fromEntries(months.map(m => [m, L.stats(id, m)])),
  spending: Object.fromEntries(months.map(m => [m, L.spending(id, m)])),
  cards: L.cardsOf(id).map(c => ({ id: c.id, from: c.from, to: c.to, limit: c.limit, used: L.cardUsed(id, c.id), left: L.cardLeft(id, c) })),
  chatEntries: L.chatEntries(id).map(e => ({ id: e.id, accountId: e.accountId, amount: e.amount, cardId: e.cardId, note: e.note })),
  charReady: L.charReady(id),
  context: L.context('chat_a'),
  bill: req('src/system/ai/context/bill.js').build({ chat: db.chats.get('chat_a') }),
  affordable: {
    me100: L.affordable('chat_a', 'me', 100), me1e5: L.affordable('chat_a', 'me', 100000),
    char500: L.affordable('chat_a', 'char', 500), char1e5: L.affordable('chat_a', 'char', 100000),
  },
  pending: L.pendingOf(id).map(e => e.id),
  labels: L.recent(id).filter(e => e.src === 'manual').map(e => ({ id: e.id, label: L.labelOf(e) })),
  categories: L.categories().map(c => ({ id: c.id, label: c.label, subs: c.subs.map(s => s.id) })),
  funcard: F.factsFor('chat_a'),
  funStates: F.cardsOf('chat_a').map(s => ({ id: s.id, name: s.name, status: s.status, used: s.used, left: s.left === Infinity ? null : s.left, holder: s.holder })),
  pass: S.factsFor('chat_a'),
  passStates: S.passesOf('chat_a').map(s => ({ id: s.id, name: s.name, revoked: s.revoked, uses: s.uses, holder: s.holder })),
  ticket: Tk.factsFor('chat_a'),
  ticketStates: Tk.ticketsOf('chat_a').map(s => ({ id: s.id, title: s.title, at: s.at, status: s.status, holder: s.holder })),
  member: M.factsFor('chat_a'),
};

fs.writeFileSync(path.join(root, 'Tests/Fixtures/ledger-web.json'), JSON.stringify(snapshot, null, 1) + '\n');
fs.writeFileSync(path.join(root, 'Tests/Fixtures/ledger-web-expected.json'), JSON.stringify(expected, null, 1) + '\n');
console.log(`ledger-web.json：${snapshot.entries.length} 笔流水、${snapshot.messages.length} 条消息；十月补 ${ranMid} 笔、十一月补 ${ranEnd} 笔`);
console.log(expected.bill);
