/*
 * CourseScheduleMath：课表 → 日历事件的「重复规则」计算
 *
 * 单独成文件的原因：这是系统日历同步里最容易出错、也最值得单测的部分。
 * 生成 Calendar 事件本身要 @kit.CalendarKit，没法在 Node 里跑；
 * 但「从第几周开始、每几周一次、总共几次、起止时刻」全是纯计算，可以。
 *
 * 规则说明：
 *   - 每周都上的课（parity=0）：interval=1，次数 = 剩余周数
 *   - 单周 / 双周的课（parity=1/2）：interval=2，次数 = 剩余周里的符合奇偶者个数
 *   - 起点必须是该课**第一次真正上课**的那一周。若起点落在不该上的那一周，
 *     interval=2 会让整个系列错位一整周（这是最容易踩的坑，测试里专门锁住）。
 */

import { CourseEntry } from './Models';
import { WeekCalc, DateParts } from '../common/WeekCalc';
import { SectionTimeStore } from '../data/SectionTimeStore';

/** 一条待写入系统日历的日程（与 Calendar 事件字段对应，但不依赖 SDK 类型） */
export class CourseEvent {
  /** 事件标题（不含前缀） */
  title: string = '';
  /** 地点文本，已合并教室与校区 */
  location: string = '';
  /** 教师 */
  description: string = '';
  /** 开始时刻（本地毫秒时间戳） */
  startMs: number = 0;
  /** 结束时刻（本地毫秒时间戳） */
  endMs: number = 0;
  /** 从该周开始（用于展示与排查） */
  fromWeek: number = 0;
  /** 重复间隔（周）：1=每周，2=隔周 */
  interval: number = 1;
  /** 重复次数 */
  count: number = 1;
  /** 该课总次数（含起点当次） */
  totalTimes: number = 0;
}

export class CourseScheduleMath {
  /**
   * 为「课表格子里的某一门课」计算日历事件。
   *
   * @param course       课程
   * @param row          课表行号（0 起，对应节次）
   * @param col          课表列号（0=周一 .. 6=周日）
   * @param startMonday  第 1 周周一（YYYY-MM-DD）
   * @param fromWeek     从第几周开始排（通常为当前周）
   * @param sectionStart 该节次的起始 "HH:mm"
   * @param sectionEnd   该节次的结束 "HH:mm"
   * @returns 事件；若该课在 fromWeek 之后不再上课，返回 null
   */
  static buildEvent(course: CourseEntry, col: number, startMonday: string,
    fromWeek: number, sectionStart: string, sectionEnd: string): CourseEvent | null {
    if (startMonday.length === 0) {
      return null;
    }
    // 找该课在 fromWeek 及以后第一次真正上课的周。
    // 这一步是正确性的关键：单双周课的起点必须落在正确的奇偶周。
    let week: number = fromWeek;
    while (week <= course.endWeek && !course.isActiveInWeek(week)) {
      week++;
    }
    if (week > course.endWeek) {
      return null;
    }

    const day: DateParts | null = WeekCalc.dateOfDay(startMonday, week, col);
    if (day === null) {
      return null;
    }
    const startMin: number = SectionTimeStore.toMinutes(sectionStart);
    if (startMin < 0) {
      return null;
    }
    const endMin: number = SectionTimeStore.toMinutes(sectionEnd);

    const startMs: number = new Date(day.year, day.month - 1, day.day,
      Math.floor(startMin / 60), startMin % 60, 0, 0).getTime();
    const endMs: number = endMin >= 0
      ? new Date(day.year, day.month - 1, day.day,
        Math.floor(endMin / 60), endMin % 60, 0, 0).getTime()
      : startMs + 90 * 60 * 1000;

    // 重复间隔与次数
    const step: number = course.parity === 0 ? 1 : 2;
    let count: number = 0;
    for (let w = week; w <= course.endWeek; w += step) {
      if (course.isActiveInWeek(w)) {
        count++;
      }
    }
    if (count <= 0) {
      return null;
    }

    let place: string = course.room;
    if (course.campus.length > 0 && course.room.length > 0) {
      place = course.room + '(' + course.campus + ')';
    }

    const ev: CourseEvent = new CourseEvent();
    ev.title = course.courseName;
    ev.location = place;
    ev.description = course.teacher.length > 0 ? ('教师：' + course.teacher) : '';
    ev.startMs = startMs;
    ev.endMs = endMs;
    ev.fromWeek = week;
    ev.interval = step;
    ev.count = count;
    // 整学期该课的总次数（从第 1 周或 startWeek 起算），仅用于校验
    let total: number = 0;
    for (let w = course.startWeek; w <= course.endWeek; w++) {
      if (course.isActiveInWeek(w)) {
        total++;
      }
    }
    ev.totalTimes = total;
    return ev;
  }
}
