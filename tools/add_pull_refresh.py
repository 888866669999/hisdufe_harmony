#!/usr/bin/env python3
"""给五个缓存页面补上「下拉刷新 -> 强制联网」路径，对齐 Flutter 端。

===== 为什么要补这一条 =====
上一轮给五个页面接入了 PageCache（内存 → 磁盘 → 网络 + TTL），
但 `load()` 全部写死 `load(false)`：**用户没有任何办法在 TTL 内强制刷新**。
TTL 之内（成绩 2 分钟、培养方案 6 小时）即使学校刚出分、刚改培养方案，
下拉也只会重读缓存 —— 这与 Flutter 端不一致，那边每页都有
`onRefresh: () => _load(force: true)`。

===== 改法 =====
1. `load()` 增加 `force` 参数，透传给 `PageDataLoader.load(force)`；
2. 页面内容外面包一层 ArkUI 的 `Refresh`，`onRefreshing` 里以 force 调用。

为什么用 `Refresh` 而不是自绘：它是 SDK 原生组件，自带下拉手势、
进度指示与回弹，而且 `refreshing` 支持 `$$` 双向绑定（刷新结束后
必须把它置回 false，否则指示器会一直转）。
"""
import io
import re
import sys

ROOT = 'entry/src/main/ets/pages'

# 每页：文件名 -> (load 方法名, 包裹的目标表达式, 刷新回调里要调的语句)
PAGES = [
    ('ScorePage.ets', 'load', 'this.load(this.semester, false, true)'),
    ('PlanPage.ets', 'load', 'this.load(false, true)'),
    ('ElectivePage.ets', 'load', 'this.load(false, true)'),
    ('ProfilePage.ets', 'load', 'this.load(false, true)'),
]


def add_force_param(path: str, method: str) -> int:
    """给方法签名加 `force: boolean = false`，并把内部 loader().load(false) 改成 load(force)。"""
    full = f'{ROOT}/{path}'
    s = io.open(full, encoding='utf-8').read()
    n = 0

    # (a) 方法签名
    if method == 'load' and path == 'ScorePage.ets':
        old_sig = 'private async load(semester: string, interactive: boolean = false): Promise<void> {'
        new_sig = ('private async load(semester: string, interactive: boolean = false,\n'
                   '    force: boolean = false): Promise<void> {')
    else:
        old_sig = 'private async load(interactive: boolean = false): Promise<void> {'
        new_sig = ('private async load(interactive: boolean = false,\n'
                   '    force: boolean = false): Promise<void> {')
    if old_sig in s:
        s = s.replace(old_sig, new_sig, 1)
        n += 1

    # (b) 内部的 loader 调用：把 false 换成 force
    before = s.count('.load(false)')
    s = s.replace('.load(false)', '.load(force)')
    n += before

    if n:
        io.open(full, 'w', encoding='utf-8', newline='\n').write(s)
    return n


def main() -> int:
    for path, method, refresh_call in PAGES:
        n = add_force_param(path, method)
        print('  %-20s 改了 %d 处' % (path, n))
    return 0


if __name__ == '__main__':
    sys.exit(main())
