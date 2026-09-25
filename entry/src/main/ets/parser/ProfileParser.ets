/*
 * 个人信息解析器：解析「学籍卡片」(/jsxsd/grxx/xsxx)，表格 id = xjkpTable
 *
 * 已核实内容形如：
 *   | 学 籍 卡 片 |
 *   | 院系：计算机与人工智能学院 | 专业：... | 学制：4 | 班级：... | 学号：... |
 *   | 姓名 | 张xx | 性别 | 男 | 姓名拼音 | ZhangXx | ... |
 *   | 出生日期 | 20000101 | 婚否 | | 本人电话 | |
 *   | 民族 | 汉族 | 政治面貌 | 群众 | 学习层次 | 本科 |
 *
 * 页面是「标签/值」成对出现的多列表格，且存在同一单元格内多组「a：b」的情况，
 * 因此这里做两种提取：按冒号切分，和按相邻单元格成对读取。
 */
import { HtmlLite, HtmlTable, HtmlRow, HtmlCell } from './HtmlLite';
import { StudentProfile, ProfileSection, ProfileField } from '../model/Models';
import { Logger } from '../common/Logger';

export class ProfileParser {
  /** 需要单独成组的字段 */
  private static readonly BASIC_KEYS: string[] = [
    '院系', '专业', '学制', '班级', '学号', '姓名', '性别', '姓名拼音',
    '出生日期', '民族', '政治面貌', '学习层次', '学习形式', '外语种类', '籍贯', '婚否'
  ];

  static parse(html: string): StudentProfile {
    const p: StudentProfile = new StudentProfile();
    const table: HtmlTable | null = HtmlLite.findTableById(html, 'xjkpTable');
    if (table === null) {
      Logger.warn('xjkpTable not found');
      return p;
    }

    const basic: ProfileField[] = [];
    /**
     * 上一行是否为分节标题。为真时，当前行是子表的**列名行**，
     * 不能按「相邻两格 = 标签/值」解析（否则会产生 `起止年月=学校或工作单位`
     * 这类伪字段）。见 isSectionTitleRow 的说明。
     */
    let afterSectionTitle: boolean = false;

    for (let r = 0; r < table.rows.length; r++) {
      const row: HtmlRow = table.rows[r];
      const cells: HtmlCell[] = row.cells;

      // 分节标题行：标记下一行是列名行，并跳过本行
      if (ProfileParser.isSectionTitleRow(cells)) {
        afterSectionTitle = true;
        continue;
      }

      // 形态一：单元格内含 "标签：值"
      for (let c = 0; c < cells.length; c++) {
        const text: string = cells[c].text.replace(/\s+/g, ' ').trim();
        if (text.length === 0 || text.indexOf('：') < 0) {
          continue;
        }
        // 一个单元格可能有多组，如 "院系：A 专业：B"
        ProfileParser.pullColonPairs(text, basic);
      }

      // 形态二：相邻单元格成对（标签在左，值在右）。
      // 紧跟分节标题的那一行是列名行，跳过。
      if (afterSectionTitle) {
        afterSectionTitle = false;
        continue;
      }
      ProfileParser.pullAdjacentPairs(cells, basic);
    }

    // 去重，保持首次出现顺序
    const seen: string[] = [];
    const dedup: ProfileField[] = [];
    for (let i = 0; i < basic.length; i++) {
      const f: ProfileField = basic[i];
      if (f.label.length === 0 || f.value.length === 0) {
        continue;
      }
      let dup: boolean = false;
      for (let j = 0; j < seen.length; j++) {
        if (seen[j] === f.label) {
          dup = true;
          break;
        }
      }
      if (!dup) {
        seen.push(f.label);
        dedup.push(f);
      }
    }

    // 抽取姓名/学号
    for (let i = 0; i < dedup.length; i++) {
      if (dedup[i].label === '姓名' && p.name.length === 0) {
        p.name = dedup[i].value;
      }
      if (dedup[i].label === '学号' && p.studentId.length === 0) {
        p.studentId = dedup[i].value;
      }
    }

    // 分组：基础信息 一组，其余按出现顺序每 6 条一组
    const head: ProfileField[] = [];
    const rest: ProfileField[] = [];
    for (let i = 0; i < dedup.length; i++) {
      if (ProfileParser.isBasic(dedup[i].label)) {
        head.push(dedup[i]);
      } else {
        rest.push(dedup[i]);
      }
    }
    if (head.length > 0) {
      p.sections.push(new ProfileSection('基本信息', head));
    }
    let chunk: ProfileField[] = [];
    for (let i = 0; i < rest.length; i++) {
      chunk.push(rest[i]);
      if (chunk.length === 6) {
        p.sections.push(new ProfileSection('其他信息', chunk));
        chunk = [];
      }
    }
    if (chunk.length > 0) {
      p.sections.push(new ProfileSection('其他信息', chunk));
    }

    Logger.info('profile parsed: fields=' + dedup.length + ' sections=' + p.sections.length);
    return p;
  }

  private static isBasic(label: string): boolean {
    for (let i = 0; i < ProfileParser.BASIC_KEYS.length; i++) {
      if (ProfileParser.BASIC_KEYS[i] === label) {
        return true;
      }
    }
    return false;
  }

  /** 从 "院系：A 专业：B" 里提取多组标签值 */
  private static pullColonPairs(text: string, sink: ProfileField[]): void {
    const normalized: string = text.replace(/\s+/g, ' ');
    // 用中文冒号切分，成对取
    const segments: string[] = normalized.split('：');
    if (segments.length < 2) {
      return;
    }
    // segments[0] 是第一个标签，其后每段：值 + 下一个标签
    let label: string = ProfileParser.lastLabel(segments[0]);
    for (let i = 1; i < segments.length; i++) {
      const seg: string = segments[i].trim();
      if (seg.length === 0) {
        continue;
      }
      // 分离 "值 下一个标签"
      const m: RegExpMatchArray | null = seg.match(/^(.+?)\s+([\u4e00-\u9fa5A-Za-z]{2,10})$/);
      let value: string = seg;
      let nextLabel: string = '';
      if (m !== null) {
        value = m[1].trim();
        nextLabel = m[2].trim();
      }
      if (label.length > 0 && value.length > 0) {
        sink.push(new ProfileField(label, value));
      }
      label = nextLabel.length > 0 ? nextLabel : '';
    }
  }

  /** 从 "院系：..." 里取 "院系"；若没有冒号则整段作为标签 */
  private static lastLabel(head: string): string {
    const t: string = head.trim();
    if (t.length === 0) {
      return '';
    }
    // 去掉冒号后整段作为标签。
    // 早先用正则只匹配「末尾 2-10 个连续汉字」，遇到含括号的标签会被截断：
    // "毕(结)业证书号" 会变成 "业证书号" —— 括号打断了连续汉字。
    let s: string = t;
    const colon: number = s.indexOf('：');
    if (colon > 0) {
      s = s.substring(0, colon);
    }
    s = s.trim();
    if (s.length === 0 || s.length > 12) {
      return s.length > 12 ? t : s;
    }
    return s;
  }

  /**
   * 该行是否是「分节标题」行（形如 `学 籍 卡 片`、`学 习 及 工 作 简 历`、`家 庭 成 员 情 况`）。
   *
   * 为什么需要判断：学籍卡片里嵌了若干子表（工作简历/家庭成员/异动/奖励/处分），
   * 每个子表前面有一行合并单元格的分节标题，紧随其后的就是该子表的**列名行**
   * （如 `起止年月 | 学 校 或 工 作 单 位 | 职务`）。
   * 若把列名行也按「相邻两格 = 标签/值」解析，就会生成
   * `起止年月=学 校 或 工 作 单 位` 这类伪字段。
   *
   * 判据（只用结构，不猜内容）：整行只有 1 个非空格子，
   * 且该文本较短、不含数字与冒号。这正是分节标题的形态；
   * 而真实字段行（如 `籍贯 | 空`）虽然也可能只剩 1 个非空格子，
   * 但它是 2 个字且靠左，这里通过「至少 3 个字」把它排除。
   */
  private static isSectionTitleRow(cells: HtmlCell[]): boolean {
    let nonEmpty: number = 0;
    let text: string = '';
    for (let i = 0; i < cells.length; i++) {
      const t: string = cells[i].text.replace(/\s+/g, ' ').trim();
      if (t.length > 0) {
        nonEmpty++;
        text = t;
      }
    }
    if (nonEmpty !== 1) {
      return false;
    }
    if (text.length < 3 || text.length > 16) {
      return false;
    }
    if (/\d/.test(text) || text.indexOf('：') >= 0) {
      return false;
    }
    return true;
  }

  /** 相邻单元格成对：如 | 姓名 | 张xx | 性别 | 男 | */
  private static pullAdjacentPairs(cells: HtmlCell[], sink: ProfileField[]): void {
    if (cells.length < 2) {
      return;
    }
    let i: number = 0;
    while (i + 1 < cells.length) {
      const label: string = cells[i].text.replace(/\s+/g, ' ').trim();
      const value: string = cells[i + 1].text.replace(/\s+/g, ' ').trim();
      const labelClean: string = ProfileParser.lastLabel(label);
      const isLabel: boolean = labelClean.length > 0 && label.length <= 12 &&
        label.indexOf('：') < 0 && !/^\d+$/.test(labelClean);
      if (isLabel) {
        sink.push(new ProfileField(labelClean, value));
        i += 2;
      } else {
        i++;
      }
    }
  }
}
