# check_ignore.py —— 不依赖 git 仓库，复核 .gitignore 是否真的挡住了敏感路径。
#
# ===== 为什么需要它 =====
# 本仓库发布前要反复确认「真实 PII 与私钥不会被提交」。正常做法是
# `git check-ignore -v <路径>`，但它有个致命的坑：**没有 git 仓库时它以
# 128 退出、且不打印任何内容** —— 看起来就像「没有任何规则匹配」。
#
# 实测踩过一次：本项目某段时间确实没有仓库（外层那个无关的 `C:\` 仓库消失后），
# 当时 `git check-ignore` 对所有路径都沉默，据此差点以为「所有规则都失效了」，
# 而规则其实一直是好的。
#
# 因此这里按 git 的语义手写一遍匹配（锚定、目录前缀、`!` 取反），
# 用固定的路径清单做断言 —— 既能在没有仓库时复核，也能当 .gitignore 的
# 回归测试（改了规则跑一下就知道有没有漏）。
#
# 用法: python tools/check_ignore.py
import io
import fnmatch
import os
import sys


def parse(path):
    """读取 .gitignore，返回 [(模式, 是否取反)]。

    只处理规则行：跳过空行与注释；`!` 前缀表示白名单（重新纳入）。
    """
    out = []
    for ln in io.open(path, encoding='utf-8'):
        ln = ln.rstrip('\n').rstrip('\r')
        if not ln.strip() or ln.lstrip().startswith('#'):
            continue
        neg = ln.startswith('!')
        out.append((ln[1:] if neg else ln, neg))
    return out


def match(pat, p):
    """判断单个模式是否匹配路径 p（p 为相对仓库根的 / 分隔路径）。"""
    if pat.startswith('/'):
        # 前导 / 表示锚定仓库根；本例中 p 本身就是相对根的，去掉即可
        pat = pat[1:]
    if pat.endswith('/'):
        pat = pat[:-1] + '/**'
    if '/' not in pat:
        # 不含斜杠的模式匹配任意层级（git 的规则）
        cands = [pat, '*/' + pat, pat + '/**', '*/' + pat + '/**']
    else:
        cands = [pat, pat + '/**']
    return any(fnmatch.fnmatch(p, c) for c in cands)


def ignored(p, rules):
    """按顺序应用全部规则，后出现的规则（含 ! 白名单）覆盖先前的。"""
    hit = False
    for pat, neg in rules:
        if match(pat, p):
            hit = not neg
    return hit


# ===== 断言清单 =====
# 左列是路径，右列是**期望是否被忽略**。
# 「期望忽略」的都是含真实 PII、私钥或签名的东西；
# 「期望保留」的是源码、模板、以及刻意公开的 CA 证书。
CASES = [
    # --- 含真实 PII，必须忽略 ---
    ('testdata/raw/profile.html', True),        # 原始抓取：姓名/学号/身份证
    ('testdata/fixtures/timetable.html', True), # 测试夹具（fixtures 整个排除了）
    ('testdata/run-tests.mjs', True),           # 测试脚本也一起排除（见 .gitignore 说明）
    ('screenshots/01-login.jpeg', True),        # 实机截图：屏幕上就有姓名与学号
    ('screenshots/b1.json', True),              # UI dump：文本里带学号
    ('tmp/sch.jpeg', True),                     # 开发期临时截图
    ('tmp/agent_reminder_apply.png', True),
    # --- 凭据与签名素材 ---
    ('signing/huawei/keystore.p12', True),      # 私钥：泄露即可冒充发布
    ('signing/huawei/app.cer', True),
    ('signing/sdufe.p7b', True),
    ('signing/profile.p12', True),
    ('build-profile.json5', True),              # 含本机绝对路径与 keystore 口令
    ('local.properties', True),                 # 含 SDK 本机路径
    # --- 构建产物与工具状态 ---
    ('entry/build/default/outputs/default/entry-default-signed.hap', True),
    ('.hvigor/cache/x.json', True),
    ('.mimosa/hook-state/x.source', True),      # 扫描工具会回显被扫代码里的字符串
    ('oh_modules/foo/bar.js', True),
    ('release/hisdufe-arkts-v1.0.0-unsigned.hap', True),
    # --- 这些必须能提交 ---
    ('build-profile.json5.example', False),     # 模板：别人照它复制
    ('README.md', False),
    ('entry/src/main/ets/pages/Index.ets', False),
    ('entry/src/main/resources/base/element/color.json', False),
    ('AppScope/app.json5', False),
    ('tools/audit_sensitive.py', False),
    ('tools/check_ignore.py', False),
    ('tools/scan_publishable.py', False),
    ('tools/__pycache__/x.pyc', True),
    ('.zcode/plans/plan-x.md', True),
    ('tmp/known-pii.txt', True),
    ('docs/tech-notes.md', False),
    # 白名单放行的脚本与公开 CA（人人都有，不是私钥）
    ('signing/emu-sign-install.sh', False),
    ('signing/make-emu-profile.mjs', False),
    ('signing/oh-root-ca.cer', False),
]


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    gi = os.path.join(root, '.gitignore')
    if not os.path.exists(gi):
        print('找不到 .gitignore: %s' % gi)
        return 2
    rules = parse(gi)
    print('已载入 %d 条规则（%s）\n' % (len(rules), gi))

    bad = []
    for p, want in CASES:
        got = ignored(p, rules)
        if got != want:
            bad.append((p, want, got))
        print('  [%s] %s  %s' % ('ok ' if got == want else 'FAIL',
                                '忽略' if got else '保留', p))
    print()
    if bad:
        print('%d 项不符预期：' % len(bad))
        for p, want, got in bad:
            print('   %s  期望%s，实际%s'
                  % (p, '忽略' if want else '保留', '忽略' if got else '保留'))
        return 1
    print('全部 %d 项符合预期' % len(CASES))
    return 0


if __name__ == '__main__':
    sys.exit(main())
