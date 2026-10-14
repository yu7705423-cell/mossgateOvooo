// 从网页版把主屏要用的三样东西原样抄过来，写成 Resources/shell.json：
//   icons   全部线条图标（src/icons/paths.js，24 格的 SVG 片段）
//   apps    每个 app 的 id、名字、图标名（src/apps/*/manifest.js）
//   layout  新用户的默认主屏版式（src/system/db/defaults.js 的 DEFAULT_LAYOUT）
//
//   node scripts/sync-shell.mjs <网页版仓库目录>
//
// 不手抄：图标与版式由网页版决定，原生版照着画。网页版改了，重跑一次再提交。
import { readFileSync, writeFileSync, readdirSync, existsSync, mkdtempSync, rmSync } from 'node:fs';
import { join, resolve, dirname } from 'node:path';
import { tmpdir } from 'node:os';
import { pathToFileURL, fileURLToPath } from 'node:url';

const web = process.argv[2];
if (!web) {
  console.error('用法：node scripts/sync-shell.mjs <网页版仓库目录>');
  process.exit(1);
}
const src = join(resolve(web), 'src');
const { PATHS } = await import(pathToFileURL(join(src, 'icons/paths.js')).href);

const apps = [];
for (const d of readdirSync(join(src, 'apps')).sort()) {
  const f = join(src, 'apps', d, 'manifest.js');
  if (!existsSync(f)) continue;
  const t = readFileSync(f, 'utf8');
  const pick = k => (t.match(new RegExp(`\\b${k}:\\s*'([^']*)'`)) || [])[1];
  const id = pick('id'), name = pick('name'), icon = pick('icon');
  if (!id || !name || !icon) { console.error(`${f} 读不出 id、name、icon`); process.exit(1); }
  apps.push({ id, name, icon });
}

const defaults = readFileSync(join(src, 'system/db/defaults.js'), 'utf8');
const a = defaults.indexOf('const app = (id');
const b = defaults.indexOf('export const GRID_COLS');
if (a < 0 || b < 0) { console.error('defaults.js 里找不到 DEFAULT_LAYOUT，脚本需要跟着改'); process.exit(1); }
const dir = mkdtempSync(join(tmpdir(), 'shell-'));
let layout;
try {
  const file = join(dir, 'layout.mjs');
  writeFileSync(file, defaults.slice(a, b));
  ({ DEFAULT_LAYOUT: layout } = await import(pathToFileURL(file).href));
} finally {
  rmSync(dir, { recursive: true, force: true });
}

const icons = Object.fromEntries(Object.keys(PATHS).sort().map(k => [k, PATHS[k]]));
const out = join(dirname(fileURLToPath(import.meta.url)), '..', 'Resources', 'shell.json');
writeFileSync(out, JSON.stringify({ icons, apps, layout }, null, 1) + '\n');
console.log(`${Object.keys(icons).length} 个图标、${apps.length} 个 app、${layout.pages.length} 页版式 -> ${out}`);
