/*
 * PrefStore：基于 preferences 的本地持久化
 *
 * 安全约定：
 *   - 会话 cookie **不在这里明文保存**，走系统密钥库（见 saveCookie/loadCookie）
 *   - 记住的账号与偏好设置可以放这里（非凭据）
 *   - 绝不保存密码
 */
import { preferences } from '@kit.ArkData';
import { Context } from '@kit.AbilityKit';
import { Logger } from '../common/Logger';
import { ContextHolder } from '../common/ContextHolder';
import { SessionCookieStore } from './SessionCookieStore';
import { PREF_STORE, KEY_COOKIE, KEY_ACCOUNT, KEY_REMEMBER, KEY_LAST_SEMESTER,
  KEY_SEMESTER_START, KEY_WEEK_ALIGN_AT, KEY_WEEK_ALIGN_VALUE } from '../common/Constants';
export class PrefStore {
  private static store: preferences.Preferences | null = null;
  /**
   * 初始化中的 Promise。
   *
   * 这里必须共享同一个 Promise，而不是用「正在初始化」的布尔标志：
   * 启动时 EntryAbility.onCreate 会先发起初始化，紧接着页面 aboutToAppear
   * 就会读取会话。如果用布尔标志做重入保护，后者会「不等待」直接继续，
   * 此时 store 仍为 null，于是读到空值 —— 表现为每次冷启动都被判定为未登录。
   */
  private static initPromise: Promise<void> | null = null;

  /** 初始化本地存储；幂等，并发调用会等待同一次初始化完成 */
  static async init(): Promise<void> {
    if (PrefStore.store !== null) {
      return;
    }
    if (PrefStore.initPromise === null) {
      PrefStore.initPromise = PrefStore.doInit();
    }
    await PrefStore.initPromise;
  }

  private static async doInit(): Promise<void> {
    const ctx = ContextHolder.getAny();
    if (ctx === null) {
      // 上下文尚未注入：清掉 Promise，让后续调用可以重试
      Logger.warn('preferences init: context not ready, will retry');
      PrefStore.initPromise = null;
      return;
    }
    try {
      const opt: preferences.Options = { name: PREF_STORE };
      PrefStore.store = await preferences.getPreferences(ctx, opt);
      Logger.info('preferences ready');
    } catch (e) {
      // 失败也要允许重试，否则会永久退化为读不到数据
      Logger.error('preferences init failed, will retry');
      PrefStore.initPromise = null;
    }
  }

  /**
   * 同步读取一个字符串。
   *
   * 存在的唯一理由：FormExtensionAbility.onAddForm 必须**同步**返回绑定数据，
   * 没办法在里面 await 一个异步读取。这里用 preferences 的同步接口读同一份存储，
   * 保证与异步路径看到的是同一份数据。
   *
   * @param ctx 卡片使用 FormExtensionContext，与 UIAbilityContext 不是同一类型，
   *            因此由调用方传入，而不是复用 ContextHolder。
   */
  static readTextSync(ctx: Context, key: string): string {
    try {
      const opt: preferences.Options = { name: PREF_STORE };
      const store: preferences.Preferences = preferences.getPreferencesSync(ctx, opt);
      const v: preferences.ValueType = store.getSync(key, '');
      return typeof v === 'string' ? v : '';
    } catch (e) {
      Logger.warn('readTextSync failed for ' + key);
      return '';
    }
  }

  private static async getString(key: string, def: string): Promise<string> {
    await PrefStore.init();
    if (PrefStore.store === null) {
      return def;
    }
    try {
      const v: preferences.ValueType = await PrefStore.store.get(key, def);
      return typeof v === 'string' ? v : def;
    } catch (e) {
      return def;
    }
  }

  private static async put(key: string, value: string): Promise<void> {
    await PrefStore.init();
    if (PrefStore.store === null) {
      return;
    }
    try {
      await PrefStore.store.put(key, value);
      await PrefStore.store.flush();
    } catch (e) {
      Logger.error('preferences put failed: ' + key);
    }
  }

  /**
   * ==================== 会话 cookie（加密存储）====================
   *
   * 会话 cookie 是「持有即可用」的凭据，**不能**明文放在 preferences 里：
   * 实测 `hdc shell cat .../preferences/sdufe_jw_pref` 能直接读到原文，
   * 且本应用开启了系统备份（整个沙箱会被带走）。
   * 因此这三个方法改为走系统密钥库，详见 SessionCookieStore。
   *
   * 对外签名保持不变，调用方（AppState）无需改动。
   */

  static async saveCookie(cookie: string): Promise<void> {
    const ok: boolean = await SessionCookieStore.save(cookie);
    // 无论密钥库是否写成功，都要把 preferences 里的明文清掉 ——
    // 否则升级后旧明文会一直留着，等于没加固。
    await PrefStore.put(KEY_COOKIE, '');
    if (!ok) {
      // 密钥库不可用（极少数设备/权限异常）时降级写 preferences，
      // 保证「能登录」优先于「加密」：登录不了比明文存储更糟，
      // 而且降级路径只在密钥库故障时才会走到。
      await PrefStore.put(KEY_COOKIE, cookie);
      Logger.warn('session cookie fell back to plaintext storage');
    }
  }

  static async loadCookie(): Promise<string> {
    const fromKeystore: string = await SessionCookieStore.load();
    if (fromKeystore.length > 0) {
      return fromKeystore;
    }
    // 密钥库没有 → 可能是升级前留下的明文（老用户）。
    // 读到就顺手迁移，让明文尽早消失；迁移对用户无感。
    const legacy: string = await PrefStore.getString(KEY_COOKIE, '');
    if (legacy.length > 0) {
      Logger.info('migrating legacy plaintext session cookie to keystore');
      await PrefStore.saveCookie(legacy);
      return legacy;
    }
    return '';
  }

  static async clearCookie(): Promise<void> {
    await SessionCookieStore.remove();
    // 兼容降级路径写下的明文，一并清掉
    await PrefStore.put(KEY_COOKIE, '');
  }

  static async saveAccount(account: string): Promise<void> {
    await PrefStore.put(KEY_ACCOUNT, account);
  }

  static async loadAccount(): Promise<string> {
    return await PrefStore.getString(KEY_ACCOUNT, '');
  }

  /**
   * 清除「当前账号」。
   *
   * 退出登录时必须清掉：这个键是课表缓存分片的唯一依据
   * （缓存文件名是 `<账号>_<学期>.json`）。若留着 A 的账号，
   * B 登录前的那段空窗期里应用会拿 A 的账号去读缓存，
   * 于是 B 看到 A 的课表 —— 属于跨账号数据串号。
   */
  static async clearAccount(): Promise<void> {
    await PrefStore.put(KEY_ACCOUNT, '');
  }

  static async saveRemember(remember: boolean): Promise<void> {
    await PrefStore.put(KEY_REMEMBER, remember ? '1' : '0');
  }

  static async loadRemember(): Promise<boolean> {
    const v: string = await PrefStore.getString(KEY_REMEMBER, '1');
    return v === '1';
  }

  static async saveLastSemester(semester: string): Promise<void> {
    await PrefStore.put(KEY_LAST_SEMESTER, semester);
  }

  static async loadLastSemester(): Promise<string> {
    return await PrefStore.getString(KEY_LAST_SEMESTER, '');
  }

  /** 学期第 1 周周一（YYYY-MM-DD） */
  static async saveSemesterStart(dateText: string): Promise<void> {
    await PrefStore.put(KEY_SEMESTER_START, dateText);
  }

  static async loadSemesterStart(): Promise<string> {
    return await PrefStore.getString(KEY_SEMESTER_START, '');
  }

  /** 上次周次对齐的时刻（毫秒时间戳，字符串存储） */
  static async saveWeekAlignAt(ms: number): Promise<void> {
    await PrefStore.put(KEY_WEEK_ALIGN_AT, ms.toString());
  }

  static async loadWeekAlignAt(): Promise<number> {
    const v: string = await PrefStore.getString(KEY_WEEK_ALIGN_AT, '0');
    const n: number = parseInt(v, 10);
    return isNaN(n) ? 0 : n;
  }

  /** 上次对齐得到的周次 */
  static async saveWeekAlignValue(week: number): Promise<void> {
    await PrefStore.put(KEY_WEEK_ALIGN_VALUE, week.toString());
  }

  static async loadWeekAlignValue(): Promise<number> {
    const v: string = await PrefStore.getString(KEY_WEEK_ALIGN_VALUE, '0');
    const n: number = parseInt(v, 10);
    return isNaN(n) ? 0 : n;
  }

  /** 通用字符串项（用于记住各页面下拉的选择） */
  static async putText(key: string, value: string): Promise<void> {
    await PrefStore.put(key, value);
  }

  /**
   * 通用字符串项（用于记住各页面下拉的选择，以及各模块的一次性键）。
   *
   * [def] 可选：新增的调用方常需要「读不到时用某个默认值」，
   * 例如「周历自动拉取的日期」读不到就当作没拉过。
   * 老调用方不传，行为与以前完全一致。
   */
  static async getText(key: string, def: string = ''): Promise<string> {
    return await PrefStore.getString(key, def);
  }
}
