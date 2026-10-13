// 最小的 ZIP 读写。
//
// 为什么要它：备份里有图片、音频、视频。塞进 JSON 就得转 base64，
// 一份五百兆的片子会变成六百多兆的**字符串**，还得整个握在内存里 —— 必炸。
// ZIP 的好处是**每一份文件原样躺在里面**，写的时候可以一段一段拼 Blob，
// 从头到尾没有哪一刻需要把全部内容读进内存。
//
// 只做 store（method 0，不压缩）。图片、音频、视频本来就是压过的，
// 再压一遍省不下几个百分点，却要把每一个字节都过一遍 CPU。
// **读的时候认 deflate**：别的工具打的包也能导进来，解压交给浏览器自带的
// DecompressionStream，同样不自己实现。
//
// 不做 ZIP64。超过四个吉字节的包这里直接拒绝 —— 那个规格要另写一套头，
// 而到那个体量，浏览器这条路本来也该换成在电脑上做。
//
// ---- 读的时候为什么还留了一条「顺着本地头爬」的后路 ----
//
// ZIP 有两份目录：每份文件前面各有一个本地头，末尾另有一张中央目录总表。
// 正常都按中央目录读，一次定位，不用把整个文件过一遍。
//
// 但中央目录是**最容易被写坏的那一份**：它记的是「第几个字节开始」，
// 任何一个把包拆开改一个文件再拼回去的工具，只要偏移量没跟着重算，
// 这张表就指到别处去了 —— 文件本身一个字节没坏，却整包都读不出来。
// 遇到过一次：改过的角色包导进来说「没有 character.json」。
//
// 所以中央目录读不出东西时，退回去从头顺着本地头爬一遍。慢，但救得回来。

const LOCAL = 0x04034b50;
const CENTRAL = 0x02014b50;
const END = 0x06054b50;
const LIMIT = 0xffffffff;

// ---- CRC32。ZIP 每一条都要带，躲不掉 ----
const TABLE = (() => {
  const t = new Uint32Array(256);
  for (let i = 0; i < 256; i++) {
    let c = i;
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
    t[i] = c >>> 0;
  }
  return t;
})();

const STEP = 4 * 1024 * 1024;

/**
 * 把一条的字节抄一份出来，顺带算 CRC。分片走，一片四兆，不整个读进内存。
 *
 * ---- 为什么要抄，不直接把源 Blob 接进包里 ----
 *
 * 从前这里只算 CRC，然后把**源 Blob 原样**接进 parts，最后 new Blob(parts)
 * 时才真正去读它。源 Blob 是 IndexedDB 里那一份，而那一读发生在整包拼完
 * 之后 —— 一个大库要拼好几分钟。WebKit 上隔这么久再去读 IndexedDB 里的
 * Blob 是会失手的，读回来比 `blob.size` 少，甚至一个字节都没有。
 *
 * 而中央目录里的偏移量早就按 `blob.size` 算好了。少写几个字节，它**后面
 * 每一条**的偏移量就全错，末尾那条记录指的位置也错 —— 打出来的包自检
 * 挂在「中央目录记的偏移量对不上」，正是这么来的。
 *
 * 抄一份之后，接进包里的是本页自己的 Blob，不再回头去问 IndexedDB。
 * 而且回来的 `size` 是**真的读到了多少字节**，不是 `blob.size` 的一面之词：
 * 就算读短了，头里记的长度和实际写进去的也是同一个数，包仍然是完整的。
 */
async function copyOf(blob) {
  let c = 0xffffffff;
  let size = 0;
  const chunks = [];
  for (let at = 0; at < blob.size; at += STEP) {
    const part = new Uint8Array(await blob.slice(at, Math.min(blob.size, at + STEP)).arrayBuffer());
    for (let i = 0; i < part.length; i++) c = TABLE[(c ^ part[i]) & 0xff] ^ (c >>> 8);
    size += part.length;
    if (part.length) chunks.push(new Blob([part]));
  }
  return { crc: (c ^ 0xffffffff) >>> 0, size, chunks };
}

const enc = new TextEncoder();

// 把几段字节接成一段
function bytes(list) {
  const out = new Uint8Array(list.reduce((n, x) => n + x.length, 0));
  let at = 0;
  for (const x of list) { out.set(x, at); at += x.length; }
  return out;
}

const u16 = n => new Uint8Array([n & 0xff, (n >> 8) & 0xff]);
const u32 = n => new Uint8Array([n & 0xff, (n >> 8) & 0xff, (n >> 16) & 0xff, (n >>> 24) & 0xff]);

// DOS 时间。分辨率是两秒，这里不在乎，取个当前时刻就行。
function dosTime(d = new Date()) {
  return {
    time: ((d.getHours() << 11) | (d.getMinutes() << 5) | (d.getSeconds() >> 1)) & 0xffff,
    date: (((d.getFullYear() - 1980) << 9) | ((d.getMonth() + 1) << 5) | d.getDate()) & 0xffff,
  };
}

/**
 * 打包。entries 每一条是 { name, blob } 或 { name, text }。
 * 回来的是一个 Blob，可以直接下载。
 */
export async function zip(entries, { onProgress } = {}) {
  const parts = [];
  const central = [];
  const { time, date } = dosTime();
  let at = 0;
  let done = 0;

  const short = [];
  for (const entry of entries) {
    const src = entry.blob || new Blob([enc.encode(String(entry.text || ''))]);
    const name = enc.encode(entry.name);
    // 先抄完再写头：头里要记 CRC 与长度，而这两样都得读完才知道
    const { crc, size, chunks } = await copyOf(src);
    // 读短了记一笔。不中断 —— 少一张图也比整份导不出来强，
    // 但导完要说清楚少了哪几张
    if (size !== src.size) short.push(entry.name);
    if (at + 30 + name.length + size > LIMIT) throw new Error('备份超过 4 GB，请去掉视频后重试');

    parts.push(bytes([
      u32(LOCAL), u16(20), u16(0x0800), u16(0),      // 0x0800：文件名按 UTF-8
      u16(time), u16(date), u32(crc), u32(size), u32(size),
      u16(name.length), u16(0), name,
    ]));
    for (const chunk of chunks) parts.push(chunk);

    central.push(bytes([
      u32(CENTRAL), u16(20), u16(20), u16(0x0800), u16(0),
      u16(time), u16(date), u32(crc), u32(size), u32(size),
      u16(name.length), u16(0), u16(0), u16(0), u16(0), u32(0), u32(at), name,
    ]));
    at += 30 + name.length + size;
    done += 1;
    if (onProgress) onProgress(done / entries.length);
  }

  const dir = bytes(central);
  parts.push(dir);
  parts.push(bytes([
    u32(END), u16(0), u16(0), u16(central.length), u16(central.length),
    u32(dir.length), u32(at), u16(0),
  ]));

  const out = new Blob(parts, { type: 'application/zip' });
  // 记的和实际拼出来的对不上，就是上面那套算术和浏览器不是一回事。
  // 当场说清楚差多少，别让一个坏包流出去 —— 它要到换设备恢复时才发作
  const total = at + dir.length + 22;
  if (out.size !== total) {
    throw new Error(`打包时长度对不上：按记录应为 ${total} 字节，实际 ${out.size} 字节`);
  }
  out.shortNames = short;
  return out;
}

// ---- 读 ----

async function view(blob, from, len) {
  return new DataView(await blob.slice(from, Math.min(blob.size, from + len)).arrayBuffer());
}

/** 从 from 开始找四字节签名，找不到返回 -1。分片读，不整个拿进内存。 */
async function findSig(blob, sig, from) {
  const STEP = 1 << 20;
  const want = new Uint8Array([sig & 0xff, (sig >> 8) & 0xff, (sig >> 16) & 0xff, (sig >>> 24) & 0xff]);
  for (let at = from; at < blob.size; at += STEP) {
    // 多读三个字节，签名正好骑在两片之间时不会漏
    const end = Math.min(blob.size, at + STEP + 3);
    const buf = new Uint8Array(await blob.slice(at, end).arrayBuffer());
    for (let i = 0; i + 4 <= buf.length; i++) {
      if (buf[i] === want[0] && buf[i + 1] === want[1]
        && buf[i + 2] === want[2] && buf[i + 3] === want[3]) return at + i;
    }
  }
  return -1;
}

/**
 * 后路：从头顺着本地头爬一遍，不看中央目录。
 * 只在中央目录读不出东西时走这里 —— 它要把整个文件过一遍，比正路慢得多。
 */
async function scanLocal(blob) {
  const out = new Map();
  const dec = new TextDecoder();
  let at = 0;
  while (at + 30 <= blob.size) {
    const head = await view(blob, at, 30);
    if (head.getUint32(0, true) !== LOCAL) {
      const next = await findSig(blob, LOCAL, at + 1);
      if (next < 0) break;
      at = next;
      continue;
    }
    const flags = head.getUint16(6, true);
    const method = head.getUint16(8, true);
    let size = head.getUint32(18, true);
    const nameLen = head.getUint16(26, true);
    const extraLen = head.getUint16(28, true);
    const nameBuf = new Uint8Array(await blob.slice(at + 30, at + 30 + nameLen).arrayBuffer());
    const name = dec.decode(nameBuf);
    const dataAt = at + 30 + nameLen + extraLen;

    // 长度写在后面的数据描述符里（flag 第 3 位）：本地头这里是 0，
    // 只能往后找到下一条记录的开头，中间那一段就是数据
    let after = dataAt + size;
    if ((flags & 8) && !size) {
      const desc = await findSig(blob, 0x08074b50, dataAt);
      const nextLocal = await findSig(blob, LOCAL, dataAt);
      const central = await findSig(blob, CENTRAL, dataAt);
      const ends = [desc, nextLocal, central].filter(x => x > 0);
      if (!ends.length) break;
      const end = Math.min(...ends);
      size = end - dataAt;
      after = end === desc ? end + 16 : end;
    }
    if (size < 0 || dataAt + size > blob.size) break;

    const raw = blob.slice(dataAt, dataAt + size);
    if (method === 0) out.set(name, raw);
    else if (method === 8 && typeof DecompressionStream === 'function') {
      try {
        out.set(name, await new Response(
          raw.stream().pipeThrough(new DecompressionStream('deflate-raw'))).blob());
      } catch { /* 这一条解不开就跳过，别连累其余的 */ }
    }
    at = Math.max(after, at + 1);
  }
  return out;
}

/**
 * 把刚打好的包再读一眼，确认中央目录指得准。
 * 导出的时候顺手查一次 —— 一个结构坏掉的包当时看不出来，
 * 等到换台设备要恢复才发现，那时候原始数据往往已经没了。
 */
export async function verify(blob, expectNames = []) {
  let got;
  try { got = await readCentral(blob); }
  catch (err) { return { ok: false, problem: err.message || String(err) }; }
  if (!got) return { ok: false, problem: '找不到中央目录' };
  const missing = expectNames.filter(n => !got.names.includes(n));
  if (missing.length) return { ok: false, problem: `少了 ${missing.slice(0, 3).join('、')}` };
  if (got.badOffset) {
    return { ok: false,
      problem: `中央目录记的偏移量对不上（记的 ${got.saidAt}，实际 ${got.foundAt}）` };
  }
  return { ok: true, names: got.names };
}

/**
 * 按中央目录读一遍，只取结构，不取数据。读不出来返回 null。
 * verify 与 unzip 共用这一段 —— 「能不能读」和「读出来什么」是同一件事。
 */
async function readCentral(blob) {
  if (blob.size < 22) return null;
  // 结尾那条记录在最后，前面可能还有注释，所以从尾巴往回找
  const tailLen = Math.min(blob.size, 66000);
  const tailAt = blob.size - tailLen;
  const tail = await view(blob, tailAt, tailLen);
  let eocd = -1;
  for (let i = tail.byteLength - 22; i >= 0; i--) {
    if (tail.getUint32(i, true) === END) { eocd = i; break; }
  }
  if (eocd < 0) return null;

  const count = tail.getUint16(eocd + 10, true);
  const dirSize = tail.getUint32(eocd + 12, true);
  let dirAt = tail.getUint32(eocd + 16, true);

  // 偏移量指的地方不是中央目录：整包被挪过位置（前面粘了别的东西），
  // 或者哪个工具改完没重算。按「结尾记录减去目录长度」再试一次。
  let badOffset = false;
  const saidAt = dirAt;
  const looksDir = async at =>
    at >= 0 && at + 4 <= blob.size && (await view(blob, at, 4)).getUint32(0, true) === CENTRAL;
  if (!await looksDir(dirAt)) {
    badOffset = true;
    const guess = tailAt + eocd - dirSize;
    dirAt = await looksDir(guess) ? guess : -1;
  }
  if (dirAt < 0) return null;

  const dir = await view(blob, dirAt, dirSize);
  const dec = new TextDecoder();
  const entries = [];
  let at = 0;
  for (let i = 0; i < count && at + 46 <= dir.byteLength; i++) {
    if (dir.getUint32(at, true) !== CENTRAL) break;
    const method = dir.getUint16(at + 10, true);
    const size = dir.getUint32(at + 20, true);
    const nameLen = dir.getUint16(at + 28, true);
    const extraLen = dir.getUint16(at + 30, true);
    const commentLen = dir.getUint16(at + 32, true);
    const localAt = dir.getUint32(at + 42, true);
    const name = dec.decode(new Uint8Array(dir.buffer, dir.byteOffset + at + 46, nameLen));
    at += 46 + nameLen + extraLen + commentLen;
    entries.push({ name, method, size, localAt });
  }
  if (!entries.length) return null;
  return { entries, names: entries.map(e => e.name), badOffset, saidAt, foundAt: dirAt };
}

/**
 * 解包。回来的是 Map：文件名 -> Blob。
 * 只认识 store 与 deflate；别的压缩方式跳过，不假装读得懂。
 *
 * 中央目录读不出东西（没有、指错地方、一条都解析不出来）时，
 * 退回去从头顺着本地头爬。见文件开头那段。
 */
export async function unzip(blob) {
  const got = await readCentral(blob);
  if (!got) {
    const rescued = await scanLocal(blob);
    if (rescued.size) return rescued;
    throw new Error('这不是一个 ZIP 文件，或者里面一条记录都读不出来');
  }

  const out = new Map();
  for (const e of got.entries) {
    // 本地头里的两个长度可能和中央目录里的不一样，数据起点得按本地头算
    const local = await view(blob, e.localAt, 30);
    if (local.getUint32(0, true) !== LOCAL) continue;
    const dataAt = e.localAt + 30 + local.getUint16(26, true) + local.getUint16(28, true);
    const raw = blob.slice(dataAt, dataAt + e.size);

    if (e.method === 0) out.set(e.name, raw);
    else if (e.method === 8 && typeof DecompressionStream === 'function') {
      try {
        out.set(e.name, await new Response(
          raw.stream().pipeThrough(new DecompressionStream('deflate-raw'))).blob());
      } catch { /* 这一条解不开就跳过，别连累其余的 */ }
    }
  }
  // 目录在，但每一条的偏移量都指到了别处 —— 同样退回去爬一遍
  if (!out.size) {
    const rescued = await scanLocal(blob);
    if (rescued.size) return rescued;
  }
  return out;
}
