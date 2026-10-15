// 探 QQ 音乐的非官方接口长什么样（只在 GitHub Actions 上跑，本地容器连不上）。
// 不带任何账号、不登录，只打印返回的形状，供写原生版的 QQMusic.swift 时对照。
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36';
const H = { 'user-agent': UA, referer: 'https://y.qq.com/', origin: 'https://y.qq.com' };
const show = (title, v) => console.log(`\n===== ${title} =====\n` + (typeof v === 'string' ? v : JSON.stringify(v, null, 1)).slice(0, 2500));

async function musicu(body) {
  const r = await fetch('https://u.y.qq.com/cgi-bin/musicu.fcg', { method: 'POST', headers: { ...H, 'content-type': 'application/json' }, body: JSON.stringify(body) });
  const t = await r.text();
  try { return { status: r.status, json: JSON.parse(t) }; } catch { return { status: r.status, text: t.slice(0, 500) }; }
}
const comm = { ct: '19', cv: '1859', uin: '0' };

let mid = '', songId = 0, albumMid = '';
try {
  const r = await musicu({ comm, req: { module: 'music.search.SearchCgiService', method: 'DoSearchForQQMusicDesktop',
    param: { grp: 1, num_per_page: 3, page_num: 1, query: '晴天 周杰伦', search_type: 0 } } });
  const list = r.json?.req?.data?.body?.song?.list || [];
  show('search code', { status: r.status, code: r.json?.code, reqCode: r.json?.req?.code, n: list.length });
  if (list[0]) {
    const s = list[0];
    mid = s.mid; songId = s.id; albumMid = s.album?.mid;
    show('search first', { mid: s.mid, id: s.id, name: s.name, title: s.title, singer: s.singer?.map(x => x.name), album: s.album, interval: s.interval, pay: s.pay, file: s.file, action: s.action });
  } else show('search raw', r);
} catch (e) { show('search error', String(e)); }

try {
  const r = await fetch(`https://c.y.qq.com/soso/fcgi-bin/client_search_cp?w=${encodeURIComponent('晴天')}&format=json&p=1&n=2&cr=1`, { headers: H });
  const j = JSON.parse(await r.text());
  const s = j?.data?.song?.list?.[0];
  if (s) {
    show('old search first keys', Object.keys(s));
    show('old search first', { songmid: s.songmid, songid: s.songid, songname: s.songname, singer: s.singer, albummid: s.albummid, interval: s.interval, pay: s.pay, strMediaMid: s.strMediaMid, media_mid: s.media_mid, size128: s.size128, sizeogg: s.sizeogg });
    if (!mid) { mid = s.songmid; songId = s.songid; albumMid = s.albummid; }
  } else show('old search raw', j);
} catch (e) { show('old search error', String(e)); }

// 搜歌的新接口换一个模块再试
try {
  const r = await musicu({ comm: { ...comm, cv: '4747474', format: 'json', inCharset: 'utf-8', outCharset: 'utf-8' },
    req_1: { module: 'music.search.SearchCgiService', method: 'DoSearchForQQMusicMobile',
      param: { query: '晴天', search_type: 0, num_per_page: 2, page_num: 1, highlight: 0, nqc_flag: 0, multi_zhida: 0, cat: 2, grp: 1, sin: 0, sem: 0 } } });
  show('search mobile', { status: r.status, code: r.json?.req_1?.code, n: r.json?.req_1?.data?.body?.item_song?.length ?? r.json?.req_1?.data?.body?.song?.list?.length });
} catch (e) { show('search mobile error', String(e)); }

// 歌单：不登录读一张公开歌单
try {
  const r = await fetch('https://c.y.qq.com/qzone/fcg-bin/fcg_ucc_getcdinfo_byids_cp.fcg?type=1&json=1&utf8=1&onlysong=0&disstid=7256912512&format=json', { headers: H });
  const t = await r.text();
  show('playlist', { status: r.status, head: t.slice(0, 300) });
} catch (e) { show('playlist error', String(e)); }

if (mid) {
  try {
    const r = await musicu({ comm, req_0: { module: 'vkey.GetVkeyServer', method: 'CgiGetVkey',
      param: { guid: '1234567890', songmid: [mid], songtype: [0], uin: '0', loginflag: 1, platform: '20' } } });
    const d = r.json?.req_0?.data;
    show('vkey', { status: r.status, code: r.json?.code, sip: d?.sip, purl: d?.midurlinfo?.[0]?.purl, result: d?.midurlinfo?.[0]?.result, msg: d?.msg, testfile: d?.testfile2g });
  } catch (e) { show('vkey error', String(e)); }

  try {
    const r = await fetch(`https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=${mid}&format=json&nobase64=1&g_tk=5381`, { headers: H });
    show('lyric old', { status: r.status, body: (await r.text()).slice(0, 400) });
  } catch (e) { show('lyric old error', String(e)); }

  try {
    const r = await musicu({ comm, req: { module: 'music.musichallSong.PlayLyricInfo', method: 'GetPlayLyricInfo',
      param: { songMID: mid, songID: songId, trans: 1 } } });
    const d = r.json?.req?.data;
    show('lyric new', { status: r.status, code: r.json?.req?.code, lyricHead: String(d?.lyric || '').slice(0, 120), transHead: String(d?.trans || '').slice(0, 80) });
  } catch (e) { show('lyric new error', String(e)); }

  try {
    const r = await fetch(`https://y.gtimg.cn/music/photo_new/T002R300x300M000${albumMid}.jpg`, { headers: H });
    show('cover', { status: r.status, type: r.headers.get('content-type'), len: r.headers.get('content-length') });
  } catch (e) { show('cover error', String(e)); }
}

// 扫码登录第一步：二维码图与 qrsig
try {
  const r = await fetch('https://ssl.ptlogin2.qq.com/ptqrshow?appid=716027609&e=2&l=M&s=3&d=72&v=4&t=0.5&daid=383&pt_3rd_aid=100497308', { headers: { 'user-agent': UA } });
  const ck = r.headers.getSetCookie?.() || [r.headers.get('set-cookie')];
  const qrsig = (ck.join(';').match(/qrsig=([^;]+)/) || [])[1] || '';
  show('qr', { status: r.status, type: r.headers.get('content-type'), cookies: ck.map(c => String(c).split(';')[0].split('=')[0]), hasQrsig: !!qrsig });
  if (qrsig) {
    let e = 0;
    for (const c of qrsig) e += (e << 5) + c.charCodeAt(0);
    const token = 2147483647 & e;
    const u = 'https://ssl.ptlogin2.qq.com/ptqrlogin?u1=' + encodeURIComponent('https://graph.qq.com/oauth2.0/login_jump')
      + `&ptqrtoken=${token}&ptredirect=0&h=1&t=1&g=1&from_ui=1&ptlang=2052&action=0-0-${Date.now()}&js_ver=20102616&js_type=1&pt_uistyle=40&aid=716027609&daid=383&pt_3rd_aid=100497308&has_onekey=1`;
    const p = await fetch(u, { headers: { 'user-agent': UA, cookie: `qrsig=${qrsig}`, referer: 'https://xui.ptlogin2.qq.com/' } });
    show('qr poll', { status: p.status, body: (await p.text()).slice(0, 300) });
  }
} catch (e) { show('qr error', String(e)); }
