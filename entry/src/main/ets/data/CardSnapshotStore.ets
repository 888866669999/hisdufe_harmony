/*
 * CardSnapshotStore：为桌面卡片准备数据
 *
 * ===== 为什么需要一层快照 =====
 * 桌面卡片由 FormExtensionAbility 驱动，可能在任何时刻被要求刷新，
 * 而卡片的渲染时间很短、也不适合做网络请求与 HTML 解析。
 * 因此由主应用在「课表变化 / 进入后台」时算好并存进 preferences；
 * 卡片只读这份数据。
 *
 * ===== 为什么从「今日快照」改成「周级载荷」（卡顿与不及时的根修）=====
 * 早先只存**在写入那一刻算好的「今天」**。卡片每次被要求刷新，只是把这份
 * 算好的结果重画一遍，于是：
 *   · `done`（已上完）与「下一节」冻结在写入时刻，一整天不再变化；
 *   · **跨天后仍显示昨天的课**，必须打开一次应用才会纠正；
 *   · 系统每 30 分钟的周期刷新形同虚设（重画旧数据）。
 *
 * 现在改为存**整周课表**（含每门课的周次区间与单双周、以及每个节次的
 * 起止时刻），让卡片自己按当前日期与时间算出「今天该显示什么」。
 * 于是任何一次刷新（系统的、主应用推的、边界闹钟触发的）都能得到
 * **当下正确**的内容，跨天自愈，且全程不需要应用在后台运行。
 *
 * 这一版与 Flutter 端（`lib/data/card_snapshot_store.dart` 的 buildWeek）
 * 的载荷结构**逐字段对齐**，两端行为一致。
 *
 * 旧的「今日快照」仍然保留一份：老版本卡片、以及主应用设置页的状态文案
 * 还在用它；同时它是周级载荷解析失败时的兜底。
 */
import { PrefStore } from './PrefStore';
import { AppState } from './AppState';
import { WeekService } from './WeekService';
import { FormIdRegistry } from './FormIdRegistry';
import { CardPusher, CardBinding, PushOutcome } from './CardPusher';
import { SectionTimeStore, SectionTime } from './SectionTimeStore';
import { Timetable, CellData, CourseEntry } from '../model/Models';
import { WeekCalc } from '../common/WeekCalc';
import { Logger } from '../common/Logger';
import { MAX_WEEKS, KEY_CARD_SNAPSHOT, KEY_CARD_WEEK,
  KEY_CARD_FORM_IDS } from '../common/Constants';

/** 卡片上的单条课程 */
export class CardCourse {
  /** 起始时刻，如 08:30 */
  time: string = '';
  name: string = '';
  room: string = '';
  teacher: string = '';
  /** 是否已经上完（用于卡片区分「接下来」与「已结束」） */
  done: boolean = false;
}

/** 卡片快照 */
export class CardSnapshot {
  /** 生成时刻（毫秒），用于卡片显示「更新于」与判断是否过期 */
  at: number = 0;
  /** 星期几（一~日） */
  weekday: string = '';
  /** 日期 MM/DD */
  date: string = '';
  /** 当前教学周（0 = 未设置开学日期） */
  week: number = 0;
  /** 今天是否有课 */
  hasCourse: boolean = false;
  courses: CardCourse[] = [];
  /** 「下一节」的展示文本 */
  nextText: string = '';

  constructor() {
  }
}

/**
 * 周级载荷里的一门课。
 *
 * 字段名与 Flutter 端 `buildWeek()` 生成的 JSON 键**逐字对应**
 * （name/room/teacher/row/startWeek/endWeek/parity），两端产出的载荷可以互相解析。
 */
export class WeekCourse {
  name: string = '';
  room: string = '';
  teacher: string = '';
  /** 节次行下标 0..4 */
  row: number = 0;
  startWeek: number = 1;
  endWeek: number = 18;
  /** 0=每周 1=单周 2=双周 */
  parity: number = 0;
}

/**
 * 周级载荷：交给卡片自己算「今天」。
 *
 * 结构（键名与卡片侧 `TodayCourseCard.ets` 的接口逐字对应，改名要两边一起改）：
 * {
 *   at, semester, startMonday, maxWeeks,
 *   sections:    ["08:30", ...],   // 每行的**上课**时刻
 *   sectionEnds: ["10:00", ...],   // 每行的**下课**时刻
 *   total,                          // 课程总数（用于「空表不覆盖」判断与卡片显示）
 *   days: [ [ {name,room,teacher,row,startWeek,endWeek,parity}, ... ] × 7 ]
 * }
 *
 * `sectionEnds` 是这一版新增的：卡片要标「已上完」，光有开始时刻只能按
 * 「开始时间过了就算上完」来猜 —— 于是**正在上的那节课也会被标成已上完**。
 * 有下课时刻才能准确判断。
 */
export class WeekPayload {
  at: number = 0;
  /** 学期号，仅用于排查 */
  semester: string = '';
  /** 第 1 周周一；空串 = 未设置 */
  startMonday: string = '';
  maxWeeks: number = MAX_WEEKS;
  /** 每行的上课时刻 */
  sections: string[] = [];
  /** 每行的下课时刻 */
  sectionEnds: string[] = [];
  /** 课程总数 */
  total: number = 0;
  /** 7 个元素，索引 0=周一 */
  days: WeekCourse[][] = [];
}

export { KEY_CARD_SNAPSHOT, KEY_CARD_WEEK } from '../common/Constants';

const WEEKDAY_CN: string[] = ['一', '二', '三', '四', '五', '六', '日'];

export class CardSnapshotStore {
  /** 读取快照；不存在返回 null */
  static async load(): Promise<CardSnapshot | null> {
    const raw: string = await PrefStore.getText(KEY_CARD_SNAPSHOT);
    if (raw.length === 0) {
      return null;
    }
    try {
      return JSON.parse(raw) as CardSnapshot;
    } catch (e) {
      Logger.warn('card snapshot parse failed');
      return null;
    }
  }

  /**
   * 删除快照。
   *
   * 退出登录时必须调用：卡片是**直接读这份持久化数据**渲染的
   * （不在应用进程内），若不清，B 登录后、B 自己打开课表之前，
   * 桌面卡片显示的还是 A 的今日课程。
   */
  static async clear(): Promise<void> {
    await PrefStore.putText(KEY_CARD_SNAPSHOT, '');
    await PrefStore.putText(KEY_CARD_WEEK, '');
    await PrefStore.putText(KEY_CARD_FORM_IDS, '');
    // 同时把空态推给卡片：否则退出登录后卡片会继续显示上一个账号的今日课程，
    // 直到系统下次周期刷新（约 30 分钟）。
    const ids: string[] = await CardSnapshotStore.targetIds();
    if (ids.length > 0) {
      const empty: CardSnapshot = new CardSnapshot();
      const binding: CardBinding = new CardBinding(JSON.stringify(empty), '4', '');
      await CardPusher.push(ids, binding).catch(() => {
        Logger.warn('card clear push failed');
      });
    }
  }

  /**
   * 由课表生成数据并落盘，**并推送给已经存在的桌面卡片**。
   *
   * 为什么这里必须推送（而不只是写盘）：卡片渲染的是 formBindingData
   * 注入的数据，它不会自己去读 preferences。改造前只写盘，导致应用内
   * 加课/改课后卡片仍显示旧内容，用户要「删掉卡片重新添加」才生效。
   *
   * ===== 这个方法**绝不抛异常** =====
   * 它在课表加载链路上被 await，而那条链路的外层 catch 会把任何异常
   * 当成「会话失效」去触发静默重新登录。于是「快照里某个字段是 null」
   * 这种小事会表现成「课表打开要重新登录」，极难定位。
   */
  static async refresh(): Promise<CardSnapshot | null> {
    try {
      const tt: Timetable | null = AppState.timetable;
      if (tt === null) {
        return null;
      }
      await SectionTimeStore.load();
      const startMonday: string = WeekService.start();
      const now: Date = new Date();

      const snap: CardSnapshot = CardSnapshotStore.build(tt, startMonday, now);
      const week: WeekPayload = CardSnapshotStore.buildWeek(tt, startMonday);
      const weekJson: string = JSON.stringify(week);

      // ===== 空表不覆盖好数据（「卡片课程消失」的防线）=====
      // 课表在「缓存为空 / 换到还没排课的学期 / 抓取只回了一半」时可能是
      // 一张**没有任何课程**的表。若照样写下去，卡片会从「满屏课程」变成
      // 「今天没有课」，而且在下一次成功刷新之前一直那样 ——
      // 用户看到的就是「课程从卡片里消失了」。
      //
      // 因此：新表一门课都没有、而上次写下的表里有课时，判定这次是
      // 「没拿到数据」而不是「用户真的没课」，**跳过写入**（保留旧数据）。
      // 代价：万一用户真的把课全删了，卡片会多显示一会儿旧课；两害相权，
      // 宁可留旧数据也不要凭空抹白。
      if (week.total === 0 && await CardSnapshotStore.storedWeekHadCourses()) {
        Logger.warn('card refresh skipped: empty timetable would wipe existing data');
        return snap;
      }

      await PrefStore.putText(KEY_CARD_SNAPSHOT, JSON.stringify(snap));
      await PrefStore.putText(KEY_CARD_WEEK, weekJson);
      Logger.info('card refreshed: today=' + snap.courses.length.toString()
        + ' total=' + week.total.toString());
      // 推送失败不影响快照已落盘的事实：卡片下次被刷新时仍能读到新数据
      await CardSnapshotStore.pushWith(ids => CardPusher.push(ids,
        new CardBinding(JSON.stringify(snap), '4', weekJson)));
      return snap;
    } catch (e) {
      // 卡片是附属功能，任何失败都不该影响课表本身
      Logger.warn('card refresh failed');
      return null;
    }
  }

  /** 上一次写下的周级载荷里是否含课程（用于「空表不覆盖」判断） */
  private static async storedWeekHadCourses(): Promise<boolean> {
    const raw: string = await PrefStore.getText(KEY_CARD_WEEK);
    if (raw.length === 0) {
      return false;
    }
    try {
      const w: WeekPayload = JSON.parse(raw) as WeekPayload;
      if (w.total !== undefined && w.total > 0) {
        return true;
      }
      // 兼容没有 total 的旧载荷：逐天看有没有课程
      if (w.days !== undefined && w.days !== null) {
        for (let i = 0; i < w.days.length; i++) {
          const d: WeekCourse[] = w.days[i];
          if (d !== undefined && d !== null && d.length > 0) {
            return true;
          }
        }
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  /** 用给定的绑定数据推给所有已登记的卡片 */
  private static async pushWith(
    make: (ids: string[]) => Promise<PushOutcome>
  ): Promise<void> {
    const ids: string[] = await CardSnapshotStore.targetIds();
    if (ids.length === 0) {
      return;
    }
    await make(ids).catch(() => {
      Logger.warn('card push failed');
    });
  }

  /** 待推送的卡片 id：登记表 ∪ 系统查询到的运行中卡片 */
  private static async targetIds(): Promise<string[]> {
    const out: string[] = await FormIdRegistry.ids();
    const found: string[] = await CardPusher.discover();
    for (let i = 0; i < found.length; i++) {
      if (out.indexOf(found[i]) < 0) {
        out.push(found[i]);
      }
    }
    return out;
  }

  /** 纯计算：生成某一天的课程快照（便于单测） */
  static build(tt: Timetable, startMonday: string, now: Date): CardSnapshot {
    const snap: CardSnapshot = new CardSnapshot();
    snap.at = now.getTime();
    const dow: number = now.getDay();          // 0=周日
    const col: number = dow === 0 ? 6 : dow - 1;
    snap.weekday = WEEKDAY_CN[col];
    snap.date = CardSnapshotStore.md(now.getMonth() + 1, now.getDate());
    snap.week = startMonday.length > 0
      ? WeekCalc.weekNumber(startMonday, now, MAX_WEEKS) : 0;

    const nowMin: number = now.getHours() * 60 + now.getMinutes();
    const list: CardCourse[] = [];
    for (let r = 0; r < 5; r++) {
      const cell: CellData | null = tt.findCell(r, col);
      if (cell === null) {
        continue;
      }
      const st: SectionTime | null = SectionTimeStore.at(r);
      if (st === null) {
        continue;
      }
      const startMin: number = st.startMinutes();
      const endMin: number = SectionTimeStore.toMinutes(st.end);
      for (let i = 0; i < cell.entries.length; i++) {
        const e: CourseEntry = cell.entries[i];
        // week=0（未设置开学日期）时不做周次过滤，宁可多显示也不漏
        if (snap.week > 0 && !e.isActiveInWeek(snap.week)) {
          continue;
        }
        const c: CardCourse = new CardCourse();
        c.time = st.start;
        c.name = e.courseName;
        c.room = e.room.length > 0 && e.campus.length > 0
          ? (e.room + '(' + e.campus + ')') : e.room;
        c.teacher = e.teacher;
        // 以**下课时刻**判断是否上完：只按开始时刻的话，正在上的那节课
        // 会被误标成「已上完」（Flutter 端同样按结束时刻判断）
        c.done = endMin >= 0 && endMin <= nowMin;
        list.push(c);
      }
    }
    // 按时间排序，卡片按上课顺序展示
    list.sort((a: CardCourse, b: CardCourse) => {
      const am: number = SectionTimeStore.toMinutes(a.time);
      const bm: number = SectionTimeStore.toMinutes(b.time);
      return am - bm;
    });
    snap.courses = list;
    snap.hasCourse = list.length > 0;

    // 下一节课：第一节还没开始的
    for (let i = 0; i < list.length; i++) {
      if (!list[i].done) {
        snap.nextText = list[i].time + ' ' + list[i].name +
          (list[i].room.length > 0 ? (' @' + list[i].room) : '');
        break;
      }
    }
    return snap;
  }

  /**
   * 纯计算：生成整周载荷，交给卡片自己算「今天」。
   *
   * 与 Flutter 端 `CardSnapshotStore.buildWeek()` 的结构逐字段一致
   * （除 `days` 在 Dart 侧是 Map、这里是用具名类 WeekCourse —— 序列化后的
   * JSON 键名相同，因此两端产出的载荷可以互相解析）。
   */
  static buildWeek(tt: Timetable, startMonday: string): WeekPayload {
    const w: WeekPayload = new WeekPayload();
    w.at = Date.now();
    w.semester = tt.semester;
    w.startMonday = startMonday;
    w.maxWeeks = MAX_WEEKS;

    const sections: string[] = [];
    const sectionEnds: string[] = [];
    for (let r = 0; r < 5; r++) {
      const st: SectionTime | null = SectionTimeStore.at(r);
      sections.push(st === null ? '' : st.start);
      sectionEnds.push(st === null ? '' : st.end);
    }
    w.sections = sections;
    w.sectionEnds = sectionEnds;

    const days: WeekCourse[][] = [];
    for (let d = 0; d < 7; d++) {
      const list: WeekCourse[] = [];
      for (let r = 0; r < 5; r++) {
        const cell: CellData | null = tt.findCell(r, d);
        if (cell === null) {
          continue;
        }
        for (let i = 0; i < cell.entries.length; i++) {
          const e: CourseEntry = cell.entries[i];
          const c: WeekCourse = new WeekCourse();
          c.name = e.courseName;
          c.room = e.room.length > 0 && e.campus.length > 0
            ? (e.room + '(' + e.campus + ')') : e.room;
          c.teacher = e.teacher;
          c.row = r;
          c.startWeek = e.startWeek;
          c.endWeek = e.endWeek;
          c.parity = e.parity;
          list.push(c);
        }
      }
      days.push(list);
      w.total += list.length;
    }
    w.days = days;
    return w;
  }

  /** MM/DD */
  private static md(m: number, d: number): string {
    const mm: string = m < 10 ? ('0' + m.toString()) : m.toString();
    const dd: string = d < 10 ? ('0' + d.toString()) : d.toString();
    return mm + '/' + dd;
  }
}
