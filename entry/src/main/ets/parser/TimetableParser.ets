/*
 * 课表解析器：解析「学期理论课表」页面 (/jsxsd/xskb/xskb_list.do)
 *
 * 已核实的页面结构：
 *   - 表格 #kbtable，第 0 行为表头：星期一..星期日
 *   - 第 1..5 行分别为节次：第一、二节 / 第三、四节 / 第五、六节 / 第七、八节 / 第九~十一节
 *   - 末行为备注（#bz_td，colspan=7），列出未排课表课程
 *   - 每个课程格内是两个同内容的 div：
 *       class="kbcontent1" 简略（课程名 / 周次 / 教室）
 *       class="kbcontent"  详细（多出教师）
 *     两者都用带语义的 font 承载字段：
 *       <font title="老师">张老师</font>
 *       <font title="周次(节次)">1-18(双周)</font>
 *       <font title="教室">7-120(章丘)</font>
 *   - 同一格可含多门课，以连续短横线分隔
 *
 * 因此优先按 font 语义属性提取（稳定），文本行启发式为兜底（兼容其他强智版本）。
 */
import { HtmlLite, HtmlTable, HtmlRow, HtmlCell } from './HtmlLite';
import { Timetable, CellData, CourseEntry } from '../model/Models';
import { Logger } from '../common/Logger';

/** 一个语义化 font 片段 */
class FontInfo {
  title: string;
  text: string;

  constructor(title: string, text: string) {
    this.title = title;
    this.text = text;
  }
}

export class TimetableParser {
  /** 节次行数 */
  private static readonly SECTION_COUNT: number = 5;
  /** 多门课的分隔符（页面为连续短横线） */
  private static readonly SPLIT_RE: RegExp = /-{6,}/;

  static parse(html: string): Timetable {
    const tt: Timetable = new Timetable();

    tt.semesters = TimetableParser.readOptions(html, 'xnxq01id');
    tt.weeks = TimetableParser.readOptions(html, 'zc');
    tt.semester = TimetableParser.readSelected(html, 'xnxq01id');
    tt.week = TimetableParser.readSelected(html, 'zc');

    const table: HtmlTable | null = HtmlLite.findTableById(html, 'kbtable');
    if (table === null) {
      Logger.warn('timetable table #kbtable not found');
      return tt;
    }

    // 逐行解析：第 0 行为星期表头，其后为 5 个节次行，末行为备注
    let sectionRow: number = 0;
    for (let r = 1; r < table.rows.length; r++) {
      const row: HtmlRow = table.rows[r];

      // 备注行要先判断，否则会被当成节次行
      if (TimetableParser.isRemarkRow(row)) {
        tt.remark = TimetableParser.remarkText(row);
        continue;
      }
      if (row.cells.length < 2 || sectionRow >= TimetableParser.SECTION_COUNT) {
        continue;
      }

      // 第 0 列是节次标签，第 1..7 列为星期一到星期日
      for (let c = 1; c < row.cells.length && c <= 7; c++) {
        const entries: CourseEntry[] = TimetableParser.parseCell(row.cells[c]);
        if (entries.length > 0) {
          const cd: CellData = new CellData();
          cd.row = sectionRow;
          cd.col = c - 1;
          cd.entries = entries;
          tt.cells.push(cd);
        }
      }
      sectionRow++;
    }

    Logger.info('timetable parsed: cells=' + tt.cells.length + ' semesters=' + tt.semesters.length +
      ' weeks=' + tt.weeks.length + ' remark=' + (tt.remark.length > 0 ? 'yes' : 'no'));
    TimetableParser.assignIds(tt);
    return tt;
  }

  /**
   * 给每门课分配稳定 ID。
   * 用「格位置 + 课程名 + 周次规则」组成，保证同一份服务器数据每次解析得到相同 ID，
   * 这样本地修改能准确对应到某一门课，而不会因为顺序变化错位。
   */
  private static assignIds(tt: Timetable): void {
    for (let i = 0; i < tt.cells.length; i++) {
      const cell: CellData = tt.cells[i];
      for (let j = 0; j < cell.entries.length; j++) {
        const e: CourseEntry = cell.entries[j];
        if (e.id.length === 0) {
          e.id = 'srv-' + cell.row.toString() + '-' + cell.col.toString() + '-' +
            e.courseName + '-' + e.startWeek.toString() + '-' + e.endWeek.toString() + '-' + e.parity.toString();
        }
      }
    }
  }

  /** 备注行：只有「备注」标签 + 一个大 colspan 单元格 */
  private static isRemarkRow(row: HtmlRow): boolean {
    if (row.cells.length === 1) {
      return row.cells[0].colspan >= 5 || row.cells[0].id === 'bz_td';
    }
    if (row.cells.length === 2) {
      return /备注/.test(row.cells[0].text) || row.cells[1].id === 'bz_td';
    }
    return false;
  }

  private static remarkText(row: HtmlRow): string {
    for (let i = 0; i < row.cells.length; i++) {
      const c: HtmlCell = row.cells[i];
      if (c.id === 'bz_td' || (c.colspan >= 5 && c.text.length > 0)) {
        return c.text.replace(/\s+/g, ' ').trim();
      }
    }
    for (let i = 0; i < row.cells.length; i++) {
      const t: string = row.cells[i].text;
      if (t.indexOf('备注') < 0 && t.length > 0) {
        return t.replace(/\s+/g, ' ').trim();
      }
    }
    return '';
  }

  /**
   * 解析一个课程格，可能含多门课。
   *
   * 关键：格内同时存在 kbcontent1（简略）与 kbcontent（详细）两个 div，
   * **两者包含完全相同的课程**（详细层多一个教师字段），由页面「放大」复选框切换显示。
   * 因此必须只选其中一层来切分，否则同一门课会被解析出两份。
   */
  private static parseCell(cell: HtmlCell): CourseEntry[] {
    const result: CourseEntry[] = [];
    const block: string = TimetableParser.pickBlock(cell.inner);
    if (block.length === 0) {
      return result;
    }
    // 在一层之内按分隔符切出多门课
    const segments: string[] = block.split(TimetableParser.SPLIT_RE);
    for (let i = 0; i < segments.length; i++) {
      const entry: CourseEntry | null = TimetableParser.parseSegment(segments[i]);
      if (entry !== null) {
        result.push(entry);
      }
    }
    return result;
  }

  /** 解析一段（一门课）的 HTML 片段，优先用语义化 font，失败则退回文本启发式 */
  private static parseSegment(segHtml: string): CourseEntry | null {
    const block: string = segHtml;
    if (block.replace(/<[^>]*>/g, '').replace(/[\s\u00a0\u3000]/g, '').length === 0) {
      return null;
    }

    const e: CourseEntry = new CourseEntry();
    const fonts: FontInfo[] = TimetableParser.parseFonts(block);

    for (let i = 0; i < fonts.length; i++) {
      const f: FontInfo = fonts[i];
      if (f.title.indexOf('老师') >= 0 || f.title.indexOf('教师') >= 0) {
        if (e.teacher.length === 0) {
          e.teacher = f.text;
        }
      } else if (f.title.indexOf('周次') >= 0 || f.title.indexOf('节次') >= 0) {
        if (e.weekText.length === 0) {
          e.weekText = f.text;
          TimetableParser.parseWeekRange(f.text, e);
        }
      } else if (f.title.indexOf('教室') >= 0 || f.title.indexOf('地点') >= 0) {
        if (e.room.length === 0) {
          TimetableParser.splitRoom(f.text, e);
        }
      }
    }

    // 课程名 = 去掉所有 font 与换行标签后的首段文本
    const withoutFonts: string = block.replace(/<font[\s\S]*?<\/font>/gi, '');
    const nameText: string = HtmlLite.toText(withoutFonts).split('\n')[0].trim();
    e.courseName = nameText;

    // 语义属性不完整时，用文本行补齐
    if (e.courseName.length === 0 || e.weekText.length === 0 || e.room.length === 0) {
      TimetableParser.fillFromText(block, e);
    }

    if (e.courseName.length === 0) {
      return null;
    }
    return e;
  }

  /**
   * 取格内用于解析的 HTML 块。
   * 优先详细层（含教师），其次简略层，最后整段兜底。
   */
  private static pickBlock(segHtml: string): string {
    const divs: string[] = HtmlLite.findAll(segHtml, 'div');
    let detailed: string = '';
    let simple: string = '';
    for (let i = 0; i < divs.length; i++) {
      const d: string = divs[i];
      const cls: string = HtmlLite.attr(d.substring(0, Math.max(0, d.indexOf('>') + 1)), 'class');
      if (cls.indexOf('kbcontent1') >= 0) {
        if (simple.length === 0) {
          simple = d;
        }
      } else if (cls.indexOf('kbcontent') >= 0) {
        if (detailed.length === 0) {
          detailed = d;
        }
      }
    }
    if (detailed.length > 0) {
      return TimetableParser.inner(detailed);
    }
    if (simple.length > 0) {
      return TimetableParser.inner(simple);
    }
    return segHtml;
  }

  /** 取元素内部 HTML */
  private static inner(outer: string): string {
    const gt: number = outer.indexOf('>');
    const closeIdx: number = outer.toLowerCase().lastIndexOf('</');
    return gt >= 0 && closeIdx > gt ? outer.substring(gt + 1, closeIdx) : outer;
  }

  /** 提取所有带 title 的 font 片段 */
  private static parseFonts(html: string): FontInfo[] {
    const out: FontInfo[] = [];
    const fonts: string[] = HtmlLite.findAll(html, 'font');
    for (let i = 0; i < fonts.length; i++) {
      const f: string = fonts[i];
      const gt: number = f.indexOf('>');
      const openTag: string = gt > 0 ? f.substring(0, gt + 1) : f;
      const title: string = HtmlLite.attr(openTag, 'title');
      const closeIdx: number = f.toLowerCase().lastIndexOf('</font');
      const body: string = gt >= 0 && closeIdx > gt ? f.substring(gt + 1, closeIdx) : '';
      const text: string = HtmlLite.toText(body).replace(/\n/g, ' ').trim();
      if (title.length > 0 && text.length > 0) {
        out.push(new FontInfo(title, text));
      }
    }
    return out;
  }

  /** 文本启发式补全（用于语义属性缺失的强智版本） */
  private static fillFromText(block: string, e: CourseEntry): void {
    const lines: string[] = HtmlLite.toText(block).split('\n');
    const cleaned: string[] = [];
    for (let i = 0; i < lines.length; i++) {
      const t: string = lines[i].replace(/[\u00a0\u3000]/g, ' ').trim();
      if (t.length > 0) {
        cleaned.push(t);
      }
    }
    // 逐行尝试拆分「课程名+教师+周次」这类粘连文本
    for (let i = 0; i < cleaned.length; i++) {
      const line: string = cleaned[i];
      if (e.weekText.length === 0) {
        const wk: RegExpMatchArray | null = line.match(/\d+\s*[-—~]+\s*\d+\s*\(\s*(单|双)?周\s*\)|\(\s*(单|双)?周\s*\)/);
        if (wk !== null) {
          e.weekText = wk[0];
          TimetableParser.parseWeekRange(wk[0], e);
        }
      }
      if (e.room.length === 0) {
        // 期望形如 7-120(章丘)
        const rm: RegExpMatchArray | null = line.match(/([0-9A-Za-z\-]+)\s*\(\s*([\u4e00-\u9fa5]{2,6})\s*\)/);
        if (rm !== null && /^\d/.test(rm[1])) {
          e.room = rm[1];
          e.campus = rm[2];
        }
      }
      if (e.courseName.length === 0) {
        // 课程名取到第一个「周次」或「教室」出现之前
        let name: string = line;
        const cut: number = TimetableParser.firstCut(name);
        if (cut > 0) {
          name = name.substring(0, cut);
        }
        name = name.replace(/[\d\-—~]+\(\s*(单|双)?周\s*\)/g, '').trim();
        if (name.length > 0) {
          e.courseName = name;
        }
      } else if (e.teacher.length === 0 && TimetableParser.looksLikeTeacher(line)) {
        e.teacher = line;
      }
    }
  }

  /** 返回课程名应当截断的位置（教师/周次/教室出现处） */
  private static firstCut(line: string): number {
    let cut: number = -1;
    const m1: RegExpMatchArray | null = line.match(/\d+\s*[-—~]+\s*\d+\s*\(\s*(单|双)?周\s*\)/);
    if (m1 !== null && m1.index !== undefined) {
      cut = cut < 0 ? m1.index : Math.min(cut, m1.index);
    }
    const m2: RegExpMatchArray | null = line.match(/\d+\s*\(\s*(单|双)?周\s*\)/);
    if (m2 !== null && m2.index !== undefined) {
      cut = cut < 0 ? m2.index : Math.min(cut, m2.index);
    }
    return cut;
  }

  /** 教室串拆分：7-120(章丘) -> room=7-120, campus=章丘 */
  private static splitRoom(text: string, e: CourseEntry): void {
    const t: string = text.trim();
    if (t.length === 0) {
      return;
    }
    const m: RegExpMatchArray | null = t.match(/^(.+?)\s*[（(]\s*([^)）]+)\s*[)）]\s*$/);
    if (m !== null) {
      e.room = m[1].trim();
      e.campus = m[2].trim();
    } else {
      e.room = t;
    }
  }

  /** 教师行特征 */
  private static looksLikeTeacher(line: string): boolean {
    if (/讲师|副教授|教授|助教|工程师|研究员/.test(line)) {
      return true;
    }
    return /^[\u4e00-\u9fa5·]{2,6}$/.test(line);
  }

  /** 解析周次规则：1-18(周) / 1-18(双周) / 1-18(单周) */
  private static parseWeekRange(text: string, e: CourseEntry): void {
    const t: string = text.replace(/[（）]/g, '(');
    if (/双周/.test(t)) {
      e.parity = 2;
    } else if (/单周/.test(t)) {
      e.parity = 1;
    } else {
      e.parity = 0;
    }
    const range: RegExpMatchArray | null = t.match(/(\d+)\s*[-—~]+\s*(\d+)/);
    if (range !== null) {
      const a: number = parseInt(range[1], 10);
      const b: number = parseInt(range[2], 10);
      e.startWeek = isNaN(a) ? 1 : a;
      e.endWeek = isNaN(b) ? e.startWeek : b;
      return;
    }
    const single: RegExpMatchArray | null = t.match(/(\d+)/);
    if (single !== null) {
      const a: number = parseInt(single[1], 10);
      e.startWeek = isNaN(a) ? 1 : a;
      e.endWeek = e.startWeek;
    }
  }

  /** 读取下拉选项值列表 */
  private static readOptions(html: string, name: string): string[] {
    const opts = HtmlLite.findSelect(html, name);
    const result: string[] = [];
    for (let i = 0; i < opts.length; i++) {
      if (opts[i].value.length > 0) {
        result.push(opts[i].value);
      }
    }
    return result;
  }

  /** 读取下拉当前选中值 */
  private static readSelected(html: string, name: string): string {
    const opts = HtmlLite.findSelect(html, name);
    for (let i = 0; i < opts.length; i++) {
      if (opts[i].selected) {
        return opts[i].value;
      }
    }
    return opts.length > 0 ? opts[0].value : '';
  }
}
