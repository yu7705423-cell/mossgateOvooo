#!/usr/bin/env python3
"""App Store Connect API 的两件小事：打包前临时申请证书与描述文件，传完之后收回。

  python3 ios/asc.py prepare  <包标识> <输出目录>    写出 key.pem cert.cer profile.mobileprovision ids.json
  python3 ios/asc.py cleanup  <输出目录>             删掉那份描述文件、撤销那张证书

密钥从环境变量读：ASC_KEY_ID、ASC_ISSUER_ID、ASC_KEY_P8（.p8 文件的全文）。

照抄网页版仓库的 ios/asc.py（ARCHITECTURE 4.548），连同补 HealthKit 那一段（健康 app 从苹果健康同步要用）。

为什么每次现申请：
  把证书导出成 p12 放进仓库机密，要用户自己在 Mac 的钥匙串里做，而用户没有 Mac。
传完不撤：网页版仓库踩过（ios/asc.py 的说明），苹果处理构建时证书已撤就是 ITMS-90035（签名无效），构建被退回。
  所以传成功就留着；发布证书一个账号只能有两三张（网页版的工作流也在用同一个账号），下一次申请之前先收掉
  这个工作流以前申请的、除最近一张以外的旧证书；满了申请不下来，再把最近那张也收掉重试。
  哪几张是这个工作流申请的，靠它建的描述文件认（名字以 PREFIX 开头），网页版那边（Eira CI）与用户自己的证书不碰。
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
PREFIX = 'Eiraowo CI '   # 这个工作流建的描述文件都叫这个开头，后面是建的时间
WEB_PREFIX = 'Eira CI '   # 网页版仓库的工作流建的（同一个账号）。它自己也只留最近一张


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


def prepare(bundle, out):
    os.makedirs(out, exist_ok=True)
    # 1. 包标识。要用户先在开发者网站登记好（App Store Connect 里建 App 也要选它），这里只查
    found = call('GET', f'/bundleIds?filter[identifier]={bundle}&limit=5').get('data', [])
    found = [b for b in found if b['attributes']['identifier'] == bundle]
    if not found:
        raise SystemExit(f'开发者账号里没有包标识 {bundle}。先在 developer.apple.com 的 Identifiers 里登记它')
    bid = found[0]['id']
    team = found[0]['attributes'].get('seedId', '')
    # 读健康数据要 HealthKit 这一项能力。登记时没勾的话补上；补不上照样往下走，签名时会报出来（网页版 ios/asc.py 同一段）
    caps = call('GET', f'/bundleIds/{bid}/bundleIdCapabilities').get('data', [])
    if not any(c['attributes'].get('capabilityType') == 'HEALTHKIT' for c in caps):
        try:
            call('POST', '/bundleIdCapabilities', {'data': {'type': 'bundleIdCapabilities',
                 'attributes': {'capabilityType': 'HEALTHKIT'},
                 'relationships': {'bundleId': {'data': {'type': 'bundleIds', 'id': bid}}}}})
            print('能力      已为包标识补上 HealthKit')
        except SystemExit as e:
            print(f'能力      HealthKit 没补上：{e}')
    # 2. 私钥与证书请求，在这台机器上现做，不出这台机器
    key = os.path.join(out, 'key.pem')
    csr = os.path.join(out, 'csr.pem')
    subprocess.run(['/usr/bin/openssl', 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-keyout', key,
                    '-subj', '/CN=Eiraowo GitHub Actions', '-out', csr], check=True, capture_output=True)
    # 以前留下的旧证书：最近那张留着（它签的构建可能还在处理），更早的收掉。满了申请不下来就连最近那张也收掉再试一次
    prune(keep=1)
    body = {'data': {'type': 'certificates', 'attributes': {
        'certificateType': 'DISTRIBUTION', 'csrContent': open(csr).read()}}}
    try:
        cert = call('POST', '/certificates', body)['data']
    except SystemExit as e:
        print(f'证书      申请不下来，收掉最近那张旧证书再试：{e}')
        prune(keep=0)
        try:
            cert = call('POST', '/certificates', body)['data']
        except SystemExit as e2:
            # 还是满的：名额被网页版的工作流占着。它自己的规矩也是只留最近一张，更早的照它的规矩收掉再试一次
            print(f'证书      仍然申请不下来：{e2}')
            listing()
            prune(keep=1, prefix=WEB_PREFIX)
            cert = call('POST', '/certificates', body)['data']
    with open(os.path.join(out, 'cert.cer'), 'wb') as f:
        f.write(base64.b64decode(cert['attributes']['certificateContent']))
    ids = {'certificate': cert['id'], 'team': team, 'bundleId': bid}
    json.dump(ids, open(os.path.join(out, 'ids.json'), 'w'))   # 先记下证书，后面失败了 cleanup 也收得回

    # 3. App Store 描述文件：这个包标识 + 刚才那张证书
    prof = call('POST', '/profiles', {'data': {'type': 'profiles',
        'attributes': {'name': f'{PREFIX}{int(time.time())}', 'profileType': 'IOS_APP_STORE'},
        'relationships': {'bundleId': {'data': {'type': 'bundleIds', 'id': bid}},
                          'certificates': {'data': [{'type': 'certificates', 'id': cert['id']}]}}}})['data']
    with open(os.path.join(out, 'profile.mobileprovision'), 'wb') as f:
        f.write(base64.b64decode(prof['attributes']['profileContent']))
    ids['profile'] = prof['id']
    json.dump(ids, open(os.path.join(out, 'ids.json'), 'w'))
    print(f'证书      已申请（{cert["id"]}），团队 {team}')
    print(f'描述文件  已生成（{prof["id"]}）')


def listing():
    """账号里现有的发布证书：编号、名字、到期日（不含私钥，只用来看名额被谁占着）"""
    rows = call('GET', '/certificates?filter[certificateType]=DISTRIBUTION,IOS_DISTRIBUTION&limit=50').get('data', [])
    print(f'证书      账号里现有 {len(rows)} 张发布证书：')
    for c in rows:
        a = c['attributes']
        print(f"          {c['id']}  {a.get('name', '')}  {a.get('displayName', '')}  到期 {a.get('expirationDate', '')}")


def prune(keep, prefix=PREFIX):
    """某个工作流以前建的描述文件与它们的证书，按建的时间留最近 keep 份，其余删掉、撤销"""
    rows = call('GET', '/profiles?filter[profileType]=IOS_APP_STORE&limit=200').get('data', [])
    mine = [p for p in rows if str(p['attributes'].get('name', '')).startswith(prefix)]
    mine.sort(key=lambda p: p['attributes']['name'], reverse=True)
    for p in mine[keep:]:
        certs = call('GET', f"/profiles/{p['id']}/certificates").get('data', [])
        for kind, rid in [('profiles', p['id'])] + [('certificates', c['id']) for c in certs]:
            try:
                call('DELETE', f'/{kind}/{rid}')
                print(f'已收回旧的 {kind} {rid}')
            except SystemExit as e:
                print(f'没收回旧的 {kind} {rid}：{e}')


def cleanup(out):
    path = os.path.join(out, 'ids.json')
    if not os.path.exists(path):
        print('没有要收回的证书')
        return
    ids = json.load(open(path))
    for kind, key in (('profiles', 'profile'), ('certificates', 'certificate')):
        if ids.get(key):
            try:
                call('DELETE', f'/{kind}/{ids[key]}')
                print(f'已收回    {kind} {ids[key]}')
            except SystemExit as e:
                print(f'没收回    {kind} {ids[key]}：{e}')


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'prepare':
        prepare(sys.argv[2], sys.argv[3])
    elif cmd == 'cleanup':
        cleanup(sys.argv[2])
    else:
        raise SystemExit(__doc__)
