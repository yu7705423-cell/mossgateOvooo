// 提示词拼装那一个 JSContext 的宿主胶水（docs/jscore-prompt.md）。手写，可以改；改了不用重跑 sync-weblogic。
//
// 加载顺序：shims.js（模块表）、本文件、prompt.bundle.js。三份都随 app 打包，不从网上下载（App Store 审核 2.5.2）。
// 回复解析那一个 JSContext（shims.js + reply.bundle.js）另是一个，两边的模块表互不相干。
//
// 本文件做四件事：
// 1. JSContext 里没有的几样全局：console（记进日志，交回宿主）、structuredClone、定时器（从不触发，只记次数）。
//    时间可以由宿主钉住（Date.now() 与 new Date() 都读它），两边对照时用同一个「此刻」。
// 2. 存储替身：网页版 db/idb.js（IndexedDB）换成内存表。db/index.js 与 collection.js 是网页版原样的。
//    **表常驻**：宿主第一次整表灌进来，之后只交变了的行（upsert / remove / dropChat / trimChat / kv），
//    哪些行变了由原生库的变更记录决定（Store/ChangeLog.swift、Prompt/WebPromptFeed.swift）。
// 3. 写：拼提示词途中网页版会写的几处（标头像已看过之类）不落盘，按行算出改了哪几个字段交回宿主（changes），
//    由原生写回自己的库（Prompt/WebPromptWrites.swift：合并字段，不认得的字段留着）。
// 4. 宿主接口 weblogic.prompt.*，以及 buildChat：照网页版 engine.js 的 streamReply 拼上下文的那一段依次调用网页版自己的函数
//    （世界书激活、召回、预设叠加、buildChatSystem、buildHistory），不重写其中任何一步的逻辑。网络那几步（识图等待、向量检索、重排、
//    天气与热点、排日程）不在这里：向量为空、召回走同步的那一条，和网页版没配这些接口时一样。
'use strict';
(function () {
  const __wl = globalThis.__wl;
  if (!__wl || !__wl.stubModule) throw new Error('weblogic: 先加载 shims.js');


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

  let colls = {};      // 数据域 -> 网页版的 collection（boot 之后才有）
  let tables = {};     // 网页版没有对应 collection 的数据域（图片登记之类）：原样放着，idb.all 读它
  let kvs = {};        // kv 键 -> 原生库里那一份（没有默认值叠上去的原文）
  let feeding = false; // 宿主灌数据时不算读，也不算写
  const ok = v => Promise.resolve(v);
  const schemaVersion = () => __wl.require('src/system/db/schema.js').DATA_VERSION;

  // 拼装途中网页版写了什么。行：先记下第一次碰它之前的样子，拼完再和那时比
  const rowTouch = new Map();   // "数据域\u0000id" -> { store, id, prev, persisted, mem }
  const kvWrites = {};          // kv 键 -> 网页版要存的整份
  const others = [];            // 网页版没有对应 collection 的数据域上的写（图片、文件……）：不写回，只报给宿主
  const cleared = new Set();    // 整个数据域清空：不写回，宿主下一次整表重灌
  const clearWrites = () => {
    rowTouch.clear();
    for (const k of Object.keys(kvWrites)) delete kvWrites[k];
    others.length = 0;
    cleared.clear();
  };

  globalThis.__wlShims = {
    'src/system/db/idb.js': () => __wl.stubModule('src/system/db/idb.js', {
      open: () => Promise.reject(new Error('weblogic: 没有 IndexedDB')),
      idb: __wl.stubModule('src/system/db/idb.js#idb', {
        all: store => ok(colls[store] ? colls[store].all() : (tables[store] || []).slice()),
        get: (store, key) => {
          if (store === 'kv') {
            if (key === 'schemaVersion') return ok({ k: key, v: schemaVersion() });   // 迁移由网页版导出时做过，这里不跑
            return ok(Object.prototype.hasOwnProperty.call(kvs, key) ? { k: key, v: kvs[key] } : undefined);
          }
          if (colls[store]) return ok(colls[store].get(key) || undefined);
          return ok((tables[store] || []).find(r => r && r.id === key));
        },
        put: (store, v) => {
          if (feeding) return ok();
          if (store === 'kv') { if (v && v.k !== 'schemaVersion') kvWrites[v.k] = v.v; }
          else if (!colls[store]) others.push({ op: 'put', store, id: v && (v.id ?? v.k) });
          return ok();
        },
        del: (store, key) => { if (!feeding && !colls[store]) others.push({ op: 'del', store, id: key }); return ok(); },
        clear: store => { if (!feeding && !colls[store]) others.push({ op: 'clear', store, id: '' }); return ok(); },
        putAll: (store, list) => { if (!feeding && !colls[store]) (list || []).forEach(v => others.push({ op: 'put', store, id: v && (v.id ?? v.k) })); return ok(); },
      }),
      WRITE_FAILED: 'eira-db-write-failed',
      // collection.js 落盘走这几个。行上的写由下面包在 collection 外面的那一层记（要知道改之前的样子），这里不重复记
      write: () => ok(),
      writeRow: () => {},
      deleteRow: () => {},
      deleteRows: () => {},
      clearRows: () => ok(),
      flushWrites: () => ok([]),
    }),
  };

  // ---- 3. 宿主接口

  // 拼装途中读过哪几个数据域（宿主据此决定以后灌哪几张表，docs/jscore-prompt.md 的「灌表」）
  const touched = new Set();
  const READS = ['get', 'has', 'all', 'each', 'where', 'byIndex', 'count', 'indexVersion'];

  let dbm = null;
  let booted = null;
  const boot = () => booted || (booted = (async () => {
    const m = __wl.require('src/system/db/index.js');
    await m.ready;
    for (const c of Object.values(m.db)) {
      if (!c || !c.name || typeof c.removeWhere !== 'function') continue;
      colls[c.name] = c;
      const rawGet = c.get, rawAll = c.all, rawCount = c.count;
      for (const k of READS) {
        const f = c[k];
        if (typeof f !== 'function') continue;
        c[k] = function (...a) { if (!feeding) touched.add(c.name); return f.apply(this, a); };
      }
      // 写：第一次碰一行之前记下它原来的样子；persist: false 的只改内存（流式占位那种），记成 mem
      const note = (id, persisted) => {
        if (feeding || id == null) return;
        const key = `${c.name}\u0000${id}`;
        let t = rowTouch.get(key);
        if (!t) rowTouch.set(key, t = { store: c.name, id: String(id), prev: rawGet.call(c, id), persisted: false, mem: false });
        if (persisted) t.persisted = true; else t.mem = true;
      };
      const wrap = (name, before) => {
        const f = c[name];
        if (typeof f !== 'function') return;
        c[name] = function (...a) { before(...a); return f.apply(this, a); };
      };
      wrap('update', (id, patch, opts) => note(id, !opts || opts.persist !== false));
      wrap('put', row => note(row && row.id, true));
      wrap('remove', id => note(id, true));
      wrap('removeWhere', fn => { if (!feeding) for (const r of rawAll.call(c).filter(fn)) note(r.id, true); });
      wrap('clear', () => { if (!feeding) cleared.add(c.name); });
      const create = c.create;
      c.create = function (data, opts) {
        const row = create.call(this, data, opts);
        if (!feeding && row) {
          const key = `${c.name}\u0000${row.id}`;
          if (!rowTouch.has(key)) rowTouch.set(key, { store: c.name, id: String(row.id), prev: null, persisted: false, mem: false });
          const t = rowTouch.get(key);
          if (!opts || opts.persist !== false) t.persisted = true; else t.mem = true;
        }
        return row;
      };
      c.__rawGet = rawGet;
      c.__rawCount = rawCount;
    }
    dbm = m;
    return m;
  })());

  const need = () => { if (!dbm) throw new Error('weblogic: 还没有 boot'); return dbm; };
  const feed = fn => { feeding = true; try { return fn(); } finally { feeding = false; } };
  const rows = json => (typeof json === 'string' ? JSON.parse(json) : json) || [];

  // kv 换了之后要重新 load（网页版的 makeKV 自己叠默认值）。load 是异步的，放到 buildChat 开头做、等它做完
  const dirtyKV = new Set();
  const KVS = ['settings', 'persona', 'layout'];
  const reloadKV = key => { dirtyKV.add(key); };
  const loadKVs = () => {
    const keys = [...dirtyKV];
    dirtyKV.clear();
    return Promise.all(keys.filter(k => dbm[k] && typeof dbm[k].load === 'function').map(k => dbm[k].load()));
  };

  const sameJSON = (a, b) => {
    if (a === b) return true;
    try { return JSON.stringify(a) === JSON.stringify(b); } catch { return false; }
  };

  /** 这一次拼装途中网页版写了什么，按行与 kv 算成改动（宿主照着写回原生库） */
  function changes() {
    const out = [];
    for (const t of rowTouch.values()) {
      const c = colls[t.store];
      if (cleared.has(t.store)) continue;
      const now = c ? (c.__rawGet.call(c, t.id) || null) : null;
      if (!t.persisted) { out.push({ op: 'mem', store: t.store, id: t.id }); continue; }
      if (!t.prev && !now) continue;
      if (!t.prev) { out.push({ op: 'insert', store: t.store, id: t.id, row: now }); continue; }
      if (!now) { out.push({ op: 'delete', store: t.store, id: t.id }); continue; }
      if (now === t.prev) {
        // 原地改了再 put：改之前的样子已经看不到，整行交回去，原生那边逐个字段盖上（不认得的字段照样留着）
        out.push({ op: 'patch', store: t.store, id: t.id, set: { ...now }, unset: [], whole: true });
        continue;
      }
      const set = {}, unset = [];
      for (const k of Object.keys(now)) {
        if (now[k] === undefined) { if (t.prev[k] !== undefined) unset.push(k); continue; }
        if (!sameJSON(now[k], t.prev[k])) set[k] = now[k];
      }
      for (const k of Object.keys(t.prev)) if (!(k in now) && t.prev[k] !== undefined) unset.push(k);
      if (Object.keys(set).length || unset.length) out.push({ op: 'patch', store: t.store, id: t.id, set, unset });
    }
    const defaults = __wl.require('src/system/db/defaults.js');
    const fallbackOf = { settings: defaults.DEFAULT_SETTINGS, persona: defaults.DEFAULT_PERSONA, layout: defaults.DEFAULT_LAYOUT };
    for (const [key, next] of Object.entries(kvWrites)) {
      const fed = kvs[key] && typeof kvs[key] === 'object' ? kvs[key] : {};
      const fb = fallbackOf[key] || {};
      const set = {}, unset = [];
      // 网页版存的是叠了默认值的整份；只交和原来（原生库里的那份，没有的取默认值）不同的那几项
      const expected = k => (k in fed
        ? (key === 'settings' && k === 'promptTemplates' ? { ...(fb.promptTemplates || {}), ...(fed.promptTemplates || {}) } : fed[k])
        : fb[k]);
      for (const k of Object.keys(next || {})) {
        if (next[k] === undefined) { if (k in fed) unset.push(k); continue; }
        if (!sameJSON(next[k], expected(k))) set[k] = next[k];
      }
      for (const k of Object.keys(fed)) if (!(k in (next || {}))) unset.push(k);
      if (Object.keys(set).length || unset.length) out.push({ op: 'kv', store: 'kv', id: key, set, unset });
    }
    for (const w of others) out.push({ op: 'other', store: w.store, id: w.id == null ? '' : String(w.id), what: w.op });
    for (const s of cleared) out.push({ op: 'clear', store: s, id: '' });
    return out;
  }

  const noFunctions = (key, value) => {
    if (typeof value === 'function') throw new Error(`weblogic: 结果里的 ${key} 是一个函数（多半是把存根当成了常量）`);
    return value;
  };

  let output = null;

  /** 照 engine.js 的 streamReply：拼上下文那一段。只调网页版的函数，次序与参数同那里 */
  async function buildChat(req) {
    const t0 = RealDate.now();
    const m = need();
    await loadKVs();
    const t1 = RealDate.now();
    const engine = __wl.require('src/system/ai/engine.js');
    const presetsLib = __wl.require('src/system/presets.js');
    const lorebook = __wl.require('src/system/ai/context/lorebook.js');
    const memory = __wl.require('src/system/ai/context/memory.js');
    const faceLib = __wl.require('src/system/face.js');
    const accounts = __wl.require('src/system/accounts.js');
    const { chats, characters, messagesOf } = m;

    const chat = chats.get(req.chatId);
    if (!chat) throw new Error(`没有这段会话：${req.chatId}`);
    const char = characters.get(req.charId || (chat.characterIds || [])[0]);
    if (!char) throw new Error(`没有这个角色：${req.charId || ''}`);
    const excludeTurn = req.excludeTurn || '';
    const msgs = messagesOf(chat.id).filter(x => x.status !== 'error' && (!excludeTurn || x.turnId !== excludeTurn));
    // 识图交给聊天模型时这一轮的原图：原生那边自己挂（AIMessage.images），这里不读图
    const pics = null;
    const s0 = presetsLib.settingsFor(chat);
    const lore = lorebook.activate(char, engine.scanTextOf(msgs, s0.scanWindow),
      engine.budgets(s0.contextBudget).lorebook, { ...(faceLib.on(chat) ? faceLib.books(chat) : {}), preset: s0.presetLore }).items;
    // 向量检索要调接口，这里没有：和网页版没配向量接口时一样，为 null
    const queryVec = null;
    const me = accounts.get(chat.personaId) || accounts.current();
    const skip = new Set(memory.recentOf(char.id, me && me.id, s0.memoryRecent, chat.id).map(x => x.id));
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
      messages: built.history.map(x => ({ role: x.role, content: String(x.content ?? '') })),
      failed: built.sys.failed || [],
      recalled: (recall || []).map(x => x.id),
      forumShown: !!built.sys.forumShown,
      ms: { refill: t1 - t0, build: t2 - t1 },
    };
  }

  const prompt = {
    /** 第一次用之前调一次：网页版 db/index.js 的 ready（全是空表）。返回 Promise；JSContext 在这次调用返回之前把它跑完 */
    boot() { return boot().then(() => true); },
    isReady() { return !!dbm; },
    /** 每拼一次之前：清掉上一次的日志与写。now：钉住的此刻（毫秒），不给就用真实时间 */
    begin(now) {
      logs.length = 0;
      touched.clear();
      timers.count = 0;
      __wl.stubHits.length = 0;
      clearWrites();
      pinned = typeof now === 'number' && isFinite(now) ? now : null;
    },
    /** 全部清空（整表重灌之前） */
    clearAll() {
      need();
      feed(() => { for (const c of Object.values(colls)) c.removeWhere(() => true); });
      tables = {};
      kvs = {};
      for (const k of KVS) reloadKV(k);
    },
    /** 一个数据域整个换掉（JSON 数组的原文）。返回行数 */
    replace(name, json) {
      need();
      const list = rows(json);
      const c = colls[name];
      if (!c) { tables[name] = list; return list.length; }
      feed(() => { c.removeWhere(() => true); for (const r of list) if (r && r.id) c.put(r); });
      return list.length;
    },
    /** 新的与改过的几行（JSON 数组的原文） */
    upsert(name, json) {
      need();
      const list = rows(json);
      const c = colls[name];
      if (!c) {
        const t = tables[name] || (tables[name] = []);
        for (const r of list) { const i = t.findIndex(x => x && x.id === r.id); if (i >= 0) t[i] = r; else t.push(r); }
        return list.length;
      }
      feed(() => { for (const r of list) if (r && r.id) c.put(r); });
      return list.length;
    },
    /** 删掉几行（id 的 JSON 数组）。返回真删掉的那几行所在的会话（只有消息有意义），JSON 数组的原文 */
    remove(name, idsJSON) {
      need();
      const ids = rows(idsJSON);
      const c = colls[name];
      const chatIds = new Set();
      if (!c) { if (tables[name]) tables[name] = tables[name].filter(r => !ids.includes(r && r.id)); return '[]'; }
      feed(() => {
        for (const id of ids) {
          const r = c.__rawGet.call(c, id);
          if (r && r.chatId != null) chatIds.add(String(r.chatId));
          c.remove(id);
        }
      });
      return JSON.stringify([...chatIds]);
    },
    /** 这段会话的消息全部从表里拿掉 */
    dropChat(chatId) {
      const m = need();
      let n = 0;
      feed(() => { for (const r of m.messages.byIndex(chatId)) { m.messages.remove(r.id); n += 1; } });
      return n;
    },
    /** 这段会话的消息只留最近 limit 条（顺序同 messagesOf） */
    trimChat(chatId, limit) {
      const m = need();
      return feed(() => {
        const list = m.messagesOf(chatId);
        const extra = list.length - limit;
        if (extra <= 0) return 0;
        const doomed = list.slice(0, extra).map(r => r.id);
        for (const id of doomed) m.messages.remove(id);
        return doomed.length;
      });
    },
    /** 这段会话的消息在表里有几条 */
    chatCount(chatId) { return need().messages.byIndex(chatId).length; },
    /** 一个数据域在表里有几行 */
    count(name) { need(); return colls[name] ? colls[name].__rawCount() : (tables[name] || []).length; },
    /** 一个 kv（settings / persona / layout）的值（JSON 原文）；null 表示库里没有这一条 */
    kv(key, json) {
      need();
      if (json == null) delete kvs[key];
      else kvs[key] = typeof json === 'string' ? JSON.parse(json) : json;
      reloadKV(key);
    },
    /**
     * 拼一次。req：{ chatId, charId?, excludeTurn? }（JSON 原文）。
     * 返回一个 Promise；JSContext 在这次调用返回之前把微任务跑完，所以宿主随后读 output() 就是结果。
     * 结果 JSON：{ ok, system, messages, failed, recalled, changes, writes, stubHits, logs, timers, ms } 或 { ok: false, error, … }
     */
    buildChat(reqJSON) {
      output = null;
      const finish = obj => {
        let ch = [];
        try { ch = changes(); } catch (e) { obj = { ok: false, error: `算写入时出错：${e && e.message}` }; }
        Object.assign(obj, {
          touched: [...touched].sort(), changes: ch,
          writes: ch.map(w => `${w.op === 'insert' || w.op === 'patch' ? 'put' : w.op === 'delete' ? 'del' : w.op} ${w.store} ${w.id}`),
          stubHits: __wl.stubHits.slice(), logs: logs.slice(), timers: timers.count, commit: __wl.commit,
        });
        try { output = JSON.stringify(obj, noFunctions); }
        catch (e) { output = JSON.stringify({ ok: false, error: `${e && e.name}: ${e && e.message}` }); }
        return output;
      };
      let req;
      try { req = JSON.parse(reqJSON); } catch (e) { return Promise.resolve(finish({ ok: false, error: `请求不是 JSON：${e.message}` })); }
      return buildChat(req).then(finish, e => finish({ ok: false, error: `${e && e.name}: ${e && e.message}`, stack: String(e && e.stack || '').slice(0, 2000) }));   // 有意截断：只给诊断看
    },
    /** 上一次 buildChat 的结果（JSON 原文）。还没跑完是 null */
    output() { return output; },

    // 从前的整表灌法（check-weblogic 与旧的调用方式）：reset 之后逐表 table
    reset(now) { this.begin(now); this.clearAll(); },
    table(name, json) { return this.replace(name, json); },
  };

  globalThis.weblogic = Object.assign(globalThis.weblogic || {}, { prompt });
})();
