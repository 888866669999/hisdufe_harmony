/*
 * WeekPickerContent：周次选择的浮层内容（毛玻璃 + 滚轮）
 *
 * ===== 为什么不用系统弹窗框架（CustomDialogController）=====
 * 这里踩过一个真机 bug，值得记下来：早先它是 `@CustomDialog` + 页面里
 * `new CustomDialogController(...)` 打开，关闭靠组件内的
 * `this.controller.close()`。真机上**点确定/取消都不关闭**。
 * 加日志确认根因：组件里的 `this.controller` 是 **undefined** ——
 * 临时 `new` 出来的控制器不会被框架注入回组件，于是那句
 * `if (this.controller !== undefined)` 静默跳过了关闭动作。
 * 同样的写法在本项目另外两个滚轮弹窗（DateWheel / SemesterPicker）里
 * 存在同样的问题。
 *
 * 现在改为**页面内浮层**（GlassOverlay + 本组件作为内容）：
 *   - 关闭 = 调用方把 `open` 置 false，是普通的 @State 变更，
 *     不依赖任何框架注入，从根本上不会再出现「关不掉」；
 *   - 宽度完全由调用方给定（`panelWidthVp`），不会再随窗口拉得过宽；
 *   - 能用上 AppleUI 液态玻璃透镜 —— 系统弹窗框架自建的容器里没有
 *     「可折射的前序兄弟」，透镜取不到背景会整块不渲染
 *     （见 GlassKit 类注释的规则二），所以早先只能用磨砂。
 *
 * ===== 三态语义（与 Flutter 端一致）=====
 * 周次有三种状态，必须区分，否则「默认跟随本周」和「手动选了全部」
 * 会互相覆盖：
 *   - WEEK_AUTO ：跟随本周（默认）
 *   - ''        ：全部周次
 *   - '3'       ：第 3 周
 */
import { Theme } from '../theme/Theme';
import { GlassKit } from '../theme/GlassKit';
import { AS_CURRENT_WEEK } from '../common/Constants';

/** 周次选择的第三种状态：自动跟随本周 */
export const WEEK_AUTO: string = 'auto';

@Component
export struct WeekPickerContent {
  /** 打开时的当前值（三态之一） */
  current: string = WEEK_AUTO;
  /**
   * 当前教学周（用于在选项里标出「本周」）。
   *
   * 用 `@StorageProp` 直接订阅 AppStorage，而不是让调用方传值：
   * 调用方 SchedulePage 里的 `currentWeekNo` 本身是 `@StorageProp`，
   * ArkTS 不允许把 `@StorageProp` 属性赋给子组件的普通属性
   * （报 "The '@StorageProp' property ... cannot be assigned to
   * the 'regular' property"）。两个组件订阅同一个键，
   * 反而与状态来源更一致。
   */
  @StorageProp(AS_CURRENT_WEEK) currentWeek: number = 0;
  /** 选项上限（周次数） */
  maxWeeks: number = 30;
  /** 选中回调 */
  onPicked: (value: string) => void = () => {};
  /** 取消回调（由调用方关闭浮层） */
  onCancel: () => void = () => {};

  @State private idx: number = 0;

  /** 选项：0=跟随本周，1=全部，2..=第 N 周 */
  private options(): string[] {
    const out: string[] = ['跟随本周', '全部'];
    for (let i = 1; i <= this.maxWeeks; i++) {
      out.push('第 ' + i.toString() + ' 周');
    }
    return out;
  }

  private static indexOf(v: string, maxWeeks: number): number {
    if (v === WEEK_AUTO) {
      return 0;
    }
    if (v.length === 0) {
      return 1;
    }
    const n: number = parseInt(v, 10);
    if (isNaN(n) || n < 1 || n > maxWeeks) {
      return 0; // 越界/非法一律回落「跟随本周」，不落到奇怪的周次
    }
    return n + 1;
  }

  private storedValue(i: number): string {
    if (i === 0) {
      return WEEK_AUTO;
    }
    if (i === 1) {
      return '';
    }
    return (i - 1).toString();
  }

  aboutToAppear(): void {
    this.idx = WeekPickerContent.indexOf(this.current, this.maxWeeks);
  }

  build() {
    Column({ space: Theme.GAP }) {
      Text('选择周次')
        .fontSize(Theme.FS_TITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .textAlign(TextAlign.Center)

      // 原生滚轮：上下滑动选择
      TextPicker({ range: this.options(), selected: this.idx })
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
            this.onPicked(this.storedValue(this.idx));
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
 * 用精确 vp 而不是比例：比例是按「可用宽度」算的，平板上会算得很宽
 * （实测用户反馈「弹窗太宽」）。这个浮层内容宽度固定 —— 一个滚轮、
 * 两个按钮 —— 给 320vp 在任何屏幕上都合适。
 */
export function weekPickerPanelWidth(): number {
  return 320;
}

/** 面板高度 = 标题 + 滚轮 + 提示 + 按钮行 + 间距 + 上下内边距 */
export function weekPickerPanelHeight(): number {
  const title: number = 28;
  const wheel: number = 200;
  const hint: number = 16;
  const buttons: number = 44;
  const gaps: number = 12 * 3;
  return title + wheel + hint + buttons + gaps + GlassKit.PANEL_PAD * 2;
}
