/*
 * 成绩解析器：解析「课程成绩查询」结果页 (/jsxsd/kscj/cjcx_list)
 *
 * 已核实表头：序号 / 开课学期 / 课程编号 / 课程名称 / 成绩 / 学分 / 绩点 / 考试性质 / 课程性质 / 课程属性 / 辅修课程
 */
import { HtmlLite, HtmlTable, HtmlRow, HtmlCell, HtmlOption } from './HtmlLite';
import { ScoreRecord, ScoreSummary, ChoiceItem } from '../model/Models';
import { Logger } from '../common/Logger';

/** 成绩表列索引 */
class ScoreCols {
  index: number = 0;
  semester: number = 1;
  courseCode: number = 2;
  courseName: number = 3;
  score: number = 4;
  credit: number = 5;
  gpa: number = 6;
  examType: number = 7;
  courseNature: number = 8;
  courseAttr: number = 9;
  minor: number = 10;
}

export class ScoreParser {
  static parse(html: string): ScoreRecord[] {
    const out: ScoreRecord[] = [];
    const table: HtmlTable | null = ScoreParser.locateTable(html);
    if (table === null) {
      Logger.warn('score table not found');
      return out;
    }
    // 找表头行，并据此定位各列（不写死列序，便于兼容其他强智版本）
    let headerRow: number = -1;
    for (let i = 0; i < table.rows.length && i < 4; i++) {
      if (table.rows[i].text.indexOf('课程名称') >= 0) {
        headerRow = i;
        break;
      }
    }
    if (headerRow < 0) {
      return out;
    }
    const col: ScoreCols = ScoreParser.resolveCols(table.rows[headerRow]);

    for (let r = headerRow + 1; r < table.rows.length; r++) {
      const row: HtmlRow = table.rows[r];
      if (row.cells.length < 5) {
        continue;
      }
      const cells: HtmlCell[] = row.cells;
      // 空态：只有一个“未查询到数据”
      if (cells.length === 1 || /未查询到数据/.test(row.text)) {
        continue;
      }
      const rec: ScoreRecord = new ScoreRecord();
      rec.index = ScoreParser.at(cells, col.index);
      rec.semester = ScoreParser.at(cells, col.semester);
      rec.courseCode = ScoreParser.at(cells, col.courseCode);
      rec.courseName = ScoreParser.at(cells, col.courseName);
      rec.score = ScoreParser.at(cells, col.score);
      rec.credit = ScoreParser.at(cells, col.credit);
      rec.gpa = ScoreParser.at(cells, col.gpa);
      rec.examType = ScoreParser.at(cells, col.examType);
      rec.courseNature = ScoreParser.at(cells, col.courseNature);
      rec.courseAttr = ScoreParser.at(cells, col.courseAttr);
      rec.minor = ScoreParser.at(cells, col.minor);
      if (rec.courseName.length === 0) {
        continue;
      }
      out.push(rec);
    }
    Logger.info('score records parsed: ' + out.length);
    return out;
  }

  /** 按表头文本定位列索引；找不到时保留默认位置 */
  private static resolveCols(header: HtmlRow): ScoreCols {
    const c: ScoreCols = new ScoreCols();
    const pick = (names: string[], def: number): number => {
      const i: number = ScoreParser.findCol(header, names);
      return i >= 0 ? i : def;
    };
    c.index = pick(['序号'], 0);
    c.semester = pick(['开课学期', '学期'], 1);
    c.courseCode = pick(['课程编号', '课程代码'], 2);
    c.courseName = pick(['课程名称', '课程名'], 3);
    c.score = pick(['成绩'], 4);
    c.credit = pick(['学分'], 5);
    c.gpa = pick(['绩点'], 6);
    c.examType = pick(['考试性质'], 7);
    c.courseNature = pick(['课程性质'], 8);
    c.courseAttr = pick(['课程属性'], 9);
    c.minor = pick(['辅修'], 10);
    return c;
  }

  private static findCol(header: HtmlRow, names: string[]): number {
    // 先精确匹配，避免「学分」误命中「平均学分绩点」这类包含关系
    for (let n = 0; n < names.length; n++) {
      for (let i = 0; i < header.cells.length; i++) {
        if (header.cells[i].text.trim() === names[n]) {
          return i;
        }
      }
    }
    for (let n = 0; n < names.length; n++) {
      for (let i = 0; i < header.cells.length; i++) {
        if (header.cells[i].text.indexOf(names[n]) >= 0) {
          return i;
        }
      }
    }
    return -1;
  }

  private static at(cells: HtmlCell[], i: number): string {
    if (i < 0 || i >= cells.length) {
      return '';
    }
    return cells[i].text.replace(/\s+/g, ' ').trim();
  }

  /** 汇总：总学分与学分加权平均绩点（客户端计算） */
  static summarize(records: ScoreRecord[]): ScoreSummary {
    const s: ScoreSummary = new ScoreSummary();
    s.count = records.length;
    let creditSum: number = 0;
    let weighted: number = 0;
    for (let i = 0; i < records.length; i++) {
      const r: ScoreRecord = records[i];
      const c: number = r.creditNumber();
      creditSum += c;
      const g: number = r.gpaNumber();
      if (g >= 0) {
        weighted += g * c;
      }
    }
    s.totalCredit = Math.round(creditSum * 100) / 100;
    s.weightedGpa = creditSum > 0 ? Math.round((weighted / creditSum) * 1000) / 1000 : 0;
    return s;
  }

  /** 读取学期下拉（用于筛选），仅保留有值的项 */
  static readSemesters(html: string): ChoiceItem[] {
    return ScoreParser.toOptions(HtmlLite.findSelect(html, 'kksj'));
  }

  /** 把原始 option 转成模型，过滤空值项 */
  private static toOptions(raw: HtmlOption[]): ChoiceItem[] {
    const out: ChoiceItem[] = [];
    for (let i = 0; i < raw.length; i++) {
      if (raw[i].value.length > 0) {
        out.push(new ChoiceItem(raw[i].label, raw[i].value));
      }
    }
    return out;
  }

  private static locateTable(html: string): HtmlTable | null {
    // 优先按表头关键字定位，避免依赖表格顺序
    const t: HtmlTable | null = HtmlLite.findTableByHeader(html, '课程名称');
    if (t !== null) {
      return t;
    }
    return HtmlLite.findTableById(html, 'dataList');
  }
}
