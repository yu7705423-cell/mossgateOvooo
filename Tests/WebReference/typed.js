// 备份里怎么放 Float32Array。
//
// 记忆条目身上挂着向量（`vec`）。它在 IndexedDB 里是原生存的，结构化克隆
// 认得 Float32Array，一条 4096 维占 16 KB，没有任何问题。
//
// **出事的是 JSON。** `JSON.stringify(new Float32Array([0.1]))` 吐出来的是
// `{"0":0.10000000149011612}` —— 不是数组，是个以下标为键的对象，
// 一个浮点数二十五个字节。实测五百条 4096 维的记忆，「仅数据」备份
// 从几百 KB 涨到 55 MB；而且恢复回来是个普通对象，`vec.length` 是 undefined，
// 检索那一步 `a.length !== b.length` 直接返回 -1，等于那几百条全废 ——
// 导出看着成功，恢复也不报错，只是再也召回不到。
//
// 所以进 JSON 之前转成 base64（原始字节，不丢精度，体积是上面那种写法的
// 五分之一），恢复时转回 Float32Array。
//
// 从前的备份里躺着的是那种 `{"0":…}` 的残骸，恢复时按下标拼回去，能救就救。
//
// **哪个域的哪个字段是 Float32Array，只在下面这张表上列。** 漏登记的后果
// 和漏登记数据域一样安静：导出成功，恢复之后那个字段不是原来的类型了。

const TYPED_FIELDS = {
  memories: ['vec'],
};

const CHUNK = 0x8000;   // 一次 apply 太多个参数会爆调用栈

function toBase64(view) {
  const bytes = new Uint8Array(new Float32Array(view).buffer);
  let s = '';
  for (let i = 0; i < bytes.length; i += CHUNK) {
    s += String.fromCharCode.apply(null, bytes.subarray(i, i + CHUNK));
  }
  return btoa(s);
}

function fromBase64(str) {
  const bin = atob(str);
  if (bin.length % 4) return null;          // 不是四的倍数，不是 float32
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return new Float32Array(bytes.buffer);
}

// 老备份里那种 {"0":0.1,"1":0.2,...}。键必须是从 0 连到底的下标才认。
function fromIndexed(obj) {
  const keys = Object.keys(obj);
  if (!keys.length) return null;
  const out = new Float32Array(keys.length);
  for (let i = 0; i < keys.length; i++) {
    const v = obj[String(i)];
    if (typeof v !== 'number') return null;
    out[i] = v;
  }
  return out;
}

/** 写进 JSON 之前。没有这类字段就原样返回，不白复制一份。 */
export function packRow(name, row) {
  const fields = TYPED_FIELDS[name];
  if (!fields || !row) return row;
  let out = row;
  for (const f of fields) {
    const v = row[f];
    if (!ArrayBuffer.isView(v)) continue;
    if (out === row) out = { ...row };
    out[f] = { __f32: toBase64(v) };
  }
  return out;
}

/** 从 JSON 读出来之后。三种形状都接：base64、普通数组、老备份的下标对象。 */
export function unpackRow(name, row) {
  const fields = TYPED_FIELDS[name];
  if (!fields || !row || typeof row !== 'object') return row;
  let out = row;
  for (const f of fields) {
    const v = row[f];
    if (!v || ArrayBuffer.isView(v)) continue;
    let got = null;
    if (typeof v === 'object' && typeof v.__f32 === 'string') got = fromBase64(v.__f32);
    else if (Array.isArray(v)) got = Float32Array.from(v);
    else if (typeof v === 'object') got = fromIndexed(v);
    if (!got) continue;
    if (out === row) out = { ...row };
    out[f] = got;
  }
  return out;
}
