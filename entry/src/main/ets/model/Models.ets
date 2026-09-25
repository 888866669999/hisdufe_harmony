/*
 * 数据模型：与教务系统页面字段一一对应
 */

/** 单条课程安排（课表格内的一门课） */
export class CourseEntry {
  /** 本地唯一标识，便于编辑与删除（服务器数据也会分配） */
  id: string = '';
  courseName: string = '';
  teacher: string = '';
  room: string = '';
  campus: string = '';
  /** 原始周次文本，如 "1-18(周)"、"1-18(双周)" */
  weekText: string = '';
  /** 起始周 */
  startWeek: number = 1;
  /** 结束周 */
  endWeek: number = 18;
  /** 0=每周 1=单周 2=双周 */
  parity: number = 0;
  /** 是否为用户在本地新增或修改过的课程 */
  local: boolean = false;
  /**
   * 内容版本号。
   * 用途：编辑后自增，使界面里 ForEach 的 key 发生变化。
   * ArkUI 在 key 不变时会复用组件树，仅改文本字段不会重新渲染，
   * 表现为「保存后界面不刷新」，靠这个版本号规避。
   */
  rev: number = 0;

  /** 判断该课程在第 week 周是否有课 */
  isActiveInWeek(week: number): boolean {
    if (week <= 0) {
      return true;
    }
    if (week < this.startWeek || week > this.endWeek) {
      return false;
    }
    if (this.parity === 1 && week % 2 === 0) {
      return false;
    }
    if (this.parity === 2 && week % 2 === 1) {
      return false;
    }
    return true;
  }

  parityText(): string {
    if (this.parity === 1) {
      return '单周';
    }
    if (this.parity === 2) {
      return '双周';
    }
    return '';
  }

  /** 周次摘要，如 "1-18周"、"1-18周(双周)" */
  weekSummary(): string {
    let s: string = this.startWeek.toString() + '-' + this.endWeek.toString() + '周';
    const p: string = this.parityText();
    if (p.length > 0) {
      s = s + '(' + p + ')';
    }
    return s;
  }

  clone(): CourseEntry {
    const c: CourseEntry = new CourseEntry();
    c.id = this.id;
    c.courseName = this.courseName;
    c.teacher = this.teacher;
    c.room = this.room;
    c.campus = this.campus;
    c.weekText = this.weekText;
    c.startWeek = this.startWeek;
    c.endWeek = this.endWeek;
    c.parity = this.parity;
    c.local = this.local;
    c.rev = this.rev;
    return c;
  }
}

/** 课表一个格子的数据 */
export class CellData {
  /** 节次索引 0..4 */
  row: number = 0;
  /** 星期索引 0..6（周一..周日） */
  col: number = 0;
  entries: CourseEntry[] = [];

  /** 传给 UI 的展示文本（可能多门课） */
  displayText(): string {
    const parts: string[] = [];
    for (let i = 0; i < this.entries.length; i++) {
      parts.push(this.entries[i].courseName);
    }
    return parts.join('\n');
  }
}

/** 学期理论课表 */
export class Timetable {
  /** 当前学年学期，如 2026-2027-1 */
  semester: string = '';
  /** 当前筛选周次，空字符串表示“全部” */
  week: string = '';
  /** 可选学年学期列表 */
  semesters: string[] = [];
  /** 可选周次列表 */
  weeks: string[] = [];
  cells: CellData[] = [];
  /** 未排课表课程备注 */
  remark: string = '';
  /** 本地数据的关键时间戳（0 表示来自服务器且未改过） */
  cachedAt: number = 0;
  /** 是否存在本地修改 */
  edited: boolean = false;

  /** 取指定节次+星期的格子 */
  findCell(row: number, col: number): CellData | null {
    for (let i = 0; i < this.cells.length; i++) {
      const c: CellData = this.cells[i];
      if (c.row === row && c.col === col) {
        return c;
      }
    }
    return null;
  }

  /** 取或创建指定格子（编辑时空格也要能写入） */
  ensureCell(row: number, col: number): CellData {
    const existed: CellData | null = this.findCell(row, col);
    if (existed !== null) {
      return existed;
    }
    const cd: CellData = new CellData();
    cd.row = row;
    cd.col = col;
    this.cells.push(cd);
    return cd;
  }

  /** 移除空格子，避免缓存里堆积无内容的记录 */
  pruneEmptyCells(): void {
    const kept: CellData[] = [];
    for (let i = 0; i < this.cells.length; i++) {
      if (this.cells[i].entries.length > 0) {
        kept.push(this.cells[i]);
      }
    }
    this.cells = kept;
  }

  /** 统计本周（week=0 表示全部）有课的格子，用于空态判断 */
  hasAnyCourse(week: number): boolean {
    for (let i = 0; i < this.cells.length; i++) {
      const cell: CellData = this.cells[i];
      for (let j = 0; j < cell.entries.length; j++) {
        if (cell.entries[j].isActiveInWeek(week)) {
          return true;
        }
      }
    }
    return false;
  }

  /** 是否含本地修改的课程 */
  hasLocalEdits(): boolean {
    for (let i = 0; i < this.cells.length; i++) {
      const cell: CellData = this.cells[i];
      for (let j = 0; j < cell.entries.length; j++) {
        if (cell.entries[j].local) {
          return true;
        }
      }
    }
    return false;
  }
}

/** 一条成绩记录 */
export class ScoreRecord {
  index: string = '';
  semester: string = '';
  courseCode: string = '';
  courseName: string = '';
  score: string = '';
  credit: string = '';
  gpa: string = '';
  examType: string = '';
  courseNature: string = '';
  courseAttr: string = '';
  minor: string = '';

  /** 数值化学分，无法解析返回 0 */
  creditNumber(): number {
    const v: number = parseFloat(this.credit);
    return isNaN(v) ? 0 : v;
  }

  /** 数值化绩点，无法解析返回 -1（表示无绩点） */
  gpaNumber(): number {
    const v: number = parseFloat(this.gpa);
    return isNaN(v) ? -1 : v;
  }
}

/** 成绩汇总（客户端计算） */
export class ScoreSummary {
  count: number = 0;
  totalCredit: number = 0;
  /** 学分加权平均绩点 */
  weightedGpa: number = 0;
}

/** 个人信息条目 */
export class ProfileField {
  label: string;
  value: string;

  constructor(label: string, value: string) {
    this.label = label;
    this.value = value;
  }
}

/** 个人信息分组 */
export class ProfileSection {
  title: string;
  fields: ProfileField[];

  constructor(title: string, fields: ProfileField[]) {
    this.title = title;
    this.fields = fields;
  }
}

/** 个人信息（学籍卡片） */
export class StudentProfile {
  name: string = '';
  studentId: string = '';
  sections: ProfileSection[] = [];
}

/** 一个下拉选项（命名避开 ArkUI 全局的 SelectOption） */
export class ChoiceItem {
  label: string;
  value: string;

  constructor(label: string, value: string) {
    this.label = label;
    this.value = value;
  }
}

/** 周次与日期的对应（教学周历） */
export class WeekDate {
  week: number = 0;
  /**
   * 该周周一日期，格式 **YYYY-MM-DD**。
   *
   * 早期只存 MM-dd，导致「当前周」只能用字符串比较判断，
   * 跨年时会算错（"01-02" <= "12-20" 为真，会选到错误的周）。
   * 存完整年份才能正确比较。
   */
  monday: string = '';

  constructor(week: number, monday: string) {
    this.week = week;
    this.monday = monday;
  }
}

// ============================ 培养方案明细 ============================

/** 培养方案里的一门课程（课程设置总表的一行） */
export class PlanCourse {
  /** 课程体系，如「实践必修课」 */
  system: string = '';
  /** 选课组 */
  group: string = '';
  courseCode: string = '';
  courseName: string = '';
  /** 课程类别，如「实践必修」 */
  category: string = '';
  credit: string = '';
  /** 开设学期 */
  semester: string = '';
  /** 各学时分类 */
  lectureHours: string = '';
  practiceHours: string = '';
  seminarHours: string = '';
  labHours: string = '';
  computerHours: string = '';
  totalHours: string = '';

  creditNumber(): number {
    const v: number = parseFloat(this.credit);
    return isNaN(v) ? 0 : v;
  }
}

/** 按课程体系分组后的课程 */
export class PlanGroup {
  system: string;
  courses: PlanCourse[] = [];
  totalCredit: number = 0;

  constructor(system: string) {
    this.system = system;
  }
}

/** 培养方案明细 */
export class PlanDetail {
  /** 培养目标等说明文本（按段落） */
  introParagraphs: string[] = [];
  /** 详细说明（可选） */
  detailParagraphs: string[] = [];
  /** 课程设置总表 */
  courses: PlanCourse[] = [];
  /** 按体系分组 */
  groups: PlanGroup[] = [];
  /** 合计学分（页面「小计/合计」行） */
  totalCredit: number = 0;
  totalHours: number = 0;
  /** 培养方案 PDF 的相对地址（可能为空） */
  pdfPath: string = '';

  /** 按体系分组并汇总学分 */
  buildGroups(): void {
    const order: string[] = [];
    const map: Map<string, PlanGroup> = new Map<string, PlanGroup>();
    for (let i = 0; i < this.courses.length; i++) {
      const c: PlanCourse = this.courses[i];
      let key: string = c.system;
      if (key.length === 0) {
        key = '未分类';
      }
      let g: PlanGroup | undefined = map.get(key);
      if (g === undefined) {
        g = new PlanGroup(key);
        map.set(key, g);
        order.push(key);
      }
      g.courses.push(c);
      g.totalCredit += c.creditNumber();
    }
    const out: PlanGroup[] = [];
    for (let i = 0; i < order.length; i++) {
      const g: PlanGroup | undefined = map.get(order[i]);
      if (g !== undefined) {
        out.push(g);
      }
    }
    this.groups = out;
  }
}

// ============================ 通选课修读情况 ============================

/** 通选课类别要求 */
export class ElectiveCategory {
  /** 类别名，如「安全教育类」 */
  name: string = '';
  /** 要求学分（大于等于），可能为空 */
  required: string = '';
  /** 已修学分 */
  earned: string = '';
  /** 正在修读 */
  ongoing: string = '';

  /** 已修 + 在修是否已达到要求（要求为空时视为无硬性要求） */
  satisfied(): boolean {
    const req: number = parseFloat(this.required);
    if (isNaN(req)) {
      return false;
    }
    const e: number = parseFloat(this.earned);
    const o: number = parseFloat(this.ongoing);
    const got: number = (isNaN(e) ? 0 : e) + (isNaN(o) ? 0 : o);
    return got >= req;
  }
}

/** 已修/在修的通选课 */
export class ElectiveCourse {
  courseCode: string = '';
  courseName: string = '';
  credit: string = '';
  /** 总成绩；未出分时为「正在修读」 */
  score: string = '';
  category: string = '';

  /** 是否正在修读（尚无成绩） */
  isOngoing(): boolean {
    return this.score.indexOf('正在修读') >= 0;
  }
}


/**
 * 一个大类 + 它下面的课程（界面按这个分组展示）。
 *
 * 学校原页面是两张独立的表：「类别修读情况」和「课程明细」，
 * 学生要自己按类别名对照。分组把两者合成一条线。
 */
export class ElectiveGroup {
  name: string = '';
  courses: ElectiveCourse[] = [];
  /** 汇总表里的要求信息；只在课程明细里出现、汇总表没有的大类为 null */
  info: ElectiveCategory | null = null;
  /**
   * 用户自录的要求学分（≥0 时生效，-1 表示未设置）。
   *
   * 为什么要这个覆盖值：学校「要求学分（大于等于）」那一列实测是空的，
   * 于是界面只能显示「学校未设置要求」、也画不出进度条 ——
   * 学生明明可以从培养方案查到自己要修多少，App 却帮不上忙。
   * 用户录一次后，达标判断与进度条都以这个值为准。
   *
   * 优先级：**用户自录 > 服务器**。用户手填的是他自己专业的准确要求，
   * 而服务器那一列要么为空、要么是学校统一口径，以用户为准更符合预期。
   */
  customRequired: number = -1;

  constructor(name: string) {
    this.name = name;
  }

  hasCourses(): boolean {
    return this.courses.length > 0;
  }

  /** 是否使用用户自录的要求（界面据此显示「修改」而不是「设置」） */
  hasCustomRequired(): boolean {
    return this.customRequired >= 0;
  }

  /** 能画进度条的前提：有正的分母（分母为 0 画出来没有意义） */
  canShowProgress(): boolean {
    const req: number = this.requiredNumber();
    return req > 0;
  }

  requiredNumber(): number {
    if (this.customRequired >= 0) {
      return this.customRequired;
    }
    const c: ElectiveCategory | null = this.info;
    if (c === null) {
      return -1;
    }
    const v: number = parseFloat(c.required);
    return isNaN(v) ? -1 : v;
  }

  earnedNumber(): number {
    const c: ElectiveCategory | null = this.info;
    if (c === null) {
      return 0;
    }
    const v: number = parseFloat(c.earned);
    return isNaN(v) ? 0 : v;
  }

  ongoingNumber(): number {
    const c: ElectiveCategory | null = this.info;
    if (c === null) {
      return 0;
    }
    const v: number = parseFloat(c.ongoing);
    return isNaN(v) ? 0 : v;
  }
}

/** 通选课修读情况汇总 */
export class ElectiveReport {
  categories: ElectiveCategory[] = [];
  courses: ElectiveCourse[] = [];
  /** 总学分：已修 */
  totalEarned: string = '';
  /** 总学分：正在修读 */
  totalOngoing: string = '';

  /** 已修学分总和（数值） */
  earnedNumber(): number {
    const v: number = parseFloat(this.totalEarned);
    return isNaN(v) ? 0 : v;
  }

  ongoingNumber(): number {
    const v: number = parseFloat(this.totalOngoing);
    return isNaN(v) ? 0 : v;
  }

  /**
   * 按「大类 → 具体课程」归并。
   *
   * 两条刻意的规则：
   *   1. 汇总表里的大类**全都保留**（即使本学期没有课）—— 修读要求挂在
   *      大类上，藏起来学生就看不到还差多少学分；
   *   2. 课程明细里出现、汇总表却没有的大类（学校数据不同步时会发生）
   *      也追加进来，避免课程凭空消失。
   *
   * 两边都保持学校给出的原始顺序，不重排。
   */
  grouped(): ElectiveGroup[] {
    const out: ElectiveGroup[] = [];
    const byName: Map<string, ElectiveGroup> = new Map<string, ElectiveGroup>();
    for (let i = 0; i < this.categories.length; i++) {
      const c: ElectiveCategory = this.categories[i];
      if (byName.has(c.name)) {
        continue;   // 汇总表出现重名时只认第一条，不重复建组
      }
      const g: ElectiveGroup = new ElectiveGroup(c.name);
      g.info = c;
      byName.set(c.name, g);
      out.push(g);
    }
    for (let i = 0; i < this.courses.length; i++) {
      const c: ElectiveCourse = this.courses[i];
      const key: string = c.category.length === 0 ? '未标注类别' : c.category;
      let g: ElectiveGroup | undefined = byName.get(key);
      if (g === undefined) {
        g = new ElectiveGroup(key);
        byName.set(key, g);
        out.push(g);
      }
      g.courses.push(c);
    }
    return out;
  }
}
