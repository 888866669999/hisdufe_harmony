"""把 Material outlined SVG 转成 HarmonyOS ArkUI `Path` 的 commands 字符串。

用途：生成 `entry/src/main/ets/common/MaterialIcons.ets`，让鸿蒙端的界面图标
与 Flutter 端的 `Icons.*_outlined` **同源**（同一批 Material 图标），
从而两端观感一致（见该文件的头部说明）。

为什么不用图片资源：
  ArkUI 的 `Image` 需要位图或 svg 文件，svg 还要放进 resources 且不支持按
  主题色着色。而 `Path().commands(...)` 是**矢量 + 可着色**的，
  与 Flutter 的 `Icon(Icons.x)` 渲染方式一致，换色/缩放都不失真，
  也不需要任何二进制资源。

用法：
  # 1) 取图标 svg（outlined 目录，与 Flutter 的 *_outlined 对应）
  mkdir -p /tmp/mi && cd /tmp/mi
  for n in calendar_month bar_chart menu_book extension meeting_room person \\
           settings school description close; do
    curl -s -o "$n.svg" \\
      "https://cdn.jsdelivr.net/npm/@material-design-icons/svg@0.14.13/outlined/$n.svg"
  done
  # 2) 转换（输出可直接覆写 MaterialIcons.ets 的正文）
  python tools/svg_to_arkts.py /tmp/mi

注意：转换结果里出现的 `A`（弧线）命令由 ArkUI Path 原生支持；
若将来换用不支持弧线的渲染目标，需要在此处把 A 拆成多段 C。
"""
import re
import sys
import pathlib

# Material 图标里出现的命令（大小写都要处理）
SUPPORTED = set('MmLlHhVvCcSsQqTtAaZz')


def parse_ops(d: str):
    """把 path 的 d 拆成 [(cmd, [nums...]), ...]"""
    token_re = re.compile(r'([MmLlHhVvCcSsQqTtAaZz])|(-?\d*\.?\d+(?:e[-+]?\d+)?)', re.I)
    ops = []
    cmd = None
    nums = []
    for m in token_re.finditer(d):
        if m.group(1):
            if cmd is not None:
                ops.append((cmd, nums))
            cmd = m.group(1)
            nums = []
        else:
            nums.append(float(m.group(2)))
    if cmd is not None:
        ops.append((cmd, nums))
    return ops


def to_arkts(d: str, scale: float = 1.0) -> str:
    """输出 ArkTS Path commands（数值归一化，避免科学计数法与多余小数位）"""
    ops = parse_ops(d)
    out = []
    for cmd, nums in ops:
        if cmd not in SUPPORTED:
            raise SystemExit(f'unsupported command: {cmd}')
        if cmd in 'Zz':
            out.append('Z')
            continue
        parts = []
        for n in nums:
            v = n * scale
            # 去掉浮点噪声，保留 3 位（图标坐标精度足够）
            s = f'{v:.3f}'.rstrip('0').rstrip('.')
            if s in ('-0', ''):
                s = '0'
            parts.append(s)
        out.append(cmd + ' '.join(parts))
    return ' '.join(out)


def main():
    src = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else '/tmp/mi')
    names = {}
    for svg in sorted(src.glob('*.svg')):
        text = svg.read_text(encoding='utf-8')
        m = re.search(r'\sd="([^"]+)"', text)
        if not m:
            print(f'!! no path in {svg.name}', file=sys.stderr)
            continue
        # 统一按 24x24 归一化（Material 的 viewBox 本身就是 24）
        vb = re.search(r'viewBox="([\d.\s]+)"', text)
        scale = 1.0
        if vb:
            vals = [float(x) for x in vb.group(1).split()]
            if len(vals) == 4 and vals[2] and abs(vals[2] - 24) > 0.01:
                scale = 24.0 / vals[2]
        names[svg.stem] = to_arkts(m.group(1), scale)

    print('// 由 tools/svg_to_arkts.py 从 @material-design-icons/svg (outlined) 生成')
    print('// 与 Flutter 版 Icons.*_outlined 同源，保证两端图标一致')
    for k, v in names.items():
        print(f'// {k}')
        print(f"export const ICON_{k.upper()}: string = '{v}';")
        print()


if __name__ == '__main__':
    main()