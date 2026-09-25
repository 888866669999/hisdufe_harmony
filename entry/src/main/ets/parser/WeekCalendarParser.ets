/*
 * 教学周历解析器：解析 /jsxsd/jxzl/jxzl_query
 *
 * 用途：把「第 r 周」换算成真实日期。已核实页面结构：
 *   <tr height='28'>
 *     <td>1</td>                                ← 第几周
 *     <td title='2026年08月24'><B>24</B></td>    ← 周一（title 里是完整年月日）
 *     <td title='2026年08月25'>…                 ← 周二 … 周日
 *   </tr>
 *
 * 为什么必须按行解析、而不能「把所有 MM月dd日 每 7 个分一组」：
 *   真实页面里只有**周六、周日**两格写完整日期（`08月29日`），
 *   周一到周五只写 `24`、`25` 这样的数字。实测该页共 42 个完整日期
 *   （= 2 × 21 周），按 7 个一组只会得到 6 组，且取到的是**周六**而不是周一。
 *   正确做法是按 <tr> 行取：行内第一个带 title 的格子就是该周周一。
 *   若 title 缺失，退化为按行内的数字自增推算（同周内相邻天差 1 天）。
 */
import { HtmlLite, HtmlTable, HtmlRow, HtmlCell, HtmlOption } from './HtmlLite';
import { WeekDate, ChoiceItem } from '../model/Models';
import { Logger } from '../common/Logger';

export class WeekCalendarParser {
  /** 提取学年学期，如 2026-2027-1 */
  static parseSemester(html: string): string {
    const m: RegExpMatchArray | null = html.match(/(\d{4}-\d{4}-[123])/);
    return m !== null ? m[1] : '';
  }

  /**
   * 解析**当前显示**的学期代码（`<option selected>` 的那个）。
   *
   * 不能用「页面里第一个出现的学期代码」：下拉列表永远是「最新的学期在前」，
   * 所以请求「2025-2026-2」时页面里第一个出现的仍是 2026-2027-1，
   * 于是会出现**标题写着第一学期、下面画的却是第二学期的日历** ——
   * 界面上看着完全正常，信息却是错的（Flutter 端实测踩到过）。
   * 服务端会把真正显示的那个学期标成 selected，以它为准。
   */
  static parseSelectedSemester(html: string): string {
    const opts: HtmlOption[] = HtmlLite.findSelect(html, 'xnxq01id');
    for (let i = 0; i < opts.length; i++) {
      if (opts[i].selected && WeekCalendarParser.isSemesterCode(opts[i].value)) {
        return opts[i].value;
      }
    }
    // 没有任何 option 被标 selected（服务端偶尔省略）→ 退化为第一个合法选项，
    // 这仍然是「列表里的学期」而非页面正文里随手出现的数字
    for (let i = 0; i < opts.length; i++) {
      if (WeekCalendarParser.isSemesterCode(opts[i].value)) {
        return opts[i].value;
      }
    }
    return '';
  }

  /**
   * 解析「可选学期」下拉，返回服务端真正排过课的学期（新的在前）。
   *
   * 服务端的 `<select name="xnxq01id">` 只列出**有教学周历的学期**，
   * 因此这份列表是「哪些学期看得到校历」的权威答案 ——
   * 比自己按当前年份推算可靠：推算出来的学期很可能点进去什么都没有。
   */
  static parseSemesterOptions(html: string): ChoiceItem[] {
    const out: ChoiceItem[] = [];
    const opts: HtmlOption[] = HtmlLite.findSelect(html, 'xnxq01id');
    for (let i = 0; i < opts.length; i++) {
      const code: string = opts[i].value.trim();
      // 只收形如 2026-2027-1 的代码：选项里混进「全部」之类的占位值时，
      // 它会变成一个切不过去的空学期
      if (!WeekCalendarParser.isSemesterCode(code)) {
        continue;
      }
      let dup: boolean = false;
      for (let j = 0; j < out.length; j++) {
        if (out[j].value === code) {
          dup = true;
          break;
        }
      }
      if (!dup) {
        out.push(new ChoiceItem(WeekCalendarParser.semesterLabel(code), code));
      }
    }
    return out;
  }

  /** 是否是合法学期代码（2026-2027-1） */
  private static isSemesterCode(code: string): boolean {
    return /^\d{4}-\d{4}-[123]$/.test(code);
  }

  /** `2026-2027-1` → `2026-2027 学年第一学期` */
  static semesterLabel(code: string): string {
    const seg: string[] = code.split('-');
    if (seg.length !== 3) {
      return code;
    }
    const term: string = seg[2] === '1' ? '第一学期' : (seg[2] === '2' ? '第二学期' : '第三学期');
    return seg[0] + '-' + seg[1] + ' 学年' + term;
  }

  /** "YYYY-MM-DD" → Date；非法返回 null */
  static dateOf(ymd: string): Date | null {
    const seg: string[] = ymd.split('-');
    if (seg.length !== 3) {
      return null;
    }
    const y: number = parseInt(seg[0], 10);
    const m: number = parseInt(seg[1], 10);
    const d: number = parseInt(seg[2], 10);
    if (isNaN(y) || isNaN(m) || isNaN(d) || m < 1 || m > 12 || d < 1 || d > 31) {
      return null;
    }
    return new Date(y, m - 1, d);
  }

  /** "YYYY-MM-DD" 格式输出 */
  static formatYmd(d: Date): string {
    return d.getFullYear().toString() + '-' +
      WeekCalendarParser.pad2(d.getMonth() + 1) + '-' +
      WeekCalendarParser.pad2(d.getDate());
  }

  /** 从 title="2026年08月24" 里取日期；失败返回空 */
  private static dateFromTitle(tagHtml: string): string {
    const m: string[] | null = tagHtml.match(/(\d{4})年(\d{1,2})月(\d{1,2})/);
    if (m === null) {
      return '';
    }
    return m[1] + '-' + WeekCalendarParser.pad2(parseInt(m[2], 10)) +
      '-' + WeekCalendarParser.pad2(parseInt(m[3], 10));
  }

  /**
   * 提取周次—日期对照。
   * 逐行解析：行首是周次，其后第一个可确定日期的格子是周一。
   */
  static parseWeekDates(html: string): WeekDate[] {
    const out: WeekDate[] = [];
    const table: HtmlTable | null = WeekCalendarParser.findCalendarTable(html);
    if (table === null) {
      Logger.warn('week calendar: table not found');
      return out;
    }
    for (let r = 0; r < table.rows.length; r++) {
      const row: HtmlRow = table.rows[r];
      const cells: HtmlCell[] = row.cells;
      if (cells.length < 2) {
        continue;
      }
      // 行首单元格应是纯数字（第几周）
      const head: string = cells[0].text.replace(/\s+/g, '').trim();
      if (!/^\d{1,2}$/.test(head)) {
        continue;
      }
      const week: number = parseInt(head, 10);
      if (week <= 0) {
        continue;
      }
      // 该行第一个带 title 完整日期的格子即周一。
      // 页面里完整年月日只写在 td 的 title 属性中（格子文本只有 "24"），
      // 所以必须读属性而不是文本。
      let monday: string = '';
      for (let c = 1; c < cells.length; c++) {
        const d: string = WeekCalendarParser.dateFromTitle(cells[c].attr('title'));
        if (d.length > 0) {
          monday = d;
          break;
        }
      }
      if (monday.length === 0) {
        continue;
      }
      out.push(new WeekDate(week, monday));
    }
    Logger.info('week calendar parsed: weeks=' + out.length);
    return out;
  }

  /** 找周历表：表头必须含「星期一」，多张候选时取行数最多的 */
  private static findCalendarTable(html: string): HtmlTable | null {
    const tables: HtmlTable[] = HtmlLite.parseTables(html);
    let best: HtmlTable | null = null;
    let bestRows: number = 0;
    for (let i = 0; i < tables.length; i++) {
      const t: HtmlTable = tables[i];
      // 周历表的结构特征：表头里有「星期一」（页面还有「备注」列）
      let hasMonday: boolean = false;
      for (let r = 0; r < t.rows.length && r < 3; r++) {
        if (t.rows[r].text.indexOf('星期一') >= 0) {
          hasMonday = true;
          break;
        }
      }
      if (!hasMonday) {
        continue;
      }
      if (t.rows.length > bestRows) {
        bestRows = t.rows.length;
        best = t;
      }
    }
    return best;
  }

  /**
   * 依据周历与今天，推算当前是第几周（不在教学周内返回 0）。
   *
   * 用**完整日期**比较，不用 MM-dd 字符串 —— 后者在跨年时必然出错
   * （"01-02" <= "12-20" 为真，会选到错误的周）。
   *
   * 返回 0 表示「不在这个学期的教学周内」（还没开学、或已放假）。
   * 这一点很关键：只看「周一不晚于今天」的话，学期结束后会一直返回
   * 最后一周（21），于是寒暑假里界面上显示「第 21 周」——
   * 一个看起来正常、实则完全错误的数字（Flutter 端写测试时发现并修掉）。
   */
  static currentWeek(weekDates: WeekDate[], today: Date): number {
    if (weekDates.length === 0) {
      return 0;
    }
    const todayMs: number = Date.UTC(today.getFullYear(), today.getMonth(), today.getDate());
    let best: number = 0;
    for (let i = 0; i < weekDates.length; i++) {
      const ms: number = WeekCalendarParser.msOf(weekDates[i].monday);
      if (ms < 0) {
        continue;
      }
      // 该周覆盖 [周一, 周日]；今天落在这一周里才算数
      const sundayMs: number = ms + 6 * 24 * 3600 * 1000;
      if (ms <= todayMs && todayMs <= sundayMs && weekDates[i].week > best) {
        best = weekDates[i].week;
      }
    }
    return best;
  }

  /** "YYYY-MM-DD" -> UTC 毫秒；非法返回 -1 */
  private static msOf(ymd: string): number {
    const seg: string[] = ymd.split('-');
    if (seg.length !== 3) {
      return -1;
    }
    const y: number = parseInt(seg[0], 10);
    const m: number = parseInt(seg[1], 10);
    const d: number = parseInt(seg[2], 10);
    if (isNaN(y) || isNaN(m) || isNaN(d)) {
      return -1;
    }
    if (m < 1 || m > 12 || d < 1 || d > 31) {
      return -1;
    }
    return Date.UTC(y, m - 1, d);
  }

  private static pad2(n: number): string {
    return n < 10 ? '0' + n.toString() : n.toString();
  }
}
