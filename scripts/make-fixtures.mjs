// 用网页版自己的代码打几份测试用的备份，写进 Tests/Fixtures。
//
//   node scripts/make-fixtures.mjs <网页版仓库目录>
//
// ZIP、加密、向量的写法全部调网页版的 zip.js、vault.js、typed.js，不在这里另写一份：
// 测的是「原生版读得懂网页版真正导出的文件」，自己写的格式测不出这件事。
import { writeFileSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';

const web = process.argv[2];
if (!web) { console.error('用法：node scripts/make-fixtures.mjs <网页版仓库目录>'); process.exit(1); }
const sys = join(resolve(web), 'src/system');
const load = f => import(pathToFileURL(join(sys, f)).href);
const { zip } = await load('zip.js');
const vault = await load('vault.js');
const { packRow } = await load('typed.js');

const out = join(dirname(fileURLToPath(import.meta.url)), '..', 'Tests', 'Fixtures');
const save = async (name, blob) => writeFileSync(join(out, name), Buffer.from(await blob.arrayBuffer()));

// 1x1 的 PNG
const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==', 'base64');
const t0 = 1760000000000;

const data = {
  _format: 'mini-phone-backup', _version: 2, _data: 12, _media: true, _keys: false, _origs: true,
  exportedAt: new Date(t0).toISOString(),
  persona: { name: '我', avatar: null },
  settings: { activePersonaId: 'me_root', msgMin: 2, msgMax: 4, services: undefined, apiKey: '', someWebOnlyKey: { nested: [1, 2, 3] } },
  layout: { pages: [] },
  characters: [
    { id: 'char_a', createdAt: t0, updatedAt: t0, name: '林', signature: '一句签名', persona: 'PERSONA_TEXT', scenario: 'SCENARIO_TEXT',
      gender: '女', avatar: 'img_a', lorebookIds: ['lb_1'], webOnlyField: { keep: true } },
  ],
  personas: [{ id: 'me_root', createdAt: t0, updatedAt: t0, name: '小于', parentId: null, description: 'USER_DESC', gender: '男' }],
  chats: [{ id: 'chat_a', createdAt: t0, updatedAt: t0, characterIds: ['char_a'], personaId: 'me_root', lastMessageAt: t0 + 3000, unread: 2, summary: '' }],
  messages: [
    { id: 'msg_1', createdAt: t0 + 1000, updatedAt: t0 + 1000, chatId: 'chat_a', role: 'user', authorId: 'me', kind: 'text', content: '你好', status: 'done' },
    { id: 'msg_2', createdAt: t0 + 2000, updatedAt: t0 + 2000, chatId: 'chat_a', role: 'char', authorId: 'char_a', kind: 'text', content: '在呢', status: 'done', turnId: 'turn_1' },
    { id: 'msg_3', createdAt: t0 + 3000, updatedAt: t0 + 3000, chatId: 'chat_a', role: 'char', authorId: 'char_a', kind: 'image', content: '[图片：一只猫]', imageId: 'img_a', status: 'done', turnId: 'turn_1' },
  ],
  memories: [
    packRow('memories', { id: 'mem_1', createdAt: t0, updatedAt: t0, charId: 'char_a', personaId: 'me_root', content: 'PINNED_MEMORY', pinned: true, vec: new Float32Array([0.5, -0.25, 1]) }),
    packRow('memories', { id: 'mem_2', createdAt: t0, updatedAt: t0, charId: 'char_a', personaId: 'me_root', content: '用户喜欢猫', keywords: ['猫'], rank: 'A', category: 'fact' }),
  ],
  lorebooks: [{ id: 'lb_1', createdAt: t0, updatedAt: t0, name: '设定', entries: [
    { id: 'e1', keys: ['猫'], content: 'LORE_CAT', enabled: true, part: 'before', depth: 0 },
    { id: 'e2', keys: [], constant: true, content: 'LORE_ALWAYS', enabled: true, part: 'after', depth: 0 },
    { id: 'e3', keys: ['不会出现的词'], content: 'LORE_MISS', enabled: true },
    { id: 'e4', keys: [], constant: true, content: 'LORE_OFF', enabled: false },
  ] }],
  stickers: [{ id: 'stk_1', createdAt: t0, updatedAt: t0, name: '开心', group: '', imageId: 'img_a' }],
  // 原生版现在不认识的数据域：导入时也要原样存下
  futureThings: [{ id: 'ft_1', createdAt: t0, whatever: 'x' }],
};
const json = JSON.stringify(data);

const full = await zip([
  { name: 'backup.json', text: json },
  { name: 'images/img_a.png', blob: new Blob([png], { type: 'image/png' }) },
  { name: 'images-orig/img_a.png', blob: new Blob([png], { type: 'image/png' }) },
  // 原图挂的那一张不在：不该放进来
  { name: 'images-orig/img_ghost.png', blob: new Blob([png], { type: 'image/png' }) },
  // 内容本身是 ZIP 的坏图（网页版 4.273）：不该放进来，要报出来
  { name: 'images/img_bad.png', blob: new Blob([Buffer.from([0x50, 0x4b, 0x03, 0x04, 1, 2, 3, 4])]) },
  { name: 'files/f_a.mp3', blob: new Blob([Buffer.from('ID3fakeaudio')], { type: 'audio/mpeg' }) },
]);
await save('full.zip', full);
writeFileSync(join(out, 'data.json'), json);
writeFileSync(join(out, 'with-keys.json'), JSON.stringify({ ...data, _keys: true,
  settings: { ...data.settings, services: { chat: { presets: [{ id: 'svc_b', name: '备份里的', provider: 'openai', apiKey: 'k', model: 'm' }], activeId: 'svc_b' } } } }));
writeFileSync(join(out, 'old.json'), JSON.stringify({ ...data, _data: 5 }));
writeFileSync(join(out, 'not-backup.json'), JSON.stringify({ hello: 'world' }));
// 段长取 1024：让一份小包也切成好几段，段号与「最后一段」那一位都测得到
await save('sealed.bin', await vault.seal(full, await vault.keyFor('口令123'), { chunk: 1024 }));
// 截掉尾巴的加密包：不能恢复出一份残的库
const sealedBytes = Buffer.from(await (await vault.seal(full, await vault.keyFor('口令123'), { chunk: 1024 })).arrayBuffer());
writeFileSync(join(out, 'sealed-truncated.bin'), sealedBytes.subarray(0, sealedBytes.length - 100));
console.log('fixtures ->', out);
