/*
 * ClassroomParser：解析「全校性教室课表」(/jsxsd/kbcx/kbxx_classroom)
 *
 * 已核实页面结构：
 *   1) 查询页 `GET /jsxsd/kbcx/kbxx_classroom`
 *      - select#xqid  校区：1 舜耕 / 2 燕山 / 3 章丘 / 4 明水 / 5 莱芜
 *      - select#xnxqh 学期
 *      - select#jzwid 教学楼（由 `POST /jsxsd/kbcx/getJxlByAjax` 按校区异步填充）
 *   2) 结果页 `POST /jsxsd/kbcx/kbxx_classroom_ifr`，返回 **HTML 片段**，
 *      内含 table#kbtable：
 *        第 0 行：星期一 … 星期日
 *        第 1 行：节次标签（如 0102）
 *        第 2 行起：教室名 + 各天占用文本
 *
 * 关键点（已实测）：
 *   - 传**单个节次组合**时表头是 8 列（教室 + 7 天）；
 *     若周次/节次跨多个组合，表头会膨胀成「5 组 × 7 天 = 36 列」。
 *     本功能每次只查一个节次组合，但解析仍按表头里的「星期」动态定位列，
 *     这样两种形态都能正确解析。
 *   - 空单元格（只有 &nbsp;）表示该时段空闲。
 *   - 周次过滤**不交给服务端**，解析阶段原样保留单元格文本里的周次说明，
 *     由 ClassroomModels 在客户端按周判断（原因见该文件顶部说明）。
 */
import { HtmlLite, HtmlTable, HtmlRow, HtmlCell } from './HtmlLite';
import { Logger } from '../common/Logger';
import {
  ClassroomResult, RoomSlot, RoomBooking, WeekSpec, WeekSpecParser
} from '../model/ClassroomModels';

export class ClassroomParser {
  /** 解析查询页里的校区选项 */
  static parseCampuses(html: string): string[] {
    const out: string[] = [];
    const opts = HtmlLite.findSelect(html, 'xqid');
    for (let i = 0; i < opts.length; i++) {
      const v: string = opts[i].value;
      const label: string = opts[i].label;
      // "-请选择-" 不作为可选项；用 value + 名称拼成 "3|章丘校区" 便于直接回传
      if (v.length > 0 && label.length > 0) {
        out.push(v + '|' + label);
      }
    }
    return out;
  }

  /** 解析查询页里的学期选项 */
  static parseSemesters(html: string): string[] {
    const out: string[] = [];
    const opts = HtmlLite.findSelect(html, 'xnxqh');
    for (let i = 0; i < opts.length; i++) {
      if (opts[i].value.length > 0) {
        out.push(opts[i].value);
      }
    }
    return out;
  }

  /**
   * 解析结果表。
   * @param sectionRow 本次查询的节次行号，写入结果便于界面回显
   */
  static parseResult(html: string, sectionRow: number): ClassroomResult {
    const result: ClassroomResult = new ClassroomResult();
    result.sectionRow = sectionRow;

    const table: HtmlTable | null = HtmlLite.findTableById(html, 'kbtable');
    if (table === null) {
      Logger.warn('classroom table #kbtable not found');
      return result;
    }
    if (table.rows.length < 3) {
      Logger.warn('classroom table too few rows: ' + table.rows.length);
      return result;
    }

    // 用第 0 行表头建立「列号 → 星期索引」映射。
    // 表头可能重复出现（跨节次组合时 5 组），取每个星期的第一次出现。
    const dayOfCol: number[] = [];
    const head: HtmlCell[] = table.rows[0].cells;
    let seen: number = 0;
    for (let c = 0; c < head.length; c++) {
      const t: string = head[c].text;
      const day: number = ClassroomParser.dayIndex(t);
      if (day >= 0 && (seen & (1 << day)) === 0) {
        seen = seen | (1 << day);
        dayOfCol.push(day);
      } else {
        dayOfCol.push(-1);
      }
    }

    for (let r = 2; r < table.rows.length; r++) {
      const row: HtmlRow = table.rows[r];
      const cells: HtmlCell[] = row.cells;
      if (cells.length < 2) {
        continue;
      }
      const room: string = ClassroomParser.clean(cells[0].text);
      if (room.length === 0 || room.indexOf('教室') >= 0) {
        continue;
      }
      const slot: RoomSlot = new RoomSlot();
      slot.room = room;
      for (let c = 1; c < cells.length && c < dayOfCol.length; c++) {
        const day: number = dayOfCol[c];
        if (day < 0) {
          continue;
        }
        const bookings: RoomBooking[] = ClassroomParser.parseCell(cells[c], day);
        for (let i = 0; i < bookings.length; i++) {
          slot.days[day].push(bookings[i]);
        }
      }
      result.rooms.push(slot);
    }

    Logger.info('classroom parsed: rooms=' + result.rooms.length +
      ' cols=' + head.length + ' sectionRow=' + sectionRow);
    return result;
  }

  /**
   * 解析一个单元格。一个格子可能有多条占用（多门课 / 课程 + 借用），
   * 以换行或连续空行分隔，这里逐段识别。
   */
  private static parseCell(cell: HtmlCell, day: number): RoomBooking[] {
    const out: RoomBooking[] = [];
    const raw: string = cell.inner;
    if (raw === undefined || raw.length === 0) {
      return out;
    }
    // 单元格内多个条目之间通常是 <br> 或空行；先按 <br> 切分
    const parts: string[] = raw.split(/<br\s*\/?>/i);
    for (let i = 0; i < parts.length; i++) {
      const text: string = ClassroomParser.clean(HtmlLite.toText(parts[i]));
      if (text.length === 0) {
        continue;
      }
      const b: RoomBooking | null = ClassroomParser.parseBooking(text);
      if (b !== null) {
        out.push(b);
      }
    }
    // 整体兜底：若按 <br> 切分后什么都没解析出来，但文本非空，
    // 则当作一条「未知周次」的占用处理（保守认为该时段被占）
    if (out.length === 0) {
      const text: string = ClassroomParser.clean(HtmlLite.toText(raw));
      if (text.length > 0) {
        const b: RoomBooking = new RoomBooking();
        b.label = text;
        const spec: WeekSpec | null = WeekSpecParser.first(text);
        if (spec !== null) {
          b.spec = spec;
        }
        out.push(b);
      }
    }
    return out;
  }

  /** 把一段文本解析成占用记录 */
  private static parseBooking(text: string): RoomBooking | null {
    const b: RoomBooking = new RoomBooking();
    b.label = text;
    const parsed: WeekSpec | null = WeekSpecParser.first(text);
    b.spec = parsed !== null ? parsed : new WeekSpec();

    // 借用形态：被借用( 第(2周)(01-04节)周,王超,学生活动 )
    const bi: number = text.indexOf('被借用');
    if (bi >= 0) {
      b.borrowed = true;
      const inner: string = text.substring(bi);
      // 逗号后依次是「借用人, 事由」
      const segs: string[] = inner.split(/[,，]/);
      if (segs.length >= 2) {
        const person: string = ClassroomParser.clean(segs[1]);
        // 第一个逗号段里还带着 "( 第(2周)(01-04节)周"，要剔掉括号内容
        b.person = person.indexOf('第') >= 0 ? '' : person;
      }
      if (segs.length >= 3) {
        b.label = '借用：' + ClassroomParser.clean(segs[2].replace(/[)）\s]+$/, ''));
      } else {
        b.label = '被借用';
      }
      if (b.person.length > 0) {
        b.label = b.label + ' · ' + b.person;
      }
      return b;
    }

    // 课程形态：课程名 教师\n(3-18周) \n班级
    // 先取出周次说明所在括号的位置，把它之前的整段作为「课程名 + 教师」
    const at: number = text.indexOf('(');
    const head: string = at > 0 ? ClassroomParser.clean(text.substring(0, at)) : text;
    if (head.length === 0) {
      return null;
    }
    // 「课程名 教师」中间以空格分隔，最后一段通常是教师名（2-6 个汉字）
    const sp: string[] = head.split(/\s+/);
    if (sp.length >= 2) {
      const last: string = sp[sp.length - 1];
      if (ClassroomParser.looksLikeName(last)) {
        b.person = last;
        b.label = sp.slice(0, sp.length - 1).join(' ');
      } else {
        b.label = head;
      }
    } else {
      b.label = head;
    }
    // 周次括号之后的剩余部分通常是班级
    if (at > 0) {
      const rest: string = text.substring(at);
      const close: number = rest.indexOf(')');
      if (close >= 0 && close + 1 < rest.length) {
        b.className = ClassroomParser.clean(rest.substring(close + 1));
      }
    }
    return b;
  }

  /** 2-6 个汉字视为人名 */
  private static looksLikeName(s: string): boolean {
    if (s.length < 2 || s.length > 6) {
      return false;
    }
    return /^[\u4e00-\u9fa5]+$/.test(s);
  }

  /** 星期的短标签 → 索引；"星期一" → 0 */
  private static dayIndex(text: string): number {
    const t: string = text.replace(/\s/g, '');
    const names: string[] = ['星期一', '星期二', '星期三', '星期四', '星期五', '星期六', '星期日'];
    for (let i = 0; i < names.length; i++) {
      if (t.indexOf(names[i]) >= 0) {
        return i;
      }
    }
    // 有的页面用「周一」写法
    const short: string[] = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    for (let i = 0; i < short.length; i++) {
      if (t.indexOf(short[i]) >= 0) {
        return i;
      }
    }
    return -1;
  }

  /** 清理文本：去 &nbsp;、多余空白与换行 */
  private static clean(s: string): string {
    if (s === undefined || s === null) {
      return '';
    }
    return s.replace(/\u00a0/g, ' ').replace(/\s+/g, ' ').trim();
  }
}
