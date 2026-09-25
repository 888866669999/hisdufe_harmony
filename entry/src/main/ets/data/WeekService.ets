/*
 * WeekService：当前教学周的统一入口
 *
 * 职责：
 *   1. 由用户在设置里配置的「学期第 1 周周一」+ 系统时间推算当前周次；
 *   2. 每 6 小时与系统时间对齐一次（跨周后自动修正），并把结果写入 AppStorage，
 *      供课表页等处订阅；
 *   3. 未配置开始日期时返回 0，界面据此提示用户去设置。
 *
 * 「每 6 小时对齐」的实现方式：记录上次对齐时间，若距现在已超过 6 小时则重算，
 * 否则直接复用缓存值。这样无需常驻定时器，进入应用/切换页面时自然完成对齐。
 */
import { PrefStore } from '../data/PrefStore';
import { WeekCalc, DateParts } from '../common/WeekCalc';
import { Logger } from '../common/Logger';
import { MAX_WEEKS, WEEK_ALIGN_INTERVAL_MS,
  AS_CURRENT_WEEK, AS_SEMESTER_START, AS_WEEK_CONFIGURED } from '../common/Constants';

/** AppStorage 键统一在 Constants 中定义，这里转出以保持既有引用可用 */
export { AS_CURRENT_WEEK, AS_SEMESTER_START, AS_WEEK_CONFIGURED } from '../common/Constants';

export class WeekService {
  /** 已配置的学期开始日期（YYYY-MM-DD），空串表示未配置 */
  private static startMonday: string = '';
  private static loaded: boolean = false;

  /** 从持久化读取配置（幂等） */
  static async load(): Promise<void> {
    if (WeekService.loaded) {
      return;
    }
    WeekService.startMonday = await PrefStore.loadSemesterStart();
    WeekService.loaded = true;
  }

  /** 当前配置的开始日期 */
  static start(): string {
    return WeekService.startMonday;
  }

  static isConfigured(): boolean {
    return WeekService.startMonday.length > 0;
  }

  /** 由设置页保存新的开学日期，并立即重新对齐 */
  static async setStartMonday(dateText: string): Promise<void> {
    const p: DateParts | null = WeekCalc.parse(dateText);
    if (p === null) {
      throw new Error('invalid date');
    }
    // 统一存成「该日期所在周的周一」，避免用户填了非周一造成周次偏移
    WeekService.startMonday = dateText;
    WeekService.loaded = true;
    await PrefStore.saveSemesterStart(dateText);
    await WeekService.align(true);
  }

  /**
   * 与系统时间对齐。
   * @param force 忽略 6 小时间隔强制重算（用户刚改配置时用）
   * @returns 当前周次（1..MAX_WEEKS），无法判断返回 0
   */
  static async align(force: boolean): Promise<number> {
    await WeekService.load();

    if (!WeekService.isConfigured()) {
      WeekService.publish(0);
      return 0;
    }

    const nowMs: number = Date.now();
    const lastAt: number = await PrefStore.loadWeekAlignAt();

    // 未超过 6 小时则直接复用上次结果，避免频繁计算
    if (!force && lastAt > 0 && nowMs - lastAt < WEEK_ALIGN_INTERVAL_MS) {
      const cached: number = await PrefStore.loadWeekAlignValue();
      WeekService.publish(cached);
      return cached;
    }

    const week: number = WeekCalc.weekNumber(WeekService.startMonday, new Date(), MAX_WEEKS);
    await PrefStore.saveWeekAlignAt(nowMs);
    await PrefStore.saveWeekAlignValue(week);
    WeekService.publish(week);
    Logger.info('week aligned: ' + week + ' (start=' + WeekService.startMonday + ')');
    return week;
  }

  /** 只读取缓存的周次（不触发重算），用于界面首帧 */
  static cachedWeek(): number {
    const v: number | undefined = AppStorage.get<number>(AS_CURRENT_WEEK);
    return (v === undefined || v === null) ? 0 : v;
  }

  private static publish(week: number): void {
    AppStorage.setOrCreate(AS_CURRENT_WEEK, week);
    AppStorage.setOrCreate(AS_SEMESTER_START, WeekService.startMonday);
    AppStorage.setOrCreate(AS_WEEK_CONFIGURED, WeekService.isConfigured());
  }

  /**
   * 取第 week 周某天的日期文本（MM/DD），offset 0=周一..6=周日。
   * 未配置开始日期时返回空串，界面据此隐藏日期行。
   */
  static dayLabel(week: number, offset: number): string {
    if (!WeekService.isConfigured() || week <= 0) {
      return '';
    }
    return WeekCalc.dayOfWeek(WeekService.startMonday, week, offset);
  }

  /** 开学日期「那天」对应的星期几（0=周一..6=周日），用于提示用户配置是否合理 */
  static configuredWeekday(): number {
    const p: DateParts | null = WeekCalc.parse(WeekService.startMonday);
    if (p === null) {
      return -1;
    }
    const d: Date = new Date(Date.UTC(p.year, p.month - 1, p.day));
    const dow: number = d.getUTCDay();
    return dow === 0 ? 6 : dow - 1;
  }
}
