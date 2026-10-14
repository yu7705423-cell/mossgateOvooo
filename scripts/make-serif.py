# 新版界面的标题宋体：把网页版 vendor/fonts/noto-serif-sc 的 101 块 woff2 合成一份 Resources/EiraSerif-SemiBold.ttf。
#
#   python3 -m venv /tmp/fv && /tmp/fv/bin/pip install fonttools brotli
#   /tmp/fv/bin/python scripts/make-serif.py <网页版仓库目录>
#
# 字体是思源宋体（Noto Serif SC）600，SIL Open Font License 1.1，可以随应用分发（见网页版那个目录的 README）。
# 网页版按 unicode-range 切块是为了浏览器按需下载；原生版装在包里，合成一份即可。字体名照网页版改为 Eira Serif。
import glob
import os
import sys
import tempfile

from fontTools.merge import Merger
from fontTools.ttLib import TTFont

web = sys.argv[1] if len(sys.argv) > 1 else sys.exit('用法：python scripts/make-serif.py <网页版仓库目录>')
files = sorted(glob.glob(os.path.join(web, 'vendor/fonts/noto-serif-sc/*.woff2')))
if not files:
    sys.exit('找不到 vendor/fonts/noto-serif-sc/*.woff2')
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Resources', 'EiraSerif-SemiBold.ttf')
with tempfile.TemporaryDirectory() as tmp:
    parts = []
    for i, f in enumerate(files):
        t = TTFont(f)
        t.flavor = None
        p = os.path.join(tmp, f'part{i}.ttf')
        t.save(p)
        parts.append(p)
    font = Merger().merge(parts)
names = font['name']
names.setName('Eira Serif', 1, 3, 1, 0x409)
names.setName('Eira Serif SemiBold', 4, 3, 1, 0x409)
names.setName('EiraSerif-SemiBold', 6, 3, 1, 0x409)
font.save(out)
print(f'{len(files)} 块 -> {out}，{len(TTFont(out).getBestCmap())} 个字')
