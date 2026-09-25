/*
 * AcademicCalendar：学校官方的**作息**数据（只有作息，没有校历日期）
 *
 * 数据来源：山东财经大学「校园服务 → 最新校历」页面
 *   https://www.sdufe.edu.cn/xyfw/zxxl.htm
 *   页面正文给出「日常教学时刻表」，校历以两张图片形式挂在页面上。
 *
 * 为什么作息要内置成数据、而不是每次去网上抓：
 *   作息时间直接决定「上课提醒」的触发时刻，抓不到就会算错；
 *   内置一份权威值 + 本地可改，比每次联网更可靠。
 *
 * 注意：作息时间与教务系统课表页面**并不一致**。
 *   课表页面只给节次名称（「第一、二节」），不给时刻；
 *   官方作息表才是真正的时间依据。两者曾经对不上（应用内旧默认值是
 *   08:00 起），现已按官方表更正。
 *
 * ===== 这里只有作息，没有校历日期（2026-09 改）=====
 * 早先这里还有硬编码的 `SEMESTER_CALENDARS`（开学日、总周数、假期备注），
 * 那是人工从校历图片上转录的：**录一次就固定了**，换学年后就是错的，
 * 而界面上看不出来。那部分已删除，改由教务系统的**教学周历**实时提供 ——
 * 见 data/SemesterCalendarService.ets。
 * 校历图片本身也不再随包内置（resources/rawfile/calendar_2026_*.jpg 已删），
 * 原因同理：一张可能过期的校历比一块空缺更危险。
 */

/** 节次作息的权威默认值（官方「日常教学时刻表」，2026 年 7 月更新） */
export class OfficialSection {
  /** 课表中的行号（0 起） */
  row: number = 0;
  /** 教科书式标签，与课表行一致 */
  label: string = '';
  /** 起始时刻 */
  start: string = '';
  /** 结束时刻 */
  end: string = '';

  constructor(row: number, label: string, start: string, end: string) {
    this.row = row;
    this.label = label;
    this.start = start;
    this.end = end;
  }
}

/**
 * 官方日常教学时刻表，按课表的 5 个行归并。
 *
 *   第一、二节      8:30-10:00
 *   第三、四节      10:20-11:50   （10:00-10:20 课间休息）
 *   第五、六节      14:00-15:30
 *   第七、八节      15:50-17:20   （15:30-15:50 课间休息）
 *   第九~十一节     18:40-21:05   （第九、十节 18:40-20:10，休息 10 分钟，
 *                                   第十一节 20:20-21:05）
 */
export const OFFICIAL_SECTIONS: OfficialSection[] = [
  new OfficialSection(0, '第一、二节', '08:30', '10:00'),
  new OfficialSection(1, '第三、四节', '10:20', '11:50'),
  new OfficialSection(2, '第五、六节', '14:00', '15:30'),
  new OfficialSection(3, '第七、八节', '15:50', '17:20'),
  new OfficialSection(4, '第九~十一节', '18:40', '21:05')
];

/**
 * 课间休息。
 * 用 followsRow 指向「排在哪个节次之后」，而不是按名称匹配 ——
 * 官方表里写的是「第九、十节」休息，而课表行名是「第九~十一节」，
 * 两者字面不同，按名称匹配会把这个课间悄悄漏掉。
 */
export class OfficialBreak {
  /** 排在第几行（0 起的课表行号）之后 */
  followsRow: number = 0;
  start: string = '';
  end: string = '';

  constructor(followsRow: number, start: string, end: string) {
    this.followsRow = followsRow;
    this.start = start;
    this.end = end;
  }
}

/** 官方课间休息安排 */
export const OFFICIAL_BREAKS: OfficialBreak[] = [
  new OfficialBreak(0, '10:00', '10:20'),
  new OfficialBreak(2, '15:30', '15:50'),
  new OfficialBreak(4, '20:10', '20:20')
];

export const CAMPUS_CALENDAR_PAGE: string = 'https://www.sdufe.edu.cn/xyfw/zxxl.htm';

export class AcademicCalendar {
  /** 按学期代码取校历；找不到返回 null */


  /**
   * 猜测某个学期代码对应的校历。
   * 教务系统的学期代码形如 2026-2027-1 / 2026-2027-2；
   * 若没有精确匹配，退化为「同学年同学期」，便于跨学年复用规则。
   */


  /** 该学期是否有同学期但不同学年的校历（用于提示「沿用往年规则」） */


  /** 官方作息表的纯文本行，用于设置页与课表页展示 */
  static sectionLines(): string[] {
    const out: string[] = [];
    for (let i = 0; i < OFFICIAL_SECTIONS.length; i++) {
      const s: OfficialSection = OFFICIAL_SECTIONS[i];
      out.push(s.label + '  ' + s.start + ' - ' + s.end);
      // 在对应节次后插入课间休息（按行号匹配，见 OfficialBreak 的说明）
      for (let j = 0; j < OFFICIAL_BREAKS.length; j++) {
        const b: OfficialBreak = OFFICIAL_BREAKS[j];
        if (b.followsRow === i) {
          out.push('课间休息  ' + b.start + ' - ' + b.end);
        }
      }
    }
    return out;
  }
}
