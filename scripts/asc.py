#!/usr/bin/env python3
"""App Store Connect API 的两件小事：打包前临时申请证书与描述文件，传完之后收回。

  python3 ios/asc.py prepare  <包标识> <输出目录>    写出 key.pem cert.cer profile.mobileprovision ids.json
  python3 ios/asc.py cleanup  <输出目录>             删掉那份描述文件、撤销那张证书

密钥从环境变量读：ASC_KEY_ID、ASC_ISSUER_ID、ASC_KEY_P8（.p8 文件的全文）。

照抄网页版仓库的 ios/asc.py（ARCHITECTURE 4.548），只去掉了补 HealthKit 那一段：原生版用不到。

为什么每次现申请、用完就撤：
  把证书导出成 p12 放进仓库机密，要用户自己在 Mac 的钥匙串里做，而用户没有 Mac。发布证书一个账号只能有两三张，
  每次申请一张不撤的话第三次就申请不下来。撤销发布证书不影响已经传上去的构建
  （Apple 的说明：已在 App Store 与 TestFlight 里的不受影响），所以传完就撤。
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
    # 2. 私钥与证书请求，在这台机器上现做，不出这台机器
    key = os.path.join(out, 'key.pem')
    csr = os.path.join(out, 'csr.pem')
    subprocess.run(['/usr/bin/openssl', 'req', '-new', '-newkey', 'rsa:2048', '-nodes', '-keyout', key,
                    '-subj', '/CN=Eiraowo GitHub Actions', '-out', csr], check=True, capture_output=True)
    cert = call('POST', '/certificates', {'data': {'type': 'certificates', 'attributes': {
        'certificateType': 'DISTRIBUTION', 'csrContent': open(csr).read()}}})['data']
    with open(os.path.join(out, 'cert.cer'), 'wb') as f:
        f.write(base64.b64decode(cert['attributes']['certificateContent']))
    ids = {'certificate': cert['id'], 'team': team, 'bundleId': bid}
    json.dump(ids, open(os.path.join(out, 'ids.json'), 'w'))   # 先记下证书，后面失败了 cleanup 也收得回

    # 3. App Store 描述文件：这个包标识 + 刚才那张证书
    prof = call('POST', '/profiles', {'data': {'type': 'profiles',
        'attributes': {'name': f'Eiraowo CI {int(time.time())}', 'profileType': 'IOS_APP_STORE'},
        'relationships': {'bundleId': {'data': {'type': 'bundleIds', 'id': bid}},
                          'certificates': {'data': [{'type': 'certificates', 'id': cert['id']}]}}}})['data']
    with open(os.path.join(out, 'profile.mobileprovision'), 'wb') as f:
        f.write(base64.b64decode(prof['attributes']['profileContent']))
    ids['profile'] = prof['id']
    json.dump(ids, open(os.path.join(out, 'ids.json'), 'w'))
    print(f'证书      已申请（{cert["id"]}），团队 {team}')
    print(f'描述文件  已生成（{prof["id"]}）')


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
