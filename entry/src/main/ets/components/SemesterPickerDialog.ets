/*
 * SemesterPickerContent：学期选择的浮层内容（毛玻璃 + 滚轮）
 *
 * ===== 为什么不用 ArkUI 的 Select（下拉框）=====
 * 实测真机（MatePad 11.5 S，2800×1840）上的两个硬伤：
 *   1. **列表被窗口底边截断且不能滚动**。教务系统返回 46 个学期，
 *      Select 展开后只画到第 9 项，剩下的既看不到也点不到 ——
 *      用户反馈的「没有全部学期」就是这个（不是没数据，是够不着）。
 *   2. **丢失「全部学期」这一项**。它在页面里的 value 是空串，
 *      而解析器为了过滤占位项会把空值 option 丢掉，
 *      于是「不筛选、看全部成绩」这个入口在界面上根本不存在。
 * 换成滚轮后两个问题一并解决：滚轮可无限滚动，且「全部学期」
 * 由本组件显式放在第一位（与 Flutter 端的学期滚轮完全一致）。
 *
 * ===== 为什么不用 CustomDialogController（真机 bug）=====
 * 早先它是 `@CustomDialog`，靠组件内的 `this.controller.close()` 关闭。
 * 真机上**点确定/取消都关不掉** —— 加日志确认 `this.controller` 是
 * undefined：临时 `new` 出来的控制器不会被框架注入回组件，
 * 那句 `if (this.controller !== undefined)` 静默跳过了关闭动作。
 * 现在改为**页面内浮层**（GlassOverlay + 本组件作为内容）：关闭就是
 * 调用方把 `open` 置 false，是普通的 @State 变更，不依赖框架注入。
 * 附带好处：宽度完全可控（不再随窗口拉宽），且能用上 AppleUI 液态玻璃
 * 透镜（系统弹窗框架里没有「可折射的前序兄弟」，透镜不渲染）。
 */
import { Theme } from '../theme/Theme';
import { GlassKit } from '../theme/GlassKit';

/** 一个可选项：label 给用户看，value 提交给服务器（空串 = 全部） */
export class SemesterOption {
  label: string = '';
  value: string = '';

  constructor(label: string, value: string) {
    this.label = label;
    this.value = value;
  }
}

@Component
export struct SemesterPickerContent {
  /** 全部学期选项（第一项应由调用方放「全部学期」） */
  options: SemesterOption[] = [];
  /** 打开时的当前值（空串 = 全部学期） */
  current: string = '';
  /** 选中回调；取消时不调用 */
  onPicked: (value: string) => void = () => {};
  /** 取消回调（由调用方关闭浮层） */
  onCancel: () => void = () => {};

  @State private idx: number = 0;

  /** 选项文案数组（TextPicker 只吃字符串） */
  private labels(): string[] {
    const out: string[] = [];
    for (let i = 0; i < this.options.length; i++) {
      out.push(this.options[i].label);
    }
    return out;
  }

  /** 当前值在选项里的下标；找不到就回到第一项（全部学期）而不是错位选中 */
  private indexOfCurrent(): number {
    for (let i = 0; i < this.options.length; i++) {
      if (this.options[i].value === this.current) {
        return i;
      }
    }
    return 0;
  }

  aboutToAppear(): void {
    this.idx = this.indexOfCurrent();
  }

  build() {
    Column({ space: Theme.GAP }) {
      Text('选择学期')
        .fontSize(Theme.FS_TITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .textAlign(TextAlign.Center)

      // 原生滚轮：上下滑动选择。学期有几十个，滚轮比贴边长列表好用得多。
      TextPicker({ range: this.labels(), selected: this.idx })
        .height(200)
        .width('100%')
        .selectedTextStyle({
          color: $r('app.color.brand'),
          font: { size: 17, weight: FontWeight.Bold }
        })
        .textStyle({ color: $r('app.color.text_secondary'), font: { size: 15 } })
        .onChange((value: string | string[], index: number | number[]) => {
          if (typeof index === 'number') {
            this.idx = index;
          }
        })

      Text('上下滑动选择')
        .fontSize(Theme.FS_TINY)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .textAlign(TextAlign.Center)

      Row({ space: Theme.GAP_S }) {
        Button('取消')
          .fontSize(Theme.FS_BODY)
          .backgroundColor($r('app.color.surface_variant'))
          .fontColor($r('app.color.text_primary'))
          .height(44)
          .layoutWeight(1)
          .borderRadius(22)
          .onClick(() => {
            this.onCancel();
          })
        Button('确定')
          .fontSize(Theme.FS_BODY)
          .backgroundColor($r('app.color.brand'))
          .fontColor($r('app.color.on_brand'))
          .height(44)
          .layoutWeight(1)
          .borderRadius(22)
          .onClick(() => {
            if (this.idx >= 0 && this.idx < this.options.length) {
              this.onPicked(this.options[this.idx].value);
            }
          })
      }
      .width('100%')

      Blank()
    }
    // 内容只负责自身布局；面板的边框/圆角/玻璃底/遮罩全由 GlassOverlay 提供
    .width('100%')
    .height('100%')
    .padding(GlassKit.PANEL_PAD)
    .alignItems(HorizontalAlign.Start)
  }
}

/**
 * 浮层面板尺寸（vp），供 GlassOverlay 使用。
 *
 * 用精确 vp 而不是比例：比例按可用宽度算，平板上会算得很宽
 * （用户反馈过「弹窗太宽」）。本浮层内容就是「一个滚轮 + 一行按钮」，
 * 320vp 足够；学期名最长 11 个字符（2025-2026-1），320 也放得下。
 */
export function semesterPanelWidth(): number {
  return 320;
}

/** 面板高度 = 标题 + 滚轮 + 提示 + 按钮行 + 间距 + 上下内边距 */
export function semesterPanelHeight(): number {
  const title: number = 28;
  const wheel: number = 200;
  const hint: number = 16;
  const buttons: number = 44;
  const gaps: number = 12 * 3;
  return title + wheel + hint + buttons + gaps + GlassKit.PANEL_PAD * 2;
}
