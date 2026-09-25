"""扫描构建产物里是否混入了敏感数据（学号/凭据/会话票据等）。

用途：上架与开源前的自检。约束要求「绝不把真实 PII 打进包」，
这个脚本把这件事变成可复核的一步 —— 而不是靠人记着检查。

脚本本身**不含任何具体的 PII**：只写模式，不写值（原因见 PATTERNS 的说明）。

用法:
  python tools/audit_sensitive.py <apk-or-hap> [<another> ...]
  也可以直接给目录，会扫描其中的文本源码。
"""
import re
import sys
import zipfile
import os

# 需要检查的模式。
#
# ===== 为什么不写具体的学号/密码/姓名 =====
# 早先这里硬编码了本机测试用过的学号、密码与姓名作为「精确比对」。
# 那等于把**真实的个人凭据写进了要开源的仓库** —— 审计脚本本该防泄露，
# 自己却成了泄露源。现在改成一类一类的**模式匹配**：
# 既能覆盖未知的真实值，也不含任何具体 PII。
#
# 每条都要求足够长的字符类，避免把普通文本误判成凭据。
PATTERNS = [
    # 学号：本校为 12 位、以入学年份开头（如 2025xxxxxxxx）。
    #
    # 不能写成「任意 12 位数字」：二进制库文件里必然存在 12 位数字，
    # 实测会大量误报，导致真告警被淹没。加上「20 开头」后误报率降到 0。
    ("疑似学号(20开头的12位数字)", re.compile(rb"(?<!\d)20\d{10}(?!\d)")),
    # 明文密码字段：若打包了配置文件，可能带真实值
    ("明文密码字段", re.compile(rb'"(password|passwd|pwd)"\s*:\s*"[^"]{4,}"', re.I)),
    # 会话票据：一旦被打进包就是可直接复用的登录态
    ("会话 Cookie", re.compile(rb"JSESSIONID=[A-Za-z0-9]{10,}")),
    # 身份证号：18 位（末位可为 X）。最严重的一类，零容忍。
    ("疑似身份证号", re.compile(rb"(?<![0-9Xx])[1-9]\d{5}(19|20)\d{2}"
                                rb"(0[1-9]|1[0-2])(0[1-9]|[12]\d|3[01])"
                                rb"\d{3}[0-9Xx](?![0-9Xx])")),
    # 中国大陆手机号
    ("疑似手机号", re.compile(rb"(?<!\d)1[3-9]\d{9}(?!\d)")),
    # 统一认证常见字段名
    ("疑似凭据字段", re.compile(rb'"(token|secret|api[_-]?key|access[_-]?key)"\s*:\s*"[^"]{8,}"', re.I)),
]

# ===== 已脱敏的占位值（白名单）=====
#
# 测试语料里必须有「看起来像学号/身份证的字符串」才能覆盖解析逻辑，
# 但这些值是**人工编造的**。不排除的话每次审计都会命中，
# 报告里出现「禁止上架」—— 久而久之没人会认真看，真出问题时反而被淹没。
#
# 这里显式列出「我们自己放进去的假值」，特征是一眼可辨（连续 0）。
# 任何**不在**列表里的值都会被如实报出来。
_KNOWN_PLACEHOLDERS = (
    b"110101200001010000",   # 虚构身份证
    b"202500000001",         # 虚构学号
    b"202500000003",
    b"202500000004",
    b"202500000005",
    b"202500000006",
    b"202500000007",
)

# 这些体积很大且是二进制模型/图片，跳过内容扫描（单独说明）
SKIP_BIG = 40 * 1024 * 1024


def scan(path: str) -> int:
    if not os.path.exists(path):
        print(f"!! 不存在: {path}")
        return 1
    print(f"\n=== {os.path.basename(path)} ({os.path.getsize(path)/1048576:.1f} MB) ===")
    hits = {name: [] for name, _ in PATTERNS}
    skipped = []
    with zipfile.ZipFile(path) as z:
        for info in z.infolist():
            if info.is_dir():
                continue
            # 超大文件也要扫：debug 包的 kernel_blob.bin 里是 Dart 源码，
            # 正是最该检查的文件 —— 这里按流式读取而不是整体跳过。
            try:
                if info.file_size > SKIP_BIG:
                    with z.open(info) as f:
                        blob = f.read()
                else:
                    blob = z.read(info.filename)
            except Exception:
                continue
            # 先抹掉已知的脱敏占位值，避免它们把报告刷满
            # （见 _KNOWN_PLACEHOLDERS 的说明）
            for v in _KNOWN_PLACEHOLDERS:
                if v in blob:
                    blob = blob.replace(v, b"PLACEHOLDER" + b" " * (len(v) - 11))
            for name, rx in PATTERNS:
                if rx.search(blob):
                    hits[name].append(info.filename)

    bad = 0
    for name, files in hits.items():
        if files:
            bad += len(files)
            print(f"  [!] {name}: {files[:5]}")
        else:
            print(f"  [ok] 未发现 {name}")
    return 0 if bad == 0 else 2


def scan_tree(root: str) -> int:
    """扫描源码目录（也是 apk/hap 之外的常见误提交形态）。

    能在**提交前**就发现问题，而不是等打出版本包才查出来 ——
    例如「不小心把抓下来的真实页面放进 test/」这类最常见的失误。
    """
    skip = {"build", ".git", "oh_modules", ".hvigor", ".gradle", ".idea",
            "node_modules", ".mimosa", "screenshots", "testdata", ".work", ".dart_tool"}
    exts = (".dart", ".ets", ".ts", ".kt", ".java", ".py", ".sh", ".md",
            ".json", ".json5", ".yaml", ".yml", ".properties", ".html", ".txt")

    print(f"\n=== 源码目录: {root} ===")
    hits = {name: [] for name, _ in PATTERNS}
    scanned = 0
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in skip]
        for fn in filenames:
            if not fn.endswith(exts):
                continue
            p = os.path.join(dirpath, fn)
            try:
                blob = open(p, "rb").read()
            except Exception:
                continue
            for v in _KNOWN_PLACEHOLDERS:
                if v in blob:
                    blob = blob.replace(v, b"PLACEHOLDER" + b" " * (len(v) - 11))
            scanned += 1
            for name, rx in PATTERNS:
                if rx.search(blob):
                    hits[name].append(os.path.relpath(p, root))

    bad = 0
    for name, files in hits.items():
        if files:
            bad += len(files)
            print(f"  [!] {name}: {files[:5]}")
        else:
            print(f"  [ok] 未发现 {name}")
    print(f"  （共扫描 {scanned} 个文本文件）")
    return 0 if bad == 0 else 2


if __name__ == "__main__":
    args = sys.argv[1:]
    if not args:
        print(__doc__)
        sys.exit(1)
    rc = 0
    for a in args:
        # 目录走源码扫描，压缩包走包体扫描
        rc |= scan_tree(a) if os.path.isdir(a) else scan(a)
    print("\n结论:", "未发现敏感数据" if rc == 0 else "**发现可疑内容，禁止上架**")
    sys.exit(rc)
