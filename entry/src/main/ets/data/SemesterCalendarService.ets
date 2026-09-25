/*
 * 学期信息：从教务系统的「教学周历」构建。
 *
 * ===== 为什么不用硬编码的校历数据 =====
 * 早先 AcademicCalendar.ets 里有一份手抄的 SEMESTER_CALENDARS
 * （开学日、总周数、假期备注）。它的失效方式很危险：
 * **换学年后就是错的，而界面上完全看不出来** —— 用户会照着过期日期安排行程。
 * 那份数据已删除，改由本文件从教务系统的教学周历实时生成。
 *
 * 教务的「教学周历查看」（/jsxsd/jxzl/jxzl_query）是同一信息的**结构化**版本：
 * 一张「第 N 周 ←→ 周一日期」的对照表，学校每学期排课时录入。
 * 用它做唯一数据源，换学年后取到的自然是新数据 —— 不需要改代码。
 *
 * ===== 与 Flutter 端对齐 =====
 * 对应 lib/data/semester_calendar_service.dart，行为逐条对应：
 *   - 三层缓存（内存 → 磁盘 → 网络），TTL 6 小时；
 *   - 强制刷新失败时**回退到缓存旧数据**，不把已显示的内容擦掉；
 *   - 系统时间超出周历范围时自动拉一次新学期，**每天限一次**；
 *   - 开学日期为空时自动用校历的值填充，用户手动设过的永不覆盖。
 */
import { PrefStore } from './PrefStore';
import { PageCache, PageDataLoader, PageLoadResult } from './PageCache';
import { WeekCalendarParser } from '../parser/WeekCalendarParser';
import { AppState } from './AppState';
import { WeekService } from './WeekService';
import { WeekDate, ChoiceItem } from '../model/Models';
import { Logger } from '../common/Logger';
import { TTL_SEMESTER_CALENDAR, TTL_SEMESTER_LIST, CACHE_SEMESTER_CALENDAR,
  CACHE_SEMESTER_LIST, KEY_SEMESTER_AUTO_FETCH_DAY } from '../common/Constants';

/** 一个学期的教学安排（全部由校历周次表推导，无硬编码日期） */
export class SemesterInfo {
  /** 学期代码，如 2026-2027-1 */
  code: string;
  /** 「第 N 周 ←→ 周一日期」，按周次升序 */
  weeks: WeekDate[];

  constructor(code: string, weeks: WeekDate[]) {
    this.code = code;
    this.weeks = weeks;
  }

  get isValid(): boolean {
    return this.code.length > 0 && this.weeks.length > 0;
  }

  /** 第 1 周周一（YYYY-MM-DD）—— 全部周次计算的基准 */
  get firstMonday(): string {
    return this.weeks.length === 0 ? '' : this.weeks[0].monday;
  }

  /** 总教学周数 */
  get totalWeeks(): number {
    return this.weeks.length === 0 ? 0 : this.weeks[this.weeks.length - 1].week;
  }

  /** 最后一周的周日（YYYY-MM-DD） */
  get lastDay(): string {
    const mon: Date | null = this.mondayOf(this.totalWeeks);
    if (mon === null) {
      return '';
    }
    const sun: Date = new Date(mon.getTime() + 6 * 24 * 3600 * 1000);
    return WeekCalendarParser.formatYmd(sun);
  }

  /** 某教学周的周一；该周不在表内或日期非法时返回 null */
  mondayOf(week: number): Date | null {
    for (let i = 0; i < this.weeks.length; i++) {
      if (this.weeks[i].week === week) {
        return WeekCalendarParser.dateOf(this.weeks[i].monday);
      }
    }
    return null;
  }

  /** 今天是第几周（不在学期内则 0） */
  weekOf(today: Date): number {
    return WeekCalendarParser.currentWeek(this.weeks, today);
  }

  /**
   * 每个日期对应的教学周；不在学期内则不出现。
   *
   * 用**日期区间**展开，而不是「周一相同」判断：这样一周里的任意一天都能查到，
   * 界面画月历时不必对每一天都去找它属于哪一周。
   */
  weekIndexByDay(): Map<string, number> {
    const out: Map<string, number> = new Map<string, number>();
    for (let i = 0; i < this.weeks.length; i++) {
      const mon: Date | null = this.mondayOf(this.weeks[i].week);
      if (mon === null) {
        continue;
      }
      for (let d = 0; d < 7; d++) {
        const day: Date = new Date(mon.getTime() + d * 24 * 3600 * 1000);
        out.set(WeekCalendarParser.formatYmd(day), this.weeks[i].week);
      }
    }
    return out;
  }
}

export class SemesterCalendarService {
  /** 当前已知的学期信息（内存） */
  private static mem: SemesterInfo | null = null;
  /** 上次加载的失败原因（界面用来区分「没数据」与「取不到」） */
  static lastError: string = '';

  static get current(): SemesterInfo | null {
    return SemesterCalendarService.mem;
  }

  /**
   * 取某学期的教学周历。
   *
   * 全程不抛异常：校历取不到只是这一块内容退化为「暂不可用」，
   * 不该影响课表、成绩等主流程。
   *
   * [force] 为 true 时**总是**重新联网（用户点了刷新就该完整拉一遍）。
   * 但强制刷新失败时**不会**把已缓存的数据丢掉 —— 见 [_fallbackFromCache]。
   */
  static async load(semester: string, force: boolean): Promise<SemesterInfo | null> {
    if (semester.length === 0) {
      SemesterCalendarService.lastError = '';
      return null;
    }
    const mem: SemesterInfo | null = SemesterCalendarService.mem;
    if (mem !== null && mem.code === semester && !force) {
      return mem;
    }
    SemesterCalendarService.lastError = '';
    const loader: PageDataLoader<SemesterInfo> =
        SemesterCalendarService.loaderFor(semester);
    try {
      const res: PageLoadResult<SemesterInfo> = await loader.load(force);
      const info: SemesterInfo = res.data;
      if (!info.isValid) {
        SemesterCalendarService.lastError = '该学期暂无教学周历';
        // 服务器回了一份合法页面但里面没有周次表（学校还没录入）：
        // 这算「这次没取到」，同样保留旧缓存
        return await SemesterCalendarService.fallbackFromCache(loader);
      }
      SemesterCalendarService.mem = info;
      await SemesterCalendarService.applyToAppState(info);
      return info;
    } catch (e) {
      // 不把异常抛给界面：校历是辅助信息
      SemesterCalendarService.lastError = e.toString();
      Logger.warn('[calendar] load failed: ' + e);
      return await SemesterCalendarService.fallbackFromCache(loader);
    }
  }

  /**
   * 刷新失败（或服务端还没录入）时的回退：用缓存里的旧数据继续显示。
   *
   * 为什么必须有这一步：曾经点「刷新」时网络不通，界面会**把已经显示着的
   * 校历整个擦掉** —— 用户手里原有的、可能是唯一一份离线可用的校历就这么没了，
   * 而这次刷新失败本不该有任何破坏性。
   *
   * 回退只读缓存、**不再联网**：刚刚那次请求就是失败的，
   * 再走一遍 load 只会白等一次超时。
   */
  private static async fallbackFromCache(
    loader: PageDataLoader<SemesterInfo>): Promise<SemesterInfo | null> {
    const old: SemesterInfo | null = await loader.loadCached();
    if (old === null || !old.isValid) {
      return null;
    }
    SemesterCalendarService.mem = old;
    // 提示与「取到的是旧的」区分开，界面据此显示成警告而不是错误
    SemesterCalendarService.lastError = SemesterCalendarService.lastError.length === 0
      ? '未能获取最新教学周历，已显示上次的数据'
      : SemesterCalendarService.lastError + '；已显示上次的数据';
    return old;
  }

  /** 构造某学期的加载器（key 带学期作变体；TTL 6 小时） */
  private static loaderFor(semester: string): PageDataLoader<SemesterInfo> {
    const account: string = AppState.account;
    const key: string = PageCache.keyOf(account, CACHE_SEMESTER_CALENDAR, [semester]);
    return new PageDataLoader<SemesterInfo>(
      key,
      () => AppState.apiInstance().getWeekCalendarHtml(semester),
      (body: string) => SemesterCalendarService.parseInfo(body, semester),
      TTL_SEMESTER_CALENDAR);
  }

  /** 原文 → SemesterInfo（静态以便复用与单测） */
  static parseInfo(html: string, requested: string): SemesterInfo {
    // 代码取「服务端实际显示的那个学期」（selected 选项），而不是
    // 请求时传的值或页面里第一个出现的代码 —— 前者会被服务端忽略，
    // 后者永远是最新的学期。取错会得到「标题与日历不同学期」的错位。
    const shown: string = WeekCalendarParser.parseSelectedSemester(html);
    const code: string = shown.length > 0 ? shown : requested;
    return new SemesterInfo(code, WeekCalendarParser.parseWeekDates(html));
  }

  /** 用户主动刷新：完整重取一次周历（语义同 load(force=true)） */
  static async refresh(semester: string): Promise<SemesterInfo | null> {
    return SemesterCalendarService.load(semester, true);
  }

  /**
   * 系统时间已经超出周历范围时，自动尝试拉取一次新周历；**每天最多一次**。
   *
   * 为什么需要：期末之后（寒暑假里）周历自然就「过期」了 ——
   * 今天是第 0 周，界面上的周次、上课提醒、桌面卡片全都算不出来。
   * 而新学期的周历此时可能已经录入教务系统，只是本地还存着旧的那份。
   *
   * 为什么限每天一次：触发条件（今天晚于最后一周）在整个假期里**持续成立**，
   * 不限频就会每次启动、每次打开校历都联网 —— 而学校一学期只更新一次。
   *
   * 返回新拉到的周历；不满足条件、今天已试过、或拉取失败都返回 null。
   */
  static async autoFetchIfOutdated(semester: string): Promise<SemesterInfo | null> {
    if (semester.length === 0) {
      return null;
    }
    if (await SemesterCalendarService.autoFetchTriedToday()) {
      return null;
    }
    const cur: SemesterInfo | null = await SemesterCalendarService.load(semester, false);
    if (cur === null || cur.weeks.length === 0) {
      return null;
    }
    // 「超出范围」= 今天晚于最后一周的周日。仍在学期内就不该自动联网。
    const lastMon: Date | null = cur.mondayOf(cur.totalWeeks);
    if (lastMon === null) {
      return null;
    }
    const lastSunday: Date = new Date(lastMon.getTime() + 6 * 24 * 3600 * 1000);
    const now: Date = new Date();
    const today: Date = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    if (!(today.getTime() > lastSunday.getTime())) {
      return null;
    }
    // 标记**先写**：一次拉取可能耗时数秒，期间用户切页会再次触发本方法，
    // 不先占位就会并发打出多个请求
    await PrefStore.putText(KEY_SEMESTER_AUTO_FETCH_DAY,
      SemesterCalendarService.todayText(today));
    Logger.info('[calendar] out of range, auto fetching: ' + semester);

    const refreshed: SemesterInfo | null =
        await SemesterCalendarService.refresh(semester);
    if (refreshed === null) {
      return null;
    }
    // ===== 必须确认「真的拿到新数据」，而不是又拿回那份旧的 =====
    // refresh 失败时会**回退到缓存**（保住离线数据），于是它可能返回一份
    // 非空、但与刚读到的完全相同的数据。若直接当成功上报，界面会弹
    // 「已获取到新学期的教学周历」—— 而实际什么都没变，属于报告了不存在的成功。
    const changed: boolean = refreshed.code !== cur.code ||
      refreshed.firstMonday !== cur.firstMonday ||
      refreshed.totalWeeks !== cur.totalWeeks;
    return changed ? refreshed : null;
  }

  /** 今天是否已经自动拉取过（用于把频率限制为每天一次） */
  private static async autoFetchTriedToday(): Promise<boolean> {
    const day: string = await PrefStore.getText(KEY_SEMESTER_AUTO_FETCH_DAY, '');
    return day.length > 0 && day === SemesterCalendarService.todayText(new Date());
  }

  private static todayText(d: Date): string {
    return WeekCalendarParser.formatYmd(d);
  }

  /**
   * 可选学期列表（服务端为准）。
   *
   * key 不带变体：它本身就是「所有学期」。服务端返回空时用缓存兜底，
   * 否则学期下拉会变成一个空框。
   */
  static async semesters(force: boolean): Promise<ChoiceItem[]> {
    const account: string = AppState.account;
    const loader: PageDataLoader<ChoiceItem[]> = new PageDataLoader<ChoiceItem[]>(
      PageCache.keyOf(account, CACHE_SEMESTER_LIST),
      () => AppState.apiInstance().getWeekCalendarHtml(''),
      (body: string) => WeekCalendarParser.parseSemesterOptions(body),
      TTL_SEMESTER_LIST);
    try {
      const got: ChoiceItem[] = (await loader.load(force)).data;
      if (got.length > 0) {
        return got;
      }
      // 服务端没给列表（页面结构变了）→ 退回上次缓存
      const cached: ChoiceItem[] | null = await loader.loadCached();
      return cached === null ? got : cached;
    } catch (e) {
      Logger.warn('[calendar] semesters failed: ' + e);
      const cached: ChoiceItem[] | null = await loader.loadCached();
      return cached === null ? [] : cached;
    }
  }

  /**
   * 把校历里的开学日期**补进**应用状态（仅在用户没设过时）。
   *
   * 这条让「开学日期」从「必须手动设置」变成「默认就是对的」：
   * 周次显示、上课提醒、桌面卡片全都依赖它，而它的权威值本来就在
   * 教务系统的周历里。用户手动改过的值永不被覆盖 ——
   * 手动设置是明确意图（比如补考周算作第 1 周），不能被一次联网抹掉。
   */
  private static async applyToAppState(info: SemesterInfo): Promise<void> {
    if (info.firstMonday.length === 0) {
      return;
    }
    // 先让 WeekService 把已存的开学日期读进来，否则 isConfigured 判断不准
    await WeekService.load();
    if (WeekService.isConfigured()) {
      return;
    }
    // 走 WeekService 而不是直接写 PrefStore：它会吸附到周一、
    // 更新 AppStorage 让界面立刻刷新，并落盘 —— 漏掉任一步都会
    // 出现「日期存了但界面还是旧周次」。
    await WeekService.setStartMonday(info.firstMonday);
    // 顺手把当前周也算出来：否则要等下一次 WeekService.align 才更新
    await WeekService.align(true);
    Logger.info('[calendar] 开学日期已由校历补全: ' + info.firstMonday);
  }

  /** 仅供测试/调试：清掉内存态 */
  static clearMemory(): void {
    SemesterCalendarService.mem = null;
    SemesterCalendarService.lastError = '';
  }
}
