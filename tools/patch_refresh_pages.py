#!/usr/bin/env python3
"""给 PlanPage / ElectivePage 加「下拉刷新 -> 强制联网」，对齐 Flutter 端。

写法上刻意不用 % 或 f-string 拼模板：模板里满是 `'100%'`，
百分号会被当成格式符（已经在写脚本时踩过一次）。
统一用 `str.replace` 的占位标记更稳。
"""
import io

PAGES = [
    ('entry/src/main/ets/pages/PlanPage.ets', 'this.load(false, true)'),
    ('entry/src/main/ets/pages/ElectivePage.ets', 'this.load(false, true)'),
]

STATE = """
  /**
   * 下拉刷新状态（`$$` 双向绑定给 Refresh）。
   * 刷新结束必须置回 false，否则指示器会一直转 —— 见 load 的 finally。
   */
  @State refreshing: boolean = false;"""

BUILD_HEAD = """  build() {
    // 下拉刷新：以 force 调用，**绕过 TTL 强制联网**（对齐 Flutter 端
    // 每页的 onRefresh: () => _load(force: true)）。没有它的话，
    // TTL 内（本页 6 小时）即使学校刚改了数据，下拉也只会重读缓存。
    Refresh({ refreshing: $$this.refreshing }) {
    Stack() {"""

BUILD_TAIL = """    .width('100%')
    .height('100%')
    }
    .onRefreshing(() => {
      REFRESH_CALL;
    })
    .layoutWeight(1)
    .width('100%')
  }
"""

FINALLY_OLD = """    } finally {
      this.loading = false;
    }"""
FINALLY_NEW = """    } finally {
      this.loading = false;
      // 复位下拉指示器（`$$` 双向绑定，不置回会一直转）
      this.refreshing = false;
    }"""


def patch(path: str, refresh_call: str) -> None:
    s = io.open(path, encoding='utf-8').read()

    if 'refreshing: boolean' not in s.split('build()')[0]:
        anchor = '  @State loading: boolean = true;'
        assert anchor in s, path + ' 找不到 loading 字段'
        s = s.replace(anchor, anchor + STATE, 1)

    old_head = '  build() {\n    Stack() {'
    assert old_head in s, path + ' build 起点未匹配'
    s = s.replace(old_head, BUILD_HEAD, 1)

    marker = "    .width('100%')\n    .height('100%')\n  }\n"
    idx = s.rfind(marker)
    assert idx > 0, path + ' build 结尾未匹配'
    s = s[:idx] + BUILD_TAIL.replace('REFRESH_CALL', refresh_call) + s[idx + len(marker):]

    assert FINALLY_OLD in s, path + ' finally 未匹配'
    s = s.replace(FINALLY_OLD, FINALLY_NEW, 1)

    io.open(path, 'w', encoding='utf-8', newline='\n').write(s)
    print('  %s 已加下拉刷新' % path.split('/')[-1])


for p, call in PAGES:
    patch(p, call)
