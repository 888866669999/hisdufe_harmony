# 扫描「假如 git init 并提交，实际会入库的那部分文件」，找出敏感值。
#
# ===== 为什么需要它（与 audit_sensitive.py 的分工）=====
# audit_sensitive.py 是**模式匹配**：查「长得像学号/身份证的串」。
# 它不知道哪些文件会被 .gitignore 排除，所以全盘扫时会把 testdata/raw、
# screenshots 这些本地文件也算进去 —— 报告一片红，反而看不清真正会公开的
# 那部分是否干净。
#
# 本脚本补上这一环：先用 gitignore 的匹配语义筛出「会入库的文件」，
# 只扫这些 —— 它的结论能直接回答「发布出去安全吗」。
#
# ===== 为什么具体值放在本地文件里 =====
# 要确认「某个真实值没被带出去」，必须知道那个值是什么。但把真实值写进
# 本脚本，就等于**脚本本身成了泄露源**（这仓库是要公开的）。
# 因此真实值从 `tmp/known-pii.txt` 读取 —— 该路径已被 .gitignore 排除。
# 文件不存在时跳过「精确值」检查，只做模式匹配（依然能用，只是弱一点）。
#
# 格式：每行一条，`标签 = 值`。
#
# 用法: python tools/scan_publishable.py
import io
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from check_ignore import parse, ignored  # noqa: E402

# 本地真实值清单（不入库）
KNOWN_FILE = 'tmp/known-pii.txt'

# 「可关联到真人的第三方信息」也要查：教师姓名。名单同样来自本地文件，
# 避免脚本自身泄露（这里只写字段名，不写具体人名）。
TEACHER_LABEL = '教师名'

# 人工放进去的占位值（连续零 / 明显的假值）
PLACEHOLDER = re.compile(r'^(2025000000\d{2}|110101200001010000|20000101|'
                         r'00000000000000|20250901)$')

SKIP_DIRS = {'node_modules', 'oh_modules', '.hvigor', '.git', '.idea',
             '.mimosa', '.zcode', 'build'}
BIG = 60 * 1024 * 1024


def load_known():
    """读取本地真实值清单，返回 [(标签, bytes)]。"""
    out = []
    if not os.path.exists(KNOWN_FILE):
        print('提示：%s 不存在，跳过精确值检查（只做模式匹配）\n' % KNOWN_FILE)
        return out
    for ln in io.open(KNOWN_FILE, encoding='utf-8'):
        ln = ln.strip()
        if not ln or ln.startswith('#'):
            continue
        if '=' not in ln:
            continue
        label, val = ln.split('=', 1)
        val = val.strip()
        if val:
            out.append((label.strip(), val.encode('utf-8')))
    return out


def tracked_files():
    """按 .gitignore 语义筛出会入库的文件。"""
    rules = parse('.gitignore')
    out = []
    for root, dirs, files in os.walk('.'):
        dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
        for f in files:
            p = os.path.relpath(os.path.join(root, f), '.').replace(os.sep, '/')
            if not ignored(p, rules):
                out.append(p)
    return sorted(out)


def main():
    known = load_known()
    files = tracked_files()
    print('会入库的文件：%d 个' % len(files))
    print('精确值条目：%d 条\n' % len(known))

    hits = {}
    for p in files:
        try:
            if os.path.getsize(p) > BIG:
                continue
            b = open(p, 'rb').read()
        except Exception:
            continue
        for label, pat in known:
            if pat in b:
                hits.setdefault(label, []).append(p)
        txt = b.decode('utf-8', 'ignore')
        for m in re.findall(r'(?<!\d)20\d{10}(?!\d)', txt):
            if not PLACEHOLDER.match(m):
                hits.setdefault('可疑学号 ' + m, []).append(p)
        for m in re.findall(r'(?<![0-9Xx])[1-9]\d{5}(?:19|20)\d{2}'
                            r'(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])'
                            r'\d{3}[0-9Xx](?![0-9Xx])', txt):
            if not PLACEHOLDER.match(m):
                hits.setdefault('可疑身份证 ' + m, []).append(p)

    if not hits:
        print('结论：将公开的文件里未发现敏感值')
        return 0
    print('发现以下问题：')
    for label, ps in sorted(hits.items()):
        print('  %s: %d 个文件' % (label, len(ps)))
        for x in ps[:10]:
            print('      ' + x)
    return 1


if __name__ == '__main__':
    sys.exit(main())
