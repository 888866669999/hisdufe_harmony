/*
 * 今日课程卡片
 *
 * ===== 它自己算「今天」，而不是重画一份快照 =====
 * 卡片由系统进程触发渲染，不能联网，但做「按今天日期筛课、按时段标已上完」
 * 这类纯算术完全没问题 —— 而且**必须**在这里算，否则必然不及时：
 *
 * 早期版本由主应用把「今天」算好写进 preferences，卡片只负责重画。
 * 那样有三个改不掉的毛病：
 *   1. `done`（已上完）与「下一节」冻结在写入那一刻，一整天不再变化；
 *   2. 平台的周期刷新（最短 30 分钟）只是把同一份旧数据再画一遍，做了无用功；
 *   3. **跨天后仍显示昨天的课**，非得打开一次应用才纠正。
 *
 * 现在主应用写的是**整周**课表（含每门课的周次区间与单双周、每个节次的
 * 起止时刻，键名 `card_week`，见 CardSnapshotStore.buildWeek），
 * 卡片每次渲染都按当前时间重新筛选与排序。于是系统每次周期回调、主应用
 * 每次推送、以及节次边界闹钟（见 TodayCourseFormAbility.scheduleNext）
 * 得到的都是**当下正确**的内容，跨天自愈，全程不需要应用在后台运行。
 *
 * 读不到周级数据时回退到旧的今日快照（`card_snapshot`），
 * 这样升级过程中桌面上的旧卡片不会空白。
 *
 * 载荷结构与 Flutter 端（`card_snapshot_store.dart` 的 buildWeek +
 * `TodayCourseWidgetProvider.kt`）逐字段对齐，两端行为一致。
 */
interface CardCourse {
  time: string;
  name: string;
  room: string;
  teacher: string;
  done: boolean;
}

interface CardSnapshot {
  at: number;
  weekday: string;
  date: string;
  week: number;
  hasCourse: boolean;
  courses: CardCourse[];
  nextText: string;
}

/** 周级载荷里的一门课（键名与主应用 buildWeek 产出的 JSON 一致） */
interface WeekCourse {
  name: string;
  room: string;
  teacher: string;
  row: number;
  startWeek: number;
  endWeek: number;
  parity: number;
}

/** 周级载荷 */
interface WeekPayload {
  at: number;
  semester: string;
  startMonday: string;
  maxWeeks: number;
  sections: string[];
  sectionEnds: string[];
  total: number;
  days: WeekCourse[][];
}

/** 一行要显示的内容（渲染期算出来的） */
class Row2 {
  time: string = '';
  end: string = '';
  name: string = '';
  room: string = '';
  done: boolean = false;
}

/** 把 "HH:mm" 转成当天第几分钟；解析不出返回 -1 */
function toMinutes(t: string): number {
  if (t === undefined || t === null || t.length < 3) {
    return -1;
  }
  const at: number = t.indexOf(':');
  if (at <= 0) {
    return -1;
  }
  const h: number = parseInt(t.substring(0, at), 10);
  const m: number = parseInt(t.substring(at + 1), 10);
  if (isNaN(h) || isNaN(m)) {
    return -1;
  }
  return h * 60 + m;
}

/** 两位补零 */
function pad2(n: number): string {
  return n < 10 ? ('0' + n.toString()) : n.toString();
}

@Entry
@Component
struct TodayCourseCard {
  /** 由 formBindingData 注入：今日快照 JSON（兜底路径） */
  @LocalStorageProp('snapshot') snapshotJson: string = '';
  /** 由 formBindingData 注入：周级载荷 JSON（主路径） */
  @LocalStorageProp('week') weekJson: string = '';
  /** 由 formBindingData 注入：建议行数（会被下面的实测值覆盖） */
  @LocalStorageProp('maxRows') maxRows: string = '3';

  private snap(): CardSnapshot | null {
    if (this.snapshotJson.length === 0) {
      return null;
    }
    try {
      return JSON.parse(this.snapshotJson) as CardSnapshot;
    } catch (e) {
      return null;
    }
  }

  private week(): WeekPayload | null {
    if (this.weekJson.length === 0) {
      return null;
    }
    try {
      return JSON.parse(this.weekJson) as WeekPayload;
    } catch (e) {
      return null;
    }
  }

  /** 今天星期几，0=周一 .. 6=周日 */
  private todayDow(): number {
    const d: number = new Date().getDay();
    return d === 0 ? 6 : d - 1;
  }

  /** 从「第 1 周周一」推算当前教学周；算不出或超范围返回 0 */
  private weekNumber(startMonday: string, maxWeeks: number): number {
    if (startMonday.length === 0) {
      return 0;
    }
    const parts: string[] = startMonday.split('-');
    if (parts.length !== 3) {
      return 0;
    }
    const y: number = parseInt(parts[0], 10);
    const m: number = parseInt(parts[1], 10);
    const d: number = parseInt(parts[2], 10);
    if (isNaN(y) || isNaN(m) || isNaN(d)) {
      return 0;
    }
    const start: Date = new Date(y, m - 1, d);
    start.setHours(0, 0, 0, 0);
    // 归一到该周周一
    const startDow: number = start.getDay() === 0 ? 6 : start.getDay() - 1;
    start.setDate(start.getDate() - startDow);
    const now: Date = new Date();
    now.setHours(0, 0, 0, 0);
    const diffDays: number = Math.floor((now.getTime() - start.getTime()) / 86400000);
    if (diffDays < 0) {
      return 0;
    }
    const w: number = Math.floor(diffDays / 7) + 1;
    if (maxWeeks > 0 && w > maxWeeks) {
      return 0;
    }
    return w;
  }

  /** 该门课本周是否要上。与主应用 CourseEntry.isActiveInWeek 严格一致 */
  private activeInWeek(c: WeekCourse, week: number): boolean {
    // 周次未知时一律显示，宁可多显示也不要漏（与两端既有约定一致）
    if (week <= 0) {
      return true;
    }
    if (week < c.startWeek || week > c.endWeek) {
      return false;
    }
    if (c.parity === 1 && week % 2 === 0) {
      return false;
    }
    if (c.parity === 2 && week % 2 === 1) {
      return false;
    }
    return true;
  }

  /**
   * 按**当前时间**算出今天要显示的课程。
   *
   * 优先用周级载荷自己算；没有就退回旧的今日快照（升级过渡期）。
   */
  private rows(): Row2[] {
    const w: WeekPayload | null = this.week();
    if (w === null || w.days === undefined || w.days === null) {
      return this.rowsFromSnapshot();
    }
    const week: number = this.weekNumber(w.startMonday, w.maxWeeks);
    const dow: number = this.todayDow();
    const day: WeekCourse[] = (dow < w.days.length) ? w.days[dow] : [];
    const now: Date = new Date();
    const nowMin: number = now.getHours() * 60 + now.getMinutes();

    const out: Row2[] = [];
    if (day !== undefined && day !== null) {
      for (let i = 0; i < day.length; i++) {
        const c: WeekCourse = day[i];
        if (!this.activeInWeek(c, week)) {
          continue;
        }
        const r: number = c.row;
        const r2: Row2 = new Row2();
        r2.time = (r >= 0 && r < w.sections.length) ? w.sections[r] : '';
        r2.end = (r >= 0 && r < w.sectionEnds.length) ? w.sectionEnds[r] : '';
        r2.name = c.name;
        r2.room = c.room;
        // 以**下课时刻**判断是否上完：只按开始时刻会让正在上的那节课
        // 被误标成「已上完」（Flutter 端同样按结束时刻判断）
        const endMin: number = toMinutes(r2.end);
        const startMin: number = toMinutes(r2.time);
        r2.done = endMin >= 0 ? (endMin <= nowMin) : (startMin >= 0 && startMin < nowMin);
        out.push(r2);
      }
    }
    // 按上课时刻排序；解析不出时间的排到最后
    out.sort((a: Row2, b: Row2) => {
      const am: number = toMinutes(a.time);
      const bm: number = toMinutes(b.time);
      const av: number = am < 0 ? 99999 : am;
      const bv: number = bm < 0 ? 99999 : bm;
      return av - bv;
    });
    return out;
  }

  /** 兜底路径：旧「今日快照」里已经是算好的今天 */
  private rowsFromSnapshot(): Row2[] {
    const s: CardSnapshot | null = this.snap();
    const out: Row2[] = [];
    if (s === null || s.courses === undefined || s.courses === null) {
      return out;
    }
    for (let i = 0; i < s.courses.length; i++) {
      const c: CardCourse = s.courses[i];
      const r: Row2 = new Row2();
      r.time = c.time;
      r.name = c.name;
      r.room = c.room;
      r.done = c.done;
      out.push(r);
    }
    return out;
  }

  /** 标题：`第 N 周 · 周X MM/DD`；周次未知时省略前半段 */
  private header(): string {
    const w: WeekPayload | null = this.week();
    const cn: string[] = ['一', '二', '三', '四', '五', '六', '日'];
    const dow: number = this.todayDow();
    const now: Date = new Date();
    const dateText: string = pad2(now.getMonth() + 1) + '/' + pad2(now.getDate());
    if (w !== null) {
      const week: number = this.weekNumber(w.startMonday, w.maxWeeks);
      return (week > 0 ? ('第' + week.toString() + '周 · ') : '') + '周' + cn[dow] + ' ' + dateText;
    }
    const s: CardSnapshot | null = this.snap();
    if (s === null) {
      return 'hi山财';
    }
    return (s.week > 0 ? ('第' + s.week.toString() + '周 · ') : '') + '周' + s.weekday + ' ' + s.date;
  }

  /**
   * 这张卡片能显示几行 —— 由主应用按卡片尺寸注入（`maxRows`）。
   *
   * ===== 为什么不在卡片里自己量 =====
   * 表单（Form）里**不能用 `onAreaChange`**（编译期直接报
   * "can't support form application"）。卡片唯一的尺寸来源是创建/刷新时
   * 系统带上的 `DIMENSION_KEY`，由 FormAbility 解析后注入进来 ——
   * 这也是 FormKit 设计的用法。
   *
   * 早先两条推送路径都写死 `maxRows='4'`，于是 2*2 的卡片也被要求画 4 行；
   * 现在 FormAbility 每次都会按当前 dimension 算出正确的行数。
   */
  private rowLimit(): number {
    const n: number = parseInt(this.maxRows, 10);
    return (isNaN(n) || n <= 0) ? 3 : n;
  }

  /**
   * 「下一节」/「正在上」提示。
   *
   * 与 Flutter 端一致：
   *   - 有还没开始的课 → `下一节 08:30 高数 @7-120`
   *   - 全部已开始但有正在上的 → `正在上 高数`
   *   - 都上完了 → 不显示（空白比「今天结束了」更安静）
   */
  private statusText(): string {
    const list: Row2[] = this.rows();
    const now: Date = new Date();
    const nowMin: number = now.getHours() * 60 + now.getMinutes();
    for (let i = 0; i < list.length; i++) {
      const startMin: number = toMinutes(list[i].time);
      if (startMin >= 0 && startMin > nowMin) {
        return '下一节 ' + list[i].time + ' ' + list[i].name +
          (list[i].room.length > 0 ? (' @' + list[i].room) : '');
      }
    }
    // 没有「下一节」了：看有没有正在上的
    for (let i = 0; i < list.length; i++) {
      const startMin: number = toMinutes(list[i].time);
      const endMin: number = toMinutes(list[i].end);
      if (startMin >= 0 && startMin <= nowMin && endMin > nowMin) {
        return '正在上 ' + list[i].name;
      }
    }
    return '';
  }

  /** 计数栏文案：课程数 + 超出行数时的「另有 N 节未显示」 */
  private countText(): string {
    const total: number = this.rows().length;
    if (total === 0) {
      return '';
    }
    const hidden: number = total - this.rowLimit();
    return hidden > 0
      ? (total.toString() + ' 节 · 另有 ' + hidden.toString() + ' 节未显示')
      : (total.toString() + ' 节');
  }

  build() {
    Column() {
      Row() {
        Text(this.header())
          .fontSize(12)
          .fontColor('#FF1F71FF')
          .fontWeight(FontWeight.Medium)
        Blank()
        Text(this.countText())
          .fontSize(11)
          .fontColor('#99000000')
      }
      .width('100%')
      .padding({ bottom: 6 })

      Divider()
        .color('#1A000000')

      if (this.weekJson.length === 0 && this.snapshotJson.length === 0) {
        Column() {
          Text('打开应用后自动显示今日课程')
            .fontSize(12)
            .fontColor('#99000000')
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .width('100%')
      } else if (this.rows().length === 0) {
        Column() {
          Text('今天没有课')
            .fontSize(13)
            .fontColor('#99000000')
        }
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
        .width('100%')
      } else {
        Column({ space: 4 }) {
          ForEach(this.rows().slice(0, this.rowLimit()), (c: Row2) => {
            Row({ space: 6 }) {
              Text(c.time)
                .fontSize(11)
                .fontColor(c.done ? '#66000000' : '#FF1F71FF')
              Column({ space: 1 }) {
                // 已上完的课加删除线：只变淡色不够明确，用户会以为是
                // 「被漏掉的课」而不是「已经上过了」（Flutter 端同样处理）
                Text(c.name)
                  .fontSize(12)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .fontColor(c.done ? '#66000000' : '#FF000000')
                  .decoration({ type: c.done ? TextDecorationType.LineThrough : TextDecorationType.None })
                  .width('100%')
                if (c.room.length > 0) {
                  Text(c.room)
                    .fontSize(10)
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .fontColor('#99000000')
                    .decoration({ type: c.done ? TextDecorationType.LineThrough : TextDecorationType.None })
                    .width('100%')
                }
              }
              .layoutWeight(1)
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .alignItems(VerticalAlign.Center)
          }, (c: Row2, idx: number) => 'c-' + idx.toString() + '-' + c.time + c.name)
        }
        .width('100%')

        Blank()

        if (this.statusText().length > 0) {
          Text(this.statusText())
            .fontSize(11)
            .fontColor('#FF1F71FF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
      }
    }
    .width('100%')
    .height('100%')
    .padding(12)
    .alignItems(HorizontalAlign.Start)
    .backgroundColor('#FFFFFFFF')
    .borderRadius(12)
    // 点击卡片打开应用：用户看完「今天要上什么」的自然动作就是进去看详情。
    // 没有点击响应时整张卡片是「死」的，会被当成卡住了。
    //
    // 用 postCardAction 而不是 onClick：卡片运行在独立的表单进程里，
    // 没有页面路由能力，只有这个 API 能把点击转成一次 Ability 跳转。
    .onClick(() => {
      postCardAction(this, {
        action: 'router',
        abilityName: 'EntryAbility',
        params: { from: 'card' }
      });
    })
  }
}
