#!/usr/bin/env python3
"""签名之前对一遍描述文件：描述文件里没有的能力不写进 entitlements，描述文件不全的扩展不打进这个包。

  python3 scripts/signplan.py <证书目录> <project.yml> <GITHUB_ENV 文件>

由 .github/workflows/testflight.yml 在生成工程之前调（生成工程之后再改就晚了：entitlements 文件与扩展的打包都由 project.yml 决定）。

为什么要有这一步：手动签名时，entitlements 里写了而描述文件里没有的那一项，整个打包直接失败。
而有几样只能由用户在开发者网站上点（把 App Group 分给包标识，docs/system-abilities.md），没点之前描述文件里就是没有。
照网页版仓库 ios/build.sh 的规矩（4.896、4.941）：缺了哪样就不带哪样，照样出包，日志里写明，功能在应用里照实显示不可用。

  应用本身   aps-environment（Eira 推送）、HealthKit、App Group：描述文件里没有就从 entitlements 去掉
  .notify    通知扩展：描述文件出来了、并且应用与它都分到了 App Group 才带（钥匙经 App Group 交给它）
  .widgets   桌面组件：同上（数据经 App Group 交给它）

写进 GITHUB_ENV：EIRA_PROFILE_APP、EIRA_PROFILE_NOTIFY、EIRA_PROFILE_WIDGETS（描述文件的 UUID），
EIRA_EXPORT_PROFILES（导出 ipa 时的 provisioningProfiles，一行一个「包标识=UUID」）。
"""
import os
import plistlib
import re
import subprocess
import sys

import yaml  # 工作流的 venv 里装 pyyaml


class Loader(yaml.SafeLoader):
    """YAML 1.1 把 NO、yes、on 读成布尔，XcodeGen（YAML 1.2）读的是字符串。这里只认 true / false，原样写回"""


Loader.yaml_implicit_resolvers = {k: [r for r in v if r[0] != 'tag:yaml.org,2002:bool']
                                  for k, v in yaml.SafeLoader.yaml_implicit_resolvers.items()}
Loader.add_implicit_resolver('tag:yaml.org,2002:bool', re.compile(r'^(?:true|True|TRUE|false|False|FALSE)$'), list('tTfF'))

GROUP_KEY = 'com.apple.security.application-groups'
APS = 'aps-environment'
HEALTH = ('com.apple.developer.healthkit', 'com.apple.developer.healthkit.access')
# 扩展：target 名、包标识后缀、描述文件、环境变量
EXTENSIONS = (
    ('EiraNotify', '.notify', 'notify-profile.mobileprovision', 'EIRA_PROFILE_NOTIFY', '通知扩展（Eira 推送在锁屏上解密显示）'),
    ('EiraWidgets', '.widgets', 'widgets-profile.mobileprovision', 'EIRA_PROFILE_WIDGETS', '桌面组件'),
)


def warn(msg):
    print(f'::warning::{msg}')


def load(path):
    if not os.path.exists(path):
        return None
    raw = subprocess.run(['security', 'cms', '-D', '-i', path], check=True, capture_output=True).stdout
    return plistlib.loads(raw)


def main(sign_dir, project, env_file):
    spec = yaml.load(open(project), Loader=Loader)
    targets = spec['targets']
    app = targets['Eira']
    bundle = app['settings']['base']['PRODUCT_BUNDLE_IDENTIFIER']
    props = app['entitlements']['properties']
    group = (props.get(GROUP_KEY) or [''])[0]

    prof = load(os.path.join(sign_dir, 'profile.mobileprovision'))
    if not prof:
        raise SystemExit('没有应用本身的描述文件')
    ent = prof.get('Entitlements', {})
    env = {'EIRA_PROFILE_APP': prof['UUID']}
    export = [f"{bundle}={prof['UUID']}"]

    if APS in ent:
        props[APS] = ent[APS]
        print(f'推送      描述文件里有 {APS}={ent[APS]}')
    else:
        props.pop(APS, None)
        warn('描述文件里没有 Push Notifications：这个包要不到推送地址，Eira 推送不可用。包标识勾上 Push Notifications 后重传（scripts/asc.py 会自动勾）')
    if HEALTH[0] not in ent:
        for k in HEALTH:
            props.pop(k, None)
        warn('描述文件里没有 HealthKit：这个包里「从健康同步」不可用')
    app_group = bool(group) and group in (ent.get(GROUP_KEY) or [])
    if app_group:
        print(f'共用存储  应用分到了 {group}')
    else:
        props.pop(GROUP_KEY, None)
        warn(f'应用的描述文件里没有 App Group {group}：通知扩展与桌面组件都不带。在开发者网站把 {group} 分给 {bundle} 与两个扩展（docs/system-abilities.md）')

    deps = []
    for name, suffix, fname, var, what in EXTENSIONS:
        ext = load(os.path.join(sign_dir, fname))
        why = ''
        if not ext:
            why = '描述文件没生成（看上一步 asc.py 的输出）'
        elif not app_group:
            why = '应用本身没分到 App Group'
        elif group not in (ext.get('Entitlements', {}).get(GROUP_KEY) or []):
            why = f'{bundle}{suffix} 没分到 {group}'
        if why:
            targets.pop(name, None)
            warn(f'这个包里不带{what}：{why}')
            continue
        deps.append({'target': name})
        env[var] = ext['UUID']
        export.append(f"{bundle}{suffix}={ext['UUID']}")
        print(f'扩展      带上 {name}（{bundle}{suffix}）')

    if deps:
        app['dependencies'] = deps
    else:
        app.pop('dependencies', None)
    with open(project, 'w') as f:
        yaml.safe_dump(spec, f, sort_keys=False, allow_unicode=True)
    with open(env_file, 'a') as f:
        for k, v in env.items():
            f.write(f'{k}={v}\n')
        f.write('EIRA_EXPORT_PROFILES<<EOF\n' + '\n'.join(export) + '\nEOF\n')


if __name__ == '__main__':
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    main(sys.argv[1], sys.argv[2], sys.argv[3])
