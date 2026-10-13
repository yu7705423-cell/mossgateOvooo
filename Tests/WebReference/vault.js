// 备份加密（ARCHITECTURE 4.555）。
//
// 备份里是全部聊天记录、记忆、人设。导出的文件会进网盘、进聊天软件，GitHub 备份躺在一个仓库里 ——
// 仓库哪天被误设成公开、令牌哪天漏了，这些东西就是明文。所以给一个口令：
// PBKDF2（SHA-256）把口令拉成一把 AES-GCM 256 的钥匙，按段加密。
//
// ---- 为什么分段 ----
//
// 完整备份动辄几百兆。WebCrypto 的 AES-GCM 只能一口气加密整块，整块读进内存再出一份密文，
// 手机上直接被系统杀掉。所以每段 4 MB 单独加密，读一段写一段。
// 每段的 IV = 基础 IV 末四个字节异或段号；附加数据里带文件头、段号与「是不是最后一段」——
// 段被调换顺序、被截掉尾巴、被拼进别的文件，都解不开，不会恢复出一份残的库。
//
// ---- 文件格式（只加字段，不改含义） ----
//
//   EIRAVLT1 (8)  迭代次数 (4, 大端)  盐 (16)  基础 IV (12)  段长 (4, 大端)     （文件头共 44 字节）
//   然后每段：密文长度 (4, 大端) + 密文（含 16 字节校验）
//
// **口令丢了就解不开。** 没有后门，也不该有：有后门就不叫加密。界面上要把这句写在两版都看得见的地方。
//
// 钥匙按「口令 + 盐 + 迭代次数」缓存在内存里：GitHub 备份几百张图共用一把盐，只派生一次。

const MAGIC = 'EIRAVLT1';
const HEAD = 44;
export const ITERATIONS = 600000;   // OWASP 2023 对 PBKDF2-SHA256 的建议值；iPhone 上不到一秒
const CHUNK = 4 * 1024 * 1024;
const enc = new TextEncoder();

const cache = new Map();

const hex = bytes => [...bytes].map(b => b.toString(16).padStart(2, '0')).join('');
const unhex = s => new Uint8Array(String(s || '').match(/../g)?.map(h => parseInt(h, 16)) || []);
export const newSalt = () => hex(crypto.getRandomValues(new Uint8Array(16)));

function fail(code, message) {
  const e = new Error(message);
  e.code = code;
  return e;
}

/**
 * 由口令得到一把钥匙。salt 是十六进制串，不给就新造一个。
 * 返回 { key, salt, iterations, fp }。fp 是钥匙的指纹（八位十六进制）：GitHub 备份拿它进文件名，
 * 口令一换指纹就换，旧口令加密的图自然被当成「没传过」重新传一遍。
 */
export async function keyFor(pass, salt = newSalt(), iterations = ITERATIONS) {
  if (!pass) throw fail('need-pass', '请填写备份口令');
  const id = `${iterations}|${salt}|${pass}`;
  if (cache.has(id)) return cache.get(id);
  const base = await crypto.subtle.importKey('raw', enc.encode(pass), 'PBKDF2', false, ['deriveBits']);
  const bits = new Uint8Array(await crypto.subtle.deriveBits(
    { name: 'PBKDF2', hash: 'SHA-256', salt: unhex(salt), iterations }, base, 256));
  const key = await crypto.subtle.importKey('raw', bits, 'AES-GCM', false, ['encrypt', 'decrypt']);
  const fp = hex(new Uint8Array(await crypto.subtle.digest('SHA-256', bits))).slice(0, 8);
  bits.fill(0);
  const k = { key, salt, iterations, fp };
  cache.set(id, k);
  return k;
}

const u32 = (view, at) => view.getUint32(at, false);
function ivOf(base, i) {
  const iv = base.slice();
  const v = new DataView(iv.buffer);
  v.setUint32(8, v.getUint32(8, false) ^ i, false);
  return iv;
}
function aadOf(head, i, last) {
  const a = new Uint8Array(head.length + 5);
  a.set(head);
  new DataView(a.buffer).setUint32(head.length, i, false);
  a[head.length + 4] = last ? 1 : 0;
  return a;
}

const asBlob = data => (data instanceof Blob ? data : new Blob([data]));

/** 是不是本格式的密文。按内容认，不按扩展名 */
export async function isSealed(data) {
  const b = asBlob(data);
  if (b.size < HEAD) return false;
  const head = new Uint8Array(await b.slice(0, 8).arrayBuffer());
  return String.fromCharCode(...head) === MAGIC;
}

/**
 * 加密。data 是 Blob 或字节；k 是 keyFor 的结果，或者直接给口令（每次新造一把盐）。
 * 返回 Blob。
 */
export async function seal(data, k, { chunk = CHUNK } = {}) {
  if (typeof k === 'string') k = await keyFor(k);
  const src = asBlob(data);
  const head = new Uint8Array(HEAD);
  const hv = new DataView(head.buffer);
  head.set(enc.encode(MAGIC), 0);
  hv.setUint32(8, k.iterations, false);
  head.set(unhex(k.salt), 12);
  const ivBase = crypto.getRandomValues(new Uint8Array(12));
  head.set(ivBase, 28);
  hv.setUint32(40, chunk, false);

  const out = [head];
  const n = Math.max(1, Math.ceil(src.size / chunk));
  for (let i = 0; i < n; i++) {
    const plain = new Uint8Array(await src.slice(i * chunk, (i + 1) * chunk).arrayBuffer());
    const ct = new Uint8Array(await crypto.subtle.encrypt(
      { name: 'AES-GCM', iv: ivOf(ivBase, i), additionalData: aadOf(head, i, i === n - 1) }, k.key, plain));
    const len = new Uint8Array(4);
    new DataView(len.buffer).setUint32(0, ct.length, false);
    out.push(len, ct);
  }
  return new Blob(out);
}

/** 读文件头，不解密。GitHub 恢复时先看用的是哪把盐 */
export async function headerOf(data) {
  const b = asBlob(data);
  if (!(await isSealed(b))) return null;
  const head = new Uint8Array(await b.slice(0, HEAD).arrayBuffer());
  const v = new DataView(head.buffer);
  return { head, iterations: u32(v, 8), salt: hex(head.subarray(12, 28)), ivBase: head.slice(28, 40), chunk: u32(v, 40) };
}

/**
 * 解密，返回 Blob。口令不对与文件被改过在 AES-GCM 看来是一回事，报同一句。
 * pass 可以是口令，也可以是 keyFor 的结果（盐须一致）。
 */
export async function open(data, pass) {
  const b = asBlob(data);
  const h = await headerOf(b);
  if (!h) throw fail('not-sealed', '不是加密的备份');
  if (!h.iterations || h.iterations > 10000000 || !h.chunk) throw fail('broken', '加密备份的文件头已损坏');
  const k = typeof pass === 'string' || !pass ? await keyFor(pass, h.salt, h.iterations) : pass;
  if (k.salt !== h.salt || k.iterations !== h.iterations) throw fail('bad-pass', '口令不正确，或文件已损坏');

  const out = [];
  let at = HEAD;
  let i = 0;
  let last = false;
  while (at < b.size) {
    if (last) throw fail('broken', '加密备份的末尾多出了内容，文件已损坏');
    const len = u32(new DataView(await b.slice(at, at + 4).arrayBuffer()), 0);
    at += 4;
    if (!len || at + len > b.size) throw fail('broken', '加密备份不完整，可能没有下载完');
    const ct = new Uint8Array(await b.slice(at, at + len).arrayBuffer());
    at += len;
    last = at >= b.size;
    try {
      out.push(new Uint8Array(await crypto.subtle.decrypt(
        { name: 'AES-GCM', iv: ivOf(h.ivBase, i), additionalData: aadOf(h.head, i, last) }, k.key, ct)));
    } catch {
      throw fail('bad-pass', '口令不正确，或文件已损坏');
    }
    i += 1;
  }
  if (!last) throw fail('broken', '加密备份不完整，可能没有下载完');
  return new Blob(out);
}
