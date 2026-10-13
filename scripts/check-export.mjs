// 用网页版自己的代码读原生版导出的备份，确认网页版恢复得了。
//
//   node scripts/check-export.mjs <导出文件所在目录>
//
// 读的方式照网页版 backup.js 的 restore：加密的先用 vault.open 解开；PK 开头的用 unzip 取 backup.json；
// 记忆的向量用 typed.js 的 unpackRow 还原。Tests/WebReference 里是网页版这三个文件的副本，网页版改了就重新抄一份。
// 文件由 Tests/Unit/ExportTests.swift 在 CI 里写出（EXPORT_CHECK_DIR）。
import { readFileSync, existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const ref = join(dirname(fileURLToPath(import.meta.url)), '..', 'Tests', 'WebReference');
const load = f => import(pathToFileURL(join(ref, f)).href);
const { unzip } = await load('zip.js');
const vault = await load('vault.js');
const { unpackRow } = await load('typed.js');

const dir = process.argv[2];
if (!dir) { console.error('用法：node scripts/check-export.mjs <目录>'); process.exit(1); }

const cases = [
  { file: 'full.zip', media: 3 },
  { file: 'data.json', media: 0 },
  { file: 'sealed.bin', media: 3, pass: '导出口令' },
];

let failed = 0;
const fail = (c, msg) => { console.error(`不通过 ${c.file}：${msg}`); failed++; };

for (const c of cases) {
  const path = join(dir, c.file);
  if (!existsSync(path)) { fail(c, '测试没有写出这份文件'); continue; }
  let blob = new Blob([readFileSync(path)]);
  if (await vault.isSealed(blob)) {
    if (!c.pass) { fail(c, '不该加密却加密了'); continue; }
    try { blob = await vault.open(blob, c.pass); } catch (e) { fail(c, `网页版解不开：${e.message}`); continue; }
  } else if (c.pass) { fail(c, '应当加密却没有加密'); continue; }

  const head = new Uint8Array(await blob.slice(0, 2).arrayBuffer());
  let data;
  let media = 0;
  if (head[0] === 0x50 && head[1] === 0x4b) {
    const found = await unzip(blob);
    const json = found.get('backup.json');
    if (!json) { fail(c, '包里没有 backup.json'); continue; }
    data = JSON.parse(await json.text());
    for (const name of found.keys()) if (/^(images|images-orig|files)\//.test(name)) media++;
    const png = found.get('images/img_a.png');
    const sig = png && new Uint8Array(await png.slice(0, 4).arrayBuffer());
    if (!sig || sig[0] !== 0x89 || sig[1] !== 0x50) fail(c, 'images/img_a.png 内容不对');
  } else {
    data = JSON.parse(await blob.text());
  }
  if (data._format !== 'mini-phone-backup') fail(c, `_format 是 ${data._format}`);
  if (!(Number(data._data) >= 12)) fail(c, `_data 是 ${data._data}`);
  if ((data.characters || []).length !== 1) fail(c, `角色 ${data.characters?.length}`);
  if (!(data.messages || []).some(m => m.chatId === 'chat_a')) fail(c, '消息不在');
  const mem = (data.memories || []).map(r => unpackRow('memories', r)).find(m => m.id === 'mem_1');
  if (!mem || !(mem.vec instanceof Float32Array) || mem.vec.length !== 3 || mem.vec[1] !== -0.25) fail(c, '记忆向量还原不出来');
  if (media !== c.media) fail(c, `图片与文件 ${media}，应为 ${c.media}`);
  if (!failed) console.log(`通过 ${c.file}`);
}
process.exit(failed ? 1 : 0);
