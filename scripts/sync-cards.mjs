// 从网页版把内置卡片（六个平台的帖子样式，system/cardkit.js 的 BUILTIN）原样抄过来，写成 Resources/cards.json。
//
//   node scripts/sync-cards.mjs <网页版仓库目录>
//
// 模板、字段说明（进提示词，英文）、示例一字不改，不许手改 cards.json。网页版改了内置卡片，重跑一次再提交。
import { writeFileSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { pathToFileURL, fileURLToPath } from 'node:url';

const web = process.argv[2];
if (!web) {
  console.error('用法：node scripts/sync-cards.mjs <网页版仓库目录>');
  process.exit(1);
}
const { BUILTIN, BUILTIN_BOOK_ID } = await import(pathToFileURL(join(resolve(web), 'src/system/cardkit.js')).href);
const here = dirname(fileURLToPath(import.meta.url));
const out = join(here, '..', 'Resources', 'cards.json');
writeFileSync(out, JSON.stringify({ bookId: BUILTIN_BOOK_ID, entries: BUILTIN }, null, 1) + '\n');
console.log(`${BUILTIN.length} 张内置卡片 -> ${out}`);
