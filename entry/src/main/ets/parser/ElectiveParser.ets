/*
 * ElectiveParser：解析「通选课修读情况」(/jsxsd/xxwcqk/xstxkxdqk.do)
 *
 * 已核实页面结构（两张表，均无 id，按表头文本定位）：
 *   表 1：类别 | 要求学分（大于等于）| 已修学分 | 正在修读
 *         末行为「总学分」汇总
 *   表 2：课程编号 | 课程名称 | 学分 | 总成绩 | 通选课类别
 *         未出成绩的行，「总成绩」为「正在修读」
 *
 * 注意：本校数据里「要求学分」列当前是空的（学校未录入），
 * 因此不能据此判断是否达标，只能原样展示，并在界面标注「学校未设置要求」。
 */
import { HtmlLite, HtmlTable, HtmlRow, HtmlCell } from './HtmlLite';
import { ElectiveReport, ElectiveCategory, ElectiveCourse } from '../model/Models';
import { Logger } from '../common/Logger';

export class ElectiveParser {
  static parse(html: string): ElectiveReport {
    const report: ElectiveReport = new ElectiveReport();
    ElectiveParser.parseCategories(html, report);
    ElectiveParser.parseCourses(html, report);
    Logger.info('elective parsed: categories=' + report.categories.length +
      ' courses=' + report.courses.length + ' earned=' + report.totalEarned);
    return report;
  }

  /** 解析类别要求表 */
  private static parseCategories(html: string, report: ElectiveReport): void {
    const t: HtmlTable | null = ElectiveParser.findTable(html, '要求学分');
    if (t === null) {
      // 表头可能写作「要求学分（大于等于）」或「要求学分」，做一次宽松查找
      Logger.warn('elective category table not found');
      return;
    }
    for (let r = 0; r < t.rows.length; r++) {
      const row: HtmlRow = t.rows[r];
      const cells: HtmlCell[] = row.cells;
      if (cells.length < 4) {
        continue;
      }
      const name: string = ElectiveParser.text(cells, 0);
      if (name.length === 0 || name === '类别') {
        continue;
      }
      const required: string = ElectiveParser.text(cells, 1);
      const earned: string = ElectiveParser.text(cells, 2);
      const ongoing: string = ElectiveParser.text(cells, 3);

      // 末行汇总
      if (name.indexOf('总学分') >= 0) {
        report.totalEarned = earned;
        report.totalOngoing = ongoing;
        continue;
      }
      const c: ElectiveCategory = new ElectiveCategory();
      c.name = name;
      c.required = required;
      c.earned = earned;
      c.ongoing = ongoing;
      report.categories.push(c);
    }
  }

  /** 解析已修课程明细表 */
  private static parseCourses(html: string, report: ElectiveReport): void {
    const t: HtmlTable | null = ElectiveParser.findTable(html, '通选课类别');
    if (t === null) {
      Logger.warn('elective course table not found');
      return;
    }
    for (let r = 0; r < t.rows.length; r++) {
      const row: HtmlRow = t.rows[r];
      const cells: HtmlCell[] = row.cells;
      if (cells.length < 5) {
        continue;
      }
      const code: string = ElectiveParser.text(cells, 0);
      if (code === '课程编号' || code.length === 0) {
        continue;
      }
      const c: ElectiveCourse = new ElectiveCourse();
      c.courseCode = code;
      c.courseName = ElectiveParser.text(cells, 1);
      c.credit = ElectiveParser.text(cells, 2);
      c.score = ElectiveParser.text(cells, 3);
      c.category = ElectiveParser.text(cells, 4);
      if (c.courseName.length === 0) {
        continue;
      }
      report.courses.push(c);
    }
  }

  /** 按表头关键字定位表格 */
  private static findTable(html: string, headerKeyword: string): HtmlTable | null {
    return HtmlLite.findTableByHeader(html, headerKeyword);
  }

  private static text(cells: HtmlCell[], i: number): string {
    if (i < 0 || i >= cells.length) {
      return '';
    }
    return cells[i].text.replace(/\s+/g, ' ').trim();
  }
}
