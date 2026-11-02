// 网页版纯逻辑在 JavaScriptCore 里跑时的宿主胶水（docs/jscore-pilot.md）。手写，可以改；改了不用重跑 sync-weblogic。
//
// 加载顺序：先本文件，再 reply.bundle.js。两份都随 app 打包，不从网上下载（App Store 审核 2.5.2）。
//
// 本文件做三件事：
// 1. 模块表（__wl.define / __wl.require）：reply.bundle.js 里每个模块注册进来，第一次 require 时执行。
// 2. 手写替身（__wlShims）：打包时被换掉的不纯模块，只给解析路径上真正调到的那一点。
//    - src/system/db/index.js：只有 settings.get()，返回网页版 DEFAULT_SETTINGS 叠上宿主传进来的几项。
//      其余数据域（messages、chats……）一律是存根。
//    - src/system/ai/templates.js：DEFAULT_TEMPLATES 给一个空对象。db/defaults.js 只 import 它、不读；
//      真正取模板的 template / fillTemplate 只在翻译请求里调，不在解析路径上，是存根。
// 3. 宿主接口 weblogic.parseReply(raw, optsJSON)：返回一段 JSON 字符串，原生那边解码。
//
// 存根：不在包里的模块读出来的每一项都是一个函数，调用就抛错，错误里写明模块与名字。
// 把存根当常量用（例如拿 day.DONE 当状态值）会把一个函数塞进结果里：序列化时遇到函数直接报错，不悄悄丢掉。
// 只用 ES2020，不碰 window / document / 定时器。
'use strict';
(function () {
  const factories = new Map();
  const cache = new Map();
  let stubbedIds = new Set();
  const hits = [];

  const unavailable = (id, name) => {
    const e = new Error(`weblogic: ${id} 的 ${String(name)} 不在包里（存根）`);
    e.name = 'WebLogicStub';
    return e;
  };

  // 一个模块的存根：任何属性都是一调就抛错的函数
  const stubModule = (id, explicit = {}) => new Proxy(explicit, {
    get(target, key) {
      if (typeof key === 'symbol') return undefined;
      if (key === 'then') return undefined;   // 不让它看起来像 Promise
      if (Object.prototype.hasOwnProperty.call(target, key)) return target[key];
      const fn = function () { hits.push(`${id}.${key}`); throw unavailable(id, key); };
      return fn;
    },
  });

  const __wl = {
    settings: {},
    commit: '',
    stubHits: hits,
    define(id, fn) { factories.set(id, fn); },
    stubbed(list) { stubbedIds = new Set(list); },
    bind(exp, name, get) { Object.defineProperty(exp, name, { get, enumerable: true }); },
    star(exp, mod) {
      for (const k of Object.keys(mod)) {
        if (k !== 'default' && !Object.prototype.hasOwnProperty.call(exp, k)) {
          Object.defineProperty(exp, k, { get: () => mod[k], enumerable: true });
        }
      }
    },
    dynamicImport(id) { return Promise.reject(unavailable(id, 'import()')); },
    require(id) {
      if (cache.has(id)) return cache.get(id);
      const shim = globalThis.__wlShims[id];
      if (shim) { const m = shim(); cache.set(id, m); return m; }
      if (stubbedIds.has(id)) { const m = stubModule(id); cache.set(id, m); return m; }
      const fn = factories.get(id);
      if (!fn) throw new Error(`weblogic: 模块表里没有 ${id}`);
      const exp = {};
      cache.set(id, exp);
      fn(exp);
      return exp;
    },
  };
  globalThis.__wl = __wl;

  globalThis.__wlShims = {
    'src/system/db/index.js': () => {
      const settings = stubModule('src/system/db/index.js#settings', {
        get: () => Object.assign({}, __wl.require('src/system/db/defaults.js').DEFAULT_SETTINGS, __wl.settings),
      });
      return stubModule('src/system/db/index.js', { settings });
    },
    'src/system/ai/templates.js': () => stubModule('src/system/ai/templates.js', { DEFAULT_TEMPLATES: {} }),
  };

  const noFunctions = (key, value) => {
    if (typeof value === 'function') throw new Error(`weblogic: 结果里的 ${key} 是一个函数（多半是把存根当成了常量）`);
    return value;
  };

  globalThis.weblogic = {
    /** 网页版提交号（打包时记下的） */
    commit: () => __wl.commit,
    /**
     * 网页版 splitReply。opts.settings 叠在网页版默认设置上，只在这一次调用里生效（例如 { autoSplitAt: 0 }）。
     * 返回 JSON：{ ok: true, parts: [...], think: "..." } 或 { ok: false, error: "..." }。
     */
    parseReply(raw, optsJSON) {
      const saved = __wl.settings;
      try {
        const opts = optsJSON ? JSON.parse(optsJSON) : {};
        __wl.settings = opts.settings || {};
        const reply = __wl.require('src/system/ai/reply.js');
        const parts = reply.splitReply(String(raw));
        const think = reply.stripThink(String(raw)).think || '';
        return JSON.stringify({ ok: true, parts, think }, noFunctions);
      } catch (e) {
        return JSON.stringify({ ok: false, error: `${e && e.name}: ${e && e.message}` });
      } finally {
        __wl.settings = saved;
      }
    },
  };
})();
