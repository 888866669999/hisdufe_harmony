/*
 * ReminderPlan：上课提醒的排期计算
 *
 * 单独成文件的原因：这里全是纯计算，不碰任何 HarmonyOS API，
 * 因此可以在 Node 里直接跑单测（见 testdata/run-tests.mjs）。
 * ClassNotifier 负责「怎么发」，本文件只负责「什么时候发什么」。
 *
 * 排期规则：
 *   - 只看未来 7 天。应用内定时器方案要求进程存活，跨度太大没有意义；
 *     代理提醒可用时由系统长期托管，也仍然按这个窗口滚动续排。
 *   - 每一天单独算它属于第几周。**不能**用「今天第几周」套给整段窗口：
 *     若今天是周五，窗口会跨到下周，周一那节课的单双周/周次区间判断就错了。
 *   - 单双周与周次区间沿用 CourseEntry.isActiveInWeek，与课表显示保持同一套语义。
 */

import { Timetable, CellData, CourseEntry } from './Models';
import { WeekCalc } from '../common/WeekCalc';

/** 一个节次的起始信息（由 SectionTimeStore 提供，这里只做值传递） */
export class SectionStart {
  label: string = '';
  /** 起始时刻文本，如 "08:00" */
  start: string = '';
  /** 起始时刻的分钟数（0:00 起算），解析失败为 -1 */
  startMinutes: number = -1;

  constructor(label: string, start: string, startMinutes: number) {
    this.label = label;
    this.start = start;
    this.startMinutes = startMinutes;
  }
}

/** 一条待触发的上课提醒 */
export class PendingNotice {
  /** 触发时刻的本地毫秒时间戳 */
  at: number = 0;
  /** 课程名 */
  title: string = '';
  /** 补充信息：节次时间 · 教室 · 教师 */
  content: string = '';
  /** 去重与取消用的稳定键（含日期，同一天同一节同一课只提醒一次） */
  key: string = '';
}

export class ReminderPlan {
  /** 排期窗口长度（天） */
  static readonly WINDOW_DAYS: number = 7;
  /** 节次数（与课表行数一致） */
  static readonly SECTION_ROWS: number = 5;

  private static pad2(n: number): string {
    return n < 10 ? '0' + n.toString() : n.toString();
  }

  /**
   * 生成未来若干天的上课提醒。
   * @param timetable   课表
   * @param startMonday 第 1 周周一（YYYY-MM-DD），为空表示尚未设置，直接返回空
   * @param advanceMinutes 提前多少分钟提醒
   * @param maxWeeks    学期最大周数（超出视为未知，不排）
   * @param sections    各节次起始信息，索引与课表行一一对应
   * @param nowMs       当前时刻（显式传入，便于单测固定时间）
   */
  static buildUpcoming(timetable: Timetable, startMonday: string, advanceMinutes: number,
    maxWeeks: number, sections: SectionStart[], nowMs: number): PendingNotice[] {
    const out: PendingNotice[] = [];
    if (startMonday.length === 0) {
      return out;
    }
    const now: Date = new Date(nowMs);

    for (let off = 0; off < ReminderPlan.WINDOW_DAYS; off++) {
      const d: Date = new Date(now.getFullYear(), now.getMonth(), now.getDate() + off);
      // 该日属于第几周：逐日计算，跨周时才不会用错单双周
      const dayWeek: number = WeekCalc.weekNumber(startMonday, d, maxWeeks);
      if (dayWeek <= 0) {
        continue;
      }
      // 周一=0 .. 周日=6，与课表列序一致
      const col: number = d.getDay() === 0 ? 6 : d.getDay() - 1;

      // 当天 00:00 的本地时间戳，加上「起始分钟 - 提前量」得到提醒时刻
      const dayStartMs: number = new Date(d.getFullYear(), d.getMonth(), d.getDate(), 0, 0, 0).getTime();
      const dateKey: string = d.getFullYear().toString() + '-' +
        ReminderPlan.pad2(d.getMonth() + 1) + '-' + ReminderPlan.pad2(d.getDate());

      for (let r = 0; r < ReminderPlan.SECTION_ROWS; r++) {
        if (r >= sections.length) {
          break;
        }
        const st: SectionStart = sections[r];
        if (st.startMinutes < 0) {
          continue;
        }
        const cell: CellData | null = timetable.findCell(r, col);
        if (cell === null) {
          continue;
        }
        const at: number = dayStartMs + (st.startMinutes - advanceMinutes) * 60 * 1000;
        // 已经过去的不排（补发没有意义，反而会在启动瞬间弹一堆）
        if (at <= nowMs) {
          continue;
        }

        for (let i = 0; i < cell.entries.length; i++) {
          const e: CourseEntry = cell.entries[i];
          if (!e.isActiveInWeek(dayWeek)) {
            continue;
          }
          let place: string = e.room;
          if (e.campus.length > 0 && e.room.length > 0) {
            place = e.room + '(' + e.campus + ')';
          }
          const p: PendingNotice = new PendingNotice();
          p.at = at;
          p.title = e.courseName;
          p.content = st.start + ' ' + st.label +
            (place.length > 0 ? ' · ' + place : '') +
            (e.teacher.length > 0 ? ' · ' + e.teacher : '');
          p.key = dateKey + '|' + r.toString() + '|' + e.courseName;
          out.push(p);
        }
      }
    }
    out.sort((a: PendingNotice, b: PendingNotice) => a.at - b.at);
    return out;
  }
}
