#!/usr/bin/env python3
"""给 ArkTS 端的输入框与下拉选择器统一加上液态玻璃底衬（fieldEffect）。

===== 为什么需要脚本 =====
输入框有十来处、`Select` 有八处，分布在 6 个文件里；手工逐个改容易漏，
而且每处的写法一模一样 —— 用脚本一次改完，漏改也能从统计里看出来。

===== 改法与「为什么不直接把底色去掉」=====
在 `.backgroundColor($r('app.color.surface_variant'))` 之后补一行
`.backgroundEffect(GlassKit.fieldEffect())`。

**刻意保留 backgroundColor**：磨砂需要一点底色才能与背后的玻璃面板分层，
纯模糊会「散」掉，看不出是一个可点的字段（见 GlassKit.fieldEffect 的注释）。

===== 范围限定 =====
只改 `TextInput` / `TextArea` / `Select` 的样式链 —— 用「向上找 8 行内是否
出现这几个组件名」来判定。卡片容器**刻意不改**：华为官方提示大面积玻璃
显著增加 GPU 负载，而卡片在列表里成百出现（docs/harmony-liquid-glass.md
记录过这条，与「课表彩卡不做玻璃」是同一个理由）。
"""
import io
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

TARGETS = [
    r'entry\src\main\ets\components\CourseEditor.ets',
    r'entry\src\main\ets\components\ReAuthDialog.ets',
    r'entry\src\main\ets\components\DateWheelDialog.ets',
    r'entry\src\main\ets\components\WeekPickerDialog.ets',
    r'entry\src\main\ets\components\SemesterPickerDialog.ets',
    r'entry\src\main\ets\pages\LoginPage.ets',
    r'entry\src\main\ets\pages\ScorePage.ets',
    r'entry\src\main\ets\pages\SettingsPage.ets',
    r'entry\src\main\ets\pages\ElectivePage.ets',
    r'entry\src\main\ets\pages\ClassroomPage.ets',
    r'entry\src\main\ets\pages\SchedulePage.ets',
]

# 判定「这一行属于哪个控件」：向上看几行
LOOKBACK = 8
CONTROLS = ('TextInput', 'TextArea', 'Select(')
GLASS_IMPORT = "import { GlassKit } from '../theme/GlassKit';"


def process(path: str) -> int:
    full = os.path.join(ROOT, path)
    if not os.path.exists(full):
        print('  [跳过] 文件不存在: %s' % path)
        return 0
    s = io.open(full, encoding='utf-8').read()
    if '.backgroundEffect(GlassKit.fieldEffect())' in s:
        # 幂等：已经改过就只补 import
        pass

    lines = s.split('\n')
    out = []
    added = 0
    for i, line in enumerate(lines):
        out.append(line)
        if '.backgroundColor($r(\'app.color.surface_variant\'))' not in line:
            continue
        ctx = '\n'.join(lines[max(0, i - LOOKBACK):i + 1])
        if not any(c in ctx for c in CONTROLS):
            continue
        # 已经有了就不重复加
        if i + 1 < len(lines) and 'fieldEffect' in lines[i + 1]:
            continue
        indent = re.match(r'(\s*)', line).group(1)
        out.append(indent + '.backgroundEffect(GlassKit.fieldEffect())')
        added += 1

    if added == 0:
        return 0

    s2 = '\n'.join(out)
    # 补 import（GlassKit 的相对路径按文件深度不同）
    if 'GlassKit' not in s2.split('\n\n')[0] and "theme/GlassKit" not in s2:
        for depth, rel in ((2, '../theme/GlassKit'), (1, '../theme/GlassKit')):
            pass
        # components/ 与 pages/ 都在 src/main/ets/ 下一层 → 都是 ../theme/GlassKit
        if "import { Theme } from '../theme/Theme';" in s2:
            s2 = s2.replace("import { Theme } from '../theme/Theme';",
                            "import { Theme } from '../theme/Theme';\n" + GLASS_IMPORT, 1)
        else:
            # 没有 Theme 导入的文件（如 LoginPage 可能用别的）：插在第一个 import 后
            m = re.search(r"^import .*;$", s2, re.M)
            if m:
                s2 = s2[:m.end()] + '\n' + GLASS_IMPORT + s2[m.end():]
            else:
                print('  [警告] 无法插入 import: %s' % path)
    io.open(full, 'w', encoding='utf-8', newline='\n').write(s2)
    return added


def main() -> int:
    total = 0
    for t in TARGETS:
        n = process(t)
        if n:
            print('  %-58s +%d 处' % (t.split('\\')[-1], n))
        total += n
    print('\n合计加了 %d 处液态玻璃底衬' % total)
    return 0


if __name__ == '__main__':
    sys.exit(main())
