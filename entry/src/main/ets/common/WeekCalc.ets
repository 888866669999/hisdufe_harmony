/*
 * WeekCalc：按「学期第 1 周周一」的日期与当前系统时间推算教学周次
 *
 * 纯计算、不依赖任何 HarmonyOS API，便于离线单测。
 *
 * 规则：
 *   - 用户设置的日期被视为第 1 周的周一；若填的不是周一，会先回退到该日期所在周的周一，
 *     这样即使填了开学第一天（可能是周三）也能得到正确周次。
 *   - 第 1 周为 [周一, 周日]，之后每 7 天递增一周。
 *   - 早于开始日期返回 0（尚未开学），超过 MAX_WEEKS 也返回 0（视为未知）。
 */

/** 日期三元组（月份为 1-12）；hour/minute 用于提醒时刻，默认 0 */
export class DateParts {
  year: number = 0;
  month: number = 1;
  day: number = 1;
  hour: number = 0;
  minute: number = 0;

  constructor(year: number, month: number, day: number, hour: number = 0, minute: number = 0) {
    this.year = year;
    this.month = month;
    this.day = day;
    this.hour = hour;
    this.minute = minute;
  }
}

export class WeekCalc {
  private static readonly MS_PER_DAY: number = 24 * 60 * 60 * 1000;

  private static pad2(n: number): string {
    return n < 10 ? '0' + n.toString() : n.toString();
  }

  /** 解析 YYYY-MM-DD；非法返回 null */
  static parse(text: string): DateParts | null {
    if (text === undefined || text === null) {
      return null;
    }
    const t: string = text.trim();
    if (t.length < 8 || t.length > 10) {
      return null;
    }
    const seg: string[] = t.split('-');
    if (seg.length !== 3) {
      return null;
    }
    const y: number = parseInt(seg[0], 10);
    const m: number = parseInt(seg[1], 10);
    const d: number = parseInt(seg[2], 10);
    if (isNaN(y) || isNaN(m) || isNaN(d)) {
      return null;
    }
    if (y < 1970 || y > 2200 || m < 1 || m > 12 || d < 1 || d > 31) {
      return null;
    }
    // 回填校验：仅看 d<=31 是不够的，像 2026-02-31、2027-02-29（平年）、
    // 2026-04-31 都能通过上面的检查，而 Date.UTC 会把它们悄悄归一化
    // （2026-02-31 变成 3 月 3 日），导致整学期周次算错。
    // 这里用 Date 归一化后反查，不一致即为不存在的日期。
    const probe: Date = new Date(Date.UTC(y, m - 1, d));
    if (probe.getUTCFullYear() !== y || probe.getUTCMonth() !== m - 1 || probe.getUTCDate() !== d) {
      return null;
    }
    return new DateParts(y, m, d);
  }

  /** 格式化为 YYYY-MM-DD */
  static format(p: DateParts): string {
    return p.year.toString() + '-' + WeekCalc.pad2(p.month) + '-' + WeekCalc.pad2(p.day);
  }

  /** 取 Date 的日期部分（本地时区，符合用户对「今天」的认知） */
  static fromDate(date: Date): DateParts {
    return new DateParts(date.getFullYear(), date.getMonth() + 1, date.getDate());
  }

  /** 显示用的 MM/DD */
  static formatMd(p: DateParts): string {
    return WeekCalc.pad2(p.month) + '/' + WeekCalc.pad2(p.day);
  }

  /** 取某个 UTC 毫秒值所在周的周一（周一为一周起点） */
  private static mondayMsOf(ms: number): number {
    const d: Date = new Date(ms);
    const dow: number = d.getUTCDay(); // 0=周日 .. 6=周六
    const back: number = dow === 0 ? 6 : dow - 1;
    return ms - back * WeekCalc.MS_PER_DAY;
  }

  /**
   * 计算某个日期属于第几周。
   * @param startMonday 用户设置的「第 1 周周一」，YYYY-MM-DD
   * @param now 当前时间
   * @returns 周次（1..MAX_WEEKS）；无法判断返回 0
   */
  static weekNumber(startMonday: string, now: Date, maxWeeks: number): number {
    const sp: DateParts | null = WeekCalc.parse(startMonday);
    if (sp === null) {
      return 0;
    }
    const startMs: number = Date.UTC(sp.year, sp.month - 1, sp.day);
    // 用户可能填了非周一的日期，统一回退到该周的周一
    const baseMs: number = WeekCalc.mondayMsOf(startMs);

    const np: DateParts = WeekCalc.fromDate(now);
    const todayMs: number = Date.UTC(np.year, np.month - 1, np.day);

    const diffDays: number = Math.floor((todayMs - baseMs) / WeekCalc.MS_PER_DAY);
    if (diffDays < 0) {
      // 还没开学
      return 0;
    }
    const week: number = Math.floor(diffDays / 7) + 1;
    if (week < 1 || week > maxWeeks) {
      return 0;
    }
    return week;
  }

  /**
   * 取第 week 周周一的日期，用于表头日期展示。
   * @returns YYYY-MM-DD；无法计算返回空串
   */
  static mondayOfWeek(startMonday: string, week: number): string {
    const sp: DateParts | null = WeekCalc.parse(startMonday);
    if (sp === null || week < 1) {
      return '';
    }
    const startMs: number = Date.UTC(sp.year, sp.month - 1, sp.day);
    const baseMs: number = WeekCalc.mondayMsOf(startMs);
    const ms: number = baseMs + (week - 1) * 7 * WeekCalc.MS_PER_DAY;
    const d: Date = new Date(ms);
    return d.getUTCFullYear().toString() + '-' +
      WeekCalc.pad2(d.getUTCMonth() + 1) + '-' + WeekCalc.pad2(d.getUTCDate());
  }

  /**
   * 取第 week 周某一天的日期文本（MM/DD），offset 0=周一 .. 6=周日。
   * 直接用日期运算，避免按 30 天估算导致的跨月错误。
   */
  static dayOfWeek(startMonday: string, week: number, offset: number): string {
    const mon: string = WeekCalc.mondayOfWeek(startMonday, week);
    const p: DateParts | null = WeekCalc.parse(mon);
    if (p === null) {
      return '';
    }
    const ms: number = Date.UTC(p.year, p.month - 1, p.day) + offset * WeekCalc.MS_PER_DAY;
    const d: Date = new Date(ms);
    return WeekCalc.formatMd(new DateParts(d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate()));
  }

  /**
   * 取第 week 周某一天的日期（offset 0=周一 .. 6=周日）。
   * 用于把「第 N 周 周 X」换算成真实日期，是上课提醒排期的核心。
   */
  static dateOfDay(startMonday: string, week: number, offset: number): DateParts | null {
    const mon: string = WeekCalc.mondayOfWeek(startMonday, week);
    const p: DateParts | null = WeekCalc.parse(mon);
    if (p === null) {
      return null;
    }
    const ms: number = Date.UTC(p.year, p.month - 1, p.day) + offset * WeekCalc.MS_PER_DAY;
    const d: Date = new Date(ms);
    return new DateParts(d.getUTCFullYear(), d.getUTCMonth() + 1, d.getUTCDate());
  }

  /** 今天是否处于第 week 周之内（用于判断「本周」提示是否准确） */
  static isTodayInWeek(startMonday: string, week: number, now: Date, maxWeeks: number): boolean {
    return week > 0 && WeekCalc.weekNumber(startMonday, now, maxWeeks) === week;
  }

  /**
   * 某年某月的天数（month 为 1-12，越界按 31 处理）。
   *
   * 「下个月的第 0 天」即本月最后一天，闰年由 Date 自行处理，
   * 不必另写闰年判断。
   */
  static daysInMonth(year: number, month: number): number {
    if (month < 1 || month > 12) {
      return 31;
    }
    return new Date(year, month, 0).getDate();
  }

  /**
   * 把「日」夹到当月合法范围。
   *
   * 用途：日期滚轮的「年」「月」两列可以独立拨动，从 1/31 切到 2 月
   * 就会停在 2/31 这种不存在的日期上。年月一变就必须夹一次。
   */
  static clampDay(year: number, month: number, day: number): number {
    const dim: number = WeekCalc.daysInMonth(year, month);
    if (day < 1) {
      return 1;
    }
    return day > dim ? dim : day;
  }
}
