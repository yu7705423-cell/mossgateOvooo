// 用网页版自己的 charpack.js 打一个角色包，写成 Tests/Fixtures/charpack.zip（CharPackTests 读它）。
//
//   node scripts/make-charpack-fixture.mjs <网页版仓库目录> <装了 fake-indexeddb 的目录>
//
// 网页版的库跑在 IndexedDB 上，node 里没有，借 fake-indexeddb（npm 上的包，只在打这份测试数据时用，不进本仓库）。
// 打包、记忆向量的写法、ZIP 全部是网页版的代码：测的是「原生版装得回网页版真正导出的角色包」。
// 网页版角色包的格式变了（charpack.js 的 VERSION、带走的数据域），重跑一次。
import { writeFileSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';

const [web, fidb] = process.argv.slice(2);
if (!web || !fidb) { console.error('用法：node scripts/make-charpack-fixture.mjs <网页版仓库目录> <装了 fake-indexeddb 的目录>'); process.exit(1); }
await import(pathToFileURL(join(resolve(fidb), 'node_modules/fake-indexeddb/auto/index.mjs')).href);
globalThis.localStorage = { getItem: () => null, setItem() {}, removeItem() {} };
const sys = join(resolve(web), 'src/system');
const load = f => import(pathToFileURL(join(sys, f)).href);
const db = await load('db/index.js');
await db.ready;
const cp = await load('charpack.js');

const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==', 'base64');
const t0 = 1760000000000;
await db.images.putRaw('img_av', new Blob([png], { type: 'image/png' }));
await db.images.putRaw('img_msg', new Blob([png], { type: 'image/png' }));
await db.images.putRaw('img_mo', new Blob([png], { type: 'image/png' }));
await db.files.putRaw('f_voice', new Blob([Buffer.from('ID3fakeaudio')], { type: 'audio/mpeg' }));

const put = (col, row) => db[col].put({ createdAt: t0, updatedAt: t0, ...row });
put('lorebooks', { id: 'lb_own', name: '她的设定', entries: [{ id: 'e1', keys: [], content: 'LORE_OWN', enabled: true }] });
put('lorebooks', { id: 'lb_global', name: '全局', global: true, entries: [] });
put('characters', { id: 'char_pk', name: '林', persona: 'PACK_PERSONA', signature: '签名', avatar: 'img_av', birthday: '3月14日',
  lorebookIds: ['lb_own', 'lb_global', 'lb_missing'], relations: [{ charId: 'char_npc', label: '邻居', circle: '楼里' }, { charId: 'char_alt', label: '小号', circle: '' }],
  webOnlyField: { keep: 1 } });
put('characters', { id: 'char_alt', name: '林的小号', parentId: 'char_pk', altReason: '想换个身份', relations: [] });
put('characters', { id: 'char_npc', name: '邻居', isNpc: true, relations: [{ charId: 'char_pk', label: '邻居', circle: '' }] });
put('personas', { id: 'me_far', name: '那边的我', parentId: null });
put('chats', { id: 'chat_pk', characterIds: ['char_pk'], personaId: 'me_far', lastMessageAt: t0 + 3000, memoryUpTo: 'msg_pk2', summary: '' });
put('chats', { id: 'chat_grp', group: true, characterIds: ['char_pk', 'char_npc'], personaId: 'me_far' });
put('messages', { id: 'msg_pk1', chatId: 'chat_pk', role: 'user', authorId: 'me', kind: 'text', content: '你好', status: 'done', createdAt: t0 + 1000 });
put('messages', { id: 'msg_pk2', chatId: 'chat_pk', role: 'char', authorId: 'char_pk', kind: 'image', content: '[图片：一只猫]', imageId: 'img_msg', status: 'done', createdAt: t0 + 2000 });
put('messages', { id: 'msg_pk3', chatId: 'chat_pk', role: 'char', authorId: 'char_pk', kind: 'voice', content: '[语音：在呢]', audioId: 'f_voice', status: 'done', createdAt: t0 + 3000 });
put('messages', { id: 'msg_grp', chatId: 'chat_grp', role: 'user', authorId: 'me', kind: 'text', content: '群里的', status: 'done', createdAt: t0 + 500 });
put('memories', { id: 'mem_pk', charId: 'char_pk', personaId: 'me_far', content: 'PACK_MEMORY', vec: new Float32Array([0.5, -0.25, 1]) });
put('memories', { id: 'mem_grp', charId: 'char_pk', personaId: 'me_far', content: 'GROUP_ONLY', scopeChat: 'chat_grp' });
put('impressions', { id: 'imp_pk', kind: 'imp', charId: 'char_pk', personaId: 'me_far', text: '说话很直接', state: 'kept',
  evidence: [{ msgId: 'msg_pk1', chatId: 'chat_pk', at: t0 + 1000, day: '2025-10-09', quote: '你好' }], against: [] });
put('impressions', { id: 'imp_draft', kind: 'draft', charId: 'char_pk', personaId: 'me_far', fresh: [] });
put('ties', { id: 'ti_pk', from: 'char_pk', to: 'me', personaId: 'me_far', blocked: true, removed: false, spans: [], hist: [{ turnId: 't' }] });
put('moments', { id: 'mo_pk', authorId: 'char_pk', text: '今天下雨', images: ['img_mo'], likes: ['me', 'char_npc'], comments: [{ id: 'c1', authorId: 'char_alt', text: '嗯' }] });

const blob = await cp.build('char_pk', { history: true });
const out = join(dirname(fileURLToPath(import.meta.url)), '..', 'Tests', 'Fixtures', 'charpack.zip');
writeFileSync(out, Buffer.from(await blob.arrayBuffer()));
console.log('charpack ->', out, JSON.stringify(cp.estimate('char_pk')));
process.exit(0);
