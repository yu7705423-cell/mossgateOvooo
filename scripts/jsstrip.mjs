// 打包时去掉注释与缩进（docs/jscore-prompt.md 的「包体」）。不改语义：
//
// - 字符串、模板字符串（含 ${} 里套的代码）、正则字面量原样照抄
// - 注释删掉；块注释里有换行的换成一个换行（不改自动分号插入），没有的换成一个空格
// - 以 /*! 开头、或写着 @license / @preserve 的注释留着（授权声明，网页版 CLAUDE.md 第 27 条）
// - 行首缩进、行尾空白、空行删掉；换行本身留着（不靠换行判断分号的写法照样对）
// - 行内的连续空白：挨着 { } ( ) [ ] ; , 或者一边是字一边是符号时删掉；两边都是字、都是符号时收成一个空格
//   （a in b、a + +b、x < !--y 这类不会粘在一起；1 .toString() 留着空格）
//
// 正则与除号靠前一个记号判断（前面是值就是除号，否则是正则）。判断不了的写法不在这里猜：
// sync-weblogic 对每个模块去注释前后各做一次语法检查，再拿同一批样本对照两份包的输出，有一处不同就不用去过注释的那一份。
//
// 无依赖。

const KEEP = /^\/\*!|@license|@preserve/;
const SAFE = new Set(['{', '}', '(', ')', '[', ']', ';', ',']);
// 这些关键字后面的 / 是正则
const BEFORE_REGEX = new Set(['return', 'typeof', 'instanceof', 'in', 'of', 'new', 'delete', 'void', 'throw', 'case', 'do', 'else', 'yield', 'await']);
const isIdent = c => /[\w$\u0080-\uffff]/.test(c);
// 两个记号之间的空白留不留：两边都是字（a in b）或都是符号（a + +b、x < !--y）时留着；
// 一边是字一边是符号时删掉，只有数字后面紧跟一个点（1 .toString()）例外
const keepSpace = (prev, next) => {
  if (SAFE.has(prev) || SAFE.has(next)) return false;
  const a = isIdent(prev), b = isIdent(next);
  if (a && b) return true;
  if (!a && !b) return true;
  return next === '.' && /[0-9]/.test(prev);
};

export function strip(src) {
  let out = '';
  let i = 0;
  const n = src.length;
  // 前一个有意义的记号：'value'（后面的 / 是除号）或 'op'（后面的 / 是正则）
  let last = 'op';
  // 模板字符串的嵌套：每一层记 ${ 之后的花括号深度
  const tpl = [];
  let pendingSpace = '';   // '' | ' ' | '\n'

  const emit = s => {
    if (pendingSpace) {
      const prev = out[out.length - 1];
      if (pendingSpace === '\n') {
        if (out.length && prev !== '\n') out += '\n';
      } else if (out.length && prev !== '\n' && keepSpace(prev, s[0])) {
        out += ' ';
      }
      pendingSpace = '';
    }
    out += s;
  };
  const space = kind => { if (kind === '\n' || pendingSpace !== '\n') pendingSpace = kind; };

  const readString = q => {
    const start = i;
    i += 1;
    while (i < n && src[i] !== q) {
      if (src[i] === '\\') i += 1;
      else if (src[i] === '\n') throw new Error(`字符串没有结束（第 ${lineOf(src, start)} 行）`);
      i += 1;
    }
    i += 1;
    return src.slice(start, i);
  };

  // 模板字符串从 ` 或 } 开始，读到 ` 或 ${ 为止
  const readTemplate = () => {
    const start = i;
    i += 1;
    while (i < n) {
      const c = src[i];
      if (c === '\\') { i += 2; continue; }
      if (c === '`') { i += 1; return { text: src.slice(start, i), open: false }; }
      if (c === '$' && src[i + 1] === '{') { i += 2; return { text: src.slice(start, i), open: true }; }
      i += 1;
    }
    throw new Error(`模板字符串没有结束（第 ${lineOf(src, start)} 行）`);
  };

  // 正则字面量：读不到同一行里的结尾就返回 null（那就是除号）
  const readRegex = () => {
    let j = i + 1;
    let cls = false;
    while (j < n) {
      const c = src[j];
      if (c === '\n') return null;
      if (c === '\\') { j += 2; continue; }
      if (cls) { if (c === ']') cls = false; }
      else if (c === '[') cls = true;
      else if (c === '/') break;
      j += 1;
    }
    if (j >= n) return null;
    j += 1;
    while (j < n && /[a-z]/i.test(src[j])) j += 1;
    const text = src.slice(i, j);
    i = j;
    return text;
  };

  while (i < n) {
    const c = src[i];
    const d = src[i + 1];

    if (c === '/' && d === '/') {
      const end = src.indexOf('\n', i);
      const text = src.slice(i, end < 0 ? n : end);
      if (KEEP.test(text)) { emit(text); space('\n'); }
      i = end < 0 ? n : end;
      continue;
    }
    if (c === '/' && d === '*') {
      const end = src.indexOf('*/', i + 2);
      if (end < 0) throw new Error(`块注释没有结束（第 ${lineOf(src, i)} 行）`);
      const text = src.slice(i, end + 2);
      i = end + 2;
      if (KEEP.test(text)) { emit(text); space('\n'); continue; }
      space(text.includes('\n') ? '\n' : ' ');
      continue;
    }
    if (c === '\n' || c === '\r' || c === ' ' || c === ' ') { space('\n'); i += 1; continue; }
    if (c === ' ' || c === '\t' || c === '\f' || c === '\v' || c === ' ' || c === '﻿') { space(' '); i += 1; continue; }

    if (c === '"' || c === "'") { emit(readString(c)); last = 'value'; continue; }
    if (c === '`') {
      const t = readTemplate();
      emit(t.text);
      if (t.open) { tpl.push(0); last = 'op'; } else last = 'value';
      continue;
    }
    if (c === '}' && tpl.length && tpl[tpl.length - 1] === 0) {
      tpl.pop();
      const t = readTemplate();
      emit(t.text);
      if (t.open) { tpl.push(0); last = 'op'; } else last = 'value';
      continue;
    }
    if (c === '/') {
      if (last === 'op') {
        const re = readRegex();
        if (re != null) { emit(re); last = 'value'; continue; }
      }
      emit(c); i += 1; last = 'op';
      continue;
    }
    if (isIdent(c)) {
      let j = i;
      while (j < n && isIdent(src[j])) j += 1;
      // 数字里的小数点与指数（1.5e-3）：读成一个记号，免得 e 后面的 - 被当成别的
      if (/[0-9]/.test(c)) {
        while (j < n && (/[\w.]/.test(src[j]) || ((src[j] === '-' || src[j] === '+') && /[eE]/.test(src[j - 1]) && !/^0[xX]/.test(src.slice(i, j))))) j += 1;
      }
      const word = src.slice(i, j);
      emit(word);
      i = j;
      last = BEFORE_REGEX.has(word) ? 'op' : 'value';
      continue;
    }
    if (c === '{' && tpl.length) tpl[tpl.length - 1] += 1;
    if (c === '}' && tpl.length) tpl[tpl.length - 1] -= 1;
    emit(c);
    i += 1;
    // ) ] 之后是值；} 之后多半是一条新语句的开头（块结束），/ 当正则
    last = c === ')' || c === ']' ? 'value' : 'op';
  }
  if (tpl.length) throw new Error('模板字符串里的 ${} 没有结束');
  return out.endsWith('\n') ? out : `${out}\n`;
}

function lineOf(src, at) {
  let line = 1;
  for (let k = 0; k < at; k += 1) if (src[k] === '\n') line += 1;
  return line;
}
