/*
 * 课表页
 *
 * 视觉参照常见的课程表 App：
 *   - 顶部：周次/学期选择、当前周与日期
 *   - 表头：星期 + 该周的日期，今天高亮
 *   - 主体：左侧节次时间段，右侧 7 天；课程以彩色卡片呈现，卡片显示
 *     课程名 / 教室 / 周次
 *   - 一屏尽量显示全部信息：列宽自适应，卡片高度按内容估算
 *
 * 交互：
 *   - 点击课程卡片 → 编辑该课程（可改、可删）
 *   - 点击空白格 → 添加课程
 *   - 修改结果持久化到本地，并在再次选择同一「账号 + 学期」时直接使用本地数据，
 *     不再请求服务器
 */
import { promptAction } from '@kit.ArkUI';
import { GlassKit } from '../theme/GlassKit';
import { Timetable, CellData, CourseEntry } from '../model/Models';
import { AppState } from '../data/AppState';
import { PrefStore } from '../data/PrefStore';
import { TimetableStore } from '../data/TimetableStore';
import { WeekService, AS_CURRENT_WEEK, AS_WEEK_CONFIGURED } from '../data/WeekService';
import { AppError } from '../common/Result';
import { ReAuthService } from '../data/ReAuthService';
import { Logger } from '../common/Logger';
import { TextMeasure, TextMetrics } from '../common/TextMeasure';
import { Theme } from '../theme/Theme';
import { SECTIONS, WEEKDAY_LABELS, SectionDef, MAX_WEEKS, KEY_LAST_WEEK, AS_WINDOW_WIDTH } from '../common/Constants';
import { WeekCalendarParser } from '../parser/WeekCalendarParser';
import { LoadingView, EmptyView, ErrorView } from '../components/StateViews';
import { CourseEditor, EditorResult } from '../components/CourseEditor';
import { CardSnapshotStore } from '../data/CardSnapshotStore';
import { Bp } from '../common/WindowService';
import { WeekPickerContent, WEEK_AUTO, weekPickerPanelWidth, weekPickerPanelHeight } from '../components/WeekPickerDialog';
import { AppIcon } from '../components/AppIcon';
import { CalendarSheet } from '../components/CalendarSheet';
import { GlassOverlay } from '../components/GlassOverlay';
import { PanelMaterial } from '../theme/GlassKit';
import { SemesterPickerContent, SemesterOption, semesterPanelWidth,
  semesterPanelHeight } from '../components/SemesterPickerDialog';

/** 课程卡片配色（按课程名散列取色，同一课程颜色稳定） */
const CARD_COLORS: string[][] = [
  ['#F8D7DC', '#8C1D2F'], // 粉
  ['#D7E3F8', '#1D3F7A'], // 蓝
  ['#D3EDE6', '#0F5A49'], // 青
  ['#FBE7CE', '#7A4A0B'], // 橙
  ['#E2DCF7', '#4A2F86'], // 紫
  ['#D9EDD7', '#2C5A28'], // 绿
  ['#F7DCEA', '#7A1F52'], // 玫红
  ['#D6EFF7', '#0E4C63']  // 天蓝
];

@Component
export struct SchedulePage {
  @StorageProp('breakpoint') bp: number = Bp.SM;
  /**
   * 真实窗口宽度（vp）。
   *
   * 为什么必须读它而不是按断点猜：原先 `fitsOneScreen()` 用的是
   * 「SM=360 / MD=700 / LG=1000」三个**假定值**。断点只告诉我们是哪一档，
   * 同一档内设备宽度差很多 —— 平板在 LG 档可能只有 860vp、也可能 1280vp，
   * 按 1000 假定去算列宽，实际更窄时就会「以为放得下、其实放不下」，
   * 于是文字被挤到溢出（用户实测到的平板课表文字溢出就是这个原因）。
   * 现在一律用 WindowService 实测并写入的 windowWidth。
   */
  @StorageProp(AS_WINDOW_WIDTH) @Watch('onWidthChanged') windowWidth: number = 360;
  /**
   * 打开空教室页。
   *
   * 顶栏的空教室入口是 Flutter 端的既定设计（看课表时最常接着问的就是
   * 「哪儿有空教室」），而页面本身不知道导航结构 —— 由外壳 Index 传入，
   * 与 ProfilePage 接收 onOpenSettings 是同一做法。
   */
  onOpenClassroom: () => void = () => {};
  /** 当前教学周：由 WeekService 按系统时间推算，每 6 小时对齐一次 */
  @StorageProp(AS_CURRENT_WEEK) currentWeekNo: number = 0;
  /** 是否已在设置里配置学期开始日期 */
  @StorageProp(AS_WEEK_CONFIGURED) weekConfigured: boolean = false;
  @State loading: boolean = true;
  @State errorText: string = '';
  @State timetable: Timetable = new Timetable();
  @State semester: string = '';
  @State week: string = '';
  /** 正在编辑的格子 */
  @State editorOpen: boolean = false;
  @State editorRow: number = 0;
  @State editorCol: number = 0;
  @State editorEntries: CourseEntry[] = [];
  /** 本地缓存命中提示 */
  @State fromCache: boolean = false;
  /** 表格横向滚动控制器，用于进入时滚到「今天」所在列 */
  private colScroller: Scroller = new Scroller();
  /** 是否已完成首次自动定位（避免每次重进都覆盖用户手动选择） */
  private autoLocated: boolean = false;
  /** 周次选择浮层是否打开 */
  @State weekPickerOpen: boolean = false;
  /** 学期选择浮层是否打开（表盘滚轮，点空白处消失） */
  @State semesterPickerOpen: boolean = false;
  /** 校历弹窗 */
  @State calendarOpen: boolean = false;
  // 校历弹窗的学期由 CalendarSheet 自己按 semester 代码处理
  // （它内部走教学周历 + 学期下拉），页面不再需要预推断学期号。

  /**
   * 卡片行数预算缓存。
   *
   * 一张卡片在渲染时会被问多次（课名/教室/教师各自的 maxLines 各一次），
   * 而同一格高度下结论不变 —— 缓存掉避免重复测量。
   * 键含格高，所以旋转/分屏改变尺寸后自然失效。
   */
  private budgetCache: Map<string, CardBudget> = new Map<string, CardBudget>();
  /**
   * 当前正在渲染的格子里的课程列表。
   *
   * ArkTS 的 @Builder 参数是值传递，卡片拿不到「我这格有几门课」这个上下文，
   * 只能由 [cell] 在渲染前挂到实例字段上（渲染顺序保证 cell 先于其内的 card）。
   * 用途：同格多门课时每张卡分到的高度是「格高 ÷ 课数」。
   */
  private budgetScope: CourseEntry[] = [];

  private static readonly WEEK_COUNT: number = 7;
  private static readonly SECTION_COUNT: number = 5;
  /** 窄屏节次列宽 */
  /**
   * 窄屏节次列宽度（vp）。
   *
   * 从 46 收到 34：手机上扣掉它之后的 7 列宽度才够用（360vp 屏上
   * 46 时每列仅 45vp，34 时能到 46.6vp）。节次列只放「一~二 / 08:30」
   * 这类短文本，34vp 足够；而多让出的每一 vp 都直接变成课程名的可读宽度。
   */
  private static readonly NARROW_LABEL_W: number = 34;
  /** 一屏显示 7 天时的最小列宽（低于此值则横向滚动） */
  private static readonly MIN_COL_W: number = 86;
  /**
   * 课名与教室之间额外拉开的间距（vp）。
   *
   * 用户反馈两者「不要挨在一起」：课名是深色粗体、教室是同色 9vp 细字，
   * 贴在一起会连成一片。取 5vp —— 比行距（约 12vp）小、比默认的 1vp 明显，
   * 拉开层级又不至于让卡片显得松散。
   *
   * 这段间距**计入高度预算**（见 [cardBudget] 的 roomGap）：
   * 它是从课名那侧扣的，所以「教室完整显示」这条要求不受影响。
   */
  private static readonly ROOM_GAP: number = 5;

  /**
   * 窗口宽度变化（旋转 / 折叠屏展开 / 分屏拖拽）时清掉行数预算缓存。
   *
   * 必须清：行数是「这段文字在这个宽度下占几行」的结论，
   * 宽度一变全部失效 —— 不清的话会沿用旧宽度的行数，
   * 表现为「转屏后课名被提前截断」或「教室明明放得下却折行」。
   * TextMeasure 内部也有缓存，一并清掉。
   */
  onWidthChanged(): void {
    this.budgetCache.clear();
    TextMeasure.invalidate();
  }

  aboutToAppear(): void {
    // 绑定文本测量并做单位标定。必须在组件生命周期内做 ——
    // MeasureUtils 要从 UIContext 取，而 UIContext 只在组件里可用。
    // 标定失败不影响渲染：TextMeasure 内部会退回估算（见该文件说明）。
    TextMeasure.init(this.getUIContext().getMeasureUtils());
    this.budgetCache.clear();

    this.loadAuto();
    // 校历/作息表的加载已随弹窗迁进 CalendarSheet 组件（它自己按需联网），
    // 页面这里不再需要预热 —— 那些数据只在弹窗打开时才用得到。
  }

  /**
   * 进入课表时的定位策略：
   *   1. 先与系统时间对齐周次（超过 6 小时才真正重算）；
   *   2. 若已配置开学日期且能算出当前周，就自动定位到当前周；
   *      —— 这是主路径，保证跨周后进来看到的就是本周；
   *   3. 但若用户上次显式选的就是当前周（说明他在正常使用），沿用该选择；
   *   4. 否则（未配置开学日期）沿用上次选择，或退化为「全部」并提示去设置。
   */
  private async loadAuto(): Promise<void> {
    await WeekService.align(false);

    const cw: number = this.currentWeekNo;
    const savedWeek: string = await PrefStore.getText(KEY_LAST_WEEK);

    if (this.weekConfigured && cw > 0) {
      // 上次是「具体周次」且不是本周时才重新定位 —— 那多半是几周前看的，
      // 现在应该跟回本周。
      // 注意**不要**把「全部」（空串）也覆盖掉：那是用户的显式选择
      // （「我要看所有周的课」），覆盖它等于无视用户意图。
      const saved: number = savedWeek.length === 0 ? 0 : parseInt(savedWeek, 10);
      if (!isNaN(saved) && saved > 0 && saved !== cw) {
        this.autoLocated = true;
        this.week = cw.toString();
        await this.load(this.week);
        this.scrollToToday();
        return;
      }
    }

    if (savedWeek.length > 0) {
      // 用户显式选过（含「全部」的空串不在此列，见下）
      this.week = savedWeek;
      await this.load(savedWeek);
      return;
    }

    // 从未选过 → **默认跟随本周**（用户要求）。
    // 用 WEEK_AUTO 而不是写成具体周次：具体周次会「冻」在当时的周，
    // 过几周再看还停在那一周；标记为自动则每次都按当前周显示。
    this.week = WEEK_AUTO;
    await this.load(WEEK_AUTO);
  }

  /** 把横向滚动定位到「今天」所在列（仅在需要横向滚动时有效） */
  private scrollToToday(): void {
    if (this.fitsOneScreen()) {
      return;
    }
    const col: number = this.todayCol();
    // 让今天那一列尽量靠左但保留前一列做参照
    const target: number = Math.max(0, (col - 1) * SchedulePage.MIN_COL_W);
    setTimeout(() => {
      try {
        this.colScroller.scrollTo({ xOffset: target, yOffset: 0, animation: { duration: 260 } });
      } catch (e) {
        Logger.warn('scrollToToday failed');
      }
    }, 120);
  }

  private isNarrow(): boolean {
    return this.bp === Bp.SM;
  }

  /**
   * 可在当前宽度内并排显示 7 天时不滚动。
   *
   * 用**实测宽度**（windowWidth）而不是按断点猜的定值：
   * 见 windowWidth 字段的说明（平板文字溢出的根因）。
   */
  /**
   * 是否一屏显示整周（7 列不分栏滚动）。
   *
   * ===== 为什么改成恒真（手机端「一屏装下一周课表」的根修）=====
   * 早先的判据是「等分列宽 ≥ 86vp 才一屏显示，否则横向滚动」。在手机上
   * 这是必然失败的：360vp 的机器扣掉 46vp 节次列只剩 314vp，7 列每列
   * 只有 45vp —— 远低于 86，于是**必然**走横向滚动，用户永远要左右拖
   * 才能看全一周。
   *
   * 现在改为**始终一屏 7 列**，把「信息密度」交给分级降级来做：
   * 列宽窄了就缩小字号、减少每张卡片显示的行数（见 [cardScale] /
   * [cardRowLimit]），而不是把整周推出屏幕。
   * 课表的核心价值是「一眼看到整周的分布」，为这点牺牲一点细节是值得的。
   */
  private fitsOneScreen(): boolean {
    return true;
  }

  /**
   * 课程卡片的显示档位（按真实列宽分级）。
   *
   * 返回 0/1/2 三档，越小越精简：
   *   0 —— 列宽 ≥ 78vp：全量（课程名 + 教师 + 教室 + 单双周）
   *   1 —— 列宽 ≥ 60vp：中档（课程名 + 教室）
   *   2 —— 更窄：紧凑（课程名 + 教室，字号更小）
   *
   * ===== 档位现在只管「显示哪些字段」，不再管「各显示几行」=====
   * 早先 [cardRowLimit] 按档位写死 4/3/2 行，于是「格子有多高」与
   * 「能显示几行」完全脱钩：平板上格子 127vp、内容只占 59vp，
   * 富余 68vp 变成卡片底部空白，课名却仍被 4 行封顶截断（用户反馈的问题）。
   *
   * 现在行数由 [cardBudget] 按**格子实际可用高度**算 —— 高度够就多排，
   * 不够才降级。档位只决定「先保谁」的优先级：
   *   所有档位：教室完整显示 > 课名尽量完整
   */
  private cardScale(): number {
    const col: number = this.realColWidth();
    if (col >= 78) {
      return 0;
    }
    if (col >= 60) {
      return 1;
    }
    return 2;
  }

  /** 卡片字号：课名 */
  private nameFontSize(): number {
    return this.cardScale() === 2 ? 10 : Theme.FS_SMALL;
  }

  /** 卡片字号：教室（比课名小一档，避免抢视觉） */
  private placeFontSize(): number {
    return 9;
  }

  /**
   * 卡片的内容预算：在给定高度里，课名与教室各能占几行。
   *
   * ===== 分配顺序（用户明确要求）=====
   *   1. **教室完整显示**优先 —— 「这节课在哪上」除了课名之外最要紧，
   *      宁可少显示课名行数也不能把地点截掉；
   *   2. 剩下的高度全给课名（想要「尽可能完整」）；
   *   3. 教师与单双周只在宽列且**还有余量**时才占行。
   *
   * 与旧实现的关键区别：行数来自「这块高度实际能放几行」，
   * 而不是按列宽档位写死的 4/3/2。格子高就多排，矮才降级。
   */
  private cardBudget(e: CourseEntry, availHeightVp: number): CardBudget {
    const scale: number = this.cardScale();
    const pad: number = scale === 2 ? 4 : 5;
    // 卡片自身有 padding，文字实际能用的宽度/高度都要扣掉它 ——
    // 早先只扣了宽度、没扣高度，于是「算出来放得下、渲染时溢出」。
    const usable: number = this.realColWidth() - pad * 2;
    const innerH: number = availHeightVp - pad * 2;
    const nameFs: number = this.nameFontSize();
    const placeFs: number = this.placeFontSize();

    // 1) 教室：按真实测量拿到「完整显示需要几行」，不封顶
    const place: string = this.placeText(e);
    let placeLines: number = 0;
    let placeLineH: number = 0;
    if (place.length > 0) {
      const m: TextMetrics = this.measureText(place, placeFs, usable);
      placeLines = m.lines;
      placeLineH = m.lineHeight;
    }

    // 2) 先扣掉教室、它与课名之间的间距，余下的留给课名。
    //
    // roomGap 用 SchedulePage.ROOM_GAP（课名与教室拉开的那段），
    // **必须在这里扣**：渲染时给教室加了 margin-top，若预算不算它，
    // 就会出现「算出来放得下、渲染时教室被挤出卡片」—— 而用户的硬要求
    // 正是教室完整显示。间距从课名那侧扣，不动教室的行数。
    const roomGap: number = placeLines > 0 ? SchedulePage.ROOM_GAP : 0;
    let left: number = innerH - placeLines * placeLineH - roomGap;

    // 3) 课名：按测量拿行数，再按剩余高度截
    const nameM: TextMetrics = this.measureText(e.courseName, nameFs, usable);
    const nameLineH: number = nameM.lineHeight;
    let nameLines: number = 0;
    if (left > 0 && nameLineH > 0) {
      nameLines = Math.floor(left / nameLineH);
    }
    // ===== 临界情况留一行余量 =====
    // 测量给的是「按测量宽度换行需要几行」，而真实排版在临界点上
    // 可能多要一行（实测：`习近平新时代中国特色社会主义思想概论` 17 字，
    // 每行 5~6 字 → 3.09 行，测量给 3、渲染需要 4，于是第三行末尾出现省略号，
    // 而卡片下方还有空白）。用户的要求正是「有空白就别截断」，
    // 所以只要高度还放得下一行，就多给一行。放不下才不勉强。
    if (nameLines >= nameM.lines && left >= nameLineH * (nameLines + 1)) {
      nameLines += 1;
    }
    // 至少给课名一行：整格只排得下一行时也不能什么都没有
    if (nameLines < 1 && nameM.lines > 0) {
      nameLines = 1;
    }
    if (nameLines > nameM.lines + 1) {
      nameLines = nameM.lines + 1;
    }
    left -= nameLines * nameLineH;

    // 4) 还有余量时才排教师/单双周（只宽列）
    //
    // 顺序刻意放在课名**之后**：用户的优先级是「教室完整 > 课名尽量完整」，
    // 教师与单双周都排在它们后面。早先教师行夹在课名与教室之间、
    // 且先于课名分配高度，结果「有空白但课名仍截断」——
    // 高度被教师行吃掉了，而那行信息对「这节课在哪、上什么」并不关键。
    let teacherLines: number = 0;
    let parityLines: number = 0;
    if (scale === 0) {
      if (e.teacher.length > 0) {
        const t: TextMetrics = this.measureText(e.teacher, 9, usable);
        if (left >= t.lineHeight) {
          teacherLines = 1;
          left -= t.lineHeight;
        }
      }
      if (e.parity !== 0 && left >= 11) {
        parityLines = 1;
      }
    }

    return new CardBudget(nameLines, teacherLines, placeLines, parityLines);
  }

  /** 教室文本（含校区），与卡片渲染保持一致 */
  private placeText(e: CourseEntry): string {
    if (e.room.length === 0 && e.campus.length === 0) {
      return '';
    }
    return '@' + e.room + (e.campus.length > 0 ? '(' + e.campus + ')' : '');
  }

  /**
   * 测量入口：可用时走真实测量，不可用时退回估算。
   *
   * 包一层是为了让「测量不可用」这件事不影响课表渲染 ——
   * 标定失败（极少数机型）时降级为估算，界面照常。
   */
  private measureText(text: string, fontSizeVp: number, usableWidthVp: number): TextMetrics {
    return TextMeasure.measure(text, fontSizeVp, usableWidthVp);
  }

  /**
   * 卡片在「不限高」时想要的高度（vp）。
   *
   * 用于算行高：先问每张卡「完整显示要多少」，取该节次里最高的一格作为行高；
   * 行高定了之后再回过头按实际高度重新分配行数（见 [cardBudget]）。
   * 这样既不会像旧实现那样把行高封顶（导致富余空白），
   * 也不会让卡片无限长高（那会把整周挤出一屏）。
   */
  private naturalCardHeight(e: CourseEntry, maxHeightVp: number): number {
    const scale: number = this.cardScale();
    const pad: number = scale === 2 ? 4 : 5;
    // 给足高度去量「完整显示」需要多少，再与上限取小
    const b: CardBudget = this.cardBudget(e, maxHeightVp);
    const usable: number = this.realColWidth() - pad * 2;
    const nameFs: number = this.nameFontSize();
    const placeFs: number = this.placeFontSize();
    let h: number = 0;
    if (b.nameLines > 0) {
      h += b.nameLines * this.measureText(e.courseName, nameFs, usable).lineHeight;
    }
    if (b.placeLines > 0) {
      // 与 card() 的渲染保持一致：教室上方有 ROOM_GAP 的间距。
      // 行高估算若漏掉它，整行会矮一点，卡片底部的教室被裁掉。
      h += SchedulePage.ROOM_GAP;
      h += b.placeLines * this.measureText(this.placeText(e), placeFs, usable).lineHeight;
    }
    if (b.teacherLines > 0) {
      h += 1 + 9 * 1.32;
    }
    if (b.parityLines > 0) {
      h += 1 + 11;
    }
    return h + pad * 2;
  }

  /**
   * 课表网格可用宽度（vp）：窗口宽减去节次列。
   *
   * 下限保护：极窄窗口（分屏）下也不能算出负数或过小值，
   * 否则列宽会变成 0 导致布局异常。
   */
  private availableGridWidth(): number {
    const w: number = this.windowWidth > 0 ? this.windowWidth : 360;
    const avail: number = w - SchedulePage.NARROW_LABEL_W;
    return avail > 0 ? avail : w;
  }

  /**
   * 真实列宽（vp）：**始终等分**可用宽度。
   *
   * 不再有「不足就用最小宽度撑开」的分支：那条分支等于把整周推出屏幕
   * （宽 7×86=602vp > 手机可用的 314vp），逼用户横向滚动。
   * 现在无论多窄都等分 —— 保证一屏看全一周，可读性交给字号降级解决。
   */
  private realColWidth(): number {
    const perCol: number = this.availableGridWidth() / SchedulePage.WEEK_COUNT;
    return perCol > 0 ? perCol : 1;
  }

  // ==================== 加载：缓存优先 ====================

  private async load(weekValue: string, interactive: boolean = false): Promise<void> {
    this.loading = true;
    this.errorText = '';
    try {
      let account: string = await AppState.resolveAccount();
      const savedSem: string = await PrefStore.loadLastSemester();
      let sem: string = this.semester.length > 0 ? this.semester : savedSem;

      // 账号未知时（没勾过「记住账号密码」、或冷启动后 AppStorage 里没有学号），
      // 缓存文件名是按账号拼的，直接按账号找会落空。这里按学期扫一遍缓存目录，
      // 把账号补回来 —— 否则明明本地有课表却会去请求服务器（会话失效时就会弹登录框）。
      if (account.length === 0 && sem.length > 0) {
        const found: string = TimetableStore.findAccountForSemester(sem);
        if (found.length > 0) {
          account = found;
          AppState.account = found;
        }
      }

      if (sem.length === 0) {
        // 没记住学期时，先看本地缓存过哪些学期（单用户取最近的一个），
        // 能命中就完全离线渲染，不必为了拿学期列表去请求服务器。
        const cachedSems: string[] = TimetableStore.cachedSemesters();
        if (cachedSems.length > 0) {
          sem = cachedSems[0];
        }
      }

      if (sem.length === 0) {
        // 本地确实没有任何缓存：只能取一次服务器数据拿到学期列表与默认学期
        const probe: Timetable = await AppState.apiInstance().getTimetable('', weekValue);
        sem = probe.semester;
        this.applyTimetable(probe, false);
        if (sem.length > 0) {
          await PrefStore.saveLastSemester(sem);
          TimetableStore.save(account, probe);
        }
        return;
      }

      // 用扫描到的学期补齐账号（见上）
      if (account.length === 0) {
        const found: string = TimetableStore.findAccountForSemester(sem);
        if (found.length > 0) {
          account = found;
          AppState.account = found;
        }
      }

      // 缓存命中：完全使用本地数据，不请求服务器。
      // 这样既省流量，也保证本地的课表修改不会被服务器数据覆盖。
      if (TimetableStore.has(account, sem)) {
        const cached: Timetable | null = TimetableStore.load(account, sem);
        if (cached !== null) {
          this.applyTimetable(cached, true);
          this.week = weekValue;
          await PrefStore.saveLastSemester(sem);
          await PrefStore.putText(KEY_LAST_WEEK, weekValue);
          return;
        }
      }

      // 未缓存：从服务器拉取并落盘
      const tt: Timetable = await AppState.apiInstance().getTimetable(sem, weekValue);
      this.applyTimetable(tt, false);
      if (tt.semester.length > 0) {
        await PrefStore.saveLastSemester(tt.semester);
        TimetableStore.save(account, tt);
      }
      await PrefStore.putText(KEY_LAST_WEEK, weekValue);
    } catch (e) {
      // 会话失效：先试静默续期，成功就重载（用户完全无感）。
      // 课表大量场景走本地缓存、根本不发请求，所以自动加载路径
      // **绝不能弹窗** —— 失败时只给内联提示即可。
      const renewed: boolean = await ReAuthService.recoverIfExpired(e, interactive);
      if (renewed) {
        await this.load(weekValue, interactive);
        return;
      }
      const msg: string = AppError.describe(e);
      this.errorText = AppError.isAuthExpired(e)
        ? '登录状态已过期，重新加载即可自动登录' : msg;
    } finally {
      this.loading = false;
    }
  }

  private applyTimetable(tt: Timetable, cached: boolean): void {
    AppState.timetable = tt;
    this.timetable = tt;
    this.semester = tt.semester.length > 0 ? tt.semester : this.semester;
    this.fromCache = cached;
    // 课表到位后刷新桌面卡片快照：应用冷启动时课表还没加载，
    // 仅靠 onForeground 刷新会得到「今天没有课」的错误结论。
    CardSnapshotStore.refresh().catch(() => {
      Logger.warn('card snapshot refresh failed after timetable load');
    });
  }

  /** 保存编辑结果并落盘 */
  private async persist(): Promise<void> {
    const account: string = await AppState.resolveAccount();
    this.timetable.pruneEmptyCells();

    // 用一个新的 Timetable 实例替换，强制 @State 触发界面刷新。
    // 直接改内部数组元素时 ArkUI 对深层变化不敏感，界面可能不更新。
    const freshCells: CellData[] = [];
    for (let i = 0; i < this.timetable.cells.length; i++) {
      const src: CellData = this.timetable.cells[i];
      const cd: CellData = new CellData();
      cd.row = src.row;
      cd.col = src.col;
      const inner: CourseEntry[] = [];
      for (let j = 0; j < src.entries.length; j++) {
        inner.push(src.entries[j]);
      }
      cd.entries = inner;
      freshCells.push(cd);
    }
    const fresh: Timetable = new Timetable();
    fresh.semester = this.timetable.semester;
    fresh.week = this.timetable.week;
    fresh.semesters = this.timetable.semesters;
    fresh.weeks = this.timetable.weeks;
    fresh.remark = this.timetable.remark;
    fresh.cells = freshCells;
    fresh.cachedAt = this.timetable.cachedAt;
    fresh.edited = fresh.hasLocalEdits();
    this.timetable = fresh;
    AppState.timetable = fresh;

    const ok: boolean = TimetableStore.save(account, fresh);
    this.fromCache = true;
    if (!ok) {
      this.errorText = '本地保存失败，修改可能在重启后丢失';
    }
    // 课表变了就把桌面卡片快照一并刷新，避免卡片继续显示旧课程
    await CardSnapshotStore.refresh().catch(() => {
      Logger.warn('card snapshot refresh failed after timetable save');
    });
  }

  // ==================== 编辑 ====================

  private openEditor(row: number, col: number): void {
    const cell: CellData | null = this.timetable.findCell(row, col);
    const list: CourseEntry[] = [];
    if (cell !== null) {
      for (let i = 0; i < cell.entries.length; i++) {
        list.push(cell.entries[i].clone());
      }
    }
    this.editorRow = row;
    this.editorCol = col;
    this.editorEntries = list;
    this.editorOpen = true;
  }

  private async onEditorSaved(result: EditorResult): Promise<void> {
    const cell: CellData = this.timetable.ensureCell(this.editorRow, this.editorCol);
    const next: CourseEntry[] = [];
    for (let i = 0; i < result.entries.length; i++) {
      const e: CourseEntry = result.entries[i];
      e.local = true;
      // 自增版本号：让界面 ForEach 的 key 变化，从而真正重绘卡片内容
      e.rev = e.rev + 1;
      next.push(e);
    }
    cell.entries = next;
    this.editorOpen = false;
    await this.persist();
  }

  /** 恢复为服务器数据：必须二次确认，避免误触丢失本地修改 */
  private confirmReset(): void {
    promptAction.showDialog({
      title: '恢复为服务器数据',
      message: '将清除本学期的所有本地修改（新增、编辑、删除），并从教务系统重新获取课表。是否继续？',
      buttons: [
        { text: '取消', color: '#666666' },
        { text: '恢复', color: '#D92D20' }
      ]
    }).then((result: promptAction.ShowDialogSuccessResponse) => {
      if (result.index === 1) {
        this.resetToServer();
      }
    }).catch(() => {
      // 忽略取消
    });
  }

  /** 实际执行恢复：删本地缓存并重新拉取 */
  private async resetToServer(): Promise<void> {
    const account: string = await AppState.resolveAccount();
    if (this.semester.length === 0) {
      return;
    }
    TimetableStore.remove(account, this.semester);
    const sem: string = this.semester;
    this.serverResetHint = '';
    // 清掉内存中的旧数据，避免缓存判断命中
    this.timetable = new Timetable();
    this.fromCache = false;
    this.semester = '';
    // 用户主动点了「恢复为服务器数据」
    await this.load(this.week, true);
    if (this.semester.length === 0) {
      this.semester = sem;
    }
    this.serverResetHint = '已恢复为服务器数据';
  }

  @State serverResetHint: string = '';

  // ==================== 周次与日期 ====================

  /**
   * 过滤用周次：**0 表示不按周次过滤**（即「全部」）。
   *
   * 三态语义（与 Flutter 端一致）：`WEEK_AUTO` 跟随本周、`''` 全部、
   * `'3'` 第 3 周。必须区分「跟随本周」与「全部」——
   * 否则用户选了「全部」下次启动会被自动定位覆盖掉。
   */
  private weekNumber(): number {
    if (this.week === WEEK_AUTO) {
      return this.currentWeekNo;
    }
    if (this.week.length === 0) {
      return 0;
    }
    const n: number = parseInt(this.week, 10);
    return isNaN(n) ? 0 : n;
  }

  /** 日期显示用周次：始终是真实周次（「全部」时用当前周） */
  private displayWeek(): number {
    if (this.week === WEEK_AUTO || this.week.length === 0) {
      return this.currentWeekNo;
    }
    const n: number = parseInt(this.week, 10);
    return isNaN(n) ? this.currentWeekNo : n;
  }

  /** 周次入口的显示文案 */
  private weekLabel(): string {
    if (this.week === WEEK_AUTO) {
      const cw: number = this.currentWeekNo;
      return cw > 0 ? ('第 ' + cw.toString() + ' 周') : '跟随本周';
    }
    if (this.week.length === 0) {
      return '全部';
    }
    return '第 ' + this.week + ' 周';
  }

  /** 是否处于「跟随本周」状态 */
  private isFollowingCurrentWeek(): boolean {
    return this.week === WEEK_AUTO;
  }

  /**
   * 打开周次选择浮层。
   *
   * 只置一个 @State 为 true —— 关闭同样由调用方置 false，不依赖框架注入
   * （早先用 CustomDialogController 时 `this.controller` 拿不到、
   * 确定/取消都关不掉，详见 WeekPickerContent 的类注释）。
   */
  private openWeekPicker(): void {
    this.weekPickerOpen = true;
  }

  private weekOptions(): string[] {
    const out: string[] = [''];
    for (let i = 1; i <= 30; i++) {
      out.push(i.toString());
    }
    return out;
  }

  /**
   * 表头上每天对应的日期文本。
   * 依托教学周历（AppState.weekDates，形如 09-16），按周次偏移推算；
   * 拿不到周历时返回空串，表头只显示星期。
   */
  /**
   * 表头上每天对应的日期文本（MM/DD）。
   * 数据来源：用户在设置里配置的「学期第 1 周周一」，用真实日期运算推算，
   * 因此跨月、跨年都准确。未配置开始日期时返回空串，表头只显示星期。
   */
  private dateOf(colIdx: number): string {
    const w: number = this.effectiveWeek();
    if (w <= 0) {
      return '';
    }
    return WeekService.dayLabel(w, colIdx);
  }

  /**
   * 学期号的顶栏缩写：`2026-2027-1` → `26-27-1`。
   *
   * 只在顶栏用；完整学期串在滚轮弹窗与设置页里照常显示。
   * 前缀两位年份已足够区分（同一时间只会看相邻几个学期）。
   * 与 Flutter 端的 _shortSemester 完全一致。
   */
  private semesterShort(): string {
    if (this.semester.length === 0) {
      return '学期';
    }
    const parts: string[] = this.semester.split('-');
    if (parts.length !== 3) {
      return this.semester;
    }
    const y = (t: string): string => t.length >= 2 ? t.substring(t.length - 2) : t;
    return y(parts[0]) + '-' + y(parts[1]) + '-' + parts[2];
  }

  /**
   * 学期滚轮的选项。
   *
   * 标签用完整的 `2026-2027 学年第一学期`：滚轮里空间只够一行，
   * 但它是「选择」场景、不是顶栏缩写场景，缩写成 26-27-1 会有歧义
   * （成绩页的学期滚轮也是完整标签，两端一致）。顶栏那颗键仍用
   * [semesterShort]。
   */
  private semesterOptions(): SemesterOption[] {
    const out: SemesterOption[] = [];
    for (let i = 0; i < this.timetable.semesters.length; i++) {
      const code: string = this.timetable.semesters[i];
      out.push(new SemesterOption(WeekCalendarParser.semesterLabel(code), code));
    }
    return out;
  }

  /** 表头/高亮要用的「参照周」：优先当前筛选的周，否则用当前教学周 */
  private effectiveWeek(): number {
    const w: number = this.weekNumber();
    return w > 0 ? w : this.currentWeekNo;
  }

  /** 今天是星期几（0=周一..6=周日），用于高亮 */
  private todayCol(): number {
    const day: number = new Date().getDay();
    return day === 0 ? 6 : day - 1;
  }

  /** 当前是否正在看本周 */
  private showingCurrentWeek(): boolean {
    const w: number = this.weekNumber();
    return w > 0 && this.currentWeekNo > 0 && w === this.currentWeekNo;
  }

  // ==================== 课程过滤与配色 ====================

  private visible(entry: CourseEntry): boolean {
    return entry.isActiveInWeek(this.weekNumber());
  }

  private visibleEntries(row: number, col: number): CourseEntry[] {
    const out: CourseEntry[] = [];
    const cell: CellData | null = this.timetable.findCell(row, col);
    if (cell === null) {
      // 空格子也要把 scope 清掉：否则会残留上一格的课数，
      // 让「同格多门课均分高度」的分母用错。
      this.budgetScope = out;
      return out;
    }
    for (let i = 0; i < cell.entries.length; i++) {
      if (this.visible(cell.entries[i])) {
        out.push(cell.entries[i]);
      }
    }
    // 顺手记下本格的课程列表，供 [budgetOf] 算「每张卡分到多少高度」。
    //
    // 为什么放在这里而不是 [cell] 的 @Builder 里：ArkTS 的 @Builder
    // 函数体只允许 UI 描述，不能写赋值语句（实测报
    // 「does not meet UI component syntax」）。而 visibleEntries 是普通方法，
    // 每格渲染时必然被调用 —— 放在这里是唯一既能拿到上下文、又不违反语法的地方。
    this.budgetScope = out;
    return out;
  }

  private colorOf(name: string): string[] {
    let h: number = 0;
    for (let i = 0; i < name.length; i++) {
      h = (h * 31 + name.charCodeAt(i)) % 100000;
    }
    return CARD_COLORS[h % CARD_COLORS.length];
  }

  // ==================== 布局尺寸 ====================

  /**
   * 列宽：优先一屏放下 7 天。
   * 手机竖屏放不下时给固定宽度并允许横向滚动。
   */
  private colWidth(): number {
    // 放得下：返回 0，交给 layoutWeight 等分（自动铺满、无误差）
    // 放不下：给最小可读宽度并允许横向滚动
    return this.fitsOneScreen() ? 0 : SchedulePage.MIN_COL_W;
  }

  /**
   * 卡片高度：按「完整显示」估算（用于算行高）。
   *
   * 与旧实现的根本差别：不再用 `chars = usable / (11*1.05)` 猜字宽，
   * 也不算「教室最多 2 行」这种与高度无关的封顶 —— 全部走真实测量。
   *
   * [maxHeightVp] 给一个很宽的上限即可：本方法只关心「完整显示要多少」，
   * 实际能显示多少由 [cardBudget] 按格子高度再截一次。
   */
  private cardHeight(e: CourseEntry): number {
    return this.naturalCardHeight(e, this.cardMaxProbeHeight());
  }

  /**
   * 探针高度：量「完整显示」时允许的最大高度。
   *
   * 取一个「肯定够」的值（一屏高度），这样 [cardBudget] 不会因为探针太小
   * 而提前截断行数 —— 我们要的是「完整需要多少」，不是「能塞多少」。
   */
  private cardMaxProbeHeight(): number {
    const h: number = this.windowWidth > 0 ? this.windowWidth : 816;
    return h * 0.5;
  }

  /** 某节次行的高度 */
  private rowHeight(row: number): number {
    let max: number = 0;
    for (let c = 0; c < SchedulePage.WEEK_COUNT; c++) {
      const list: CourseEntry[] = this.visibleEntries(row, c);
      let sum: number = 0;
      for (let i = 0; i < list.length; i++) {
        sum += this.cardHeight(list[i]) + 4;
      }
      if (sum > max) {
        max = sum;
      }
    }
    const h: number = max + 8;
    // 下限跟随列宽缩放（而不是固定 64）。
    //
    // ===== 为什么必须跟随（手机端「一屏装下」的最后一道坎）=====
    // 固定 64vp 下限时，5 行至少 320vp；再加上表头 46、筛选栏 36+24、
    // 备注、底部 dock 让位 92 —— 360×816vp 的手机上合计超过可用高度，
    // 于是**表格把备注挤出可视区**（真机截图里备注被 dock 压住）。
    // 现在下限按列宽比例走：窄列上卡片本身也矮（见 cardScale），
    // 行高跟着收，整块表格自然装得下。
    const floor: number = Math.max(44, Math.round(this.realColWidth() * 1.15));
    // 上限：单行不超过窗口高度的一半。同一节次里若某天堆了很多门课，
    // 自然高度会失控（把整周挤出屏幕）。封顶后由 [cardBudget] 在卡内截行。
    const ceil: number = Math.round(this.windowWidth * 0.5);
    let out: number = h < floor ? floor : h;
    if (ceil > floor && out > ceil) {
      out = ceil;
    }
    return out;
  }

  // ==================== 视图 ====================

  @Builder
  filterBar() {
    // ===== 一行四控件（与 Flutter 端对齐）=====
    // 早先是两行：第一行「周次 + 校历」，第二行「学期 + 已修改」。
    // 那占掉整整两行高度，而手机端一屏本来就要装下整周课表 —— 每省一行
    // 都是实打实的课表空间。现在收成一行：
    //
    //   [ 周次 │ 学期 │ 校历 │ 空教室 ]
    //
    // 周次与学期**等宽平分**剩余空间（flex 1:1），两个固定宽的按钮在右侧。
    // 「已 modified 标记」挪到下方备注标签旁（见 remarkBox），
    // 从「一个占行的大标签」降级为「与备注同高的小按钮」。
    Row({ space: Theme.GAP_S }) {
      // 周次：点开屏幕中央的玻璃滚轮弹窗
      Row({ space: 4 }) {
        Text(this.weekLabel())
          .fontSize(Theme.FS_SMALL)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        if (this.isFollowingCurrentWeek()) {
          Text('本周')
            .fontSize(Theme.FS_TINY)
            .fontColor($r('app.color.brand'))
        }
      }
      .layoutWeight(3)
      .height(36)
      .padding({ left: 10, right: 10 })
      .borderRadius(18)
      .backgroundColor($r('app.color.surface_variant'))
      .backgroundEffect(GlassKit.fieldEffect())
      .onClick(() => {
        this.openWeekPicker();
      })

      // 学期：与周次一样是弹窗（而不是 ArkUI 的 Select 下拉框）。
      //
      // ===== 为什么不用 Select（真机两个硬伤）=====
      //   1. 列表被窗口底边截断且**不能滚动**：教务系统返回 40 多个学期，
      //      展开后只画到第 9 项，剩下的既看不到也点不到（成绩页早先
      //      「没有全部学期」就是这个原因，不是没数据）。
      //   2. 展开的浮层不由我们控制：材质、圆角、点空白关闭都由系统决定，
      //      与「材质为系统默认 + 表盘滚轮 + 点空白消失」的要求对不上。
      // 因此与周次、成绩页的学期选择统一成同一个滚轮弹窗（SemesterPickerContent）。
      Row() {
        Text(this.semesterShort())
          .fontSize(Theme.FS_SMALL)
          .fontColor($r('app.color.text_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Text('▾')
          .fontSize(Theme.FS_TINY)
          .fontColor($r('app.color.text_tertiary'))
      }
      .layoutWeight(3)
      .height(36)
      .padding({ left: 10, right: 10 })
      .borderRadius(18)
      .backgroundColor($r('app.color.surface_variant'))
      .backgroundEffect(GlassKit.fieldEffect())
      .onClick(() => {
        if (this.timetable.semesters.length > 0) {
          this.semesterPickerOpen = true;
        }
      })

      // 校历入口
      Row({ space: 4 }) {
        AppIcon({ res: 'calendar_month', iconSize: 15, color: $r('app.color.brand') })
        Text('校历')
          .fontSize(Theme.FS_SMALL)
          .fontColor($r('app.color.brand'))
      }
      .height(36)
      .padding({ left: 12, right: 12 })
      .borderRadius(18)
      .backgroundColor($r('app.color.surface_variant'))
      .backgroundEffect(GlassKit.fieldEffect())
      .onClick(() => {
        this.calendarOpen = true;
      })

      // 空教室快捷入口（与 Flutter 端一致：看课表时最常接着问的就是它）
      Row() {
        AppIcon({ res: 'meeting_room', iconSize: 16, color: $r('app.color.brand') })
      }
      .height(36)
      .padding({ left: 10, right: 10 })
      .borderRadius(18)
      .backgroundColor($r('app.color.surface_variant'))
      .backgroundEffect(GlassKit.fieldEffect())
      .onClick(() => {
        this.onOpenClassroom();
      })
    }
    .width('100%')
    .padding(Theme.GAP)
    // ===== 筛选栏用页面底色，不用 surface（白）=====
    // 早先这一条是白色，而下面的表格是 `sched_bg`（淡紫），于是窗口顶部
    // 与中间拼出两块不同底色 —— 用户看到的就是「顶部颜色和内容底色不一样」。
    // Flutter 端早已统一（`schedBgColor`：筛选栏、表格、备注、底部栏同色，
    // 分隔只靠留白与卡片本身的颜色）。
    .backgroundColor($r('app.color.sched_bg'))
  }

  /** 表头：星期 + 日期，今天高亮 */
  @Builder
  headerCell(colIdx: number, narrow: boolean) {
    Column({ space: 1 }) {
      Text(WEEKDAY_LABELS[colIdx].replace('星期', ''))
        .fontSize(Theme.FS_SMALL)
        .fontColor(colIdx >= 5 ? $r('app.color.text_tertiary') : $r('app.color.text_secondary'))
        .fontWeight(FontWeight.Medium)
      Text(this.dateOf(colIdx))
        .fontSize(9)
        .fontColor($r('app.color.text_tertiary'))
      // 今天的小圆点
      Circle()
        .width(4)
        .height(4)
        .fill(this.showingCurrentWeek() && colIdx === this.todayCol()
          ? $r('app.color.brand') : Color.Transparent)
    }
    .height(46)
    .justifyContent(FlexAlign.Center)
    .width(narrow ? this.realColWidth() : undefined)
    .layoutWeight(narrow ? 0 : 1)
  }

  /** 节次标签 */
  @Builder
  sectionLabel(sec: SectionDef, height: number, width: number) {
    Column({ space: 2 }) {
      Text(sec.label.replace('第', '').replace('节', ''))
        .fontSize(Theme.FS_TINY)
        .fontWeight(FontWeight.Medium)
        .fontColor($r('app.color.text_secondary'))
        .textAlign(TextAlign.Center)
        .maxLines(2)
      Text(sec.start)
        .fontSize(9)
        .fontColor($r('app.color.text_tertiary'))
      Text(sec.end)
        .fontSize(9)
        .fontColor($r('app.color.text_tertiary'))
    }
    .width(width)
    .height(height)
    .justifyContent(FlexAlign.Center)
  }

  /**
   * 课程卡片：卡片自身可点击，避免落点在文字上时事件不冒泡。
   *
   * ===== 显示策略（用户要求：保教室，课名尽量完整）=====
   * 行数由 [cardBudget] 按**本格实际可用高度**分配，不再按列宽写死：
   *   1. 教室按真实测量完整显示（窄列上该折几行就几行，不截断）；
   *   2. 剩余高度全给课名；
   *   3. 教师/单双周只在宽列且还有余量时占行。
   *
   * [availH] 由 [cell] 传入（它就是格子的高度）—— 这是修掉
   * 「格子大片空白却仍截断」的关键：卡片终于知道自己有多少地方可用。
   */
  @Builder
  card(e: CourseEntry, narrow: boolean, row: number, col: number, availH: number) {
    Column({ space: 1 }) {
      Text(e.courseName)
        .fontSize(this.nameFontSize())
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colorOf(e.courseName)[1])
        .maxLines(this.budgetOf(e, availH).nameLines)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
      if (this.budgetOf(e, availH).teacherLines > 0) {
        Text(e.teacher)
          .fontSize(9)
          .fontColor(this.colorOf(e.courseName)[1])
          .opacity(0.85)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      // 教室：**任何宽度档位都要显示，且完整显示**（用户明确要求）。
      //
      // 行数来自真实测量（[cardBudget] 的 placeLines），不是写死的 1 行 ——
      // 早先窄列固定 1 行，`@9-109(章丘)` 这类 10 字符的教室必然被省略号
      // 截掉，这正是用户反馈的「教室被截断」。
      // 现在为了放下完整的教室，可以牺牲课名的行数。
      //
      // ===== 与课名拉开距离（用户要求「尽量不要挨在一起」）=====
      // 多留一段上边距：课名是深色粗体、教室是同色的 9vp 细字，
      // 两者贴在一起时视觉上会连成一片，读起来像一行半（尤其课名最后一行
      // 较短、教室紧跟其后时）。这里给教室单独加 [ROOM_GAP] vp。
      //
      // 这段间距**已计入 cardBudget 的高度预算**（见 [cardBudget] 的
      // roomGap），所以「教室完整显示」仍然成立 —— 拉开的距离是从
      // 课名那侧扣的，不是从教室那侧。
      if (this.budgetOf(e, availH).placeLines > 0) {
        Text(this.placeText(e))
          .fontSize(this.placeFontSize())
          .fontColor(this.colorOf(e.courseName)[1])
          .opacity(0.7)
          .maxLines(this.budgetOf(e, availH).placeLines)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .margin({ top: SchedulePage.ROOM_GAP })
      }
      if (this.budgetOf(e, availH).parityLines > 0) {
        Text(e.parityText())
          .fontSize(9)
          .fontColor(this.colorOf(e.courseName)[1])
          .opacity(0.75)
      }
    }
    .width('100%')
    // 撑满所在格：同一格只有一门课时占满整格；有多门（单周/双周各一门）
    // 时按权重等分，颜色块之间只留 2vp 的缝以区分是两门课。
    .layoutWeight(1)
    .padding(this.cardScale() === 2 ? 4 : 5)
    // 圆角收小：色块现在是整格铺满的，7vp 圆角在大块面上会被看出明显缺角；
    // 保留 3vp 是为了不显得生硬（格线本身是直角）。
    .borderRadius(3)
    .backgroundColor(this.colorOf(e.courseName)[0])
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.openEditor(row, col);
    })
  }

  /**
   * 一格内多张卡片时的预算缓存。
   *
   * 为什么需要：一张卡片在渲染里被问多次（每个 Text 的 maxLines 各一次），
   * 而 `(height, 卡片数)` 不变时结论也不变 —— 缓存掉可以避免
   * 「同一格被反复测量」带来的重排开销。
   * 键里带 height 与卡片数：格子高度变了（旋转/分屏）自然失效。
   */
  private budgetOf(e: CourseEntry, availH: number): CardBudget {
    const list: CourseEntry[] = this.budgetScope;
    const n: number = list.length > 0 ? list.length : 1;
    // 同格多门课时每张卡按权重等分格子高度（与 layoutWeight(1) 的效果一致），
    // 再扣掉格内 2vp 的间隔
    const per: number = (availH - (n - 1) * 2) / n;
    const key: string = e.id + '#' + e.rev.toString() + '@' + Math.round(per);
    const hit: CardBudget | undefined = this.budgetCache.get(key);
    if (hit !== undefined) {
      return hit;
    }
    const b: CardBudget = this.cardBudget(e, per);
    this.budgetCache.set(key, b);
    return b;
  }

  /**
   * 一个格子。
   *
   * ===== 为什么格内不留内边距 =====
   * 原先格子有 `padding(2)` 且内容垂直居中，于是彩色块四周始终留一圈底色、
   * 上下方向更是明显（行高越大留白越多），观感上「课」是浮在格子中间的小标签，
   * 而不是占据这一节的时间段。现在去掉内边距，让卡片用 layoutWeight 撑满格子，
   * 同一格有多门课时（例如单周/双周各一门）则按权重等分整格 ——
   * 两种情况下都不再有空白，彩色块即代表占用的时间。
   */
  @Builder
  cell(row: number, col: number, height: number, narrow: boolean) {
    Column({ space: 2 }) {
      // 空格子留白：不再画「+」占位符（按要求隐藏）。
      // 格子的高度由下面 .height(height) 固定，与内容无关，
      // 所以空着不会导致行高塌陷；点击添加的能力保留在 .onClick 上，
      // 点空白格依然能添加课程。
      ForEach(this.visibleEntries(row, col), (e: CourseEntry) => {
        this.card(e, narrow, row, col, height)
      }, (e: CourseEntry, idx: number) => e.id + '#' + e.rev.toString() + '#' + e.courseName + '#' + idx.toString())
    }
    .width(narrow ? SchedulePage.MIN_COL_W : undefined)
    .layoutWeight(narrow ? 0 : 1)
    .height(height)
    .alignItems(HorizontalAlign.Start)
    .border({ width: { left: 0.5, top: 0.5, right: 0.5, bottom: 0.5 },
      color: $r('app.color.divider') })
    .onClick(() => {
      this.openEditor(row, col);
    })
  }

  /** 宽屏（可一屏 7 天） */
  @Builder
  gridWide() {
    Column() {
      Row() {
        Text('')
          .width(SchedulePage.NARROW_LABEL_W)
        ForEach(WEEKDAY_LABELS, (label: string, idx: number) => {
          this.headerCell(idx, false)
        }, (label: string) => 'h' + label)
      }
      .width('100%')
      .backgroundColor($r('app.color.surface_variant'))

      ForEach(SECTIONS, (sec: SectionDef, rowIdx: number) => {
        Row() {
          this.sectionLabel(sec, this.rowHeight(rowIdx), SchedulePage.NARROW_LABEL_W)
          ForEach(WEEKDAY_LABELS, (label: string, colIdx: number) => {
            this.cell(rowIdx, colIdx, this.rowHeight(rowIdx), false)
          }, (label: string) => 'w' + label)
        }
        .width('100%')
        .alignItems(VerticalAlign.Top)
      }, (sec: SectionDef) => sec.label)
    }
    .width('100%')
    .backgroundColor($r('app.color.sched_bg'))
    .borderRadius(Theme.RADIUS_SM)
    .clip(true)
  }

  /**
   * 窄屏：节次列 + 7 天**等分铺满**（不再横向滚动）。
   *
   * ===== 为什么去掉横向滚动 =====
   * 原实现把 7 列按 86vp 固定宽放进一个横向 Scroll —— 360vp 的手机上
   * 总宽 602vp，用户必须左右拖动才能看全一周，而且进页面时只看到前 3~4 天
   * （「一屏装下一周课表」这条要求在手机上直接不成立）。
   *
   * 现在整周压缩进一屏：7 列等分剩余宽度，卡片内容按列宽分级降级
   * （见 [card]）。代价是窄列上每门课只能显示课程名，收益是
   * **抬眼就能看清这周每天几节课、分布如何** —— 这正是课表最主要的作用。
   * 想看完整信息点开卡片即可（编辑弹窗里有教师、教室、周次全量）。
   *
   * 顺带去掉了 colScroller 与「自动滚到今天」的逻辑（见 [scrollToToday]
   * 的判据已恒真，它自然不会执行）。
   */
  @Builder
  gridNarrow() {
    Row() {
      Column() {
        Blank()
          .width(SchedulePage.NARROW_LABEL_W)
          .height(46)
          .backgroundColor($r('app.color.surface_variant'))
        ForEach(SECTIONS, (sec: SectionDef, rowIdx: number) => {
          this.sectionLabel(sec, this.rowHeight(rowIdx), SchedulePage.NARROW_LABEL_W)
        }, (sec: SectionDef) => 'nl' + sec.label)
      }
      .width(SchedulePage.NARROW_LABEL_W)
      .backgroundColor($r('app.color.surface_variant'))

      Column() {
        Row() {
          ForEach(WEEKDAY_LABELS, (label: string, idx: number) => {
            this.headerCell(idx, true)
          }, (label: string) => 'nh' + label)
        }
        .width('100%')
        .backgroundColor($r('app.color.surface_variant'))

        ForEach(SECTIONS, (sec: SectionDef, rowIdx: number) => {
          Row() {
            ForEach(WEEKDAY_LABELS, (label: string, colIdx: number) => {
              this.cell(rowIdx, colIdx, this.rowHeight(rowIdx), true)
            }, (label: string) => 'nc' + label)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
        }, (sec: SectionDef) => 'nr' + sec.label)
      }
      .layoutWeight(1)
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    // 与 gridWide 同色：早先这里是 surface（白），而宽屏网格是 sched_bg，
    // 同一个页面在两种窗口宽度下底色不同（Flutter 端两处都是 schedBgColor）。
    .backgroundColor($r('app.color.sched_bg'))
    .clip(true)
  }

  build() {
    Stack() {
      Column() {
        this.filterBar()

        if (this.loading) {
          LoadingView({ message: '正在获取课表…' })
        } else if (this.errorText.length > 0) {
          ErrorView({
            message: this.errorText,
            onRetry: () => {
              this.load(this.week, true);
            }
          })
        } else if (!this.timetable.hasAnyCourse(this.weekNumber())) {
          EmptyView({ title: '本周暂无课程', hint: '点击任意空白格可手动添加课程' })
        } else {
          Scroll() {
            Column({ space: Theme.GAP }) {
              if (this.fitsOneScreen()) {
                this.gridWide()
              } else {
                this.gridNarrow()
              }

              // 备注 + 「已修改」小按钮（与 Flutter 端一致）
              if (this.timetable.remark.length > 0 ||
                  (this.fromCache && this.timetable.hasLocalEdits())) {
                Column({ space: 4 }) {
                  Row({ space: 8 }) {
                    if (this.timetable.remark.length > 0) {
                      Text('备注')
                        .fontSize(Theme.FS_SMALL)
                        .fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.warning'))
                    }
                    // 「已修改」：从顶栏的大标签降级为与「备注」同高的小按钮。
                    // 它是低频的「恢复」入口，不该占顶栏里最紧俏的一行宽度。
                    if (this.fromCache && this.timetable.hasLocalEdits()) {
                      Text('已修改')
                        .fontSize(Theme.FS_SMALL)
                        .fontWeight(FontWeight.Medium)
                        .fontColor($r('app.color.warning'))
                        .backgroundColor('#24FFA940')
                        .padding({ left: 8, right: 8, top: 1, bottom: 1 })
                        .borderRadius(999)
                        .onClick(() => {
                          this.confirmReset();
                        })
                    }
                  }
                  .width('100%')

                  if (this.timetable.remark.length > 0) {
                    Text(this.timetable.remark)
                      .fontSize(Theme.FS_TINY)
                      .fontColor($r('app.color.text_secondary'))
                  }
                }
                .width('100%')
                .alignItems(HorizontalAlign.Start)
                .padding(Theme.GAP)
                .backgroundColor($r('app.color.surface'))
                .borderRadius(Theme.RADIUS_SM)
              }

              // 底部常驻的「当前第 N 周 / 点击课程可编辑」已删除：
              // 前者在周次选择器上就能看到，后者是操作提示而非状态，
              // 常驻显示只是平白占掉一行、天天看同一句话。
              // 唯一需要用户处理的「没设开学日期」保留为一次性提示：
              if (!this.weekConfigured || this.currentWeekNo <= 0) {
                Text('未设置开学日期，无法自动定位当前周')
                  .fontSize(Theme.FS_TINY)
                  .fontColor($r('app.color.warning'))
                  .width('100%')
              }

              if (this.serverResetHint.length > 0) {
                Text(this.serverResetHint)
                  .fontSize(Theme.FS_TINY)
                  .fontColor($r('app.color.success'))
              }
            }
            .width('100%')
            // 底部留出浮层 dock 的高度，否则备注会被玻璃压住。
            //
            // ===== 为什么在 bottomInset 之外再加一截 =====
            // `bottomInset` 只算了 dock 胶囊本体（56）与它的下边距（36）。
            // 但 dock 之上还有系统手势条/导航区的安全边距，且胶囊上方的
            // 投影与圆角会额外遮住十几个 vp —— 只按 92 让位时，手机端
            // 备注仍会被压住（真机截图确认）。这里统一多留 24。
            .padding({
              left: this.isNarrow() ? Theme.GAP_S : Theme.GAP,
              right: this.isNarrow() ? Theme.GAP_S : Theme.GAP,
              top: this.isNarrow() ? Theme.GAP_S : Theme.GAP,
              bottom: (this.isNarrow() ? Theme.GAP_S : Theme.GAP)
                + Theme.bottomInset() + 24
            })
          }
          .layoutWeight(1)
          .align(Alignment.Top)
        }
      }
      .width('100%')
      .height('100%')
      // 整页统一底色（筛选栏、表格、底部都同色号）——
      // 之前用 app.color.bg，与表格/栏的 surface 不同，整页出现多种底色
      .backgroundColor($r('app.color.sched_bg'))

      // 课程编辑浮层：AppleUI 玻璃外壳（遮罩挖空、透镜贴边折射）。
      // 高度用比例并设上限，配合 KeyboardAvoidMode.RESIZE，
      // 键盘弹出时面板会收缩，底部按钮始终可点。
      if (this.editorOpen) {
        GlassOverlay({
          panelWidthRatio: 0.92,
          panelHeightRatio: 0.88,
          maxPanelWidth: 460,
          maxPanelHeight: 620,
          onDismiss: () => {
            this.editorOpen = false;
          }
        }) {
          CourseEditor({
            sectionLabel: SECTIONS[this.editorRow >= 0 && this.editorRow < SECTIONS.length
              ? this.editorRow : 0].label,
            weekdayLabel: WEEKDAY_LABELS[this.editorCol >= 0 && this.editorCol < SchedulePage.WEEK_COUNT
              ? this.editorCol : 0],
            entries: this.editorEntries,
            onSaved: (r: EditorResult) => {
              this.onEditorSaved(r);
            },
            onCancel: () => {
              this.editorOpen = false;
            }
          })
        }
      }

      // 周次选择浮层。宽度/高度用精确 vp：滚轮内容宽度固定，
      // 按比例算在平板上会拉得很宽（用户反馈「弹窗太宽」）。
      if (this.weekPickerOpen) {
        GlassOverlay({
          panelWidthVp: weekPickerPanelWidth(),
          panelHeightVp: weekPickerPanelHeight(),
          onDismiss: () => {
            this.weekPickerOpen = false;
          }
        }) {
          WeekPickerContent({
            current: this.week,
            maxWeeks: MAX_WEEKS,
            onPicked: (v: string) => {
              this.weekPickerOpen = false;
              this.week = v;
              this.load(v, true);
              this.scrollToToday();
            },
            onCancel: () => {
              this.weekPickerOpen = false;
            }
          })
        }
      }

      // 校历与作息表浮层。材质为**系统默认**（不透明面板）：面板里是密集的
      // 月历网格与说明文字，磨砂玻璃上会被糊开（见 PanelMaterial 的说明）。
      if (this.calendarOpen) {
        GlassOverlay({
          material: PanelMaterial.SYSTEM,
          panelWidthRatio: 0.94,
          panelHeightRatio: 0.86,
          maxPanelWidth: 720,
          onDismiss: () => {
            this.calendarOpen = false;
          }
        }) {
          CalendarSheet({
            initialSemester: this.semester,
            onClose: () => {
              this.calendarOpen = false;
            }
          })
        }
      }

      // 学期选择浮层：系统默认材质 + 表盘滚轮，点空白处即消失。
      // 与成绩页的学期选择共用同一个内容组件，两端交互完全一致。
      if (this.semesterPickerOpen) {
        GlassOverlay({
          material: PanelMaterial.SYSTEM,
          panelWidthVp: semesterPanelWidth(),
          panelHeightVp: semesterPanelHeight(),
          onDismiss: () => {
            this.semesterPickerOpen = false;
          }
        }) {
          SemesterPickerContent({
            options: this.semesterOptions(),
            current: this.semester,
            onPicked: (v: string) => {
              this.semesterPickerOpen = false;
              if (v !== this.semester) {
                this.semester = v;
                // 切学期是用户主动操作
                this.load(this.week, true);
              }
            },
            onCancel: () => {
              this.semesterPickerOpen = false;
            }
          })
        }
      }
    }
    .width('100%')
    .height('100%')
    .alignContent(Alignment.Center)
  }
}

/**
 * 卡片的内容预算：在这个高度里，课名/教室/教师/单双周各排几行。
 *
 * 由 [SchedulePage.cardBudget] 算出来 —— 依据是本格**实际可用高度**与
 * 文本真实测量，而不是列宽档位。0 表示该项不显示。
 */
class CardBudget {
  /** 课名行数 */
  nameLines: number;
  /** 教师行数（0 或 1） */
  teacherLines: number;
  /** 教室行数（按测量，完整显示所需） */
  placeLines: number;
  /** 单双周行数（0 或 1） */
  parityLines: number;

  constructor(nameLines: number, teacherLines: number, placeLines: number, parityLines: number) {
    this.nameLines = nameLines;
    this.teacherLines = teacherLines;
    this.placeLines = placeLines;
    this.parityLines = parityLines;
  }
}
