// 从网页版把默认提示词模板原样抄过来，写成 Resources/templates.json。
//
//   node scripts/sync-templates.mjs <网页版仓库目录>
//
// 提示词正文一字不改（网页版第 14、16 条）。手抄必然走样，所以由这份脚本直接读网页版的
// DEFAULT_TEMPLATES。网页版改了模板，重跑一次再提交。
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL, fileURLToPath } from 'node:url';

const web = process.argv[2];
if (!web) {
  console.error('用法：node scripts/sync-templates.mjs <网页版仓库目录>');
  process.exit(1);
}
const src = readFileSync(join(resolve(web), 'src/system/ai/templates.js'), 'utf8');
// 唯一的 import 是 settings（template() 运行时读用户改过的那份），这里用不到，换成空的
const body = src.replace(/^import \{ settings \} from '\.\.\/db\/index\.js';$/m, 'const settings = { get: () => ({}) };');
if (body === src) {
  console.error('templates.js 的 import 与预期不同，脚本需要跟着改');
  process.exit(1);
}
const dir = mkdtempSync(join(tmpdir(), 'tpl-'));
try {
  const file = join(dir, 'templates.mjs');
  writeFileSync(file, body);
  const { DEFAULT_TEMPLATES } = await import(pathToFileURL(file).href);
  const sorted = Object.fromEntries(Object.keys(DEFAULT_TEMPLATES).sort().map(k => [k, DEFAULT_TEMPLATES[k]]));
  const here = dirname(fileURLToPath(import.meta.url));
  const out = join(here, '..', 'Resources', 'templates.json');
  writeFileSync(out, JSON.stringify(sorted, null, 2) + '\n');
  console.log(`${Object.keys(sorted).length} 段模板 -> ${out}`);
} finally {
  rmSync(dir, { recursive: true, force: true });
}
