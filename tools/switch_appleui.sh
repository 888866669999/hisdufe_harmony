#!/usr/bin/env bash
#
# 在「正式 AppleUI」与「模拟器占位」之间切换依赖，然后 ohpm install。
#
# ===== 为什么需要它 =====
# 正式的 com.hm.appleui.hw 只提供 arm64-v8a 的原生库，且 HAR 内不含 cpp
# 源码，无法为 x86_64 重新编译。于是任何依赖它的 HAP 都装不上 x86_64 模拟器
# （hdc 报 `install parse native so failed`，ABI 不匹配）。
#
# 而「手机端一屏装下整周课表」「不同 dpi 的布局响应」只与布局有关，
# 与玻璃着色器无关。因此提供 devstub/appleui 这个 API 完全一致的占位实现，
# 让模拟器能真实验证布局。
#
# 用法:
#   bash tools/switch_appleui.sh stub     # 切到占位（给模拟器构建）
#   bash tools/switch_appleui.sh real     # 切回正式包（给真机构建）
#   bash tools/switch_appleui.sh status   # 查看当前用的是哪个
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
PKG='oh-package.json5'
BAK='oh-package.json5.bak'

if [ ! -f "$BAK" ]; then
  echo "缺少 $BAK（正式依赖的备份）。请先手工确认 oh-package.json5 内容正确。" >&2
  exit 1
fi

mode="${1:-status}"

case "$mode" in
  stub)
    # 用 Python 改写 JSON5 里的依赖行（只替换那一行的值，其余保持原样）
    python - "$PKG" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding='utf-8').read()
s = s.replace('"com.hm.appleui.hw": "^2.1.0"',
              '"com.hm.appleui.hw": "file:./devstub/appleui"')
open(p, 'w', encoding='utf-8').write(s)
print('oh-package.json5 -> devstub')
PY
    ohpm install --all 2>&1 | tail -3
    echo "已切到**占位** AppleUI —— 现在可为 x86_64 模拟器构建。"
    echo "测完请执行：bash tools/switch_appleui.sh real"
    ;;
  real)
    cp "$BAK" "$PKG"
    ohpm install --all 2>&1 | tail -3
    echo "已切回**正式** AppleUI —— 现在构建的 HAP 可装 arm64 真机。"
    ;;
  status)
    if command grep -q 'file:./devstub/appleui' "$PKG"; then
      echo "当前：占位（模拟器用）"
    else
      echo "当前：正式包（真机用）"
    fi
    ;;
  *)
    echo "用法: bash tools/switch_appleui.sh [stub|real|status]" >&2
    exit 1
    ;;
esac
