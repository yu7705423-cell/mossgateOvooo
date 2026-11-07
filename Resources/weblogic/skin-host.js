// 美化生成器在 JavaScriptCore 里跑时的宿主接口（docs/jscore-skin.md）。手写，可以改；改了不用重跑 sync-weblogic。
//
// 加载顺序：shims.js、本文件、skin.bundle.js（三份都随 app 打包，不从网上下载）。
// skin.bundle.js 是网页版 src/system/skin-gen.js 与 skin-paint.js 原样打的包：编辑器那一堆旋钮的定义（GROUPS）、
// 把设置编成一段 CSS（emit）。这里只把它们换成 JSON 交给原生：
//
//   weblogic.skin.groups()          全部分组与旋钮的定义（去掉函数；有显示条件的记 cond: true）
//   weblogic.skin.state(genJSON)    这一份设置下：每组显示哪几项、每组改过几项、每项当前的值、伪元素撞车、内嵌图片的账、渐变的摘要
//   weblogic.skin.emit(genJSON)     编出来的那一段 CSS
//
// 返回一律是 JSON 字符串：{ ok: true, ... } 或 { ok: false, error }。只用 ES2020，不碰 window / document / 定时器。
'use strict';
(function () {
  // JSContext 没有 btoa（skin-paint.js 的毛玻璃质感把一段 SVG 编成 base64）。只给 Latin-1 的字符串，同浏览器：超出的抛错
  if (typeof globalThis.btoa !== 'function') {
    const abc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    globalThis.btoa = input => {
      const s = String(input);
      let out = '';
      for (let i = 0; i < s.length; i += 3) {
        const a = s.charCodeAt(i), b = s.charCodeAt(i + 1), c = s.charCodeAt(i + 2);
        if (a > 255 || b > 255 || c > 255) throw new Error('btoa：字符串里有 Latin-1 以外的字符');
        const n = (a << 16) | ((b || 0) << 8) | (c || 0);
        out += abc[(n >> 18) & 63] + abc[(n >> 12) & 63] + (i + 1 < s.length ? abc[(n >> 6) & 63] : '=') + (i + 2 < s.length ? abc[n & 63] : '=');
      }
      return out;
    };
  }
  const gen = () => __wl.require('src/system/skin-gen.js');
  const parse = s => {
    if (!s) return {};
    const v = JSON.parse(s);
    return v && typeof v === 'object' && !Array.isArray(v) ? v : {};
  };
  const wrap = f => {
    try { return JSON.stringify(Object.assign({ ok: true }, f())); } catch (e) {
      return JSON.stringify({ ok: false, error: `${e && e.name}: ${e && e.message}` });
    }
  };
  const plain = v => (v === undefined || typeof v === 'function' ? undefined : v);
  const option = o => ({ id: String(o.id), label: String(o.label || o.id) });

  globalThis.weblogic.skin = {
    commit: () => __wl.commit,

    groups() {
      return wrap(() => ({
        groups: gen().GROUPS.map(g => ({
          id: g.id, label: g.label, short: plain(g.short), icon: plain(g.icon), desc: plain(g.desc),
          scene: plain(g.scene), focus: plain(g.focus), pick: plain(g.pick), card: g.card === true ? true : undefined,
          items: g.items.map(it => ({
            id: it.id, label: it.label, type: it.type, def: plain(it.def), unit: plain(it.unit),
            min: plain(it.min), max: plain(it.max), desc: plain(it.desc), more: it.more === true ? true : undefined,
            rows: plain(it.rows), hard: it.hard === true ? true : undefined,
            cond: typeof it.when === 'function' ? true : undefined,
            options: Array.isArray(it.options) ? it.options.map(option) : undefined,
          })),
        })),
      }));
    },

    state(genJSON) {
      return wrap(() => {
        const G = gen();
        const g = parse(genJSON);
        const visible = {};
        const changed = {};
        const values = {};
        const paints = {};
        for (const grp of G.GROUPS) {
          const v = G.groupValues(g, grp.id);
          values[grp.id] = v;
          visible[grp.id] = grp.items.filter(it => G.showItem(it, v)).map(it => it.id);
          changed[grp.id] = G.changedIn(g, grp.id);
          for (const it of grp.items) {
            if (it.type === 'paint') paints[`${grp.id}.${it.id}`] = G.paint.summary(v[it.id]);
          }
        }
        return { visible, changed, values, paints, conflicts: G.conflictsOf(g), weigh: G.weigh(g) };
      });
    },

    emit(genJSON) {
      return wrap(() => ({ css: gen().emit(parse(genJSON)) }));
    },
  };
})();
