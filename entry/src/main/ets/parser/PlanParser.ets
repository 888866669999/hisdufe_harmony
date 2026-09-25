/*
 * PlanParser：解析「培养方案明细」(/jsxsd/pyfa/topyfamx)
 *
 * 已核实页面结构：
 *   - #dataList 承载说明文本，按行给出：
 *       一、培养目标 …（培养目标正文）
 *       二、详细说明
 *       三、课程设置总表
 *     课程设置总表（#mxh）是嵌在其中的子表，解析时要跳过该行。
 *   - #mxh 为课程设置总表，双层表头：
 *       第 0 行：体系 | 选课组 | 课号 | 课程名称 | 类别 | 学分 | 学时分类 | 开设学期
 *       第 1 行：讲课学时 | 实践学时 | 讲座学时 | 实验学时 | 上机学时 | 总学时
 *     数据行列数不固定（首个体系行 13 格，同类后续行因 rowspan 只有 12 格），
 *     因此**从右侧倒推**定位列，避免按固定下标取值出错：
 *       [-1] 开设学期 [-2] 总学时 [-3] 上机 [-4] 实验 [-5] 讲座 [-6] 实践 [-7] 讲课
 *       [-8] 学分 [-9] 类别 [-10] 课程名称 [-11] 课号 [-12] 选课组 [-13] 体系(可选)
 *   - 「小计 / 合计」行为汇总，形如：小计 | 学分 | 讲课 | 实践 | 讲座 | 实验 | 上机 | 总学时
 *   - 培养方案附件是直接嵌在 iframe 里的 PDF 地址（/ewebeditor/uploadfile/xxx.pdf）
 */
import { HtmlLite, HtmlTable, HtmlRow, HtmlCell } from './HtmlLite';
import { PlanDetail, PlanCourse } from '../model/Models';
import { Logger } from '../common/Logger';

export class PlanParser {
  /** 需要单独成段的说明性段落前缀 */
  private static readonly SECTION_PREFIXES: string[] = ['一、', '二、', '三、', '四、', '五、'];

  static parse(html: string): PlanDetail {
    const plan: PlanDetail = new PlanDetail();

    PlanParser.parseIntro(html, plan);
    PlanParser.parseCourses(html, plan);
    plan.pdfPath = PlanParser.parsePdfPath(html);
    plan.buildGroups();

    Logger.info('plan parsed: courses=' + plan.courses.length + ' groups=' + plan.groups.length +
      ' paragraphs=' + plan.introParagraphs.length + ' pdf=' + (plan.pdfPath.length > 0 ? 'yes' : 'no'));
    return plan;
  }

  /** 取培养目标等说明段落 */
  private static parseIntro(html: string, plan: PlanDetail): void {
    const dl: HtmlTable | null = HtmlLite.findTableById(html, 'dataList');
    if (dl === null) {
      return;
    }
    for (let r = 0; r < dl.rows.length; r++) {
      const row: HtmlRow = dl.rows[r];
      const text: string = row.text.replace(/\s+/g, ' ').trim();
      if (text.length === 0) {
        continue;
      }
      // 课程设置总表是嵌套子表，其内容由 parseCourses 单独处理，这里跳过
      if (PlanParser.isCourseTableRow(text)) {
        continue;
      }
      let isSection: boolean = false;
      for (let i = 0; i < PlanParser.SECTION_PREFIXES.length; i++) {
        if (text.indexOf(PlanParser.SECTION_PREFIXES[i]) === 0) {
          isSection = true;
          break;
        }
      }
      if (!isSection) {
        continue;
      }
      // 三、课程设置总表 只是标题，正文在子表里
      if (text.indexOf('课程设置总表') >= 0) {
        continue;
      }
      if (text.indexOf('培养目标') >= 0 && plan.introParagraphs.length === 0) {
        // 形如「一、培养目标 本专业培养…」，去掉标题留正文
        const body: string = PlanParser.stripHeading(text);
        if (body.length > 0) {
          plan.introParagraphs.push(body);
        }
      } else {
        const body: string = PlanParser.stripHeading(text);
        if (body.length > 0) {
          plan.detailParagraphs.push(body);
        }
      }
    }
  }

  /** 该行是否是课程设置总表的表头（其内容由 parseCourses 单独处理） */
  private static isCourseTableRow(rowText: string): boolean {
    return rowText.indexOf('学时分类') >= 0 && rowText.indexOf('开设学期') >= 0;
  }

  /** 去掉「一、培养目标」这类编号标题 */
  private static stripHeading(text: string): string {
    let t: string = text;
    for (let i = 0; i < PlanParser.SECTION_PREFIXES.length; i++) {
      if (t.indexOf(PlanParser.SECTION_PREFIXES[i]) === 0) {
        t = t.substring(PlanParser.SECTION_PREFIXES[i].length);
        break;
      }
    }
    // 再削掉「培养目标」这类小标题（其后紧跟正文）
    const known: string[] = ['培养目标', '详细说明'];
    for (let i = 0; i < known.length; i++) {
      if (t.indexOf(known[i]) === 0) {
        t = t.substring(known[i].length);
        break;
      }
    }
    return t.trim();
  }

  /** 解析课程设置总表 */
  private static parseCourses(html: string, plan: PlanDetail): void {
    const mx: HtmlTable | null = HtmlLite.findTableById(html, 'mxh');
    if (mx === null) {
      Logger.warn('plan course table #mxh not found');
      return;
    }

    let currentSystem: string = '';
    for (let r = 0; r < mx.rows.length; r++) {
      const row: HtmlRow = mx.rows[r];
      const cells: HtmlCell[] = row.cells;
      if (cells.length === 0) {
        continue;
      }
      const first: string = cells[0].text.replace(/\s+/g, '').trim();

      // 表头行：跳过
      if (first === '体系' || first === '讲课学时') {
        continue;
      }

      // 汇总行
      if (first === '小计' || first === '合计' || first.indexOf('小计') === 0 ||
        first.indexOf('合计') === 0) {
        PlanParser.readTotals(cells, plan, first);
        continue;
      }

      // 数据行：从右侧倒推取字段
      if (cells.length < 11) {
        continue;
      }
      const course: PlanCourse = new PlanCourse();
      const n: number = cells.length;
      course.semester = PlanParser.at(cells, n - 1);
      course.totalHours = PlanParser.at(cells, n - 2);
      course.computerHours = PlanParser.at(cells, n - 3);
      course.labHours = PlanParser.at(cells, n - 4);
      course.seminarHours = PlanParser.at(cells, n - 5);
      course.practiceHours = PlanParser.at(cells, n - 6);
      course.lectureHours = PlanParser.at(cells, n - 7);
      course.credit = PlanParser.at(cells, n - 8);
      course.category = PlanParser.at(cells, n - 9);
      course.courseName = PlanParser.at(cells, n - 10);
      course.courseCode = PlanParser.at(cells, n - 11);
      course.group = n >= 12 ? PlanParser.at(cells, n - 12) : '';
      // 体系列只在分组首行出现（后续行因 rowspan 为空），需要向下继承
      const sysCell: string = n >= 13 ? PlanParser.at(cells, n - 13) : '';
      if (sysCell.length > 0) {
        currentSystem = sysCell;
      }
      course.system = currentSystem;

      if (course.courseName.length === 0) {
        continue;
      }
      plan.courses.push(course);
    }
  }

  /** 读取小计/合计行 */
  private static readTotals(cells: HtmlCell[], plan: PlanDetail, label: string): void {
    // 形如：小计 | 学分 | 讲课 | 实践 | 讲座 | 实验 | 上机 | 总学时
    const credit: number = PlanParser.numAt(cells, 1);
    const hours: number = PlanParser.numAt(cells, 7);
    if (label.indexOf('合计') === 0) {
      if (credit > 0) {
        plan.totalCredit = credit;
      }
      if (hours > 0) {
        plan.totalHours = hours;
      }
      return;
    }
    // 小计：用于兜底合计
    plan.totalCredit += credit;
    plan.totalHours += hours;
  }

  /**
   * 取 PDF 相对地址。页面里的形态是 iframe 的 src，例如：
   *   <iframe src="/ewebeditor/uploadfile/2025033110250359448.pdf">
   * 这里直接匹配路径本身，避免依赖引号与属性的排列顺序。
   */
  private static parsePdfPath(html: string): string {
    const m: string[] | null = html.match(/\/[A-Za-z0-9_\/.-]*uploadfile\/[A-Za-z0-9_.%-]+\.pdf/i);
    if (m !== null && m.length > 0 && m[0].length > 0) {
      return m[0];
    }
    // 兜底：任意位置的 .pdf 路径
    const m2: string[] | null = html.match(/[A-Za-z0-9_\/.-]+\.pdf/i);
    return (m2 !== null && m2.length > 0) ? m2[0] : '';
  }

  private static at(cells: HtmlCell[], i: number): string {
    if (i < 0 || i >= cells.length) {
      return '';
    }
    return cells[i].text.replace(/\s+/g, ' ').trim();
  }

  private static numAt(cells: HtmlCell[], i: number): number {
    const s: string = PlanParser.at(cells, i);
    const v: number = parseFloat(s);
    return isNaN(v) ? 0 : v;
  }
}
