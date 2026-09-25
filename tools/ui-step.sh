#!/usr/bin/env bash
# 日期滚轮的自动化验证辅助脚本（仅开发期使用，不参与打包）
#
# 为什么要它：TextPicker 的无障碍树只暴露**可见的几行**，看不到「日」列
# 的最大值（28/30/31），因此没法用一次 dump 判断年月联动是否正确。
# 只能「拨一格 → 读一次选中值」地收敛，手工点太慢。
#
# 用法: source tools/ui-step.sh; swipe <x1> <y1> <x2> <y2>; dump
#
# hdc 的位置随 DevEco 安装目录而变，因此优先读环境变量 DEVECO_HOME，
# 未设置时退回常见默认值 —— 不把某台机器的绝对路径写死。
# 若 hdc 已在 PATH 里，直接把它设成 PATH 上的 hdc 更省事：
#   export DEVECO_HOME=/path/to/DevEco\ Studio
DEVECO="${DEVECO_HOME:-/d/DevEco Studio}"
if command -v hdc >/dev/null 2>&1; then
  HDC="hdc"
else
  HDC="$DEVECO/sdk/default/openharmony/toolchains/hdc.exe"
fi

swipe() {
  "$HDC" shell "uitest uiInput swipe $1 $2 $3 $4 ${5:-400}" >/dev/null 2>&1
}

dump() {
  "$HDC" shell "uitest dumpLayout -p /data/local/tmp/u.json" >/dev/null 2>&1
  MSYS_NO_PATHCONV=1 "$HDC" file recv /data/local/tmp/u.json "build/u.json" >/dev/null 2>&1
  python -c "
import json,io,re
d=json.load(io.open('build/u.json',encoding='utf-8'))
sel={}; vis={'月':[], '日':[]}
def walk(n):
    a=n.get('attributes',{}); t=a.get('text',''); b=a.get('bounds','')
    key='月' if b.startswith('[1140') else ('日' if b.startswith('[1660') else None)
    if key and t and re.fullmatch(r'\d{2}',t):
        m=re.match(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]',b)
        if int(m.group(4))-int(m.group(2))>100: sel[key]=t
        elif len(vis[key])<30: vis[key].append(t)
    for c in n.get('children',[]): walk(c)
walk(d)
print('选中 月=%s 日=%s | 日列可见=%s' % (sel.get('月','?'), sel.get('日','?'), vis['日']))
"
}
