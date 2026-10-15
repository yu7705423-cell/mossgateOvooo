#!/usr/bin/env node
// 说明书（网页版 scripts/gen-help.mjs，ARCHITECTURE 4.527）：把界面上收起来的说明（HelpNote("…")）从代码里收集出来，
// 生成 Resources/help.json，「设置 - 说明书」读它。
//
//   node scripts/gen-help.mjs           重新生成
//   node scripts/gen-help.mjs --check   只核对是不是最新的（编译工作流里跑），不是就报错退出
//
// 标题取这条说明所在那一组的组头（header 里的 Text），没有组头取这一组里第一个控件的名字。
// 插值 \(…) 写成「…」。三目两边各成一条；用加号连起来的拼成一条。
import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const views = join(root, 'Sources/Eira/Views');
const outPath = join(root, 'Resources/help.json');

// 文件归哪个 app。新加一个有说明的文件要在这里登记，否则报错
const APPS = {
  'ApiSettingsView.swift': '设置', 'BgPushView.swift': '设置', 'ExportView.swift': '设置', 'FeedbackView.swift': '设置',
  'ImageSettingsView.swift': '设置', 'ImportView.swift': '设置', 'NotifyView.swift': '设置', 'OnboardingView.swift': '设置',
  'SettingsView.swift': '设置', 'StorageView.swift': '设置', 'UsageLimitsView.swift': '设置', 'VoiceViews.swift': '设置',
  'CanonViews.swift': '设定集', 'LoreViews.swift': '设定集', 'MemoryViews.swift': '设定集',
  'CardImportView.swift': '联系', 'CharacterEditView.swift': '联系', 'CharCapsView.swift': '联系', 'PersonaViews.swift': '联系', 'FaceLockViews.swift': '联系', 'AvatarPoolViews.swift': '联系',
  'ChatLookView.swift': '聊天', 'ChatSettingsView.swift': '聊天', 'ConversationView.swift': '聊天', 'ForwardViews.swift': '聊天',
  'GroupViews.swift': '聊天', 'MomentsViews.swift': '聊天', 'SkinViews.swift': '聊天', 'StatusBarViews.swift': '聊天',
  'StickerViews.swift': '聊天', 'TimeSettingsView.swift': '聊天', 'SceneViews.swift': '聊天', 'PanelViews.swift': '聊天', 'BondViews.swift': '聊天', 'BadgeDefViews.swift': '聊天', 'CardViews.swift': '聊天',
  'DailyViews.swift': '日常', 'UserSchedViews.swift': '日常', 'DiaryViews.swift': '日记', 'MusicViews.swift': '音乐', 'HomeEditViews.swift': '主屏', 'HomeArrangeViews.swift': '主屏',
  'SpaceViews.swift': '情侣空间', 'AlbumViews.swift': '相册', 'HealthViews.swift': '健康', 'TheirsViews.swift': '角色手机',
};
const ORDER = ['聊天', '联系', '设定集', '日常', '日记', '音乐', '相册', '情侣空间', '健康', '角色手机', '主屏', '设置'];

/** 从 i（指向开引号）读一个字符串字面量，返回 [文字, 结束位置] */
function literal(s, i) {
  let out = '';
  let j = i + 1;
  while (j < s.length && s[j] !== '"') {
    if (s[j] === '\\' && s[j + 1] === '(') {
      let d = 1; j += 2;
      while (d) { if (s[j] === '(') d++; else if (s[j] === ')') d--; else if (s[j] === '"') { j = literal(s, j)[1] - 1; } j++; }
      out += '…';
      continue;
    }
    if (s[j] === '\\') { out += s[j + 1] === 'n' ? '' : s[j + 1]; j += 2; continue; }
    out += s[j++];
  }
  return [out, j + 1];
}

/** 从 i（指向开括号）找到配对的闭括号，跳过字符串 */
function closeParen(s, i) {
  let d = 0;
  for (let j = i; j < s.length; j++) {
    if (s[j] === '"') { j = literal(s, j)[1] - 1; continue; }
    if (s[j] === '(') d++;
    else if (s[j] === ')' && --d === 0) return j;
  }
  return s.length;
}

function texts(call) {
  const out = [];
  let cur = null;
  let gap = '';
  for (let j = 0; j < call.length; j++) {
    if (call[j] === '"') {
      const [t, end] = literal(call, j);
      // 条件里比较用的字面量（x == "apart"、raw["giftBlind"]）不是说明
      const before = call.slice(0, j).trimEnd();
      if (/(==|!=|\[)$/.test(before) || /^\s*\]/.test(call.slice(end))) { j = end - 1; continue; }
      if (cur !== null && /^[\s+()]*$/.test(gap)) cur += t;
      else { if (cur) out.push(cur); cur = t; }
      gap = '';
      j = end - 1;
    } else if (cur !== null) gap += call[j];
  }
  if (cur) out.push(cur);
  return out.map(t => t.trim()).filter(Boolean);
}

const CONTROL_RE = /(?:Toggle|Picker|Button|Stepper|TextField|Label|LabeledContent|ColorPicker|NumberRow\(title:)\(?\s*"((?:[^"\\]|\\.)*)"/;
const TEXT_RE = /Text\("((?:[^"\\]|\\.)*)"/;

function titleFor(s, at) {
  let sec = -1;
  for (const m of s.slice(0, at).matchAll(/\bSection\s*[{(]/g)) sec = m.index;
  let block = sec >= 0 ? s.slice(sec, at) : '';
  const head = block.match(/header:\s*\{\s*(?:Text|groupTitle)\("((?:[^"\\]|\\.)*)"/);
  const foot = block.lastIndexOf('footer:');
  if (foot >= 0) block = block.slice(0, foot);
  const pick = head ? head[1] : (block.match(CONTROL_RE) || block.match(TEXT_RE) || [])[1] || '';
  return literal(`"${pick}"`, 0)[0];
}

const rows = [];
for (const f of readdirSync(views).sort()) {
  if (!f.endsWith('.swift')) continue;
  const s = readFileSync(join(views, f), 'utf8');
  const re = /(?<![\w.])HelpNote\(/g;
  let m;
  while ((m = re.exec(s))) {
    if (s.slice(m.index - 7, m.index) === 'struct ') continue;
    const open = m.index + 'HelpNote'.length;
    const call = s.slice(open + 1, closeParen(s, open));
    const named = call.match(/,\s*title:\s*"((?:[^"\\]|\\.)*)"\s*$/);
    const list = texts(named ? call.slice(0, named.index) : call);
    if (!list.length) continue;
    const app = APPS[f];
    if (!app) { console.error(`${f} 里有说明，但没在 scripts/gen-help.mjs 的 APPS 里登记归哪个 app`); process.exit(1); }
    const title = named ? literal(`"${named[1]}"`, 0)[0] : titleFor(s, m.index);
    for (const text of list) rows.push({ app, title, text });
  }
}
rows.sort((a, b) => ORDER.indexOf(a.app) - ORDER.indexOf(b.app));
const seen = new Set();
const uniq = rows.filter(r => { const k = `${r.app}|${r.title}|${r.text}`; if (seen.has(k)) return false; seen.add(k); return true; });
const json = '[\n' + uniq.map(r => '  ' + JSON.stringify(r)).join(',\n') + '\n]\n';

if (process.argv.includes('--check')) {
  let cur = '';
  try { cur = readFileSync(outPath, 'utf8'); } catch {}
  if (cur !== json) {
    console.error('Resources/help.json 不是最新的：改了界面上的说明之后跑一次 node scripts/gen-help.mjs');
    process.exit(1);
  }
  console.log(`说明书是最新的，共 ${uniq.length} 条`);
} else {
  writeFileSync(outPath, json);
  console.log(`已生成 Resources/help.json，共 ${uniq.length} 条`);
}
