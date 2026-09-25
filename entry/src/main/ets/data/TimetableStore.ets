/*
 * TimetableStore：课表本地持久化
 *
 * 为什么需要它：
 *   - 用户要能修改课表，而服务器数据是只读的，修改必须缓存到本地；
 *   - 已经拉取过的「某用户 + 某学期」课表，再次选择时直接读本地，
 *     不再请求服务器，既省流量也让本地的修改得以保留。
 *
 * 存储形态：应用私有目录下的 JSON 文件，按账号+学期分片：
 *   filesDir/timetable/<account>_<semester>.json
 * 文件在应用沙箱内，其他应用无法读取。
 */
import { fileIo } from '@kit.CoreFileKit';
import { Timetable, CellData, CourseEntry } from '../model/Models';
import { ContextHolder } from '../common/ContextHolder';
import { Logger } from '../common/Logger';

/** 序列化用的课程条目 */
interface CourseJson {
  id: string;
  name: string;
  teacher: string;
  room: string;
  campus: string;
  startWeek: number;
  endWeek: number;
  parity: number;
  local: boolean;
  rev: number;
  row: number;
  col: number;
}

/** 序列化用的课表文件结构 */
interface TimetableJson {
  version: number;
  account: string;
  semester: string;
  savedAt: number;
  remark: string;
  /** 可选学期列表（缓存命中后仍需用于切换），旧版本文件可能没有 */
  semesters: string[];
  /** 可选周次列表 */
  weeks: string[];
  courses: CourseJson[];
}

export class TimetableStore {
  private static readonly DIR: string = 'timetable';
  private static readonly VERSION: number = 1;

  /** 目录是否存在，避免重复建目录 */
  private static dirReady: boolean = false;

  private static baseDir(): string {
    const ctx = ContextHolder.get();
    if (ctx === null) {
      return '';
    }
    return ctx.filesDir + '/' + TimetableStore.DIR;
  }

  private static ensureDir(): string {
    const dir: string = TimetableStore.baseDir();
    if (dir.length === 0) {
      return '';
    }
    if (!TimetableStore.dirReady) {
      try {
        if (!fileIo.accessSync(dir)) {
          fileIo.mkdirSync(dir, true);
        }
        TimetableStore.dirReady = true;
      } catch (e) {
        Logger.warn('timetable dir create failed');
        return '';
      }
    }
    return dir;
  }

  /** 文件名里的账号与学期需要做安全化，避免路径字符 */
  private static safe(s: string): string {
    let out: string = '';
    for (let i = 0; i < s.length; i++) {
      const ch: string = s.charAt(i);
      if ((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
        ch === '-' || ch === '_' || ch === '.') {
        out = out + ch;
      } else {
        out = out + '_';
      }
    }
    return out.length > 0 ? out : 'default';
  }

  private static filePath(account: string, semester: string): string {
    const dir: string = TimetableStore.ensureDir();
    if (dir.length === 0) {
      return '';
    }
    return dir + '/' + TimetableStore.safe(account) + '_' + TimetableStore.safe(semester) + '.json';
  }

  /**
   * 列出缓存目录里出现过的**全部账号**（去重）。
   *
   * 用途：判断本机是否「只有一个账号用过课表」。
   * 课表缓存按账号分文件，若账号未知就只能靠猜；
   * 只有当设备上确实只存在一个账号时，猜才是安全的。
   */
  static cachedAccounts(): string[] {
    const dir: string = TimetableStore.ensureDir();
    const out: string[] = [];
    if (dir.length === 0) {
      return out;
    }
    try {
      const names: string[] = fileIo.listFileSync(dir);
      for (let i = 0; i < names.length; i++) {
        const name: string = names[i];
        if (name.lastIndexOf('.json') !== name.length - 5) {
          continue;
        }
        const body: string = name.substring(0, name.length - 5);
        const at: number = body.lastIndexOf('_');
        if (at <= 0) {
          continue;
        }
        const acc: string = body.substring(0, at);
        if (acc.length > 0 && out.indexOf(acc) < 0) {
          out.push(acc);
        }
      }
    } catch (e) {
      Logger.warn('timetable dir scan failed');
    }
    return out;
  }

  /**
   * 在缓存目录里找「某学期」的课表文件，返回它所属的账号。
   *
   * 为什么需要它：缓存文件名是 `<账号>_<学期>.json`，若账号未知
   * （用户没勾过「记住账号密码」、或 AppStorage 里的学号在冷启动后丢失），
   * 按账号拼路径就找不到文件，于是明明本地有课表却仍去请求服务器 ——
   * 而用户可能只是想看课表，会话又恰好失效，就会被弹登录框。
   *
   * **安全约束（重要）**：只有当本机只存在**一个**账号的缓存时才允许返回。
   * 否则「猜账号」可能把别人（同机另一个账号）的课表读出来，属于跨账号串号 ——
   * 这种宁可让用户重新联网取，也不能猜错。
   */
  static findAccountForSemester(semester: string): string {
    const dir: string = TimetableStore.ensureDir();
    if (dir.length === 0 || semester.length === 0) {
      return '';
    }
    // 多账号共存时不做任何猜测
    const accounts: string[] = TimetableStore.cachedAccounts();
    if (accounts.length !== 1) {
      if (accounts.length > 1) {
        Logger.info('skip timetable guess: ' + accounts.length + ' accounts cached');
      }
      return '';
    }
    const only: string = accounts[0];
    // 确认该账号确实有这一学期的文件（而不是只凭账号存在就返回）
    if (TimetableStore.has(only, semester)) {
      Logger.info('timetable cache hit by unique-account fallback, account=' + only);
      return only;
    }
    return '';
  }

  /** 本地已缓存过课表的全部学期（去重），用于学期选择兜底 */
  static cachedSemesters(): string[] {
    const dir: string = TimetableStore.ensureDir();
    const out: string[] = [];
    if (dir.length === 0) {
      return out;
    }
    try {
      const names: string[] = fileIo.listFileSync(dir);
      for (let i = 0; i < names.length; i++) {
        const name: string = names[i];
        if (name.lastIndexOf('.json') !== name.length - 5) {
          continue;
        }
        // 文件名形如 <account>_<semester>.json；学期名不含下划线，
        // 因此取最后一个下划线之后、.json 之前的部分。
        const body: string = name.substring(0, name.length - 5);
        const at: number = body.lastIndexOf('_');
        if (at < 0 || at + 1 >= body.length) {
          continue;
        }
        const sem: string = body.substring(at + 1);
        if (sem.length > 0 && out.indexOf(sem) < 0) {
          out.push(sem);
        }
      }
    } catch (e) {
      Logger.warn('timetable dir scan failed');
    }
    return out;
  }

  /** 是否存在该「账号+学期」的本地缓存 */
  static has(account: string, semester: string): boolean {
    if (account.length === 0 || semester.length === 0) {
      return false;
    }
    const p: string = TimetableStore.filePath(account, semester);
    if (p.length === 0) {
      return false;
    }
    try {
      return fileIo.accessSync(p);
    } catch (e) {
      return false;
    }
  }

  /** 从缓存读取；不存在或损坏返回 null */
  static load(account: string, semester: string): Timetable | null {
    const p: string = TimetableStore.filePath(account, semester);
    if (p.length === 0) {
      return null;
    }
    try {
      if (!fileIo.accessSync(p)) {
        return null;
      }
      const text: string = fileIo.readTextSync(p);
      if (text.length === 0) {
        return null;
      }
      const json: TimetableJson = JSON.parse(text) as TimetableJson;
      if (json === null || json.courses === undefined || json.courses === null) {
        return null;
      }
      const tt: Timetable = new Timetable();
      tt.semester = json.semester;
      tt.remark = json.remark;
      tt.cachedAt = json.savedAt;
      tt.edited = false;
      // 学期/周次列表也要一并恢复，否则缓存命中后无法切换学期
      if (json.semesters !== undefined && json.semesters !== null) {
        tt.semesters = json.semesters;
      }
      if (json.weeks !== undefined && json.weeks !== null) {
        tt.weeks = json.weeks;
      }
      for (let i = 0; i < json.courses.length; i++) {
        const cj: CourseJson = json.courses[i];
        const cell: CellData = tt.ensureCell(cj.row, cj.col);
        const e: CourseEntry = new CourseEntry();
        e.id = cj.id;
        e.courseName = cj.name;
        e.teacher = cj.teacher;
        e.room = cj.room;
        e.campus = cj.campus;
        e.startWeek = cj.startWeek;
        e.endWeek = cj.endWeek;
        e.parity = cj.parity;
        e.local = cj.local;
        e.rev = (cj.rev === undefined || cj.rev === null) ? 0 : cj.rev;
        e.weekText = e.weekSummary();
        cell.entries.push(e);
        if (e.local) {
          tt.edited = true;
        }
      }
      tt.pruneEmptyCells();
      Logger.info('timetable loaded from cache: ' + tt.cells.length + ' cells, edited=' + tt.edited);
      return tt;
    } catch (e) {
      Logger.warn('timetable cache read failed');
      return null;
    }
  }

  /** 写入缓存（含本地修改） */
  static save(account: string, tt: Timetable): boolean {
    if (account.length === 0 || tt.semester.length === 0) {
      return false;
    }
    const p: string = TimetableStore.filePath(account, tt.semester);
    if (p.length === 0) {
      return false;
    }
    const courses: CourseJson[] = [];
    for (let i = 0; i < tt.cells.length; i++) {
      const cell: CellData = tt.cells[i];
      for (let j = 0; j < cell.entries.length; j++) {
        const e: CourseEntry = cell.entries[j];
        const cj: CourseJson = {
          id: e.id,
          name: e.courseName,
          teacher: e.teacher,
          room: e.room,
          campus: e.campus,
          startWeek: e.startWeek,
          endWeek: e.endWeek,
          parity: e.parity,
          local: e.local,
          rev: e.rev,
          row: cell.row,
          col: cell.col
        };
        courses.push(cj);
      }
    }
    const out: TimetableJson = {
      version: TimetableStore.VERSION,
      account: account,
      semester: tt.semester,
      savedAt: Date.now(),
      remark: tt.remark,
      semesters: tt.semesters,
      weeks: tt.weeks,
      courses: courses
    };
    // 用 try/finally 保证文件句柄一定关闭：writeSync 若抛错而没关闭，
    // fd 会永久泄漏 —— 课表保存是高频路径（每次编辑/每次拉取都写），
    // 反复失败最终会耗尽句柄。与 PdfStore.download 保持同一写法。
    let file: fileIo.File | null = null;
    try {
      const text: string = JSON.stringify(out);
      file = fileIo.openSync(p,
        fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.CREATE | fileIo.OpenMode.TRUNC);
      fileIo.writeSync(file.fd, text);
      Logger.info('timetable saved: ' + courses.length + ' courses, edited=' + tt.hasLocalEdits());
      return true;
    } catch (e) {
      Logger.error('timetable save failed');
      return false;
    } finally {
      if (file !== null) {
        try {
          fileIo.closeSync(file);
        } catch (inner) {
          // 忽略：关闭失败不影响主流程
        }
      }
    }
  }


  /**
   * 删除某学期的本地缓存。
   * 用于「恢复为服务器数据」：删掉本地后下次进入会重新拉取。
   */
  static remove(account: string, semester: string): boolean {
    const p: string = TimetableStore.filePath(account, semester);
    if (p.length === 0) {
      return false;
    }
    try {
      if (fileIo.accessSync(p)) {
        fileIo.unlinkSync(p);
      }
      return true;
    } catch (e) {
      Logger.warn('timetable cache remove failed');
      return false;
    }
  }
}
