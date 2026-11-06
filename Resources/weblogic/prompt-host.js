// 提示词拼装那一个 JSContext 的宿主胶水（docs/jscore-prompt.md）。手写，可以改；改了不用重跑 sync-weblogic。
//
// 加载顺序：shims.js（模块表）、本文件、prompt.bundle.js。三份都随 app 打包，不从网上下载（App Store 审核 2.5.2）。
// 回复解析那一个 JSContext（shims.js + reply.bundle.js）另是一个，两边的模块表互不相干。
//
// 本文件做四件事：
// 1. JSContext 里没有的几样全局：console（记进日志，交回宿主）、structuredClone、定时器（从不触发，只记次数）。
//    时间可以由宿主钉住（Date.now() 与 new Date() 都读它），两边对照时用同一个「此刻」。
// 2. 存储替身：网页版 db/idb.js（IndexedDB）换成内存表。表由宿主在每次拼装之前从原生库灌进来（table / kv），
//    db/index.js 与 collection.js 是网页版原样的，读到的就是这几张表。
//    **写一律不落盘**：拼提示词途中网页版会写的几处（标头像已看过之类）记进 writes 交回宿主，原生那边决定怎么办。
// 3. 宿主接口 weblogic.prompt.*：reset / table / kv / buildChat / output。
// 4. buildChat 照网页版 engine.js 的 streamReply 拼上下文的那一段依次调用网页版自己的函数（世界书激活、召回、
//    预设叠加、buildChatSystem、buildHistory），不重写其中任何一步的逻辑。网络那几步（识图等待、向量检索、重排、
//    天气与热点、排日程）不在这里：向量为空、召回走同步的那一条，和网页版没配这些接口时一样。
'use strict';
(function () {
  const __wl = globalThis.__wl;
  if (!__wl || !__wl.stubModule) throw new Error('weblogic: 先加载 shims.js');

  // ---- 1. 全局

  const logs = [];
  const say = level => (...args) => {
    if (logs.length >= 200) return;
    logs.push(`${level} ${args.map(a => {
      if (a instanceof Error) return `${a.name}: ${a.message}`;
      if (typeof a === 'string') return a;
      try { return JSON.stringify(a); } catch { return String(a); }
    }).join(' ')}`.slice(0, 2000));   // 有意截断：日志只给诊断看，一行太长的不必全留
  };
  globalThis.console = { log: say('log'), info: say('info'), debug: say('debug'), warn: say('warn'), error: say('error') };
  if (typeof globalThis.structuredClone !== 'function') {
    globalThis.structuredClone = v => (v === undefined ? undefined : JSON.parse(JSON.stringify(v)));
  }
  let timerSeq = 0;
  const timers = { count: 0 };
  globalThis.setTimeout = () => { timers.count += 1; return ++timerSeq; };
  globalThis.setInterval = () => { timers.count += 1; return ++timerSeq; };
  globalThis.clearTimeout = () => {};
  globalThis.clearInterval = () => {};
  if (typeof globalThis.queueMicrotask !== 'function') globalThis.queueMicrotask = fn => { Promise.resolve().then(fn); };
  // 几个模块在顶层建一个 TextEncoder（zip.js 之类，拼装路径上不用）。只给 UTF-8
  if (typeof globalThis.TextEncoder !== 'function') {
    globalThis.TextEncoder = class TextEncoder {
      get encoding() { return 'utf-8'; }
      encode(str = '') {
        const s = unescape(encodeURIComponent(String(str)));
        const out = new Uint8Array(s.length);
        for (let i = 0; i < s.length; i += 1) out[i] = s.charCodeAt(i);
        return out;
      }
    };
  }
  if (typeof globalThis.TextDecoder !== 'function') {
    globalThis.TextDecoder = class TextDecoder {
      get encoding() { return 'utf-8'; }
      decode(buf) {
        if (!buf) return '';
        const u = buf instanceof Uint8Array ? buf : new Uint8Array(buf.buffer || buf);
        let s = '';
        for (let i = 0; i < u.length; i += 1) s += String.fromCharCode(u[i]);
        try { return decodeURIComponent(escape(s)); } catch { return s; }
      }
    };
  }

  const RealDate = Date;
  let pinned = null;
  class HostDate extends RealDate {
    constructor(...a) { if (a.length) super(...a); else super(pinned ?? RealDate.now()); }
    static now() { return pinned ?? RealDate.now(); }
  }
  globalThis.Date = HostDate;

  // 动态 import：包里有那个模块就给它（异步），没有就拒
  __wl.dynamicImport = id => (__wl.has(id)
    ? Promise.resolve().then(() => __wl.require(id))
    : Promise.reject(new Error(`weblogic: import('${id}') 不在包里`)));

  // ---- 2. 存储替身

  let tables = {};     // 数据域 -> 行数组
  let kvs = {};        // kv 键 -> 值
  const writes = [];   // 拼装途中网页版想写的：{ op, store, id }
  let feeding = false; // 宿主灌数据时不算写
  const wrote = (op, store, id) => { if (!feeding && writes.length < 500) writes.push({ op, store, id: id == null ? '' : String(id) }); };
  const ok = v => Promise.resolve(v);
  const schemaVersion = () => __wl.require('src/system/db/schema.js').DATA_VERSION;

  globalThis.__wlShims = {
    'src/system/db/idb.js': () => __wl.stubModule('src/system/db/idb.js', {
      open: () => Promise.reject(new Error('weblogic: 没有 IndexedDB')),
      idb: __wl.stubModule('src/system/db/idb.js#idb', {
        all: store => ok((tables[store] || []).slice()),
        get: (store, key) => {
          if (store === 'kv') {
            if (key === 'schemaVersion') return ok({ k: key, v: schemaVersion() });   // 迁移由网页版导出时做过，这里不跑
            return ok(Object.prototype.hasOwnProperty.call(kvs, key) ? { k: key, v: kvs[key] } : undefined);
          }
          return ok((tables[store] || []).find(r => r && r.id === key));
        },
        put: (store, v) => { wrote('put', store, v && (v.id ?? v.k)); return ok(); },
        del: (store, key) => { wrote('del', store, key); return ok(); },
        clear: store => { wrote('clear', store, ''); return ok(); },
        putAll: (store, list) => { (list || []).forEach(v => wrote('put', store, v && (v.id ?? v.k))); return ok(); },
      }),
      WRITE_FAILED: 'eira-db-write-failed',
      write: store => { wrote('write', store, ''); return ok(); },
      writeRow: (store, row) => wrote('put', store, row && row.id),
      deleteRow: (store, id) => wrote('del', store, id),
      deleteRows: (store, ids) => (ids || []).forEach(id => wrote('del', store, id)),
      clearRows: store => { wrote('clear', store, ''); return ok(); },
      flushWrites: () => ok([]),
    }),
  };

  // ---- 3. 宿主接口

  // 拼装途中读过哪几个数据域（宿主据此决定以后灌哪几张表，docs/jscore-prompt.md 的「灌表」）
  const touched = new Set();
  const READS = ['get', 'has', 'all', 'each', 'where', 'byIndex', 'count', 'indexVersion'];

  let booted = null;
  const boot = () => booted || (booted = (async () => {
    const dbm = __wl.require('src/system/db/index.js');
    await dbm.ready;
    for (const c of Object.values(dbm.db)) {
      if (!c || !c.name || typeof c.removeWhere !== 'function') continue;
      for (const k of READS) {
        const f = c[k];
        if (typeof f !== 'function') continue;
        c[k] = function (...a) { if (!feeding) touched.add(c.name); return f.apply(this, a); };
      }
    }
    return dbm;
  })());

  /**
   * 把宿主灌进来的表换进网页版的内存镜像。
   * 不用 collection.load()：它会把桶的版本号清零再数一遍，条数相同、内容变了的一段会话，
   * db/index.js 里 messagesOf 的排序缓存会认成没变。这里先整表删掉再逐条放进去，版本号只增不减。
   */
  function refill(dbm) {
    feeding = true;
    try {
      for (const c of Object.values(dbm.db)) {
        if (!c || typeof c.removeWhere !== 'function' || typeof c.put !== 'function' || !c.name) continue;
        c.removeWhere(() => true);
        for (const r of tables[c.name] || []) if (r && r.id) c.put(r);
      }
    } finally { feeding = false; }
    return Promise.all([dbm.settings.load(), dbm.persona.load(), dbm.layout.load()]);
  }

  const noFunctions = (key, value) => {
    if (typeof value === 'function') throw new Error(`weblogic: 结果里的 ${key} 是一个函数（多半是把存根当成了常量）`);
    return value;
  };

  let output = null;

  /** 照 engine.js 的 streamReply：拼上下文那一段。只调网页版的函数，次序与参数同那里 */
  async function buildChat(req) {
    const t0 = RealDate.now();
    const dbm = await boot();
    await refill(dbm);
    const t1 = RealDate.now();
    const engine = __wl.require('src/system/ai/engine.js');
    const presetsLib = __wl.require('src/system/presets.js');
    const lorebook = __wl.require('src/system/ai/context/lorebook.js');
    const memory = __wl.require('src/system/ai/context/memory.js');
    const faceLib = __wl.require('src/system/face.js');
    const accounts = __wl.require('src/system/accounts.js');
    const { chats, characters, messagesOf } = dbm;

    const chat = chats.get(req.chatId);
    if (!chat) throw new Error(`没有这段会话：${req.chatId}`);
    const char = characters.get(req.charId || (chat.characterIds || [])[0]);
    if (!char) throw new Error(`没有这个角色：${req.charId || ''}`);
    const excludeTurn = req.excludeTurn || '';
    const msgs = messagesOf(chat.id).filter(m => m.status !== 'error' && (!excludeTurn || m.turnId !== excludeTurn));
    // 识图交给聊天模型时这一轮的原图：原生那边自己挂（AIMessage.images），这里不读图
    const pics = null;
    const s0 = presetsLib.settingsFor(chat);
    const lore = lorebook.activate(char, engine.scanTextOf(msgs, s0.scanWindow),
      engine.budgets(s0.contextBudget).lorebook, { ...(faceLib.on(chat) ? faceLib.books(chat) : {}), preset: s0.presetLore }).items;
    // 向量检索要调接口，这里没有：和网页版没配向量接口时一样，为 null
    const queryVec = null;
    const me = accounts.get(chat.personaId) || accounts.current();
    const skip = new Set(memory.recentOf(char.id, me && me.id, s0.memoryRecent, chat.id).map(m => m.id));
    // 重排要调接口：走同步的那一条（recallAsync 没开重排时也是它）
    const recall = s0.memoryEnabled ? memory.recall({
      settings: s0, char, chat, scanText: engine.scanTextOf(msgs, s0.scanWindow),
      budgets: engine.budgets(s0.contextBudget), queryVec, persona: me, skip,
    }) : [];
    const built = presetsLib.within(chat, () => {
      const sys = engine.buildChatSystem(chat, char, msgs, { queryVec, lore, recall });
      return { sys, history: engine.buildHistory(chat, char, msgs,
        { images: pics, lore, recall, volatile: sys.volatile, inserts: sys.inserts, followUp: true }) };
    });
    const t2 = RealDate.now();
    return {
      ok: true,
      system: built.sys.system,
      messages: built.history.map(m => ({ role: m.role, content: String(m.content ?? '') })),
      failed: built.sys.failed || [],
      recalled: (recall || []).map(m => m.id),
      forumShown: !!built.sys.forumShown,
      ms: { refill: t1 - t0, build: t2 - t1 },
    };
  }

  const prompt = {
    /** 清空上一次灌进来的表与日志。now：钉住的此刻（毫秒），不给就用真实时间 */
    reset(now) {
      tables = {};
      kvs = {};
      writes.length = 0;
      logs.length = 0;
      touched.clear();
      timers.count = 0;
      __wl.stubHits.length = 0;
      pinned = typeof now === 'number' && isFinite(now) ? now : null;
    },
    /** 一个数据域的全部行（JSON 数组的原文） */
    table(name, json) { tables[name] = JSON.parse(json); return tables[name].length; },
    /** 一个 kv（settings / persona / layout）的值（JSON 原文） */
    kv(key, json) { kvs[key] = JSON.parse(json); },
    /**
     * 拼一次。req：{ chatId, charId?, excludeTurn? }（JSON 原文）。
     * 返回一个 Promise；JSContext 在这次调用返回之前把微任务跑完，所以宿主随后读 output() 就是结果。
     * 结果 JSON：{ ok, system, messages, failed, recalled, writes, stubHits, logs, timers, ms } 或 { ok: false, error, … }
     */
    buildChat(reqJSON) {
      output = null;
      const finish = obj => {
        Object.assign(obj, { touched: [...touched].sort(), writes: writes.slice(), stubHits: __wl.stubHits.slice(), logs: logs.slice(), timers: timers.count, commit: __wl.commit });
        try { output = JSON.stringify(obj, noFunctions); }
        catch (e) { output = JSON.stringify({ ok: false, error: `${e && e.name}: ${e && e.message}` }); }
        return output;
      };
      let req;
      try { req = JSON.parse(reqJSON); } catch (e) { return Promise.resolve(finish({ ok: false, error: `请求不是 JSON：${e.message}` })); }
      return buildChat(req).then(finish, e => finish({ ok: false, error: `${e && e.name}: ${e && e.message}`, stack: String(e && e.stack || '').slice(0, 2000) }));
    },
    /** 上一次 buildChat 的结果（JSON 原文）。还没跑完是 null */
    output() { return output; },
  };

  globalThis.weblogic = Object.assign(globalThis.weblogic || {}, { prompt });
})();
