/*
 * DateWheelContent：年/月/日三列滚轮的日期选择浮层内容
 *
 * ===== 为什么不用系统 DatePickerDialog =====
 * 系统日期选择器是「日历格子」形态，与本应用整体的液态玻璃风格不一致
 * （用户明确要求开学日期改成 yy/mm/dd 上下滑动的玻璃滚轮，Flutter 端
 * 已是这个形态，两端应当一致）。系统弹窗还带自己的底色，无法融入背景。
 *
 * ===== 为什么也不用 CustomDialogController（真机 bug）=====
 * 早先它是 `@CustomDialog`，靠组件内的 `this.controller.close()` 关闭。
 * 真机上**点确定/取消都关不掉** —— 加日志确认 `this.controller` 是
 * undefined：临时 `new` 出来的控制器不会被框架注入回组件，
 * 那句 `if (this.controller !== undefined)` 静默跳过了关闭动作。
 * 现在改为**页面内浮层**（GlassOverlay + 本组件作为内容）：关闭就是
 * 调用方把 `open` 置 false，是普通的 @State 变更，不依赖框架注入。
 * 附带好处：宽度完全可控（不再随窗口拉宽），且能用上 AppleUI 液态玻璃
 * 透镜（系统弹窗框架里没有「可折射的前序兄弟」，透镜不渲染）。
 *
 * ===== 玻璃怎么画 =====
 * 三列选中行的底色统一由外层画一条高亮带，而不是每列各画一段 ——
 * 后者会在列缝处断成三块，看起来像是三个独立控件。
 *
 * ===== 为什么三列要联动 =====
 * 年月决定当月天数。若「日」列固定 31 项，从 1/31 切到 2 月就会得到
 * 2/31 这种不存在的日期。因此年月变化后必须把日的选项重建，并把
 * 已选值夹到合法范围（见 clampDay）。
 */
import { Theme } from '../theme/Theme';
import { GlassKit } from '../theme/GlassKit';
import { WeekCalc } from '../common/WeekCalc';

/** 滚轮每列显示的行高（vp），选中行底色与之等高 */
const ITEM_H: number = 40;
/** 滚轮可见高度：约 5 行，上下能看到相邻项 */
const WHEEL_H: number = 200;

/** 回调用的年月日三元组（避免在组件间传递 Date 的时区歧义） */
export class YmdValue {
  year: number = 2026;
  month: number = 1;
  day: number = 1;

  constructor(year: number, month: number, day: number) {
    this.year = year;
    this.month = month;
    this.day = day;
  }
}

/** 某年某月的天数（month 为 1-12）。逻辑在 WeekCalc 里，便于 Node 单测 */
export function daysInMonth(year: number, month: number): number {
  return WeekCalc.daysInMonth(year, month);
}

@Component
export struct DateWheelContent {
  /** 打开时的当前值 */
  @Prop initial: YmdValue = new YmdValue(2026, 1, 1);
  /** 可选年份范围 */
  @Prop firstYear: number = 2020;
  @Prop lastYear: number = 2100;
  /** 确定回调；取消时不调用 */
  onPicked: (value: YmdValue) => void = () => {};
  /** 取消回调（由调用方关闭浮层） */
  onCancel: () => void = () => {};

  @State private yy: number = 0;       // 年下标
  @State private mm: number = 0;       // 月下标（0-11）
  @State private dd: number = 0;       // 日下标（0 起）
  /** 当月的天数：随年月变化而重建，用于「日」列的 range */
  @State private dim: number = 31;

  private years(): string[] {
    const out: string[] = [];
    for (let y = this.firstYear; y <= this.lastYear; y++) {
      // 年份用四位，避免与月份/日期混淆
      out.push(y.toString());
    }
    return out;
  }

  /** 月/日统一补零成两位，视觉上三列宽度一致 */
  private static pad2(v: number): string {
    return v < 10 ? '0' + v.toString() : v.toString();
  }

  private months(): string[] {
    const out: string[] = [];
    for (let m = 1; m <= 12; m++) {
      out.push(DateWheelContent.pad2(m));
    }
    return out;
  }

  private days(): string[] {
    const out: string[] = [];
    for (let d = 1; d <= this.dim; d++) {
      out.push(DateWheelContent.pad2(d));
    }
    return out;
  }

  aboutToAppear(): void {
    const y: number = Math.min(Math.max(this.initial.year, this.firstYear), this.lastYear);
    const m: number = Math.min(Math.max(this.initial.month, 1), 12);
    this.dim = daysInMonth(y, m);
    const d: number = WeekCalc.clampDay(y, m, this.initial.day);
    this.yy = y - this.firstYear;
    this.mm = m - 1;
    this.dd = d - 1;
  }

  /** 年月变化后重建日列，并把已选日夹进合法范围 */
  private clampDay(): void {
    const y: number = this.firstYear + this.yy;
    const m: number = this.mm + 1;
    const dim: number = daysInMonth(y, m);
    this.dim = dim;
    if (this.dd > dim - 1) {
      this.dd = dim - 1;
    }
  }

  /** 结果值 */
  private value(): YmdValue {
    return new YmdValue(this.firstYear + this.yy, this.mm + 1, this.dd + 1);
  }

  build() {
    Column({ space: Theme.GAP }) {
      Text('选择开学日期')
        .fontSize(Theme.FS_TITLE)
        .fontWeight(FontWeight.Bold)
        .fontColor($r('app.color.text_primary'))
        .width('100%')
        .textAlign(TextAlign.Center)

      Text('上下滑动选择，保存时会自动归到该周周一')
        .fontSize(Theme.FS_TINY)
        .fontColor($r('app.color.text_tertiary'))
        .width('100%')
        .textAlign(TextAlign.Center)

      // 列标题**独立成行**，不放进滚轮那一层。
      //
      // ===== 为什么必须独立（真机实测的错位根因）=====
      // 早先把「年/月/日」标放在每列内部（Column { 标题; TextPicker }），
      // 于是标题的高度把 TextPicker 整体下推了约 20vp，而高亮带是在
      // 滚轮区里**居中**画的 —— 结果选中行比高亮带中心低了小半行
      // （用户反馈「选中框没有上下居中对齐」），并且列高度超出滚轮区，
      // 底部两行还会溢出去被按钮压住。
      // 标题拿出来单独占一行后，滚轮区里只剩「高亮带 + 三个 TextPicker」，
      // 高度一致、天然同心，不再需要任何偏移补偿。
      Row() {
        Text('年')
          .fontSize(Theme.FS_TINY)
          .fontColor($r('app.color.text_tertiary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Text('月')
          .fontSize(Theme.FS_TINY)
          .fontColor($r('app.color.text_tertiary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Text('日')
          .fontSize(Theme.FS_TINY)
          .fontColor($r('app.color.text_tertiary'))
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
      }
      .width('100%')

      // 三列并排 + 一条横跨三列的选中高亮带。
      // 高亮带写在前面：Stack 里后写的节点在上层，因此三列会盖在带上，
      // 触摸事件也由三列接收，不会被这条装饰性的带子挡住。
      //
      // 三列在这里**内联展开**，没有抽成 @Builder：TextPicker 的 range
      // 只在创建时生效，之后改 range 不会重建选项（真机实测：1 月 31 日
      // 切到 2 月后，「日」列仍停在 31）。因此「日」列必须靠 `.key()`
      // 随当月天数变化来**强制销毁重建**，而 key 只有写在 build() 里、
      // 随 @State 一起重新求值才可靠。
      Stack() {
        Row() {
          Blank()
            .height(ITEM_H)
            .layoutWeight(1)
            .backgroundColor($r('app.color.brand_soft'))
            .borderRadius(10)
        }
        .width('100%')
        .height(WHEEL_H)
        .justifyContent(FlexAlign.Center)

        Row() {
          // ---- 年 ----
          TextPicker({ range: this.years(), selected: this.yy })
            .height(WHEEL_H)
            .layoutWeight(1)
            .selectedTextStyle({
              color: $r('app.color.brand'),
              font: { size: 17, weight: FontWeight.Bold }
            })
            .textStyle({ color: $r('app.color.text_secondary'), font: { size: 15 } })
            .divider({ strokeWidth: 0 })
            .onChange((value: string | string[], index: number | number[]) => {
              if (typeof index === 'number') {
                this.yy = index;
                this.clampDay();
              }
            })

          // ---- 月 ----
          TextPicker({ range: this.months(), selected: this.mm })
            .height(WHEEL_H)
            .layoutWeight(1)
            .selectedTextStyle({
              color: $r('app.color.brand'),
              font: { size: 17, weight: FontWeight.Bold }
            })
            .textStyle({ color: $r('app.color.text_secondary'), font: { size: 15 } })
            .divider({ strokeWidth: 0 })
            .onChange((value: string | string[], index: number | number[]) => {
              if (typeof index === 'number') {
                this.mm = index;
                this.clampDay();
              }
            })

          // ---- 日 ----
          // key 里带上当月天数：年月一变，dim 变、key 变，
          // ArkUI 会销毁旧的 TextPicker 并按新的 range/selected 重建。
          TextPicker({ range: this.days(), selected: this.dd })
            .key('day-' + this.dim.toString())
            .height(WHEEL_H)
            .layoutWeight(1)
            .selectedTextStyle({
              color: $r('app.color.brand'),
              font: { size: 17, weight: FontWeight.Bold }
            })
            .textStyle({ color: $r('app.color.text_secondary'), font: { size: 15 } })
            .divider({ strokeWidth: 0 })
            .onChange((value: string | string[], index: number | number[]) => {
              if (typeof index === 'number') {
                this.dd = index;
              }
            })
        }
        .width('100%')
      }
      .width('100%')
      .height(WHEEL_H)

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
            this.onPicked(this.value());
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
 * （用户反馈过「弹窗太宽」）。三列滚轮 + 两个按钮的固有宽度就这么多，
 * 320vp 在任何屏幕上都不会显得空。
 */
export function dateWheelPanelWidth(): number {
  return 320;
}

/** 面板高度 = 标题 + 说明 + 列标题行 + 滚轮 + 按钮行 + 间距 + 上下内边距 */
export function dateWheelPanelHeight(): number {
  const title: number = 30;
  const hint: number = 16;
  // 列标题（年/月/日）独立成行，必须计入高度 —— 漏掉它会让按钮压住滚轮底部
  const labelRow: number = 18;
  const wheel: number = WHEEL_H;
  const buttons: number = 44;
  // 5 个间距：标题↔说明、说明↔列标题、列标题↔滚轮、滚轮↔按钮、按钮↔底部
  const gaps: number = 12 * 4;
  return title + hint + labelRow + wheel + buttons + gaps + GlassKit.PANEL_PAD * 2;
}
