/*
 * CalendarSheet：校历（自绘月历 + 官方作息表）弹窗，设置页与课表页共用。
 *
 * ===== 数据来源与「随年份更新」怎么保证 =====
 * 主数据是教务系统的**教学周历**（/jsxsd/jxzl/jxzl_query）：
 * 一张「第 N 周 ←→ 周一日期」的对照表，学校每学期排课时录入，
 * **换学年后取到的是新数据**，不需要改代码、不需要随包图片。
 * 见 data/SemesterCalendarService。
 *
 * 界面由三部分组成：
 *   1. 自绘月历（SemesterMonthGrid）：每个教学日标出教学周次、非教学日留白，
 *      今天描边。承载的是「日期 + 周次 + 学期边界」，
 *      与官方校历图给的信息一致，但可随年份更新、可参与计算；
 *   2. 官方作息表：节次起止时刻（决定上课提醒），
 *      仍从学校官网抓、失败退内置（那部分是数字表格，不是图片，能直接解析）；
 *   3. 官方校历图：**只在联网抓到当期版本时**才显示，拿不到就不显示。
 *
 * ===== 为什么删掉了随包内置的校历图片 =====
 * 早先随包内置了 2026 学年的两张校历图（约 740KB）。它的失效方式很危险：
 * 换学年后内置图就是去年的，而界面上完全看不出，用户会照着过期日期安排行程。
 * 相比之下「取不到就不显示」是安全的降级。
 */
import { CampusCalendar, CampusCalendarService } from '../data/CampusCalendarService';
import { SemesterCalendarService, SemesterInfo } from '../data/SemesterCalendarService';
import { AcademicCalendar } from '../data/AcademicCalendar';
import { WeekService } from '../data/WeekService';
import { ChoiceItem } from '../model/Models';
import { Logger } from '../common/Logger';
import { Theme } from '../theme/Theme';
import { GlassKit, PanelMaterial } from '../theme/GlassKit';
import { GlassOverlay } from './GlassOverlay';
import { SemesterMonthGrid } from './SemesterMonthGrid';
import { SemesterPickerContent, SemesterOption, semesterPanelWidth,
  semesterPanelHeight } from './SemesterPickerDialog';

/** 一个月（用于渲染循环） */
class MonthRef {
  year: number;
  month: number;

  constructor(year: number, month: number) {
    this.year = year;
    this.month = month;
  }
}

@Component
export struct CalendarSheet {
  /**
   * 初始学期代码（如 2026-2027-1）。
   * 为空时由服务端返回的最新学期兜底。
   */
  initialSemester: string = '';
  /** 关闭回调（点「关闭」触发） */
  onClose: () => void = () => {};

  /** 当前查看的学期代码 */
  @State semester: string = '';
  /** 服务端给的「有周历的学期」列表；为空时只显示当前学期 */
  @State semesters: ChoiceItem[] = [];
  @State info: SemesterInfo | null = null;
  @State loading: boolean = true;
  @State refreshing: boolean = false;
  @State error: string = '';
  /** 作息表文本行；先给内置值，联网后替换 */
  @State officialLines: string[] = AcademicCalendar.sectionLines();
  /** 官网校历图路径（仅联网拿到时非空） */
  @State images: string[] = [];
  /** 校正开学日期后的结果提示 */
  @State fixHint: string = '';
  /** 学期选择浮层是否打开 */
  @State pickerOpen: boolean = false;

  aboutToAppear(): void {
    this.semester = this.initialSemester;
    this.init();
  }

  private async init(): Promise<void> {
    // 作息表先出（本地缓存/内置，不等网络）
    try {
      const local: CampusCalendar = await CampusCalendarService.load();
      this.officialLines = local.sections;
      this.images = local.images;
    } catch (e) {
      Logger.warn('campus calendar load failed');
    }

    // 学期列表：决定下拉里有哪些选项
    try {
      const sems: ChoiceItem[] = await SemesterCalendarService.semesters(false);
      this.semesters = sems;
      if (this.semester.length === 0 && sems.length > 0) {
        this.semester = sems[0].value;
      }
    } catch (e) {
      Logger.warn('semester list failed');
    }

    await this.loadSemester(this.semester, false);
    this.loading = false;

    // 打开时**不再**无条件重抓作息表与校历图：那两张原始图实测 2.74MB，
    // 学校一学期才换一次，每开一次弹窗就重下纯属浪费。
    if (await CampusCalendarService.isStale()) {
      this.refreshCampus(true);
    }
    // 系统时间已超出周历范围（放假了）→ 每天最多自动拉一次新学期周历
    this.autoFetchIfOutdated(this.semester);
  }

  private async autoFetchIfOutdated(code: string): Promise<void> {
    const got: SemesterInfo | null = await SemesterCalendarService.autoFetchIfOutdated(code);
    if (got === null) {
      return;
    }
    // 真拉到了新周历：换成它并提示一次（这种事一个假期只发生一两次）
    this.info = got;
    this.semester = got.code;
    this.fixHint = '已获取到新学期的教学周历（' + got.code + '）';
  }

  /**
   * 取某学期的教学周历。
   *
   * **只在 got 非空时才替换 info**：早先无条件赋值，于是点刷新遇到断网，
   * 界面会把已经显示着的校历整个擦掉 —— 用户手里唯一的离线副本就这么没了，
   * 而那次刷新失败本不该有任何破坏性。
   */
  private async loadSemester(code: string, force: boolean): Promise<void> {
    if (code.length === 0) {
      this.info = null;
      this.error = '';
      return;
    }
    this.error = '';
    const got: SemesterInfo | null = await SemesterCalendarService.load(code, force);
    if (got !== null) {
      this.info = got;
    }
    this.error = got === null
      ? (SemesterCalendarService.lastError.length === 0
        ? '该学期暂无教学周历' : SemesterCalendarService.lastError)
      : '';
  }

  /** @param silent 静默刷新失败时不显示错误（后台路径一律 silent） */
  private async refreshCampus(silent: boolean): Promise<void> {
    if (this.refreshing) {
      return;
    }
    this.refreshing = true;
    try {
      const got: CampusCalendar | null = await CampusCalendarService.refresh();
      if (got !== null) {
        this.officialLines = got.sections;
        this.images = got.images;
      } else if (!silent) {
        this.error = '未能获取最新校历，已显示上次的数据';
      }
    } finally {
      this.refreshing = false;
    }
  }

  /**
   * 用户点了刷新：**完整重取一遍**，一个都不省。
   *
   * 三样东西各自独立，缺任何一样都会让人以为「刷新了但没变」：
   *   1. 教学周历 —— 强制联网；
   *   2. 作息时刻表 —— refresh 本身就是无条件抓取；
   *   3. 校历原图 —— 同上（URL 未变时会跳过下载，那说明学校没换图）。
   * 学期列表也一起重取：它决定下拉里有哪些学期，学校新开学时全靠它。
   */
  private async refreshAll(): Promise<void> {
    const sems: ChoiceItem[] = await SemesterCalendarService.semesters(true);
    if (sems.length > 0) {
      this.semesters = sems;
    }
    await this.loadSemester(this.semester, true);
    await this.refreshCampus(false);
  }

  /**
   * 学期要覆盖的月份：从第 1 周周一所在月，到最后一周周日所在月。
   *
   * 上限 14 个月：一个学期最多跨 8 个月左右，14 足够且能防住脏数据
   * （比如服务端某行日期写成了 2099 年，会把这里变成死循环）。
   */
  private months(): MonthRef[] {
    const info: SemesterInfo | null = this.info;
    if (info === null || info.weeks.length === 0) {
      return [];
    }
    const first: Date | null = info.mondayOf(1);
    const lastMon: Date | null = info.mondayOf(info.totalWeeks);
    if (first === null || lastMon === null) {
      return [];
    }
    const end: Date = new Date(lastMon.getTime() + 6 * 24 * 3600 * 1000);
    const out: MonthRef[] = [];
    let y: number = first.getFullYear();
    let m: number = first.getMonth() + 1;
    const stopY: number = end.getFullYear();
    const stopM: number = end.getMonth() + 1;
    for (let i = 0; i < 14; i++) {
      out.push(new MonthRef(y, m));
      if (y === stopY && m === stopM) {
        break;
      }
      m++;
      if (m > 12) {
        m = 1;
        y++;
      }
    }
    return out;
  }

  /**
   * 开学日期与校历不一致时，给一条可一键校正的提示。
   *
   * 为什么需要：开学日期决定**全应用**的周次（课表标题、上课提醒、
   * 桌面卡片都按它算）。它是可以手动设的，一旦设错，界面上不会有任何
   * 报错 —— 只是所有周次集体偏移，而且看起来完全正常。
   * 校历里的第 1 周周一就是权威答案。
   *
   * 刻意**不自动覆盖**：手动设置是明确的用户意图（有人会故意把
   * 补考周算作第 1 周），静默改掉比不改更糟。
   */
  private async applyOfficialStart(): Promise<void> {
    const info: SemesterInfo | null = this.info;
    if (info === null || info.firstMonday.length === 0) {
      return;
    }
    try {
      // 四步缺一不可：写入并吸附周一 → 重算当前周 → 落盘与广播。
      // 只做第一步的话，周次显示会立刻对，但提醒与卡片仍按旧日期排定。
      await WeekService.setStartMonday(info.firstMonday);
      const w: number = await WeekService.align(true);
      this.fixHint = '已按校历把开学日期改为 ' + info.firstMonday + '，当前第 ' + w + ' 周';
    } catch (e) {
      this.fixHint = '保存失败：' + e;
    }
  }

  /** 开学日期是否需要校正（已设置且与校历不一致） */
  private startMismatch(): boolean {
    const info: SemesterInfo | null = this.info;
    if (info === null || info.firstMonday.length === 0) {
      return false;
    }
    const stored: string = WeekService.start();
    return stored.length > 0 && stored !== info.firstMonday;
  }

  /** 学期显示名 */
  private semesterLabel(code: string): string {
    for (let i = 0; i < this.semesters.length; i++) {
      if (this.semesters[i].value === code) {
        return this.semesters[i].label;
      }
    }
    return code.length === 0 ? '选择学期' : code;
  }

  build() {
    // 根是 Stack 而不是 Column：学期选择浮层要**盖在**面板内容之上。
    // 早先浮层是 Column 的最后一个子节点，而它高度 100% —— Column 顺序排布时
    // 它会被推到面板之外（被 GlassOverlay 的 clip 裁掉），等于打不开。
    Stack() {
      Column({ space: Theme.GAP }) {
        Column({ space: 2 }) {
          Text('校历')
            .fontSize(Theme.FS_TITLE)
            .fontWeight(FontWeight.Bold)
            .fontColor($r('app.color.text_primary'))
          Text(this.subtitle())
            .fontSize(Theme.FS_TINY)
            .fontColor($r('app.color.text_tertiary'))
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        // 学期选择 + 刷新
        //
        // ===== 这两个键为什么是液态玻璃，而面板本身是系统材质 =====
        // 用户的要求：校历**面板**用系统默认材质（月历网格太密，磨砂玻璃上
        // 是糊的，见 PanelMaterial 的说明），但这两个键要液态玻璃。
        // 键的尺寸很小、背后是面板的一块纯色，透镜无内容可截 —— 因此用
        // fieldEffect 磨砂 + 一条高光细边（FIELD_EDGE）：模糊出的是面板底色，
        // 但那道接光的白边加上提饱和的底色，在两种主题下都能看出玻璃感。
        Row({ space: Theme.GAP_S }) {
          Row() {
            Text(this.semesterLabel(this.semester))
              .fontSize(Theme.FS_SMALL)
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text('▾')
              .fontSize(Theme.FS_TINY)
              .fontColor($r('app.color.text_tertiary'))
          }
          .layoutWeight(1)
          .height(36)
          .padding({ left: 12, right: 12 })
          .borderRadius(18)
          .backgroundColor($r('app.color.surface_variant'))
          .backgroundEffect(GlassKit.fieldEffect())
          .border({ width: 0.5, color: GlassKit.FIELD_EDGE })
          .onClick(() => {
            if (this.semesters.length > 0) {
              this.pickerOpen = true;
            }
          })

          Text(this.refreshing ? '获取中…' : '刷新')
            .fontSize(Theme.FS_SMALL)
            .fontColor(this.refreshing
              ? $r('app.color.text_tertiary') : $r('app.color.brand'))
            .padding({ left: 12, right: 12 })
            .height(36)
            .borderRadius(18)
            .backgroundColor($r('app.color.brand_soft'))
            .backgroundEffect(GlassKit.fieldEffect())
            .border({ width: 0.5, color: GlassKit.FIELD_EDGE })
            .onClick(() => {
              if (!this.refreshing) {
                this.refreshAll();
              }
            })
        }
        .width('100%')

        // 开学日期不一致的校正提示
        if (this.startMismatch()) {
          Column({ space: 6 }) {
            Text('开学日期与校历不一致')
              .fontSize(Theme.FS_SMALL)
              .fontWeight(FontWeight.Medium)
              .fontColor($r('app.color.text_primary'))
            Text('当前设为 ' + WeekService.start() + '，校历显示第 1 周应为 ' +
              (this.info === null ? '' : this.info.firstMonday) +
              '。周次、上课提醒、桌面卡片都按这个日期计算，设错会让它们整体偏移。')
              .fontSize(Theme.FS_TINY)
              .fontColor($r('app.color.text_secondary'))
            Text('按校历校正为 ' + (this.info === null ? '' : this.info.firstMonday))
              .fontSize(Theme.FS_TINY)
              .fontColor($r('app.color.on_brand'))
              .padding({ left: 14, right: 14, top: 7, bottom: 7 })
              .borderRadius(Theme.RADIUS_SM)
              .backgroundColor($r('app.color.brand'))
              .onClick(() => {
                this.applyOfficialStart();
              })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding(Theme.GAP)
          .borderRadius(Theme.RADIUS_SM)
          .backgroundColor($r('app.color.warning'))
          .opacity(0.92)
        }

        if (this.fixHint.length > 0) {
          Text(this.fixHint)
            .fontSize(Theme.FS_TINY)
            .fontColor($r('app.color.brand'))
            .width('100%')
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .borderRadius(Theme.RADIUS_SM)
            .backgroundColor($r('app.color.brand_soft'))
        }

        Scroll() {
          Column({ space: Theme.GAP }) {
            if (this.loading) {
              Text('正在读取校历…')
                .fontSize(Theme.FS_SMALL)
                .fontColor($r('app.color.text_tertiary'))
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ top: 40, bottom: 40 })
            } else {
              // 自绘月历：每个教学日标周次。
              //
              // key 里带上**学期代码**：SemesterMonthGrid 的内部对照表在
              // aboutToAppear 里算一次，而 @Prop 变化不会重跑它 ——
              // 换学期时若不换 key，月历会沿用上一学期的周次
              // （表现为「切到第二学期但日期上的周次还是第一学期的」）。
              if (this.info !== null && this.info.weeks.length > 0) {
                ForEach(this.months(), (m: MonthRef) => {
                  SemesterMonthGrid({
                    year: m.year,
                    month: m.month,
                    info: this.info
                  })
                    .margin({ bottom: 12 })
                }, (m: MonthRef) => 'm' + this.semester + '-' + m.year.toString() + '-' +
                  m.month.toString())
              } else {
                Text('暂无该学期的教学周历')
                  .fontSize(Theme.FS_SMALL)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding({ top: 28, bottom: 28 })
                  .borderRadius(Theme.RADIUS_SM)
                  .backgroundColor($r('app.color.surface_variant'))
              }

              // 官方作息表（决定上课提醒的时刻）
              Column({ space: 4 }) {
                Text('日常教学时刻表')
                  .fontSize(Theme.FS_SMALL)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .width('100%')
                ForEach(this.officialLines, (line: string, idx: number) => {
                  Text(line)
                    .fontSize(Theme.FS_SMALL)
                    .fontColor(line.indexOf('课间') >= 0
                      ? $r('app.color.text_tertiary') : $r('app.color.text_secondary'))
                    .width('100%')
                }, (line: string, idx: number) => 'cl-' + idx.toString())
                Text('此处为学校官方的作息时刻；「设置 → 节次作息」可本地微调，上课提醒按该值计算。')
                  .fontSize(10)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
                  .margin({ top: 4 })
              }
              .width('100%')
              .alignItems(HorizontalAlign.Start)
              .padding(Theme.GAP)
              .backgroundColor($r('app.color.sched_bg'))
              .borderRadius(Theme.RADIUS_SM)

              // 官方校历原图：**只在联网拿到当期版本时**才显示。
              // 拿不到就不显示 —— 一张可能过期的校历比一块空缺更危险。
              if (this.images.length > 0) {
                Text('学校官方校历图')
                  .fontSize(Theme.FS_SMALL)
                  .fontWeight(FontWeight.Medium)
                  .fontColor($r('app.color.text_primary'))
                  .width('100%')
                Text('来源：学校官网「校园服务 · 最新校历」，上面的月历由教务系统教学周历生成。')
                  .fontSize(10)
                  .fontColor($r('app.color.text_tertiary'))
                  .width('100%')
                ForEach(this.images, (p: string, idx: number) => {
                  Image('file://' + p)
                    .width('100%')
                    .objectFit(ImageFit.Contain)
                    .borderRadius(Theme.RADIUS_SM)
                }, (p: string, idx: number) => 'img-' + idx.toString())
              }

              if (this.error.length > 0) {
                Text(this.error)
                  .fontSize(Theme.FS_TINY)
                  .fontColor($r('app.color.warning'))
                  .width('100%')
              }
            }
          }
          .width('100%')
        }
        .layoutWeight(1)
        .align(Alignment.TopStart)

        Button('关闭')
          .width('100%')
          .height(46)
          .fontSize(Theme.FS_BODY)
          .backgroundColor($r('app.color.surface_variant'))
          .fontColor($r('app.color.text_primary'))
          .onClick(() => {
            this.onClose();
          })
      }
      .width('100%')
      .height('100%')
      .padding(GlassKit.PANEL_PAD)

      // 学期选择浮层：盖在本面板之上，点空白处即消失。
      //
      // 材质用系统默认（与校历面板一致）：这层背后是校历的纯色面板，
      // 透镜无内容可截，只会得到一块死板深色。avoidDock 置 false ——
      // 本层所在区域已经在 dock 之上，再扣一次会让滚轮无谓地上移、压扁。
      if (this.pickerOpen) {
        GlassOverlay({
          material: PanelMaterial.SYSTEM,
          avoidDock: false,
          panelWidthVp: semesterPanelWidth(),
          panelHeightVp: semesterPanelHeight(),
          onDismiss: () => {
            this.pickerOpen = false;
          }
        }) {
          SemesterPickerContent({
            options: this.pickerOptions(),
            current: this.semester,
            onPicked: (v: string) => {
              this.pickerOpen = false;
              if (v !== this.semester) {
                this.semester = v;
                this.loading = true;
                this.loadSemester(v, false).then(() => {
                  this.loading = false;
                });
              }
            },
            onCancel: () => {
              this.pickerOpen = false;
            }
          })
        }
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 学期滚轮的选项。校历没有「全部学期」，逐项就是服务端给的学期列表。 */
  private pickerOptions(): SemesterOption[] {
    const out: SemesterOption[] = [];
    for (let i = 0; i < this.semesters.length; i++) {
      const s: ChoiceItem = this.semesters[i];
      out.push(new SemesterOption(s.label.length > 0 ? s.label : s.value, s.value));
    }
    return out;
  }

  private subtitle(): string {
    const info: SemesterInfo | null = this.info;
    if (info === null || info.weeks.length === 0) {
      return '教学周历';
    }
    return '共 ' + info.totalWeeks.toString() + ' 周 · 第 1 周 ' + info.firstMonday +
      ' 起 · 至 ' + info.lastDay;
  }
}
