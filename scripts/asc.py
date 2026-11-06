#!/usr/bin/env python3
"""App Store Connect API 的几件小事：打包前临时申请证书与描述文件，没传上去时收回，以及只读的状态核对。

  python3 scripts/asc.py prepare  <包标识> <输出目录>    写出 key.pem cert.cer profile.mobileprovision
                                                        notify-profile.mobileprovision widgets-profile.mobileprovision ids.json
  python3 scripts/asc.py cleanup  <输出目录>             这一次没传上去：删掉这次的描述文件、撤销这次的证书
  python3 scripts/asc.py status   <包标识>               只读：发布证书、这个 App 的描述文件、包标识上的能力

密钥从环境变量读：ASC_KEY_ID、ASC_ISSUER_ID、ASC_KEY_P8（.p8 文件的全文）。

做法照网页版仓库的 ios/asc.py（ARCHITECTURE 4.548、4.581、4.896、4.941、4.1037），这里是原生版自己写的一份。

为什么每次现申请：
  把证书导出成 p12 放进仓库机密，要用户自己在 Mac 的钥匙串里做，而用户没有 Mac。
传完不撤：苹果处理构建时证书已撤就是 ITMS-90035（签名无效），构建被退回。所以传成功就留着；发布证书一个账号只能有两三张，
  下一次申请之前先收掉这个工作流以前申请的、除最近一张以外的旧证书；满了申请不下来，再把最近那张也收掉重试。
**只收这个 App 自己的**（网页版 4.1037）：哪几份是这里建的，靠描述文件的名字前缀与它绑的包标识一起认 ——
  包标识是 cn.eiraphone.native 本身或它的扩展。从前这里在名额满时还会去收网页版工作流（Eira CI）的旧证书，
  两边互相把对方的当成旧的收掉，网页版第 39 次构建的证书因此被撤、TestFlight 退回 ITMS-90035。现在不碰别的 App 的任何东西。

能力（描述文件里有，签名时才写得进 entitlements）：
  应用本身：HealthKit（健康同步）、Push Notifications（Eira 推送）、App Groups（与两个扩展共用钥匙与组件数据）；
  通知扩展 .notify、桌面组件 .widgets：App Groups。
  接口能勾上能力，但**分到哪个 App Group 只能在开发者网站上点**（docs/system-abilities.md 的清单）。
  没分到时描述文件里没有那个 group：scripts/signplan.py 在生成工程之前把对应的 entitlements 与扩展去掉，照样出包，日志里写明。
"""
import base64
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

import jwt  # PyJWT，工作流里装

API = 'https://api.appstoreconnect.apple.com/v1'
PREFIX = 'Eiraowo CI '   # 这个工作流给应用本身建的描述文件，后面是建的时间
EXT_PREFIX = 'Eiraowo CX '   # 给扩展建的，后面是同一次的时间与扩展的后缀
# 壳 App 试点（shell.yml 的 [shell-owo]，2026-11-06 停用）曾用网页版的脚本给这个包标识建过描述文件，名字是网页版的前缀。
# 包标识是这个 App 的那几份同样算这里的旧东西，一起收；绑在别的包标识上的一律不碰
LEGACY_PREFIXES = ('Eira CI ', 'Eira CX ')

# 扩展：后缀、ids.json 里的键、描述文件的文件名、开发者网站上的名字、要勾的能力
EXTENSIONS = (
    ('.notify', 'notifyProfile', 'notify-profile', 'Eiraowo Notify', ('APP_GROUPS',)),
    ('.widgets', 'widgetsProfile', 'widgets-profile', 'Eiraowo Widgets', ('APP_GROUPS',)),
)
APP_CAPS = ('HEALTHKIT', 'PUSH_NOTIFICATIONS', 'APP_GROUPS')


def token():
    key = os.environ['ASC_KEY_P8'].strip().replace('\\n', '\n')
    now = int(time.time())
    return jwt.encode({'iss': os.environ['ASC_ISSUER_ID'], 'iat': now, 'exp': now + 15 * 60, 'aud': 'appstoreconnect-v1'},
                      key, algorithm='ES256', headers={'kid': os.environ['ASC_KEY_ID'], 'typ': 'JWT'})


def call(method, path, body=None):
    req = urllib.request.Request(API + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={'Authorization': 'Bearer ' + token(), 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors='replace')
        raise SystemExit(f'App Store Connect 返回 {e.code}（{method} {path}）：{detail}')


def bundle_id(identifier):
    got = call('GET', f'/bundleIds?filter[identifier]={identifier}&limit=5').get('data', [])
    got = [b for b in got if b['attributes']['identifier'] == identifier]
    return got[0] if got else None


def enable(bid, cap):
    """给包标识勾上一项能力。已经有了就不动；勾不上不拦，签名前的核对会把用不了的那一项去掉"""
    have = call('GET', f'/bundleIds/{bid}/bundleIdCapabilities').get('data', [])
    if any(c['attributes'].get('capabilityType') == cap for c in have):
        return
    try:
        call('POST', '/bundleIdCapabilities', {'data': {'type': 'bundleIdCapabilities',
             'attributes': {'capabilityType': cap},
             'relationships': {'bundleId': {'data': {'type': 'bundleIds', 'id': bid}}}}})
        print(f'能力      {bid} 已勾上 {cap}')
    except SystemExit as e:
        print(f'能力      {bid} 没勾上 {cap}：{e}')


def profile(name, bid, cert_id, path):
    prof = call('POST', '/profiles', {'data': {'type': 'profiles',
        'attributes': {'name': name, 'profileType': 'IOS_APP_STORE'},
        'relationships': {'bundleId': {'data': {'type': 'bundleIds', 'id': bid}},
                          'certificates': {'data': [{'type': 'certificates', 'id': cert_id}]}}}})['data']
    with open(path, 'wb') as f:
        f.write(base64.b64decode(prof['attributes']['profileContent']))
    return prof


def prepare(bundle, out):
    os.makedirs(out, exist_ok=True)
    # 1. 包标识。要用户先在开发者网站登记好（App Store Connect 里建 App 也要选它），这里只查
    found = bundle_id(bundle)
    if not found:
        raise SystemExit(f'开发者账号里没有包标识 {bundle}。先在 developer.apple.com 的 Identifiers 里登记它')
    bid = found['id']
    team = found['attributes'].get('seedId', '')
    for cap in APP_CAPS:
        enable(bid, cap)

    # 2. 私钥与证书请求，在这台机器上现做，不出这台机器
    key = os.path.join(out, 'key.pem')
    csr = os.path.join(out, 'csr.pem')
    subprocess.run(['/usr/bin/openssl', 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-keyout', key,
                    '-subj', '/CN=Eiraowo GitHub Actions', '-out', csr], check=True, capture_output=True)
    # 以前留下的旧证书：最近那张留着（它签的构建可能还在处理），更早的收掉。满了申请不下来就连最近那张也收掉再试一次
    prune(keep=1, bundle=bundle)
    body = {'data': {'type': 'certificates', 'attributes': {
        'certificateType': 'DISTRIBUTION', 'csrContent': open(csr).read()}}}
    try:
        cert = call('POST', '/certificates', body)['data']
    except SystemExit as e:
        print(f'证书      申请不下来，收掉最近那张旧证书再试：{e}')
        prune(keep=0, bundle=bundle)
        try:
            cert = call('POST', '/certificates', body)['data']
        except SystemExit as e2:
            listing()
            raise SystemExit('发布证书的名额满了，这个 App 自己的旧证书已经收完。同一个开发者账号里别的项目（网页版的外壳）也在用名额，'
                             f'等它那边的构建处理完、由它自己收掉旧证书再传，或者在开发者网站撤一张不用的：{e2}')
    with open(os.path.join(out, 'cert.cer'), 'wb') as f:
        f.write(base64.b64decode(cert['attributes']['certificateContent']))
    ids = {'certificate': cert['id'], 'team': team, 'bundleId': bid}
    json.dump(ids, open(os.path.join(out, 'ids.json'), 'w'))   # 先记下证书，后面失败了 cleanup 也收得回

    # 3. App Store 描述文件：这个包标识 + 刚才那张证书
    ts = str(int(time.time()))
    prof = profile(f'{PREFIX}{ts}', bid, cert['id'], os.path.join(out, 'profile.mobileprovision'))
    ids['profile'] = prof['id']
    json.dump(ids, open(os.path.join(out, 'ids.json'), 'w'))
    print(f'证书      已申请（{cert["id"]}），团队 {team}')
    print(f'描述文件  已生成（{prof["id"]}）')

    # 4. 扩展：包标识是应用的后面接一段。没登记就替用户登记；登记不了或描述文件出不来都不拦，
    #    这个包里不带那个扩展（scripts/signplan.py 看描述文件有没有、里面有没有分到 App Group）
    for suffix, idkey, fname, name, caps in EXTENSIONS:
        ext = bundle + suffix
        try:
            got = bundle_id(ext)
            if got:
                eid = got['id']
            else:
                eid = call('POST', '/bundleIds', {'data': {'type': 'bundleIds', 'attributes': {
                    'identifier': ext, 'name': name, 'platform': 'IOS'}}})['data']['id']
                print(f'包标识    已登记 {ext}')
            for cap in caps:
                enable(eid, cap)
            eprof = profile(f'{EXT_PREFIX}{ts}{suffix}', eid, cert['id'], os.path.join(out, fname + '.mobileprovision'))
            ids[idkey] = eprof['id']
            json.dump(ids, open(os.path.join(out, 'ids.json'), 'w'))
            print(f'描述文件  {name} 已生成（{eprof["id"]}）')
        except SystemExit as e:
            print(f'扩展      {name} 的描述文件没生成，这个包里不带它：{e}')


def listing():
    """账号里现有的发布证书：编号、名字、到期日（不含私钥，只用来看名额被谁占着）"""
    rows = call('GET', '/certificates?filter[certificateType]=DISTRIBUTION,IOS_DISTRIBUTION&limit=50').get('data', [])
    print(f'证书      账号里现有 {len(rows)} 张发布证书：')
    for c in rows:
        a = c['attributes']
        print(f"          {c['id']}  {a.get('name', '')}  {a.get('displayName', '')}  到期 {a.get('expirationDate', '')}")


def bundle_of(profile_id):
    """描述文件绑的包标识；查不到回空串"""
    try:
        return call('GET', f'/profiles/{profile_id}/bundleId').get('data', {}).get('attributes', {}).get('identifier', '')
    except SystemExit:
        return ''


def ours(profile_id, bundle):
    """只认这个 App 的：包标识是它本身或它的扩展"""
    got = bundle_of(profile_id)
    return got == bundle or got.startswith(bundle + '.')


def stamp(name):
    """描述文件名字里的时间（同一次建的应用那份与扩展那几份相同）"""
    for p in (PREFIX, EXT_PREFIX) + LEGACY_PREFIXES:
        if name.startswith(p):
            return name[len(p):].split('.')[0]
    return ''


def prune(keep, bundle):
    """这个 App 以前建的描述文件与它们的证书，按建的时间留最近 keep 次，其余删掉、撤销。别的 App 的一概不碰"""
    rows = call('GET', '/profiles?filter[profileType]=IOS_APP_STORE&limit=200').get('data', [])
    named = [p for p in rows if str(p['attributes'].get('name', '')).startswith((PREFIX, EXT_PREFIX) + LEGACY_PREFIXES)]
    mine = [p for p in named if ours(p['id'], bundle)]
    # 留最近 keep 次（只看这里自己建的；壳 App 试点留下的一律算旧的）
    times = sorted({stamp(p['attributes']['name']) for p in mine if p['attributes']['name'].startswith(PREFIX)}, reverse=True)
    kept = set(times[:keep])
    drop = [p for p in mine if not (p['attributes']['name'].startswith((PREFIX, EXT_PREFIX)) and stamp(p['attributes']['name']) in kept)]
    if not drop:
        return
    drop_ids = {p['id'] for p in drop}
    # 还留着的描述文件（这个 App 留下的那几份，以及别的项目的）在用的证书不撤：一张证书可能被几份描述文件共用
    keep_certs = set()
    for p in rows:
        if p['id'] in drop_ids:
            continue
        keep_certs |= {c['id'] for c in call('GET', f"/profiles/{p['id']}/certificates").get('data', [])}
    certs = set()
    for p in drop:
        certs |= {c['id'] for c in call('GET', f"/profiles/{p['id']}/certificates").get('data', [])}
        try:
            call('DELETE', f"/profiles/{p['id']}")
            print(f"已收回旧的描述文件 {p['id']}（{p['attributes']['name']}）")
        except SystemExit as e:
            print(f"没收回旧的描述文件 {p['id']}：{e}")
    for cid in sorted(certs - keep_certs):
        try:
            call('DELETE', f'/certificates/{cid}')
            print(f'已收回旧的证书 {cid}')
        except SystemExit as e:
            print(f'没收回旧的证书 {cid}：{e}')


def cleanup(out):
    path = os.path.join(out, 'ids.json')
    if not os.path.exists(path):
        print('没有要收回的证书')
        return
    ids = json.load(open(path))
    keys = [('profiles', k) for _, k, _, _, _ in EXTENSIONS] + [('profiles', 'profile'), ('certificates', 'certificate')]
    for kind, key in keys:
        if ids.get(key):
            try:
                call('DELETE', f'/{kind}/{ids[key]}')
                print(f'已收回    {kind} {ids[key]}')
            except SystemExit as e:
                print(f'没收回    {kind} {ids[key]}：{e}')


def status(bundle):
    """只读：发布证书、这个 App 的描述文件是否有效、各包标识上勾了哪些能力。不建、不删、不撤"""
    listing()
    print('== 这个 App 的描述文件')
    rows = call('GET', '/profiles?filter[profileType]=IOS_APP_STORE&limit=200').get('data', [])
    for p in sorted(rows, key=lambda p: p['attributes'].get('name', ''), reverse=True):
        a = p['attributes']
        if not str(a.get('name', '')).startswith((PREFIX, EXT_PREFIX) + LEGACY_PREFIXES) or not ours(p['id'], bundle):
            continue
        certs = [c['id'] for c in call('GET', f"/profiles/{p['id']}/certificates").get('data', [])]
        print(f"  {a.get('name')}  {a.get('profileState')}  包标识 {bundle_of(p['id'])}  证书 {','.join(certs) or '无'}")
    print('== 包标识上的能力')
    for ident in [bundle] + [bundle + s for s, _, _, _, _ in EXTENSIONS]:
        b = bundle_id(ident)
        if not b:
            print(f'  {ident}  未登记')
            continue
        caps = [c['attributes'].get('capabilityType') for c in call('GET', f"/bundleIds/{b['id']}/bundleIdCapabilities").get('data', [])]
        print(f"  {ident}  {', '.join(sorted(c for c in caps if c)) or '无'}")


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'prepare':
        prepare(sys.argv[2], sys.argv[3])
    elif cmd == 'cleanup':
        cleanup(sys.argv[2])
    elif cmd == 'status':
        status(sys.argv[2])
    else:
        raise SystemExit(__doc__)
