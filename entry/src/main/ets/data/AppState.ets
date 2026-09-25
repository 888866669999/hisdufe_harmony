/*
 * AppState：全局会话与应用状态
 *
 * 使用 AppStorage 让各页面共享登录态与已加载数据，避免重复请求。
 */
import { QzApi } from '../network/QzApi';
import { CookieJar } from '../network/CookieJar';
import { PrefStore } from '../data/PrefStore';
import { CredentialStore } from '../data/CredentialStore';
import { ClassNotifier } from '../data/ClassNotifier';
import { ElectiveRequirementStore } from '../data/ElectiveRequirementStore';
import { PageCache } from '../data/PageCache';
import { Timetable, ScoreRecord, StudentProfile } from '../model/Models';
import { Logger } from '../common/Logger';
import {
  AS_LOGGED_IN, AS_STUDENT_NAME, AS_STUDENT_ID, AS_HAS_CREDENTIAL, AS_REAUTH_PENDING,
  KEY_CARD_SNAPSHOT, KEY_LAST_SEMESTER, KEY_LAST_WEEK, KEY_LAST_SCORE_SEMESTER,
  KEY_CARD_FORM_IDS, KEY_CARD_WEEK
} from '../common/Constants';

/** AppStorage 键统一在 Constants 中定义，这里转出以保持既有引用可用 */
export { AS_LOGGED_IN, AS_STUDENT_NAME, AS_STUDENT_ID } from '../common/Constants';

/**
 * 会话探测结果。
 *
 * 为什么要把「网络失败」与「会话失效」分开：
 * 两者都拿不到正常页面，但含义完全相反 ——
 * 会话失效意味着需要重新验证；网络失败只说明此刻判断不了，
 * 必须**保持登录态不动**，否则一出校园网就会被误踢回登录页。
 */
export class SessionProbe {
  /** 服务器确认会话仍有效 */
  alive: boolean = false;
  /** 网络层失败，无法判断会话状态（不代表失效） */
  networkError: boolean = false;

  constructor(alive: boolean, networkError: boolean) {
    this.alive = alive;
    this.networkError = networkError;
  }
}

export class AppState {
  private static jar: CookieJar = new CookieJar();
  private static api: QzApi | null = null;

  /**
   * 已加载数据缓存。
   *
   * **只缓存课表**。其余（成绩 / 个人信息 / 培养方案 / 通选课 / 周历）
   * 一律不做会话级缓存，每次进入页面都向服务器重新取，以保证时效性 ——
   * 成绩刚出、培养方案被调整这类变化必须能立刻看到，
   * 而这几个页面本身访问频率很低，重复请求的代价可以接受。
   * 课表是例外：它按「账号 + 学期」落到本地文件（见 TimetableStore），
   * 用户允许在本地编辑课程，必须优先读本地以免改动被服务器数据覆盖。
   */
  static timetable: Timetable | null = null;
  static scores: ScoreRecord[] = [];
  static profile: StudentProfile | null = null;
  /** 当前登录账号（课表缓存分片的键） */
  static account: string = '';

  static apiInstance(): QzApi {
    if (AppState.api === null) {
      AppState.api = new QzApi(AppState.jar);
    }
    return AppState.api;
  }

  static cookieJar(): CookieJar {
    return AppState.jar;
  }

  /** 是否已登录（含从缓存恢复） */
  static isLoggedIn(): boolean {
    const v: boolean | undefined = AppStorage.get<boolean>(AS_LOGGED_IN);
    return v === true;
  }

  /**
   * 从持久化恢复会话。
   *
   * 设计要点（避免「每次切后台都要重新登录」）：
   *   1. 只要有已保存的 cookie 就**乐观进入主界面**，不阻塞等待服务器校验；
   *   2. 服务器校验放到后台进行，且**只有服务器明确要求重新登录**才清除会话；
   *      网络不可用（不在校园网、超时等）一律保持登录态，避免误踢；
   *   3. 校验成功后把服务器可能轮换过的 cookie 写回本地，延长可用时间。
   */
  static async restoreSession(): Promise<boolean> {
    const saved: string = await PrefStore.loadCookie();
    if (saved.length === 0) {
      return false;
    }
    AppState.jar.deserialize(saved);
    // 乐观放行：立刻进入主界面
    AppStorage.setOrCreate(AS_LOGGED_IN, true);
    // 后台静默校验，不阻塞 UI。
    // 加 .catch 兜底：这是 fire-and-forget 调用，若内部意外抛出，
    // 会变成未处理的 Promise rejection（ArkTS 下可能上报为应用异常）。
    AppState.verifySessionInBackground().catch(() => {
      Logger.info('session verify suppressed');
    });
    return true;
  }

  /**
   * 后台校验会话有效性。
   *
   * 关键行为：**无论会话是否失效、有没有保存凭据，这里都不退出登录**。
   *
   * 原因（按产品要求）：用户如果只是想看课表，而课表来自本地缓存、不需要联网，
   * 那就不该被打扰 —— 既不该跳回登录页，也不该弹任何登录窗。
   * 会话失效的后果因此被推迟到「真正需要联网的那一刻」：
   * 由 QzApi.ensureAuthed 置「等待重新验证」标记，界面弹出居中的重新登录弹窗。
   *
   * 这样「只看课表」永远是安静的；一旦点到成绩/培养/通选/空教室等需要请求的功能，
   * 才会看到弹窗（有凭据只需补验证码，无凭据给完整登录表单）。
   */
  static async verifySessionInBackground(): Promise<void> {
    const probe: SessionProbe = await AppState.probeSession();
    if (probe.networkError) {
      // 网络异常：保持登录态，等下次进入或下次请求再判断
      Logger.info('session verify skipped (network)');
      return;
    }
    if (probe.alive) {
      return;
    }
    const hasCred: boolean | undefined = AppStorage.get<boolean>(AS_HAS_CREDENTIAL);
    Logger.info('session stale (credential=' + (hasCred === true) +
      '): stay signed in, reauth on demand');
  }

  /**
   * 探测一次会话是否仍然有效，并在有效时回写服务器轮换过的 cookie。
   *
   * 单独抽出来的原因：冷启动校验与会话失效后的重验证需要的是**同一件事**，
   * 只是触发时机不同。共享一个实现可以保证两条路径的判定标准、
   * cookie 回写行为完全一致。
   *
   * 注意：本方法**只管探测，不弹窗、不退出登录、不改 AS_REAUTH_PENDING**。
   * 是否要弹重新验证弹窗由按需路径（QzApi.ensureAuthed）决定。
   */
  static async probeSession(): Promise<SessionProbe> {
    try {
      const alive: boolean = await AppState.apiInstance().isSessionAlive();
      if (alive) {
        // 服务器可能轮换过 JSESSIONID，回写最新值
        await PrefStore.saveCookie(AppState.jar.serialize());
        return new SessionProbe(true, false);
      }
      const hasCred: boolean = await CredentialStore.exists();
      AppStorage.setOrCreate(AS_HAS_CREDENTIAL, hasCred);
      return new SessionProbe(false, false);
    } catch (e) {
      return new SessionProbe(false, true);
    }
  }

  /** 会话被服务器判定失效时调用（业务请求也会触发） */
  static async handleAuthExpired(): Promise<void> {
    if (!AppStorage.get<boolean>(AS_LOGGED_IN)) {
      return;
    }
    Logger.warn('auth expired during request');
    await AppState.forceLogout();
  }

  /**
   * 清空所有「跟账号绑定」的内存缓存。
   *
   * 为什么必须集中做这件事：这些字段都是 static，进程内跨账号共享。
   * 若切账号（A 退出 → B 登录）时不清，B 会看到 A 的成绩/个人信息，
   * 属于数据串号。
   *
   * 注意：**只清内存，不动课表文件**。课表按「账号 + 学期」单独存盘
   * （见 TimetableStore.filePath），所以换回原账号时会自动读回本地缓存，
   * 用户的课表本地修改得以保留。
   */
  static clearUserCaches(): void {
    AppState.timetable = null;
    AppState.scores = [];
    AppState.profile = null;
  }

  /** 把当前内存中的会话写回本地（应用退到后台时调用，捕获服务器轮换的 cookie） */
  static async persistSession(): Promise<void> {
    if (!AppState.jar.isEmpty()) {
      await PrefStore.saveCookie(AppState.jar.serialize());
    }
  }

  /** 登录成功后持久化会话并预热用户信息 */

  static async onLoggedIn(account: string): Promise<void> {
    // 换账号时先清掉上一个账号的内存缓存，避免数据串号；
    // 同一账号重新登录（如会话续期）则保留缓存，避免白重取一遍。
    const prev: string = AppState.account;
    if (prev.length > 0 && prev !== account) {
      Logger.info('account switched, clearing in-memory caches');
      AppState.clearUserCaches();
    }
    AppState.account = account;
    await PrefStore.saveCookie(AppState.jar.serialize());
    AppStorage.setOrCreate(AS_LOGGED_IN, true);
    // 记录学号：既用于展示，也是课表缓存分片的键。
    // 必须落盘 —— AppStorage 只在内存里，冷启动就没了；
    // 之前这里只写 AppStorage，导致重启后账号未知、按账号找不到课表缓存，
    // 明明本地有课表却会去请求服务器。
    if (account.length > 0) {
      await PrefStore.saveAccount(account);
      AppStorage.setOrCreate(AS_STUDENT_ID, account);
    }
    // 登录成功后清掉「等待重新验证」标记：否则若上一个账号残留了该标记，
    // 新账号刚进来就会立刻弹出上一轮遗留的验证码弹窗。
    AppStorage.setOrCreate(AS_REAUTH_PENDING, false);
  }

  /** 会话恢复后补上账号（优先用已存的记住账号，否则用个人信息里的学号） */
  static async resolveAccount(): Promise<string> {
    if (AppState.account.length > 0) {
      return AppState.account;
    }
    const saved: string = await PrefStore.loadAccount();
    if (saved.length > 0) {
      AppState.account = saved;
      return saved;
    }
    const sid: string | undefined = AppStorage.get<string>(AS_STUDENT_ID);
    if (sid !== undefined && sid !== null && sid.length > 0) {
      AppState.account = sid;
      return sid;
    }
    return '';
  }

  /**
   * 退出登录时的完整清理：内存缓存 + 跟账号绑定的后台行为 + 持久化的账号相关键。
   *
   * 为什么必须集中、且要做到这么全：
   *   这些都是「跨账号共享」的状态，漏掉任何一项都会让 B 看到 A 的数据：
   *     - 内存字段（成绩/个人信息等）→ 见 clearUserCaches()
   *     - 应用内提醒定时器 → 否则继续按 A 的课表弹通知
   *     - 桌面卡片快照 → 卡片直接读这份持久化数据渲染，不清就显示 A 的今日课程
   *     - 已保存账号 → 课表缓存按账号分片，留着会让下一次读到 A 的课表
   *     - 上次学期/周次/成绩学期 → 会把 B 引导到 A 的学期
   *     - 等待重新验证标记 → 否则 B 登录瞬间弹出 A 遗留的验证码弹窗
   *     - 通选课要求学分 → 按专业录的，留着会以 A 的要求判断 B 的达标
   *
   * 刻意**不删**课表文件与系统日历日程：
   *   课表按「账号+学期」分文件保存，换回原账号要能读回本地修改；
   *   系统日历日程是用户主动开启、由系统托管的，退出登录通常只是临时的。
   */
  private static async clearAccountScopedState(): Promise<void> {
    // 1. 应用内提醒定时器（必须在清内存缓存之前停，否则定时器仍按旧课表跑）
    try {
      ClassNotifier.stopInAppChannel();
    } catch (e) {
      Logger.warn('stop in-app notifier failed');
    }

    // 2. 内存缓存
    AppState.clearUserCaches();

    // 3. 持久化里跟账号绑定的键
    //    注意：卡片快照的键在 Constants 中定义，这里直接用 PrefStore 清除，
    //    而不是引用 CardSnapshotStore —— 后者反过来依赖 AppState，会形成循环依赖。
    //
    //    账号必须**先取出来**：下面几句会把 remembered_account 清掉，
    //    之后 resolveAccount() 就再也问不出「要清哪个账号的数据」了。
    const account: string = await AppState.resolveAccount();
    try {
      // 通选课要求学分按账号分片：留着会让下一个账号以本账号的要求判断达标
      await ElectiveRequirementStore.clearAccount(account);
      // 页面缓存（成绩/培养方案/通选/个人信息/空教室/校历原文）。
      // **必须清**：缓存内容是上一个账号的数据。磁盘层按账号前缀分文件，
      // 不清就长期留在设备上；内存层更直接 —— 同一次进程内换个账号登录，
      // 旧条目仍在内存里。必须在下面 PrefStore.clearAccount() 清掉账号之前调用，
      // 否则就不知道要清哪个账号的数据了。
      PageCache.clearAccount(account);
      await PrefStore.putText(KEY_CARD_SNAPSHOT, '');
      // 周级载荷必须一并清掉：卡片会自己按它算「今天」，
      // 只清今日快照的话，换了账号仍能算出上一个账号的课表。
      await PrefStore.putText(KEY_CARD_WEEK, '');
      await PrefStore.clearAccount();
      await PrefStore.putText(KEY_LAST_SEMESTER, '');
      await PrefStore.putText(KEY_LAST_WEEK, '');
      await PrefStore.putText(KEY_LAST_SCORE_SEMESTER, '');
      // 顺带清掉已登记的卡片 id：换了账号后，旧卡片的 id 不该再被用于推送
      // （卡片本身仍由用户管理，我们只是不再主动更新它）
      await PrefStore.putText(KEY_CARD_FORM_IDS, '');
    } catch (e) {
      Logger.warn('clear account-scoped prefs failed');
    }

    // 4. 等待重新验证标记
    AppStorage.setOrCreate(AS_REAUTH_PENDING, false);
  }

  static async logout(): Promise<void> {
    AppState.jar.clear();
    await PrefStore.clearCookie();
    await AppState.clearAccountScopedState();
    AppState.account = '';
    AppStorage.setOrCreate(AS_LOGGED_IN, false);
    AppStorage.setOrCreate(AS_STUDENT_NAME, '');
    AppStorage.setOrCreate(AS_STUDENT_ID, '');
  }

  /**
   * 强制退出（没有可用凭据、只能回登录页时调用）。
   * 同样要走完整清理：否则用户以 B 登录后会看到 A 的数据与提醒。
   */
  static async forceLogout(): Promise<void> {
    AppState.jar.clear();
    await PrefStore.clearCookie();
    await AppState.clearAccountScopedState();
    AppState.account = '';
    AppStorage.setOrCreate(AS_LOGGED_IN, false);
    AppStorage.setOrCreate(AS_STUDENT_NAME, '');
    AppStorage.setOrCreate(AS_STUDENT_ID, '');
  }
}
