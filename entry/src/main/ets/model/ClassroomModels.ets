/*
 * ClassroomModels：空教室查询的模型与纯计算
 *
 * 单独成文件的原因：这里包含「某教室在某周某天某节次是否空闲」的全部判断逻辑，
 * 不依赖任何 HarmonyOS API，可以在 Node 里直接单测（见 testdata/run-tests.mjs）。
 *
 * ===== 为什么必须自己按周次过滤（已实测，很关键）=====
 * 服务端 `kbxx_classroom_ifr` 的 `zc1`/`zc2`（周次区间）参数**不可靠**：
 *   1. 课程类占用会被正确过滤；
 *   2. 但「被借用」类占用**完全无视周次**——第 2 周的借用记录在任何一周都会出现；
 *   3. 而且当周次筛选后，**该周没有任何占用记录的教室会被整行丢掉**
 *      （实测章丘：不筛=231 间，筛第 4 周=196 间，筛第 10 周=225 间）。
 * 第 3 点对「找空教室」是致命的：真正全周空闲的教室恰恰就是被丢掉的那些。
 *
 * 因此本功能**一律不传周次**去查（拿到完整教室表与全学期占用文本），
 * 再由客户端按单元格里的周次说明自行过滤 —— 语义统一，也不会漏掉空教室。
 *
 * 单元格里两种周次写法都已覆盖：
 *   课程：(3-18周)、(5-18双周)、(1-2,4-8,10周)
 *   借用：被借用( 第(2周)(01-04节)周,王超,学生活动 )
 */

import { SECTIONS } from '../common/Constants';

/** 周次说明：区间集合 + 单双周约束 */
export class WeekSpec {
  /** 区间列表，每项为 [起, 止]（含两端） */
  ranges: number[][] = [];
  /** 0=每周 1=单周 2=双周 */
  parity: number = 0;
  /** 原始文本，便于界面回显与排查 */
  raw: string = '';

  /** 第 week 周是否命中该说明 */
  isActive(week: number): boolean {
    if (week <= 0) {
      return true;
    }
    if (this.parity === 1 && week % 2 === 0) {
      return false;
    }
    if (this.parity === 2 && week % 2 === 1) {
      return false;
    }
    for (let i = 0; i < this.ranges.length; i++) {
      const r: number[] = this.ranges[i];
      if (r.length !== 2) {
        continue;
      }
      if (week >= r[0] && week <= r[1]) {
        return true;
      }
    }
    return false;
  }

  /** 是否为「整学期每周」——这类占用在任何一周都算忙 */
  allowsAnyWeek(): boolean {
    if (this.parity !== 0) {
      return false;
    }
    for (let i = 0; i < this.ranges.length; i++) {
      const r: number[] = this.ranges[i];
      if (r.length === 2 && r[0] <= 1 && r[1] >= 30) {
        return true;
      }
    }
    return false;
  }

  /** 展示用文本，如 "3-18周" / "5-18周(双)" */
  display(): string {
    if (this.ranges.length === 0) {
      return this.raw;
    }
    const parts: string[] = [];
    for (let i = 0; i < this.ranges.length; i++) {
      const r: number[] = this.ranges[i];
      parts.push(r[0] === r[1] ? r[0].toString() : (r[0].toString() + '-' + r[1].toString()));
    }
    let s: string = parts.join(',') + '周';
    if (this.parity === 1) {
      s = s + '(单)';
    } else if (this.parity === 2) {
      s = s + '(双)';
    }
    return s;
  }
}

/** 一条占用记录（一节课或一次借用） */
export class RoomBooking {
  /** 课程名 / 借用事由 */
  label: string = '';
  /** 教师 / 借用人，可能为空 */
  person: string = '';
  /** 上课班级（借用记录没有） */
  className: string = '';
  /** 是否为「被借用」 */
  borrowed: boolean = false;
  /** 周次说明 */
  spec: WeekSpec = new WeekSpec();

  /** 在第 week 周是否占用 */
  isActive(week: number): boolean {
    if (this.spec.ranges.length === 0) {
      // 拿不到周次说明时保守处理：视为占用，避免把有课的教室报成空闲
      return true;
    }
    return this.spec.isActive(week);
  }
}

/** 一间教室在某节次、一周 7 天的占用情况 */
export class RoomSlot {
  room: string = '';
  /** 7 项，索引 0=周一 … 6=周日 */
  days: RoomBooking[][] = [];

  constructor() {
    for (let i = 0; i < 7; i++) {
      this.days.push([]);
    }
  }

  /** 该教室在第 day 天、第 week 周是否有占用 */
  isBusy(day: number, week: number): boolean {
    if (day < 0 || day >= this.days.length) {
      return false;
    }
    const list: RoomBooking[] = this.days[day];
    for (let i = 0; i < list.length; i++) {
      if (list[i].isActive(week)) {
        return true;
      }
    }
    return false;
  }

  /** 该教室在第 day 天的占用列表（不过滤周次，供详情展示） */
  bookingsOf(day: number): RoomBooking[] {
    return (day >= 0 && day < this.days.length) ? this.days[day] : [];
  }
}

/** 一次查询的结果 */
export class ClassroomResult {
  campus: string = '';
  building: string = '';
  semester: string = '';
  /** 节次行（0 起，对应 SECTIONS） */
  sectionRow: number = 0;
  rooms: RoomSlot[] = [];
}

/** 某一间空教室的信息（供列表展示） */
export class FreeRoom {
  room: string = '';
  /** 该时段本来有课但恰逢停开/换周等情况时为空 */
  constructor(room: string) {
    this.room = room;
  }
}

/** 一个星期的空闲统计，用于「本周哪天最空」的速览 */
export class DayFreeStat {
  day: number = 0;
  free: number = 0;
  total: number = 0;

  constructor(day: number, free: number, total: number) {
    this.day = day;
    this.free = free;
    this.total = total;
  }
}

export class ClassroomFinder {
  /**
   * 取某周、某天的空闲教室。
   * @param result 查询结果（应来自不传周次的完整查询）
   * @param week   教学周次
   * @param day    0=周一 … 6=周日
   * @param buildingFilter 教学楼名（为空则不过滤）
   */
  static freeRooms(result: ClassroomResult, week: number, day: number,
    buildingFilter: string): string[] {
    const out: string[] = [];
    for (let i = 0; i < result.rooms.length; i++) {
      const slot: RoomSlot = result.rooms[i];
      if (buildingFilter.length > 0 && !ClassroomFinder.belongsTo(slot.room, buildingFilter)) {
        continue;
      }
      if (!slot.isBusy(day, week)) {
        out.push(slot.room);
      }
    }
    out.sort((a: string, b: string) => ClassroomFinder.compareRoom(a, b));
    return out;
  }

  /** 取某周、某天被占用的教室（用于核对与展示） */
  static busyRooms(result: ClassroomResult, week: number, day: number): RoomSlot[] {
    const out: RoomSlot[] = [];
    for (let i = 0; i < result.rooms.length; i++) {
      if (result.rooms[i].isBusy(day, week)) {
        out.push(result.rooms[i]);
      }
    }
    return out;
  }

  /** 一周 7 天的空闲数统计 */
  static weekStats(result: ClassroomResult, week: number): DayFreeStat[] {
    const out: DayFreeStat[] = [];
    const total: number = result.rooms.length;
    for (let d = 0; d < 7; d++) {
      out.push(new DayFreeStat(d, ClassroomFinder.freeRooms(result, week, d, '').length, total));
    }
    return out;
  }

  /**
   * 教室名是否属于某教学楼。
   *
   * 教室名形如 "7-116(章丘)"、"圣井7-101"，而页面给的楼名可能是 "7"、"圣井7"。
   * 只按楼号做**整体相等**比较，不做「后缀包含」——
   * 曾用后缀匹配，结果 "1" 会把 "11-101" 也匹配进来（1 是 11 的后缀）。
   * 现在的规则：取教室名的楼号部分，与楼名互相「去掉校区前缀后」「去掉数字后缀后」比较。
   */
  static belongsTo(room: string, building: string): boolean {
    if (building.length === 0) {
      return true;
    }
    const head: string = room.indexOf('-') > 0 ? room.substring(0, room.indexOf('-')) : room;
    if (head === building) {
      return true;
    }
    // 楼名带中文前缀（如「圣井7」），教室名只有数字（如「7」）：比较数字部分，
    // 但必须整段相等，不能是子串关系。
    const bNum: string = building.replace(/[^0-9]/g, '');
    const hNum: string = head.replace(/[^0-9]/g, '');
    if (bNum.length > 0 && bNum === hNum) {
      return true;
    }
    return false;
  }

  /** 教室排序：先按楼号数值，再按房间号，保证 "7-116" 排在 "8-108" 前 */
  static compareRoom(a: string, b: string): number {
    const ha: string = a.indexOf('-') > 0 ? a.substring(0, a.indexOf('-')) : a;
    const hb: string = b.indexOf('-') > 0 ? b.substring(0, b.indexOf('-')) : b;
    const na: number = parseInt(ha.replace(/[^0-9]/g, ''), 10);
    const nb: number = parseInt(hb.replace(/[^0-9]/g, ''), 10);
    const va: boolean = !isNaN(na);
    const vb: boolean = !isNaN(nb);
    if (va && vb && na !== nb) {
      return na - nb;
    }
    if (va !== vb) {
      return va ? -1 : 1;
    }
    return a < b ? -1 : (a > b ? 1 : 0);
  }

  /** 节次行 → 服务端节次代码区间，如 0 → ["01","02"]，4 → ["09","11"] */
  static sectionCodes(row: number): string[] {
    if (row < 0 || row >= SECTIONS.length) {
      return ['01', '02'];
    }
    if (row === 4) {
      // 第九~十一节：服务端把 09/10/11 合成一组
      return ['09', '11'];
    }
    const first: number = row * 2 + 1;
    const second: number = row * 2 + 2;
    return [ClassroomFinder.pad2(first), ClassroomFinder.pad2(second)];
  }

  private static pad2(n: number): string {
    return n < 10 ? ('0' + n.toString()) : n.toString();
  }

  /** 星期标签（短），如 "周一" */
  static dayLabel(day: number): string {
    const full: string[] = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return (day >= 0 && day < 7) ? full[day] : '';
  }
}

export class WeekSpecParser {
  /** 匹配 (3-18周) / (5-18双周) / (2单周) / (1-2,4-8,10周) 等写法 */
  private static readonly ONE: RegExp = /\(([0-9][0-9,\-]*)\s*(单|双)?\s*周\)/;
  /** 全局版，用于一个单元格里有多个时间段的课程 */
  private static readonly ALL: RegExp = /\(([0-9][0-9,\-]*)\s*(单|双)?\s*周\)/g;

  /** 从单元格文本里提取第一个周次说明；提取不到返回 null */
  static first(text: string): WeekSpec | null {
    const m: RegExpMatchArray | null = text.match(WeekSpecParser.ONE);
    if (m === null || m.length < 2) {
      return null;
    }
    return WeekSpecParser.build(m[1], m.length >= 3 && m[2] !== undefined ? m[2] : '');
  }

  /** 提取单元格里所有周次说明（一个格子可能有多门课） */
  static all(text: string): WeekSpec[] {
    const out: WeekSpec[] = [];
    const found: string[] | null = text.match(WeekSpecParser.ALL);
    if (found === null) {
      return out;
    }
    for (let i = 0; i < found.length; i++) {
      const spec: WeekSpec | null = WeekSpecParser.first(found[i]);
      if (spec !== null) {
        out.push(spec);
      }
    }
    return out;
  }

  /** 由数字串（可含逗号与短横）与单双周标记构造 WeekSpec */
  static build(digits: string, parityText: string): WeekSpec {
    const spec: WeekSpec = new WeekSpec();
    spec.raw = digits + parityText + '周';
    if (parityText === '单') {
      spec.parity = 1;
    } else if (parityText === '双') {
      spec.parity = 2;
    }
    const segs: string[] = digits.split(',');
    for (let i = 0; i < segs.length; i++) {
      const seg: string = segs[i].trim();
      if (seg.length === 0) {
        continue;
      }
      const dash: number = seg.indexOf('-');
      if (dash > 0) {
        const a: number = parseInt(seg.substring(0, dash), 10);
        const b: number = parseInt(seg.substring(dash + 1), 10);
        if (!isNaN(a) && !isNaN(b)) {
          spec.ranges.push(a <= b ? [a, b] : [b, a]);
        }
      } else {
        const v: number = parseInt(seg, 10);
        if (!isNaN(v)) {
          spec.ranges.push([v, v]);
        }
      }
    }
    return spec;
  }
}
