/*
 * 自绘月历：把「周次表」画成日历的样子。
 *
 * ===== 为什么要有它 =====
 * 学校官网的校历是**图片**，一年一换。App 里内置图片有两个死结：
 *   1. 换学年后内置图就过期了，而界面上完全看不出来 —— 用户会照着
 *      去年的日期安排行程，这比「没有校历」更糟；
 *   2. 图片里的信息（第几周、哪天开学、假期边界）没法参与计算。
 *
 * 教务系统的「教学周历」给的是结构化的「第 N 周 ←→ 周一日期」，
 * 每学期由学校录入，因此换学年会自动更新。本组件把它渲染成月历网格：
 * **每个教学日标出教学周次**，非教学日留白。这样用户既能看到「这周是第几周」，
 * 也能一眼看出学期边界 —— 与官方校历图所承载的信息一致，
 * 而且是可随年份更新的数据，不依赖任何随包图片。
 *
 * 与 Flutter 端 widgets/semester_month_grid.dart 视觉与规则一致。
 */
import { SemesterInfo } from '../data/SemesterCalendarService';
import { WeekCalendarParser } from '../parser/WeekCalendarParser';

@Component
export struct SemesterMonthGrid {
  @Prop year: number;
  @Prop month: number;
  /** 学期信息（由父组件传入） */
  @Prop info: SemesterInfo | null = null;

  /** 星期表头：周一起（中国习惯） */
  private static readonly WEEKDAYS: string[] = ['一', '二', '三', '四', '五', '六', '日'];

  /**
   * 「日期 → 教学周」对照表。
   *
   * 在 [refreshIndex] 里算，**不能在 build() 里赋值**：ArkTS 的 build 只允许
   * UI 描述，写赋值语句会报 `Unexpected token`（实测踩到）。
   */
  private byDay: Map<string, number> = new Map<string, number>();

  aboutToAppear(): void {
    this.refreshIndex();
  }

  /**
   * 重算对照表。
   *
   * @Prop info 变化时不会自动触发（@Prop 只保证值同步，不会重跑字段初始化），
   * 所以父组件切学期时若显示不对，需要在父侧重建本组件（见 CalendarSheet
   * 用 ForEach 的 key 带上学期代码）。
   */
  private refreshIndex(): void {
    this.byDay = this.info === null
      ? new Map<string, number>() : this.info.weekIndexByDay();
  }

  /** 本月第一天是周几（0=周一）。JS 的 getDay() 里周日是 0，换算成「周一为 0」 */
  private leadingDays(): number {
    const first: Date = new Date(this.year, this.month - 1, 1);
    return (first.getDay() + 6) % 7;
  }

  /** 本月天数 */
  private daysInMonth(): number {
    return new Date(this.year, this.month, 0).getDate();
  }

  /**
   * 需要几行。
   * 按需算而不是固定 6 行：很多月份只需要 5 行，
   * 固定 6 行会多出一条空白行，视觉上像是数据缺失。
   */
  private rowCount(): number {
    return Math.ceil((this.leadingDays() + this.daysInMonth()) / 7);
  }

  /** 第 row 行第 col 列对应的日号；不在本月返回 0 */
  private dayAt(row: number, col: number): number {
    const n: number = row * 7 + col - this.leadingDays() + 1;
    const dim: number = this.daysInMonth();
    return (n < 1 || n > dim) ? 0 : n;
  }

  /** 该日属于第几教学周；非教学日返回 0 */
  private weekOfDay(day: number): number {
    if (day <= 0) {
      return 0;
    }
    const d: Date = new Date(this.year, this.month - 1, day);
    const hit: number | undefined = this.byDay.get(WeekCalendarParser.formatYmd(d));
    return hit === undefined ? 0 : hit;
  }

  private isToday(day: number): boolean {
    const now: Date = new Date();
    return now.getFullYear() === this.year && now.getMonth() + 1 === this.month &&
      now.getDate() === day;
  }

  build() {
    Column() {
      Text(this.year.toString() + ' 年 ' + this.month.toString() + ' 月')
        .fontSize(13)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_primary'))
        .margin({ bottom: 4 })
        .width('100%')

      // 星期表头
      Row() {
        ForEach(SemesterMonthGrid.WEEKDAYS, (w: string) => {
          Text(w)
            .fontSize(10)
            .fontColor($r('app.color.text_tertiary'))
            .textAlign(TextAlign.Center)
            .layoutWeight(1)
        }, (w: string) => 'wd' + w)
      }
      .width('100%')

      ForEach(Array.from({ length: this.rowCount() }, (_v: number, i: number) => i),
        (row: number) => {
          Row() {
            ForEach(Array.from({ length: 7 }, (_v: number, i: number) => i),
              (col: number) => {
                this.dayCell(this.dayAt(row, col))
              }, (col: number) => 'c' + row.toString() + '_' + col.toString())
          }
          .width('100%')
        }, (row: number) => 'r' + row.toString())
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /**
   * 一个日期格。
   *
   * 教学日：品牌淡色底 + 加粗日期 + 下方「N周」；非教学日：透明底 + 灰字。
   * 今天描边（在容器层，这样非教学日的今天也能标出来）。
   *
   * 注意：@Builder 的根节点必须是**唯一的容器组件**，不能是 if/else
   * （ArkTS 编译期报「the 'build' method can have only one root node」）。
   * 所以这里用「日号为 0 时两个 Text 都不画」的方式处理空格，
   * 而不是在外面套 if/else。
   */
  @Builder
  dayCell(day: number) {
    Column() {
      Text(day > 0 ? day.toString() : '')
        .fontSize(12)
        .fontWeight(this.weekOfDay(day) > 0 ? FontWeight.Medium : FontWeight.Normal)
        // 非教学日弱化：它们是假期或尚未开学，与教学日不是一回事
        .fontColor(this.weekOfDay(day) > 0
          ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
      Text(this.weekOfDay(day) > 0 ? this.weekOfDay(day).toString() + '周' : '')
        .fontSize(8)
        .fontColor($r('app.color.brand'))
    }
    .layoutWeight(1)
    .height(40)
    .padding(1)
    .borderRadius(6)
    .backgroundColor(day > 0 && this.weekOfDay(day) > 0
      ? $r('app.color.brand_soft') : Color.Transparent)
    .border(day > 0 && this.isToday(day)
      ? { width: 1.5, color: $r('app.color.brand') }
      : { width: 0 })
  }
}
